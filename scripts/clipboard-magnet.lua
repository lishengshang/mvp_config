local msg = require "mp.msg"

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decode_percent(s)
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function extract_magnet(text)
    if not text or text == "" then
        return nil
    end

    local raw = trim(text)
    if raw:find("^magnet:%?") == 1 then
        return raw
    end

    local lower = raw:lower()
    local pos = lower:find("magnet:%?", 1, true)
    if pos then
        return raw:sub(pos)
    end

    local enc_pos = lower:find("magnet%%3a%%3f", 1, true)
    if enc_pos then
        local decoded = decode_percent(raw:sub(enc_pos)):gsub("+", " ")
        if decoded:find("^magnet:%?") == 1 then
            return decoded
        end
    end

    return nil
end

local function load_magnet_from_clipboard()
    local clip = mp.get_property("clipboard/text")
    local magnet = extract_magnet(clip)
    if not magnet then
        mp.osd_message("剪贴板里没有磁力链接", 2)
        msg.warn("clipboard has no magnet URI")
        return
    end

    mp.commandv("loadfile", magnet, "replace")
    mp.osd_message("已载入磁力链接", 2)
end

mp.register_script_message("load-magnet-from-clipboard", load_magnet_from_clipboard)