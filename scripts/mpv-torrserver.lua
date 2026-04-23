-- Install [Torrserver](https://github.com/YouROK/TorrServer)
-- then add "script-opts-append=mpv_torrserver-server=http://[TorrServer ip]:[port]" to mpv.conf
local utils = require 'mp.utils'

local opts = {
    server = "http://localhost:8090",
    torrserver_init = false,
    torrserver_path = "TorrServer",
    search_for_external_tracks = true
}

(require 'mp.options').read_options(opts)
local luacurl_available, cURL = pcall(require, 'cURL')

local is_windows = package.config:sub(1, 1) == "\\" -- detect path separator, windows uses backslashes

local function find_executable(name)
    if not name or name == "" then
        return nil
    end

    -- absolute/relative path provided directly
    local direct_meta = utils.file_info(name)
    if direct_meta and direct_meta.is_file then
        return name
    end

    local os_path = os.getenv("PATH") or ""
    local path_separator = is_windows and ";" or ":"
    local fallback_path = utils.join_path("/usr/bin", name)
    local exec_path
    for path in os_path:gmatch("[^" .. path_separator .. "]+") do
        exec_path = utils.join_path(path, name)
        local meta = utils.file_info(exec_path)
        if meta and meta.is_file then
            return exec_path
        end

        if is_windows and not name:lower():match("%.exe$") then
            local exe_path = exec_path .. ".exe"
            local exe_meta = utils.file_info(exe_path)
            if exe_meta and exe_meta.is_file then
                return exe_path
            end
        end
    end

    if not is_windows then
        local fallback_meta = utils.file_info(fallback_path)
        if fallback_meta and fallback_meta.is_file then
            return fallback_path
        end
    end

    return name -- fallback to just the name, hoping it's in PATH
end

local function init()
    local exec_path = find_executable(opts.torrserver_path)
    local args = { exec_path }
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        detach = true,
        capture_stdout = true,
        capture_stderr = true,
        args = args
    })

    if not res or res.status ~= 0 then
        local err = "unknown error"
        if res then
            err = res.stderr or res.error_string or ("status " .. tostring(res.status))
        end
        mp.msg.error("TorrServer failed to start: " .. err)
    else
        mp.msg.info("TorrServer start command sent: " .. exec_path)
    end
end

local char_to_hex = function(c)
  return string.format("%%%02X", string.byte(c))
end

local function urlencode(url)
  if url == nil then
    return
  end
  url = url:gsub("\n", "\r\n")
  url = url:gsub("([^%w ])", char_to_hex)
  url = url:gsub(" ", "+")
  return url
end

local function urldecode(url)
    if url == nil then
        return nil
    end
    url = url:gsub("+", " ")
    url = url:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return url
end

local function extract_btih(url)
    if not url or url == "" then
        return nil
    end

    local query = url:match("^magnet:%?(.*)$")
    if not query then
        return nil
    end

    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=?(.*)$")
        if key then
            local decoded_key = (urldecode(key) or ""):lower()
            if decoded_key == "xt" then
                local decoded_value = urldecode(value or "") or ""
                local btih = decoded_value:lower():match("^urn:btih:([a-z0-9]+)$")
                if btih and btih ~= "" then
                    return btih
                end
            end
        end
    end

    return nil
end

local function normalize_torrserver_link(url)
    local btih = extract_btih(url)
    if btih ~= nil then
        return btih, true
    end
    return url, false
end

local function has_magnet_payload(info)
    return type(info) == "table" and (info.file_stats ~= nil or info.name ~= nil or info.hash ~= nil or info.stat ~= nil)
end

local function get_magnet_info(url)
    local info_url = opts.server .. "/stream?stat&link=" .. urlencode(url)
    local res
    if not (luacurl_available) then
        -- if Lua-cURL is not available on this system
        local curl_cmd = {
            "curl",
            "-L",
            "--silent",
            "--max-time", "10",
            info_url
        }
        local cmd = mp.command_native {
            name = "subprocess",
            capture_stdout = true,
            playback_only = false,
            args = curl_cmd
        }
        res = cmd.stdout
    else
        -- otherwise use Lua-cURL (binding to libcurl)
        local buf = {}
        local c = cURL.easy_init()
        c:setopt_followlocation(1)
        c:setopt_url(info_url)
        c:setopt_writefunction(function(chunk)
            table.insert(buf, chunk);
            return true;
        end)
        c:perform()
        res = table.concat(buf)
    end
    if res and res ~= "" then
        return (require 'mp.utils').parse_json(res)
    else
        return nil, "no info response (timeout?)"
    end
end

local function extract_torrent_url(raw_url)
    if not raw_url or raw_url == "" then
        return nil
    end

    if raw_url:find("^magnet:") == 1 then
        return raw_url
    end

    if raw_url:find("^https?://") == 1 and raw_url:find("%.torrent$") ~= nil then
        return raw_url
    end

    -- Some open-file dialogs can pass "D:\\...\\magnet:?xt=..." as a local path.
    local magnet_pos = raw_url:find("magnet:%?", 1)
    if magnet_pos ~= nil then
        return raw_url:sub(magnet_pos)
    end

    -- Also handle encoded magnet URLs in case they are pasted as file-like strings.
    local encoded_magnet_pos = raw_url:lower():find("magnet%%3a%%3f", 1)
    if encoded_magnet_pos ~= nil then
        local encoded = raw_url:sub(encoded_magnet_pos)
        local decoded = urldecode(encoded)
        if decoded and decoded:find("^magnet:%?") == 1 then
            return decoded
        end
    end

    return nil
end

local function edlencode(url)
    return "%" .. string.len(url) .. "%" .. url
end

