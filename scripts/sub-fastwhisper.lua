--[[
    * sub-fastwhisper.lua
    *
    * AUTHORS: dyphire
    * License: MIT
    * link: https://github.com/dyphire/mpv-sub-fastwhisper
]]

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require "mp.options"

---- Script Options ----
local o = {
    -- Path to the faster-whisper executable, you can download it from here:
    -- https://github.com/Purfview/whisper-standalone-win
    -- Supports absolute and relative paths
    fast_whisper_path = "faster-whisper",
    -- Model to use, available models are: base, small，medium, large, large-v2, large-v3, turbo
    model = "base",
    -- Device to use, available devices are: cpu, cuda
    device = "cpu",
    -- Specify the language of transcription
    -- Leave it blank and it will be automatically detected
    language = "",
    -- Number of cpu threads to use
    -- Default value is 0 will auto-detect but max 4 threads
    threads = "0",
    -- The maximum number of characters in a line before breaking the line
    max_line_width = "100",
    -- Specify output path, supports absolute and relative paths
    -- Special value: "source" saves the subtitle file to the directory 
    -- where the video file is located
    output_path = "source",
    -- Specify how many subtitles are generated before updating
    -- to avoid frequent flickering of subtitles
    update_interval = 20,
    -- Uses segmentation for speech transcription, 
    -- which significantly improves the speed of subtitle initialization.
    -- but it will reduce the accuracy and overall speed of subtitle generation, 
    -- which is more suitable for long video scenarios.
    --! Depends on FFmpeg
    use_segment = false,
    -- Segment duration in seconds
    segment_duration = 10,
    -- Automatically translate generated subtitles when API is available
    auto_translate = true,
    -- Skip translation when the source subtitle is mostly Chinese
    skip_translate_if_chinese = true,
    -- Translation task debounce delay in seconds
    translate_delay = 2,
    -- Chinese detection threshold (0-1)
    chinese_ratio_threshold = 0.35,
    ---- GPT API Options ----
    -- Compatible with other AI API with the same structure as the GPT API
    api_url = "https://api.openai.com/v1/chat/completions",
    api_key = "",
    api_mode = "gpt-4o",
    api_temperature = 0.7,
    -- Timeout settings for API requests (seconds)
    api_connect_timeout = 10,
    api_timeout = 120,
    -- Optional debug log file path for raw API request/response troubleshooting
    -- Example: ~~/files/sub_fastwhisper_api.log
    api_debug_log = "",
    -- Rate per minute used by the API
    -- See the corresponding API documentation for instructions
    api_rate = 15,
    -- Translation target language
    translate = "Chinese",
    -- Specify the font to be used for the generated ass captions
    font_name = "sans-serif",
}

options.read_options(o, _, function() end)
------------------------

local fast_whisper_path = mp.command_native({ "expand-path", o.fast_whisper_path })
local output_path = mp.command_native({ "expand-path", o.output_path })
local pid = mp.get_property_native('pid')
local temp_path = os.getenv("TEMP") or "/tmp/"

local start_index = 1
local subtitle_count = 1
local append_subtitle_count = 1
local in_progress_batches = 0
local translated_batches_count = 0
local subtitles_written = false
local whisper_running = false
local gpt_api_enabled = false
local translation_in_progress = false
local translation_pending = false
local translation_timer_active = false
local pending_translation_file = nil
local state = {}
local time_ranges = {}
local progress_cache = {}
local translated_cache = {}

local is_windows = package.config:sub(1, 1) == "\\"

-- Persistent OSD Overlay
local status_overlay = mp.create_osd_overlay and mp.create_osd_overlay("ass-events") or nil
local status_timer = nil

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local function file_exists(path)
    if path then
        local meta = utils.file_info(path)
        return meta and meta.is_file
    end
    return false
end

local function is_writable(path)
    local file = io.open(path, "w")
    if file then
        file:close()
        os.remove(path)
        return true
    end
    return false
end

local function check_and_remove_empty_file(file_path)
    if file_exists(file_path) then
        local file = io.open(file_path, "r")
        if file then
            local content = file:read("*all")
            file:close()
            if content == "" then
                os.remove(file_path)
            end
        end
    end
end

local function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({"normalize-path", path})
        else
            local directory = mp.get_property("working-directory", "")
            path = utils.join_path(directory, path:gsub('^%.[\\/]',''))
            if is_windows then path = path:gsub("\\", "/") end
        end
        return path
    end

    normalize_path = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

local function is_text_identical(text1, text2)
    local function normalize_text(text)
        text = text:gsub("，", ",")
                  :gsub("。", ".")
                  :gsub("！", "!")
                  :gsub("？", "?")
                  :gsub("；", ";")
                  :gsub("：", ":")
                  :gsub("“", "\"")
                  :gsub("”", "\"")
                  :gsub("‘", "'")
                  :gsub("’", "'")
                  :gsub("（", "(")
                  :gsub("）", ")")
                  :gsub("【", "[")
                  :gsub("】", "]")
                  :gsub("《", "<")
                  :gsub("》", ">")
                  :gsub("、", "/")
                  :gsub("～", "~")

        text = text:gsub("[%p%s]", "")
        text = text:lower()
        return text
    end

    local clean_text1 = normalize_text(text1)
    local clean_text2 = normalize_text(text2)
    return clean_text1 == clean_text2
end

