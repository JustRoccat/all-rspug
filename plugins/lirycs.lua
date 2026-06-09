local TAB_ID = "lyrics"
local MAX_LINES = 700 -- change that if lyrics of played song are long asf


local cur_artist = ""
local cur_title = ""
local lyr_lines = {} -- 
local status = "idle" 
local status_msg = "Play a song to load lyrics"
local scroll_pos = 0

-- helpers here

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function urlencode(s)
    return (s:gsub("([^%w%-%.%_%~ ])", function(c)
        return ("%%%02X"):format(c:byte())
    end):gsub(" ", "%%20"))
end

local function split_lines(text)
    local t = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        t[#t + 1] = line
    end

    while #t > 0 and t[#t] == "" do
        t[#t] = nil
    end
    return t
end

-- extract lyrics from json 
local function extract_lyrics_value(json)
    local _, val_start = json:find('"lyrics"%s*:%s*"')
    if not val_start then
        return nil
    end
    val_start = val_start + 1 

    local buf = {}
    local i = val_start
    while i <= #json do
        local c = json:sub(i, i)
        if c == "\\" then
            local nxt = json:sub(i + 1, i + 1)
            if nxt == "n" then
                buf[#buf + 1] = "\n"
            elseif nxt == "r" then 
            elseif nxt == '"' then
                buf[#buf + 1] = '"'
            elseif nxt == "\\" then
                buf[#buf + 1] = "\\"
            elseif nxt == "t" then
                buf[#buf + 1] = "\t"
            else
                buf[#buf + 1] = nxt
            end
            i = i + 2
        elseif c == '"' then
            break 
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end

    if i > #json then
        return nil
    end 
    return table.concat(buf)
end



local function do_fetch(art, ttl)
    status = "loading"
    lyr_lines = {}
    scroll_pos = 0

    local url = ("https://api.lyrics.ovh/v1/%s/%s"):format(urlencode(art), urlencode(ttl)) 


    local cmd = ("curl -s --connect-timeout 4 --max-time 8 %q"):format(url)
    local handle = io.popen(cmd)
    if not handle then
        status = "error"
        status_msg = "err"
        return
    end

    local raw = handle:read("*a")
    handle:close()

    if not raw or raw == "" then
        status = "error"
        status_msg = "No response from lyrics.ovh"
        return
    end

    local lyrics_text = extract_lyrics_value(raw)
    if lyrics_text and #lyrics_text > 0 then
        lyr_lines = split_lines(lyrics_text)
        if #lyr_lines > MAX_LINES then
            for i = MAX_LINES + 1, #lyr_lines do
                lyr_lines[i] = nil
            end
            lyr_lines[#lyr_lines + 1] = "[lyrics cut]"
        end
        status = "done"
    else

        local err = raw:match('"error"%s*:%s*"(.-)"')
        status = "error"
        status_msg = err or "Lyrics not found"
    end
end



local function load_song(song)
    cur_title = trim(song.title or "")
    cur_artist = trim(song.artist or "")


    if cur_artist == "" and cur_title ~= "" then

        local a, t = cur_title:match("^(.-)%s+[%-%–—]+%s+(.+)$")
        if a and t then
            cur_artist = trim(a)
            cur_title = trim(t)
        end
    end

    if cur_artist ~= "" and cur_title ~= "" then
        do_fetch(cur_artist, cur_title)
    else
        status = "idle"
        -- POPRAWIONE: Zmiana konstrukcji stringa zapobiegająca błędowi składni
        status_msg = string.format("Can't identify song: %q", song.title or "?")
        lyr_lines = {}
        scroll_pos = 0
    end
end



return {


    on_tabs = function(_)
        return {
            { id = TAB_ID, title = "Lyrics", icon = "♪" },
        }
    end,


    on_song_start = function(song)
        load_song(song)
        return song 
    end,


    on_key = function(key, state)
        if state.active_plugin_tab ~= TAB_ID then
            return nil
        end

        local max_scroll = math.max(0, #lyr_lines - 5)

        if key == "down" or key == "char:j" then
            scroll_pos = math.min(scroll_pos + 3, max_scroll)
            return { consume = true }
        elseif key == "up" or key == "char:k" then
            scroll_pos = math.max(0, scroll_pos - 3)
            return { consume = true }
        elseif key == "char:g" then 
            scroll_pos = 0
            return { consume = true, flash = "↑ Początek" }
        elseif key == "char:G" then 
            scroll_pos = max_scroll
            return { consume = true, flash = "↓ Koniec" }
        elseif key == "char:r" then 
            if cur_artist ~= "" and cur_title ~= "" then
                do_fetch(cur_artist, cur_title)
                return { consume = true, flash = "Fetching lyrics..." }
            end
            return { consume = true, flash = "No song played" }
        end
    end,


    on_ui_panels = function(state)
        if state.active_plugin_tab ~= TAB_ID then
            return nil
        end


        local main = {}


        if cur_artist ~= "" or cur_title ~= "" then
            main[#main + 1] = { type = "option", key = "Artist", value = cur_artist ~= "" and cur_artist or "—" }
            main[#main + 1] = { type = "option", key = "Title", value = cur_title ~= "" and cur_title or "—" }
            main[#main + 1] = { type = "separator" }
        end


        if status == "idle" then
            main[#main + 1] = { type = "info", text = status_msg }
        elseif status == "loading" then
            main[#main + 1] = { type = "info", text = "Fetching lyrics" }
        elseif status == "error" then
            main[#main + 1] = { type = "info", text = "✗  " .. status_msg }
            main[#main + 1] = { type = "text", text = "Press r to try again" }
        else -- done
            for i = scroll_pos + 1, #lyr_lines do
                local ln = lyr_lines[i]
                if ln == "" then
                    main[#main + 1] = { type = "separator" }
                else
                    main[#main + 1] = { type = "text", text = ln }
                end
            end
        end


        local side = {
            { type = "stat", label = "Status", value = status },
            { type = "separator" },
            { type = "text", text = "↑ / k   go up" },
            { type = "text", text = "↓ / j   go down" },
            { type = "text", text = "g       go back to top" },
            { type = "text", text = "G       end of lyrics" },
            { type = "text", text = "r       refresh" },
        }

        if status == "done" and #lyr_lines > 0 then
            side[#side + 1] = { type = "separator" }
            side[#side + 1] = {
                type = "stat",
                label = "Line",
                value = (scroll_pos + 1) .. "/" .. #lyr_lines,
            }
        end

        return {
            { title = "♪ Lyrics", target = "results", items = main },
            { title = "Controls", target = "queue", items = side },
        }
    end,
}