local function guess_type_by_extension(ext)
    if ext == "mkv" or ext == "mp4" or ext == "avi" or ext == "wmv" or ext == "vob" or ext == "m2ts" or ext == "ogm" then
        return "video"
    end
    if ext == "mka" or ext == "mp3" or ext == "aac" or ext == "flac" or ext == "ogg" or ext == "wma" or ext == "mpg"
            or ext == "wav" or ext == "wv" or ext == "opus" or ext == "ac3" then
        return "audio"
    end
    if ext == "ass" or ext == "srt" or ext == "vtt" then
        return "sub"
    end
    return "other";
end

local function string_replace(str, match, replace)
    local s, e = string.find(str, match, 1, true)
    if s == nil or e == nil then
        return str
    end
    return string.sub(str, 1, s - 1) .. replace .. string.sub(str, e + 1)
end

-- https://github.com/mpv-player/mpv/blob/master/DOCS/edl-mpv.rst
local function generate_m3u(link_value, files)
    for _, fileinfo in ipairs(files) do
        -- strip top directory
        if fileinfo.path:find("/", 1, true) then
            fileinfo.fullpath = string.sub(fileinfo.path, fileinfo.path:find("/", 1, true) + 1)
        else
            fileinfo.fullpath = fileinfo.path
        end
        fileinfo.path = {}
        for w in fileinfo.fullpath:gmatch("([^/]+)") do table.insert(fileinfo.path, w) end
        local ext = string.match(fileinfo.path[#fileinfo.path], "%.(%w+)$")
        fileinfo.type = guess_type_by_extension(ext)
    end
    table.sort(files, function(a, b)
        -- make top-level files appear first in the playlist
        if (#a.path == 1 or #b.path == 1) and #a.path ~= #b.path then
            return #a.path < #b.path
        end
        -- make videos first
        if (a.type == "video" or b.type == "video") and a.type ~= b.type then
            return a.type == "video"
        end
        -- otherwise sort by path
        return a.fullpath < b.fullpath
    end);

    local infohash = urlencode(link_value)

    local playlist = { '#EXTM3U' }

    for _, fileinfo in ipairs(files) do
        if fileinfo.processed ~= true then
            table.insert(playlist, '#EXTINF:0,' .. fileinfo.fullpath)
            local basename = string.match(fileinfo.path[#fileinfo.path], '^(.+)%.%w+$')

            local url = opts.server .. "/stream/" .. urlencode(fileinfo.fullpath) .."?play&index=" .. fileinfo.id .. "&link=" .. infohash
            local hdr = { "!new_stream", "!no_clip",
                          --"!track_meta,title=" .. edlencode(basename),
                          edlencode(url)
            }
            local edl = "edl://" .. table.concat(hdr, ";") .. ";"
            local external_tracks = 0

            fileinfo.processed = true
            if opts.search_for_external_tracks and basename ~= nil and fileinfo.type == "video" then
                mp.msg.info("!" .. basename)

                for _, fileinfo2 in ipairs(files) do
                    if #fileinfo2.path > 0 and
                            fileinfo2.type ~= "other" and
                            fileinfo2.processed ~= true and
                            string.find(fileinfo2.path[#fileinfo2.path], basename, 1, true) ~= nil
                    then
                        mp.msg.info("->" .. fileinfo2.fullpath)
                        local title = string_replace(fileinfo2.fullpath, basename, "%")
                        local url = opts.server .. "/stream/" .. urlencode(fileinfo2.fullpath).."?play&index=" .. fileinfo2.id .. "&link=" .. infohash
                        local hdr = { "!new_stream", "!no_clip", "!no_chapters",
                                      "!delay_open,media_type=" .. fileinfo2.type,
                                      "!track_meta,title=" .. edlencode(title),
                                      edlencode(url)
                        }
                        edl = edl .. table.concat(hdr, ";") .. ";"
                        fileinfo2.processed = true
                        external_tracks = external_tracks + 1
                    end
                end
            end
            if external_tracks == 0 then -- dont use edl
                table.insert(playlist, url)
            else
                table.insert(playlist, edl)
            end
        end
    end
    return table.concat(playlist, '\n')
end

mp.add_hook("on_load", 5, function()
    local raw_url = mp.get_property("stream-open-filename")
    local url = extract_torrent_url(raw_url)
    if url ~= nil then
        mp.set_property_bool("file-local-options/ytdl", false)
        -- Magnet/remote torrent URLs are not regular local files; disable watch-later mtime logic for this entry.
        mp.set_property_bool("file-local-options/save-position-on-quit", false)
        mp.set_property_bool("file-local-options/resume-playback-check-mtime", false)
        if opts.torrserver_init then init() end
        local link_value, is_btih = normalize_torrserver_link(url)
        local magnet_info, err = get_magnet_info(link_value)

        -- For unseen torrents, BTIH-only stat may be insufficient on some setups.
        -- Retry once with the original magnet/.torrent URL to bootstrap metadata.
        if is_btih and not has_magnet_payload(magnet_info) then
            magnet_info, err = get_magnet_info(url)
        end

        if type(magnet_info) == "table" then
            if magnet_info.file_stats then
                -- torrent has multiple files. open as playlist
                mp.set_property("stream-open-filename", "memory://" .. generate_m3u(link_value, magnet_info.file_stats))
                return
            end
            -- if not a playlist and has a name
            if magnet_info.name then
                mp.set_property("stream-open-filename", "memory://#EXTM3U\n" ..
                        "#EXTINF:0," .. magnet_info.name .. "\n" ..
                        opts.server .. "/stream?play&index=1&link=" .. urlencode(link_value))
                return
            end
        else
            mp.msg.warn("error: " .. err)
        end
        mp.set_property("stream-open-filename", opts.server .. "/stream?m3u&link=" .. urlencode(link_value))
    end
end)