local function format_time(time_str)
    local h, m, s, ms = nil, nil, nil, nil
    if time_str:match("^%d+:%d+:%d+[%.:]%d+$") then
        h, m, s, ms = time_str:match("(%d+):(%d+):(%d+)[%.:](%d+)")
    elseif time_str:match("^%d+:%d+[%.:]%d+$") then
        h = 0
        m, s, ms = time_str:match("(%d+):(%d+)[%.:](%d+)")
    else
        return time_str
    end

    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

local function timestamp_to_seconds(timestamp)
    local h, m, s, ms = timestamp:match("(%d+):(%d+):(%d+),(%d+)")
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function seconds_to_timestamp(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds - math.floor(seconds)) * 1000)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

local function get_current_sub()
    local sub = mp.get_property_native("current-tracks/sub")
    if sub then
        if sub.external and not is_protocol(sub["external-filename"])
        and sub["external-filename"]:lower():match("%.srt$") then
            return sub["external-filename"]
        end
    end
    return nil
end

local function show_status_ass(text, duration)
    if status_timer then
        status_timer:kill()
        status_timer = nil
    end

    if not text or text == "" then
        if status_overlay then
            status_overlay.data = ""
            status_overlay.hidden = true
            status_overlay:update()
        else
            mp.set_osd_ass(0, 0, "")
        end
        return
    end

    -- \an7: top left, \fs10: font size
    local ass = "{\\an7}{\\fs10}{\\b1}{\\bord2}{\\3c&H000000&}{\\backc&H222222&}{\\xbord6}{\\ybord2}{\\q2}" .. text
    
    if status_overlay then
        status_overlay.res_x = 0
        status_overlay.res_y = 0
        status_overlay.z = 9999
        status_overlay.hidden = false
        status_overlay.data = ass
        status_overlay:update()
    else
        mp.set_osd_ass(0, 0, ass)
    end
    
    if duration and duration > 0 then
        status_timer = mp.add_timeout(duration, function()
            if status_overlay then
                status_overlay.data = ""
                status_overlay.hidden = true
                status_overlay:update()
            else
                mp.set_osd_ass(0, 0, "")
            end
            status_timer = nil
        end)
    end
end

local function extract_current_sub()
    local sub = mp.get_property_native("current-tracks/sub")
    if not sub then
        msg.warn("No subtitle track selected")
        show_status_ass("{\\1c&H0000FF&}Error: No subtitle track selected", 3)
        return nil
    end

    if sub.external and not is_protocol(sub["external-filename"])
    and sub["external-filename"]:lower():match("%.srt$") then
        msg.info("Subtitle is already an external SRT file: " .. sub["external-filename"])
        return sub["external-filename"]
    end

    local video_path = mp.get_property("path")
    if not video_path then 
        msg.warn("Could not get video path")
        return nil 
    end

    if is_protocol(video_path) then
        msg.warn("Cannot extract subtitles from protocol-based video: " .. video_path)
        show_status_ass("{\\1c&H0000FF&}Error: Cannot extract from URL", 3)
        return nil
    end

    local ff_index = nil
    local tracks = mp.get_property_native("track-list")
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id == sub.id then
            ff_index = track["ff-index"]
            break
        end
    end

    if not ff_index then
        msg.warn("Could not find ff-index for subtitle track (ID: " .. tostring(sub.id) .. ")")
        show_status_ass("{\\1c&H0000FF&}Error: Subtitle stream not found", 3)
        return nil
    end

    local dir, filename = utils.split_path(video_path)
    local fname = filename:match("(.+)%..-$") or filename
    local ext_srt = utils.join_path(dir, fname .. ".extracted.srt")
    
    show_status_ass("Extracting subtitles from video...")
    msg.info("Extracting subtitle track " .. ff_index .. " to " .. ext_srt)
    
    local args = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "error",
        "-i", video_path,
        "-map", "0:" .. ff_index,
        "-c:s", "srt",
        ext_srt
    }

    local res = mp.command_native({ name = "subprocess", capture_stdout = true, capture_stderr = true, args = args })
    if res and res.status == 0 and file_exists(ext_srt) then
        msg.info("Successfully extracted subtitles to: " .. ext_srt)
        return ext_srt
    end
    
    local err_msg = "FFmpeg extraction failed"
    if res and res.stderr then
        err_msg = err_msg .. ": " .. res.stderr
    end
    msg.error(err_msg)
    show_status_ass("{\\1c&H0000FF&}FFmpeg Error: Check Console", 3)
    return nil
end

local function check_sub(sub_file)
    local tracks = mp.get_property_native("track-list")
    local _, sub_title = utils.split_path(sub_file)
    for _, track in ipairs(tracks) do
        local external_filename = track["external-filename"]
        local track_title = track["title"]
        if external_filename then
            _, track_title = utils.split_path(external_filename)
        end

        if track["type"] == "sub" and track_title == sub_title then
            return true, track["id"]
        end
    end
    return false, nil
end

local function append_sub(sub_file, auto)
    local sub, id = check_sub(sub_file)
    if not sub then
        if auto then
            mp.commandv('sub-add', sub_file, 'auto')
        else
            mp.commandv('sub-add', sub_file)
        end
    else
        mp.commandv('sub-reload', id)
    end
end

