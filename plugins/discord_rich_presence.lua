local CLIENT_ID = "1500615661947195433"
local APP_NAME = "rs-pug"

local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
local state_file = runtime_dir .. "/rs-pug-discord-rpc-state.json"
local helper_file = runtime_dir .. "/rs-pug-discord-rpc-helper.py"
local pid_file = runtime_dir .. "/rs-pug-discord-rpc-helper.pid"
local parent_pid_file = runtime_dir .. "/rs-pug-discord-rpc-parent.pid"

local current_title = nil
local current_artist = nil
local current_player_state = "stopped"
local started_at = nil
local helper_started = false

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_track_title(value)
	value = trim(value)
	local artist, title = value:match("^(.-)%s+%-%s+(.*)$")
	if artist and title and trim(artist) ~= "" and trim(title) ~= "" then
		return trim(title), trim(artist)
	end
	return value, nil
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function json_escape(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\")
	value = value:gsub('"', '\\"')
	value = value:gsub("\b", "\\b")
	value = value:gsub("\f", "\\f")
	value = value:gsub("\n", "\\n")
	value = value:gsub("\r", "\\r")
	value = value:gsub("\t", "\\t")
	return value
end

local function write_file(path, content)
	local file = io.open(path, "w")
	if not file then
		return false
	end

	file:write(content)
	file:close()
	return true
end

local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end

	local content = file:read("*a")
	file:close()
	return content
end

local function get_own_pid()
	local stat = io.open("/proc/self/stat", "r")
	if stat then
		local content = stat:read("*l")
		stat:close()
		local pid = content and content:match("^(%d+)")
		if pid then
			return pid
		end
	end

	local handle = io.popen("echo $PPID")
	if handle then
		local pid = handle:read("*l")
		handle:close()
		if pid then
			pid = pid:match("^(%d+)")
			if pid then
				return pid
			end
		end
	end

	return nil
end

local function write_parent_pid()
	local pid = get_own_pid()
	if pid then
		write_file(parent_pid_file, pid)
	end
end

local helper_source = [==[
#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys
import time
import uuid

CLIENT_ID = sys.argv[1]
STATE_FILE = sys.argv[2]
PID_FILE = sys.argv[3]
PARENT_PID_FILE = sys.argv[4]

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None

def write_pid():
    try:
        with open(PID_FILE, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
    except Exception:
        pass

def discord_socket_paths():
    bases = []
    if os.getenv("XDG_RUNTIME_DIR"):
        bases.append(os.getenv("XDG_RUNTIME_DIR"))
    bases.extend(["/run/user/%s" % os.getuid(), "/tmp"])

    seen = set()
    for base in bases:
        if not base or base in seen:
            continue
        seen.add(base)
        for index in range(10):
            yield os.path.join(base, "discord-ipc-%d" % index)

def encode_packet(opcode, payload):
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return struct.pack("<II", opcode, len(raw)) + raw

def send_packet(sock, opcode, payload):
    sock.sendall(encode_packet(opcode, payload))

def recv_packet(sock):
    header = sock.recv(8)
    if len(header) < 8:
        raise ConnectionError("Discord IPC closed")
    opcode, length = struct.unpack("<II", header)
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise ConnectionError("Discord IPC closed")
        body += chunk
    return opcode, json.loads(body.decode("utf-8"))

def connect():
    last_error = None
    for path in discord_socket_paths():
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
            send_packet(sock, 0, {"v": 1, "client_id": CLIENT_ID})
            recv_packet(sock)
            return sock
        except Exception as exc:
            last_error = exc
            try:
                sock.close()
            except Exception:
                pass
    raise ConnectionError(last_error or "Discord IPC socket not found")

def build_activity(state):
    player_state = state.get("player_state") or "stopped"
    title = state.get("title") or ""
    artist = state.get("artist") or ""

    if player_state == "playing" and title:
        activity = {
            "details": title[:128],
            "assets": {"large_text": "rs-pug"},
            "instance": False,
        }
        if artist:
            activity["state"] = artist[:128]
        started_at = int(state.get("started_at") or 0)
        if started_at > 0:
            activity["timestamps"] = {"start": started_at}
        return activity

    if player_state == "paused" and title:
        activity = {
            "details": title[:128],
            "assets": {"large_text": "rs-pug"},
            "instance": False,
        }
        if artist:
            activity["state"] = artist[:128]
        return activity
    return None

def set_activity(sock, state):
    activity = build_activity(state)
    payload = {
        "cmd": "SET_ACTIVITY",
        "args": {
            "pid": os.getpid(),
            "activity": activity,
        },
        "nonce": str(uuid.uuid4()),
    }
    send_packet(sock, 1, payload)
    recv_packet(sock)

def clear_activity(sock):
    payload = {
        "cmd": "SET_ACTIVITY",
        "args": {
            "pid": os.getpid(),
            "activity": None,
        },
        "nonce": str(uuid.uuid4()),
    }
    send_packet(sock, 1, payload)
    recv_packet(sock)

def read_target_pid():
    try:
        with open(PARENT_PID_FILE, "r", encoding="utf-8") as handle:
            raw = handle.read().strip()
        if raw:
            return int(raw)
    except Exception:
        return None
    return None

def process_alive(pid):
    return pid is not None and os.path.exists("/proc/%d" % pid)

def main():
    write_pid()
    sock = None
    last_payload = None
    last_connect_attempt = 0

    while True:
        target_pid = read_target_pid()
        if not process_alive(target_pid):
            break

        state = read_json(STATE_FILE) or {}
        payload = json.dumps(state, sort_keys=True, separators=(",", ":"))

        if sock is None and time.time() - last_connect_attempt >= 5:
            last_connect_attempt = time.time()
            try:
                sock = connect()
                last_payload = None
            except Exception:
                sock = None

        if sock is not None and payload != last_payload:
            try:
                set_activity(sock, state)
                last_payload = payload
            except Exception:
                try:
                    sock.close()
                except Exception:
                    pass
                sock = None

        try:
            time.sleep(2)
        except Exception:
            break

    try:
        if sock is not None:
            clear_activity(sock)
            sock.close()
    except Exception:
        pass

    for path in (STATE_FILE, PID_FILE, ):
        try:
            os.remove(path)
        except Exception:
            pass

    try:
        os.remove(PARENT_PID_FILE)
    except Exception:
        pass

    try:
        os.remove(__file__)
    except Exception:
        pass

if __name__ == "__main__":
    main()
]==]

local function helper_is_running()
	local pid = read_file(pid_file)
	if not pid then
		return false
	end

	pid = pid:match("^(%d+)")
	if not pid then
		return false
	end

	local ok = os.execute("kill -0 " .. pid .. " >/dev/null 2>&1")
	return ok == true or ok == 0
end

local function ensure_helper()
	write_file(helper_file, helper_source)

	write_parent_pid()

	if helper_started or helper_is_running() then
		helper_started = true
		return
	end

	local command = "python3 "
		.. shell_quote(helper_file)
		.. " "
		.. shell_quote(CLIENT_ID)
		.. " "
		.. shell_quote(state_file)
		.. " "
		.. shell_quote(pid_file)
		.. " "
		.. shell_quote(parent_pid_file)
		.. " >/dev/null 2>&1 &"

	os.execute(command)
	helper_started = true
end

local function update_presence(state)
	if state then
		current_player_state = state.player_state or current_player_state
	end

	if current_player_state == "playing" and not started_at then
		started_at = os.time()
	elseif current_player_state ~= "playing" then
		started_at = nil
	end

	local json = "{"
		.. '"app":"'
		.. json_escape(APP_NAME)
		.. '",'
		.. '"title":"'
		.. json_escape(current_title or "")
		.. '",'
		.. '"artist":"'
		.. json_escape(current_artist or "")
		.. '",'
		.. '"player_state":"'
		.. json_escape(current_player_state)
		.. '",'
		.. '"started_at":'
		.. tostring(tonumber(started_at) or 0)
		.. "}"

	write_file(state_file, json)
	ensure_helper()
end

return {
	on_song_start = function(song)
		if song then
			current_title = song.title or song.track_title or song.name or song.webpage_url or current_title

			current_artist = song.uploader or song.artist or song.creator or song.album_artist or nil

			if current_title and not current_artist then
				local split_title, split_artist = split_track_title(current_title)
				current_title = split_title
				current_artist = split_artist
			end
			current_player_state = "playing"
			started_at = os.time()
			update_presence()
			return song
		end
	end,

	on_event = function(event, state)
		if state then
			current_player_state = state.player_state or current_player_state
		end

		if event and event.kind == "started" and event.message then
			current_title = event.message

			current_artist = nil
			local split_title, split_artist = split_track_title(current_title)
			current_title = split_title
			current_artist = split_artist
			current_player_state = "playing"
			started_at = os.time()
		elseif event and event.kind == "player_state" and event.value then
			current_player_state = event.value
			if current_player_state ~= "playing" then
				current_title = nil
				current_artist = nil
			end
		end

		update_presence(state)
	end,

	on_key = function(key, state)
		update_presence(state)
	end,
}