local function parse_sub(filename)
    local subtitles = {}
    local file = io.open(filename, "r")
    if not file then return nil end

    local index, start_time, end_time, text
    for line in file:lines() do
        line = line:gsub("[\r\n]+", "")
        if line:match("^%d+$") then
            index = tonumber(line)
        elseif line:match("^%d%d:%d%d:%d%d,%d%d%d%s%-%->%s%d%d:%d%d:%d%d,%d%d%d$") then
            start_time, end_time = line:match("^(%d%d:%d%d:%d%d,%d%d%d)%s%-%->%s(%d%d:%d%d:%d%d,%d%d%d)$")
            start_time = start_time:gsub(",", "."):sub(1, -2)
            end_time = end_time:gsub(",", "."):sub(1, -2)
        elseif line:match("^%s*$") then
            if index and start_time and end_time and text then
                table.insert(subtitles, {index = index, start_time = start_time, end_time = end_time, text = text})
            end
            index, start_time, end_time, text = nil, nil, nil, nil
        else
            text = (text and text .. "\n" or "") .. line
        end
    end
    file:close()
    return subtitles
end

local function shift_subtitle_timestamps(temp_srt, srt_file, subtitle_count, start_time)
    local temp_file = io.open(temp_srt, "r")
    local main_file = io.open(srt_file, "a")

    if not temp_file or not main_file then
        msg.error("Failed to open temporary or main SRT file.")
        return subtitle_count
    end

    local subtitle_number = subtitle_count
    if subtitle_number == 1 then
        mp.osd_message("AI subtitles are loaded and updated in real time", 5)
        msg.info("AI subtitles are loaded and updated in real time")
    end
    for line in temp_file:lines() do
        if line:match("%d+:%d+:%d+,%d+%D+%d+:%d+:%d+,%d+") then
            local start_ts, end_ts = line:match("(%d+:%d+:%d+,%d+)%D+(%d+:%d+:%d+,%d+)")
            if start_ts and end_ts then
                local start_seconds = timestamp_to_seconds(start_ts) + start_time
                local end_seconds = timestamp_to_seconds(end_ts) + start_time
                main_file:write(subtitle_number .. "\n")
                main_file:write(seconds_to_timestamp(start_seconds) .. " --> " .. seconds_to_timestamp(end_seconds) .. "\n")
                subtitle_number = subtitle_number + 1
            end
        elseif line ~= "" and not tonumber(line) then
            main_file:write(line .. "\n")
        end
    end

    temp_file:close()
    main_file:close()

    os.remove(temp_srt)

    return subtitle_number
end

-- Merge two subtitles
local function merge_subtitles(sub1, sub2)
    local merged = {}
    local used1, used2 = {}, {}

    for i, s1 in ipairs(sub1) do
        for j, s2 in ipairs(sub2) do
            if not used1[i] and not used2[j] and s1.start_time == s2.start_time then
                table.insert(merged, {
                    start_time = s1.start_time,
                    end_time = s1.end_time or s2.end_time,
                    text = s1.text .. (s1.text ~= "" and s2.text ~= "" and "\n" or "") .. s2.text
                })
                used1[i] = true
                used2[j] = true
            end
        end
    end

    for i, s1 in ipairs(sub1) do
        if not used1[i] then
            table.insert(merged, {
                start_time = s1.start_time,
                end_time = s1.end_time,
                text = s1.text
            })
        end
    end

    for j, s2 in ipairs(sub2) do
        if not used2[j] then
            table.insert(merged, {
                start_time = s2.start_time,
                end_time = s2.end_time,
                text = s2.text
            })
        end
    end

    table.sort(merged, function(a, b)
        return a.start_time < b.start_time
    end)

    return merged
end

-- Generating ASS subtitles files
local function generate_ass(subtitles_file)
    local ass_name = string.format(".%s.ass", o.translate)
    local translated_file = subtitles_file:gsub("%.srt$", ".translate.srt")
    local merge_file = subtitles_file:gsub("%.srt$", ass_name)
    if file_exists(subtitles_file) and file_exists(translated_file) then
        local sub1 = parse_sub(translated_file)
        local sub2 = parse_sub(subtitles_file)
        if sub1 and sub2 then
            merged = merge_subtitles(sub1, sub2)

            if #merged == 0 then return end
        end
    end
    local file = io.open(merge_file, "w")
    if not file then return end
    file:write("[Script Info]\n")
    file:write("Title: Bilingual Subtitles\n")
    file:write("ScriptType: v4.00+\n")
    file:write("WrapStyle: 0\n")
    file:write("ScaledBorderAndShadow: yes\n")
    file:write("PlayResX: 1920\n")
    file:write("PlayResY: 1080\n")
    file:write("\n")
    file:write("[V4+ Styles]\n")
    file:write("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n")
    file:write("Style: Default,".. o.font_name .. ",70,&H00FFFFFF,&HF0000000,&H00000000,&H32000000,0,0,0,0,100,100,0,0.00,1,2,1,2,5,5,2,-1\n")
    file:write("\n")
    file:write("[Events]\n")
    file:write("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")

    for _, sub in pairs(merged) do
        local translate_text, original_text = sub.text:gsub("\n$", ""):match("^(.-)\n+(.*)$")
        if translate_text and original_text then
            translate_text = translate_text:gsub("^%s*(.-)%s*$", "%1")
            original_text = sanitize_subtitle_text(original_text)
            if is_text_identical(translate_text, original_text) then
                file:write(string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", sub.start_time, sub.end_time, translate_text))
            else
                file:write(string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s\n", sub.start_time, sub.end_time, translate_text ..
                '\\N{\\fn'.. o.font_name .. '}{\\b0}{\\fs50}{\\c&H62A8EB&}{\\shad1}' .. original_text))
            end
        end
    end

    file:close()
    append_sub(merge_file)
end

-------------Translation function----------------
local function is_mostly_chinese_subtitles(subtitles)
    local total_chars = 0
    local chinese_chars = 0

    for _, subtitle in ipairs(subtitles) do
        local text = subtitle.text or ""
        local compact = text:gsub("%s+", "")
        local chars = select(2, compact:gsub("[^\128-\193]", ""))
        local cjk = select(2, compact:gsub("[\228-\233][\128-\191][\128-\191]", ""))
        total_chars = total_chars + chars
        chinese_chars = chinese_chars + cjk
    end

    if total_chars == 0 then
        return false
    end

    local ratio = chinese_chars / total_chars
    return ratio >= o.chinese_ratio_threshold
end

local function write_api_debug_log(tag, content)
    if not o.api_debug_log or o.api_debug_log == "" then
        return
    end

    local log_path = mp.command_native({ "expand-path", o.api_debug_log })
    local file = io.open(log_path, "a")
    if not file then
        return
    end

    file:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), tag))
    file:write((content or "") .. "\n\n")
    file:close()
end

local function normalize_api_content(content)
    if type(content) == "string" then
        return content
    end

    if type(content) == "table" then
        local parts = {}
        for _, item in ipairs(content) do
            if type(item) == "string" then
                table.insert(parts, item)
            elseif type(item) == "table" and type(item.text) == "string" then
                table.insert(parts, item.text)
            end
        end

        if #parts > 0 then
            return table.concat(parts, "\n")
        end
    end

    return nil
end

local function parse_api_response(stdout, stderr)
    local raw = (stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        msg.warn("Empty API response")
        write_api_debug_log("api-empty-response", "STDERR:\n" .. (stderr or ""))
        return nil
    end

    local response = utils.parse_json(raw)
    if not response then
        local start_idx = raw:find("{", 1, true)
        local end_idx = raw:match(".*()}")
        if start_idx and end_idx and end_idx >= start_idx then
            response = utils.parse_json(raw:sub(start_idx, end_idx))
        end
    end

    if not response then
        msg.warn("Unable to parse API response")
        write_api_debug_log("api-parse-failed", "STDERR:\n" .. (stderr or "") .. "\nSTDOUT:\n" .. raw)
        return nil
    end

    if response.error then
        local error_msg = "Unknown API error"
        if type(response.error) == "table" and response.error.message then
            error_msg = tostring(response.error.message)
        elseif type(response.error) == "string" then
            error_msg = response.error
        end
        msg.warn("API error: " .. error_msg)
        write_api_debug_log("api-error", utils.format_json(response))
        return nil
    end

    if response.choices and #response.choices > 0 and response.choices[1].message then
        local content = normalize_api_content(response.choices[1].message.content)
        if content and content ~= "" then
            return content
        end
    end

    msg.warn("API response missing translatable content")
    write_api_debug_log("api-missing-content", utils.format_json(response))
    return nil
end

-- Call the GPT API
local function call_gpt_api(subtitles, callback)
    if not o.api_key or o.api_key == "" then
        msg.warn("API key is empty, skip translation")
        return nil
    end

    msg.info("AI subtitle translation in progress")
    local prompt = string.format("You are a professional translation assistant, " ..
    "Translate the following subtitles from the original language to %s. " ..
    "Keep the same number of lines, preserve each timestamp prefix, and output plain text only.", o.translate)

    local request_body = {
        messages = {
            {
                role = "system",
                content = prompt
            },
            {
                role = "user",
                content = subtitles
            }
        },
        model = o.api_mode,
        temperature = o.api_temperature,
        stream = false
    }

    local request_json = utils.format_json(request_body)
    write_api_debug_log("api-request", request_json)

    local command = {
        "curl", "-sS", "-X", "POST", o.api_url,
        "--connect-timeout", tostring(o.api_connect_timeout),
        "--max-time", tostring(o.api_timeout),
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-H", "Authorization: Bearer " .. o.api_key,
        "-d", request_json
    }

    if not callback then
        local result = mp.command_native({
            name = "subprocess",
            args = command,
            capture_stdout = true,
            capture_stderr = true,
        })

        if not result or result.status ~= 0 then
            msg.info("API request failed: " .. (result.stderr or "Unknown error"))
            write_api_debug_log("api-request-failed", "STATUS: " .. tostring(result and result.status or "nil") .. "\nSTDERR:\n" .. (result and result.stderr or ""))
            return nil
        end

        return parse_api_response(result.stdout, result.stderr)
    end

    local abort_signal
    abort_signal = mp.command_native_async({
        name = "subprocess",
        args = command,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result, error)
        if not success or result.status ~= 0 then
            msg.info("API request failed: " .. (result.stderr or "Unknown error"))
            write_api_debug_log("api-request-failed-async", "STATUS: " .. tostring(result and result.status or "nil") .. "\nSTDERR:\n" .. (result and result.stderr or ""))
            callback(nil)
            return
        end

        callback(parse_api_response(result.stdout, result.stderr))
    end)

    return function()
        mp.abort_async_command(abort_signal)
    end
end

-- Parse .srt file
local function parse_srt(file_path)
    local file = io.open(file_path, "r")
    if not file then
        msg.error("Unable to open file: " .. file_path)
        return nil
    end

    local subtitles = {}
    local current_entry = {}

    for line in file:lines() do
        line = line:gsub("[\r\n]+", "")

        if line:match("^%d+$") then
            if current_entry.text then
                table.insert(subtitles, current_entry)
            end
            current_entry = { id = line, timestamp = nil, text = nil }
        elseif line:match("^%d%d:%d%d:%d%d,%d%d%d%s*%-%-%>%s*%d%d:%d%d:%d%d,%d%d%d$") then
            current_entry.timestamp = line
        elseif line ~= "" then
            current_entry.text = (current_entry.text and current_entry.text .. "\n" or "") .. line
        end
    end

    if current_entry.text then
        table.insert(subtitles, current_entry)
    end

    file:close()
    return subtitles
end

local function sanitize_subtitle_text(text)
    if not text then
        return ""
    end

    local cleaned = text
        :gsub("<[^>]->", "") -- Remove HTML tags
        :gsub("{\\[^}]-}", "") -- Remove ASS tags
        :gsub("[\r\n]+", " ")
        :gsub("%s+", " ")
        :gsub("^%s*(.-)%s*$", "%1")

    return cleaned
end

local function sleep_seconds(seconds)
    if not seconds or seconds <= 0 then
        return
    end

    local ms = math.floor(seconds * 1000)
    if ms <= 0 then
        return
    end

    if is_windows then
        mp.command_native({
            name = "subprocess",
            args = { "cmd", "/c", "ping", "127.0.0.1", "-n", tostring(math.max(2, math.floor(seconds + 1))), ">", "nul" },
            capture_stdout = true,
            capture_stderr = true,
        })
    else
        mp.command_native({
            name = "subprocess",
            args = { "sh", "-c", "sleep " .. tostring(seconds) },
            capture_stdout = true,
            capture_stderr = true,
        })
    end
end

local function call_gpt_api_with_retry(batch_text, max_retries)
    local retries = max_retries or 2
    for attempt = 1, retries + 1 do
        local translated_text = call_gpt_api(batch_text)
        if translated_text and translated_text ~= "" then
            return translated_text
        end

        if attempt <= retries then
            local backoff = math.min(8, attempt * 2)
            msg.warn("API request failed, retrying in " .. backoff .. "s (attempt " .. attempt .. "/" .. retries .. ")")
            sleep_seconds(backoff)
        end
    end

    return nil
end

local function get_progress_bar(current, total)
    local bar_len = 10
    local filled = math.floor(current / total * bar_len)
    local bar = ""
    for i = 1, bar_len do
        if i <= filled then
            bar = bar .. "■"
        else
            bar = bar .. "□"
        end
    end
    return bar
end

-- Translate subtitles and write to file
local function translate_and_write(subtitles, subtitles_file)
    local batch_size = 20
    local max_calls_per_minute = o.api_rate
    local delay_between_calls = 60 / max_calls_per_minute
    local translated_file = subtitles_file:gsub("%.srt$", ".translate.srt")
    local total_batches = math.ceil(#subtitles / batch_size)

    if max_calls_per_minute <= 0 then
        max_calls_per_minute = 1
        delay_between_calls = 60
    end

    if file_exists(translated_file) then
        os.remove(translated_file)
    end

    local current_batch = 0
    for batch_start_index = 1, #subtitles, batch_size do
        current_batch = current_batch + 1
        local end_index = math.min(batch_start_index + batch_size - 1, #subtitles)
        local batch = {}

        local bar = get_progress_bar(current_batch, total_batches)
        local progress_msg = string.format("AI Translating: [%s] %d/%d (%.0f%%)", bar, current_batch, total_batches, current_batch/total_batches*100)
        show_status_ass(progress_msg)
        msg.info(progress_msg)

        for i = batch_start_index, end_index do
            local subtitle = subtitles[i]
            local cleaned_text = sanitize_subtitle_text(subtitle.text)
            table.insert(batch, subtitle.timestamp .. " | " .. cleaned_text)
            progress_cache[subtitle.timestamp] = true
        end

        local batch_text = table.concat(batch, "\n")
        local translated_text = call_gpt_api_with_retry(batch_text, 2)

        if not translated_text then
            local error_msg = string.format("{\\1c&H0000FF&}Translation Failed: Batch %d/%d", current_batch, total_batches)
            show_status_ass(error_msg, 5)
            msg.warn("Translation Failed: Batch " .. current_batch .. "/" .. total_batches .. ", fallback to original text")
            translated_text = batch_text
        end

        local translated_lines = {}
        for line in translated_text:gmatch("[^\r\n]+") do
            table.insert(translated_lines, line)
        end

        if #translated_lines ~= #batch then
            msg.warn("Mismatch: Original=" .. #batch .. ", Translated=" .. #translated_lines)
        end

        local file = io.open(translated_file, "a")
        if not file then
            msg.error("Unable to open file: " .. translated_file)
            return
        end

        local write_index = batch_start_index
        for i = 1, #batch do
            local translated_line = translated_lines[i] or ""
            local subtitle = subtitles[batch_start_index + i - 1]
            local text = translated_line:match("|%s*(.+)$") or translated_line

            if text then
                text = text:gsub("^%s*(.-)%s*$", "%1")
            end

            if not text or text == "" then
                text = sanitize_subtitle_text(subtitle.text)
            else
                text = sanitize_subtitle_text(text)
            end

            translated_cache[subtitle.timestamp] = text
            progress_cache[subtitle.timestamp] = nil

            file:write(write_index .. "\n")
            file:write(subtitle.timestamp .. "\n")
            file:write(text .. "\n\n")
            write_index = write_index + 1
        end

        file:close()

        translated_batches_count = translated_batches_count + 1
        msg.info("Translated and written batch: " .. batch_start_index .. " to " .. end_index)
        append_sub(translated_file)
        generate_ass(subtitles_file)

        if batch_start_index + batch_size <= #subtitles then
            sleep_seconds(delay_between_calls)
        end

    end

    msg.info("Subtitle translation completed!")
    show_status_ass("{\\1c&H00FF00&}Translation completed!", 3)
    append_sub(translated_file)
    generate_ass(subtitles_file)
    start_index = #subtitles + 1
end

-- Translate .srt file
local function translate_srt_file(subtitles_file)
    if not o.api_key or o.api_key == "" then
        msg.warn("API key is empty, skip translation")
        return
    end
    if not subtitles_file then
        show_status_ass("Detecting and extracting subtitles...")
        subtitles_file = extract_current_sub()
    end
    if not subtitles_file then
        show_status_ass("{\\1c&H0000FF&}Failed to extract subtitles", 3)
        return
    end

    -- Check if translated file already exists
    local translated_file = subtitles_file:gsub("%.srt$", ".translate.srt")
    local ass_name = string.format(".%s.ass", o.translate)
    local ass_file = subtitles_file:gsub("%.srt$", ass_name)

    if file_exists(ass_file) then
        msg.info("Translated ASS file already exists, loading it: " .. ass_file)
        show_status_ass("{\\1c&H00FF00&}Loading existing translation...", 2)
        append_sub(ass_file)
        return
    elseif file_exists(translated_file) then
        msg.info("Translated SRT file already exists, loading it: " .. translated_file)
        show_status_ass("{\\1c&H00FF00&}Loading existing translation...", 2)
        append_sub(translated_file)
        return
    end

    -- Parse the original subtitle file
    local subtitles = parse_srt(subtitles_file)
    if not subtitles then
        msg.error("Failed to parse .srt file")
        return
    end

    if o.skip_translate_if_chinese and is_mostly_chinese_subtitles(subtitles) then
        msg.info("Skip translation: subtitles appear to be Chinese")
        return
    end

    -- Start translating
    translate_and_write(subtitles, subtitles_file)
end

local function process_translation_queue()
    if not translation_pending or translation_in_progress then
        return
    end

    local subtitles_file = pending_translation_file
    if not subtitles_file or subtitles_file == "" then
        translation_pending = false
        return
    end

    translation_pending = false
    translation_in_progress = true
    translate_srt_file(subtitles_file)
    translation_in_progress = false

    if translation_pending and not translation_timer_active then
        translation_timer_active = true
        mp.add_timeout(o.translate_delay, function()
            translation_timer_active = false
            process_translation_queue()
        end)
    end
end

local function request_translation(subtitles_file, immediate)
    if not gpt_api_enabled or not o.auto_translate then
        return
    end

    pending_translation_file = subtitles_file
    translation_pending = true

    if immediate then
        process_translation_queue()
        return
    end

    if translation_in_progress or translation_timer_active then
        return
    end

    translation_timer_active = true
    mp.add_timeout(o.translate_delay, function()
        translation_timer_active = false
        process_translation_queue()
    end)
end
--------------------------------------------------

local function fastwhisper_cmd(file_path, sub_path)
    local args = {
        fast_whisper_path,
        file_path,
        "--beep_off",
        "--model", o.model,
        "--device", o.device,
        "--max_line_width", o.max_line_width,
        "--threads", o.threads,
        "--output_dir", sub_path,
    }

    if o.language ~= "" then
        table.insert(args, "--language")
        table.insert(args, o.language)
    end

    return args
end

local function fastwhisper()
    local path = mp.get_property("path")
    local fname = mp.get_property("filename/no-ext")
    if not path or is_protocol(path) then return end
    if path then
        path = normalize(path)
        dir = utils.split_path(path)
    end

    if output_path ~= "source" then
        subtitles_file = utils.join_path(output_path, fname .. ".srt")
    else
        subtitles_file = utils.join_path(dir, fname .. ".srt")
    end

    if file_exists(subtitles_file) then return end

    if not is_writable(subtitles_file) then
        subtitles_file = utils.join_path(temp_path, fname .. ".srt")
    end

    local screenx, screeny, aspect = mp.get_osd_size()
    mp.set_osd_ass(screenx, screeny, "{\\an9}● ")
    mp.osd_message("AI subtitle generation in progress", 9)
    msg.info("AI subtitle generation in progress")

    subtitle_count = 1
    append_subtitle_count = 1
    subtitles_written = false
    whisper_running = true

    local args = fastwhisper_cmd(path, output_path)
    mp.command_native_async({ name = "subprocess", capture_stderr = true, args = args }, function(success, res)
        whisper_running = false
        mp.set_osd_ass(screenx, screeny, "")
        if res.status ~= 0 then
            if file_exists(subtitles_file) then
                local file = io.open(subtitles_file, "r")
                if file then
                    local content = file:read("*all")
                    file:close()

                    if content == "" then
                        os.remove(subtitles_file)
                    else
                        mp.osd_message("AI subtitles successfully generated", 5)
                        msg.info("AI subtitles successfully generated")
                        append_sub(subtitles_file, true)
                        request_translation(subtitles_file, true)
                    end
                end
            end
        else
            mp.osd_message("AI subtitle generation failed, check console for more info.")
            msg.info("AI subtitle generation failed")
        end
    end)
end

mp.enable_messages('info')

mp.register_event('log-message', function(e)
    if e.prefix ~= mp.get_script_name() then return end

    local file = subtitles_file and io.open(subtitles_file, "a")
    if file and e.text and e.text ~= '' then
        local text_pattern = "%[([%d+:]?%d+:%d+%.%d+)%D+([%d+:]?%d+:%d+%.%d+)%]%s*(.*)"
        local start_time_srt, end_time_srt, subtitle_text = e.text:match(text_pattern)
        if start_time_srt and end_time_srt and subtitle_text then
            local start_time = format_time(start_time_srt)
            local end_time = format_time(end_time_srt)

            file:write(subtitle_count .. "\n")
            file:write(start_time .. " --> " .. end_time.. "\n")
            file:write(subtitle_text .. "\n")
            file:close()

            subtitle_count = subtitle_count + 1
            subtitles_written = true
        end
        if subtitle_count % o.update_interval == 1 and subtitles_written then
            if append_subtitle_count == 1 then
                mp.osd_message("AI subtitles are loaded and updated in real time", 5)
                msg.info("AI subtitles are loaded and updated in real time")
            end
            append_sub(subtitles_file)
            request_translation(subtitles_file, false)
            subtitles_written = false
            append_subtitle_count = append_subtitle_count + 1
        end
    end
end)
------------------------

local function extract_audio_segment(video_path, segment_audio_file, start_time, duration)
    local args = {
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel", "quiet",
        "-i", video_path,
        "-ss", tostring(start_time),
        "-t", tostring(duration),
        "-map", string.format("a:%s?", mp.get_property_number("current-tracks/audio/id", 0) - 1),
        "-vn",
        "-sn",
        -- Always re-encode segments to a valid wav stream for whisper input.
        "-c:a", "pcm_s16le",
        "-ac", "1",
        "-ar", "16000",
        segment_audio_file
    }

    local res = mp.command_native({ name = "subprocess", capture_stdout = true, capture_stderr = true, args = args })

    if res and res.status ~= 0 then
        msg.error("Error extracting audio segment: " .. segment_audio_file .. "\n" .. res.stderr)
        return false
    end
    msg.verbose("Successfully extracted: " .. segment_audio_file)
    return true
end

local function process_audio_segment(segment_audio_file, subtitle_count)
    local temp_srt_path = utils.split_path(segment_audio_file)
    local temp_srt = segment_audio_file:gsub("%.[^%.]+$", ".srt")

    local args = fastwhisper_cmd(segment_audio_file, temp_srt_path)
    local res = mp.command_native({ name = "subprocess", capture_stdout = true, capture_stderr = true, args = args })

    if res and res.status ~= 0 then
        msg.error("faster-whisper failed for: " .. segment_audio_file .. "\n" .. res.stderr)
    end

    return subtitle_count, temp_srt
end

local function process_video_incrementally(video_path, srt_file, segment_duration)
    local start_time = 0
    local subtitle_count = 1
    local segment_index = 1
    local temp_srt = nil
    local file_duration = mp.get_property_number('duration')

    while true do
        if start_time >= file_duration then
            break
        end
        if start_time + segment_duration > file_duration then
            segment_duration = file_duration - start_time
        end

        local segment_audio_file = utils.join_path(temp_path, "whisper-" .. pid .. ".wav")
        local temp_srt_file = utils.join_path(temp_path, "whisper-" .. pid .. ".srt")
        if file_exists(segment_audio_file) then
            os.remove(segment_audio_file)
        end
        if file_exists(temp_srt_file) then
            os.remove(temp_srt_file)
        end

        local start_time_str = string.format("%02d:%02d:%02d", math.floor(start_time / 3600), math.floor(start_time / 60) % 60, start_time % 60)
        msg.verbose(string.format("Extracting segment: %d, Start Time: %s", segment_index, start_time_str))

        local success = extract_audio_segment(video_path, segment_audio_file, start_time_str, segment_duration)
        if not success or not file_exists(segment_audio_file) then
            msg.verbose("Audio extraction completed or failed.")
            break
        end

        msg.verbose("Processing segment: " .. segment_audio_file)
        subtitle_count, temp_srt = process_audio_segment(segment_audio_file, subtitle_count)
        if file_exists(temp_srt) then
            subtitle_count = shift_subtitle_timestamps(temp_srt, srt_file, subtitle_count, start_time)
        end

        if file_exists(srt_file) then
            append_sub(srt_file)
            request_translation(srt_file, false)
        end

        start_time = start_time + segment_duration
        segment_index = segment_index + 1
    end
end

local function fastwhisper_segment()
    local path = mp.get_property("path")
    local fname = mp.get_property("filename/no-ext")
    if not path or is_protocol(path) then return end
    if path then
        path = normalize(path)
        dir = utils.split_path(path)
    end

    if output_path ~= "source" then
        subtitles_file = utils.join_path(output_path, fname .. ".srt")
    else
        subtitles_file = utils.join_path(dir, fname .. ".srt")
    end

    if file_exists(subtitles_file) then
        msg.info("Subtitles file already exists: " .. subtitles_file)
        return
    end

    if not is_writable(subtitles_file) then
        subtitles_file = utils.join_path(temp_path, fname .. ".srt")
    end

    mp.osd_message("AI subtitle generation in progress", 9)
    msg.info("AI subtitle generation in progress")

    whisper_running = true
    process_video_incrementally(path, subtitles_file, o.segment_duration)
    whisper_running = false

    if file_exists(subtitles_file) then
        mp.osd_message("AI subtitles successfully generated", 5)
        msg.info("AI subtitles successfully generated")
        append_sub(subtitles_file, true)
        request_translation(subtitles_file, true)
    end
end
------------------------

local function adjust_time_range(strat_time, end_time)
    for _, range in ipairs(time_ranges) do
        if not (end_time <= range.start or strat_time >= range.finish) then
            if strat_time >= range.start and end_time <= range.finish then
                return nil, nil
            end
            if strat_time < range.finish and end_time > range.start then
                if strat_time < range.finish then
                    strat_time = range.finish
                end
                if end_time > range.start then
                    end_time = range.start
                end
            end
        end
    end
    return strat_time, end_time
end

local function get_time_range(strat_time, end_time)
    local strat_time, end_time = adjust_time_range(strat_time, end_time)
    if strat_time and strat_time < end_time then
        return true, strat_time, end_time
    else
        return false
    end
end

local function fastwhisper_cache(current_pos, subtitle_count)
    local temp_video_file = utils.join_path(temp_path, "whisper-" .. pid .. ".mkv")
    local srt_file  = utils.join_path(temp_path, "whisper.srt")
    local file_duration = mp.get_property_number('duration')
    local cache_state = mp.get_property_native("demuxer-cache-state")
    local cache_ranges = cache_state and cache_state["seekable-ranges"] or {}
    local cache_start = cache_ranges[1] and cache_ranges[1]["start"] or current_pos
    local cache_end = cache_ranges[1] and cache_ranges[1]["end"] or current_pos

    if current_pos < cache_start or cache_start < state.pos then
        current_pos = cache_start
        state.pos = current_pos
    end

    if current_pos >= file_duration then
        if file_exists(srt_file) then
            append_sub(srt_file, true)
            request_translation(srt_file, true)
        end
        return
    end

    local valid_range, strat_time, end_time = get_time_range(current_pos, cache_end)
    if strat_time and end_time then
        current_pos = strat_time
        cache_end = end_time
    end

    if not valid_range or cache_end <= current_pos then
        mp.add_timeout(1, function() fastwhisper_cache(current_pos, subtitle_count) end)
        return
    end

    if subtitle_count == 0 then
        mp.osd_message("AI subtitle generation in progress", 9)
        msg.info("AI subtitle generation in progress")
        local files_to_remove = {
            temp_srt_file1 = utils.join_path(temp_path, "whisper.srt"),
            temp_srt_file2 = utils.join_path(temp_path, "whisper-" .. pid .. ".srt"),
            temp_srt_file3 = utils.join_path(temp_path, "whisper.translate.srt"),
            temp_srt_file4 = utils.join_path(temp_path, "whisper." .. o.translate .. ".ass")
        }

        for _, file in pairs(files_to_remove) do
            if file_exists(file) then
                os.remove(file)
            end
        end
    end

    whisper_running = true
    mp.commandv("dump-cache", math.ceil(current_pos), math.floor(cache_end), temp_video_file)
    local subtitle_number, temp_srt = process_audio_segment(temp_video_file, subtitle_count)
    whisper_running = false

    if file_exists(temp_srt) then
        subtitle_number = shift_subtitle_timestamps(temp_srt, srt_file, subtitle_number, current_pos)
    end

    if file_exists(srt_file) then
        subtitle_count = subtitle_count + 1
        append_sub(srt_file)
        request_translation(srt_file, false)
    end

    table.insert(time_ranges, {start = current_pos, finish = cache_end})
    table.sort(time_ranges, function(a, b) return a.start < b.start end)

    current_pos = cache_end

    -- Callback
    mp.add_timeout(1, function() fastwhisper_cache(current_pos, subtitle_count) end)
end
------------------------

local function whisper()
    if whisper_running then return end
    gpt_api_enabled = call_gpt_api("test") ~= nil and true or false
    local path =  mp.get_property_native("path")
    local cache = mp.get_property_native("cache")
    local cache_state = mp.get_property_native("demuxer-cache-state")
    local cache_ranges = cache_state and cache_state["seekable-ranges"] or {}
    if path and is_protocol(path) or cache == "auto" and #cache_ranges > 0 then
        time_ranges = {}
        local subtitle_count = 0
        local current_pos = mp.get_property_native("time-pos")
        local cache_start = cache_ranges[1]["start"]
        state.pos = cache_start or current_pos
        fastwhisper_cache(cache_start, subtitle_count)
        return
    end
    if o.use_segment then
        fastwhisper_segment()
    else
        fastwhisper()
    end
end

mp.add_hook("on_unload", 50, function()
    start_index = 1
    in_progress_batches = 0
    translated_batches_count = 0
    time_ranges = nil
    progress_cache = nil
    translated_cache = nil
    collectgarbage()
    time_ranges = {}
    progress_cache = {}
    translated_cache = {}
    translation_in_progress = false
    translation_pending = false
    translation_timer_active = false
    pending_translation_file = nil

    local temp_path = os.getenv("TEMP") or "/tmp/"
    local path = mp.get_property("path")
    local dir = utils.split_path(path)
    local filename = mp.get_property("filename/no-ext")
    local translated_file = utils.join_path(dir, filename .. ".translate.srt")
    local files_to_remove = {
        temp_video_file = utils.join_path(temp_path, "whisper-" .. pid .. ".mkv"),
        segment_audio_file = utils.join_path(temp_path, "whisper-" .. pid .. ".wav"),
        temp_srt_file1 = utils.join_path(temp_path, "whisper.srt"),
        temp_srt_file2 = utils.join_path(temp_path, "whisper-" .. pid .. ".srt"),
        temp_srt_file3 = utils.join_path(temp_path, "whisper.translate.srt"),
        temp_srt_file4 = utils.join_path(temp_path, "whisper." .. o.translate .. ".ass")
    }

    for _, file in pairs(files_to_remove) do
        if file_exists(file) then
            os.remove(file)
        end
    end

    check_and_remove_empty_file(subtitles_file)
    check_and_remove_empty_file(translated_file)
end)

mp.register_script_message("sub-translate", translate_srt_file)
mp.register_script_message("sub-fastwhisper", whisper)
