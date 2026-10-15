local LOVE_KEY = "char:l"
local TAB_ID = "lastfm"
local HELPER_CHECK_SECS = 15
local STATUS_CACHE_SECS = 10

local helper_source = [==[
#!/usr/bin/env python3
import hashlib
import json
import os
import re
import signal
import sys
import time
import urllib.parse
import urllib.request

APP = "rs-pug-lastfm"
API_URL_DEFAULT = "https://ws.audioscrobbler.com/2.0/"
AUTH_PAGE = "https://www.last.fm/api/auth/"
USER_AGENT = "rs-pug-lastfm/1.0"
HTTP_TIMEOUT = 20
POLL_SECS = 2
BATCH_MAX = 50
CONFIG_MODE = 0o600
LOG_ROTATE_BYTES = 200 * 1024


class TransientError(Exception):
    pass


class AuthNeededError(Exception):
    pass


class FatalError(Exception):
    pass


def runtime_dir():
    override = os.environ.get("RS_PUG_LASTFM_RUNTIME_DIR")
    if override:
        return override
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return base


def config_dir():
    override = os.environ.get("RS_PUG_LASTFM_CONFIG_DIR")
    if override:
        return override
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    return os.path.join(base, "rs-pug")


def paths():
    run = runtime_dir()
    cfg = config_dir()
    return {
        "state": os.path.join(run, "rs-pug-lastfm-state.json"),
        "status": os.path.join(run, "rs-pug-lastfm-status.json"),
        "pid": os.path.join(run, "rs-pug-lastfm-helper.pid"),
        "parent_pid": os.path.join(run, "rs-pug-lastfm-parent.pid"),
        "self": os.path.join(run, "rs-pug-lastfm-helper.py"),
        "config": os.path.join(cfg, "lastfm.toml"),
        "queue": os.path.join(cfg, "lastfm-queue.json"),
        "log": os.path.join(cfg, "lastfm.log"),
    }


DEFAULT_CONFIG = {
    "api_key": "",
    "api_secret": "",
    "session_key": "",
    "username": "",
    "password": "",
    "enabled": True,
    "offline": False,
    "api_url": API_URL_DEFAULT,
}


def _parse_simple_toml(text):
    found = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(
            r'^([A-Za-z_][\w]*)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|(true|false|-?\d+))\s*(?:#.*)?$',
            line,
        )
        if not match:
            continue
        key, quoted, squoted, bare = match.groups()
        if quoted is not None:
            found[key] = quoted
        elif squoted is not None:
            found[key] = squoted
        elif bare in ("true", "false"):
            found[key] = bare == "true"
        else:
            found[key] = int(bare)
    return found


def load_config(path):
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return cfg
    try:
        import tomllib

        parsed = tomllib.loads(text)
        if isinstance(parsed, dict):
            for key in cfg:
                if key in parsed:
                    cfg[key] = parsed[key]
            return cfg
    except Exception:
        pass
    for key, value in _parse_simple_toml(text).items():
        if key in cfg:
            cfg[key] = value
    return cfg


def save_config_values(path, updates, remove=()):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        lines = []
    seen = set()
    out = []
    for line in lines:
        match = re.match(r"^(\s*)([A-Za-z_][\w]*)(\s*=.*)$", line)
        if match and not line.strip().startswith("#"):
            key = match.group(2)
            if key in remove:
                continue
            if key in updates:
                value = updates[key]
                rendered = (
                    "true"
                    if value is True
                    else "false"
                    if value is False
                    else str(value)
                    if isinstance(value, int)
                    else '"%s"' % str(value).replace('"', "")
                )
                out.append("%s = %s" % (key, rendered))
                seen.add(key)
                continue
        out.append(line)
    for key in updates:
        if key not in seen and key not in remove:
            value = updates[key]
            rendered = (
                "true"
                if value is True
                else "false"
                if value is False
                else str(value)
                if isinstance(value, int)
                else '"%s"' % str(value).replace('"', "")
            )
            out.append("%s = %s" % (key, rendered))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")
    os.replace(tmp, path)
    try:
        os.chmod(path, CONFIG_MODE)
    except OSError:
        pass


def md5hex(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def sign(params, secret):
    ordered = sorted(params.items())
    base = "".join(key + value for key, value in ordered) + secret
    return md5hex(base)


def _raise_for_api_error(payload):
    if isinstance(payload, dict) and "error" in payload:
        code = int(payload.get("error") or 0)
        message = str(payload.get("message") or "unknown Last.fm error")
        if code == 9:
            raise AuthNeededError("%s (%d)" % (message, code))
        if code in (11, 16):
            raise TransientError("%s (%d)" % (message, code))
        raise FatalError("%s (%d)" % (message, code))


def http_call(api_url, params, method="POST"):
    body = urllib.parse.urlencode(params, doseq=True).encode("utf-8")
    if method == "GET":
        url = api_url + "?" + body.decode("utf-8")
        request = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT}
        )
    else:
        request = urllib.request.Request(
            api_url,
            data=body,
            headers={
                "User-Agent": USER_AGENT,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            },
        )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            raw = response.read().decode("utf-8", "replace")
            status = getattr(response, "status", 200)
    except urllib.error.HTTPError as exc:
        try:
            raw = exc.read().decode("utf-8", "replace")
        except Exception:
            raw = ""
        status = exc.code
        if status >= 500:
            raise TransientError("HTTP %d" % status)
        try:
            _raise_for_api_error(json.loads(raw) if raw else {})
        except (TransientError, AuthNeededError, FatalError):
            raise
        raise FatalError("HTTP %d %s" % (status, raw[:200]))
    except Exception as exc:
        raise TransientError(str(exc))
    try:
        payload = json.loads(raw) if raw else {}
    except ValueError as exc:
        raise TransientError("bad JSON response: %s" % exc)
    _raise_for_api_error(payload)
    return payload


def authed_params(cfg, extra):
    params = {"api_key": cfg["api_key"], "sk": cfg["session_key"]}
    params.update(extra)
    params["api_sig"] = sign(params, cfg["api_secret"])
    params["format"] = "json"
    return params


def check_credentials(cfg):
    if not cfg["api_key"] or not cfg["api_secret"]:
        raise FatalError(
            "missing api_key/api_secret in lastfm.toml "
            "(create them at https://www.last.fm/api/account/create)"
        )


def api_request_token(cfg):
    check_credentials(cfg)
    params = {"method": "auth.getToken", "api_key": cfg["api_key"]}
    params["api_sig"] = sign(params, cfg["api_secret"])
    params["format"] = "json"
    payload = http_call(cfg["api_url"], params, method="GET")
    token = payload.get("token")
    if not token:
        raise FatalError("auth.getToken returned no token: %r" % (payload,))
    return token


def api_request_session(cfg, token):
    check_credentials(cfg)
    params = {
        "method": "auth.getSession",
        "api_key": cfg["api_key"],
        "token": token,
    }
    params["api_sig"] = sign(params, cfg["api_secret"])
    params["format"] = "json"
    payload = http_call(cfg["api_url"], params, method="GET")
    session = payload.get("session") or {}
    if not session.get("key"):
        raise FatalError("auth.getSession returned no key: %r" % (payload,))
    return {"name": session.get("name", ""), "key": session["key"]}


def api_mobile_session(cfg):
    check_credentials(cfg)
    if not cfg["username"] or not cfg["password"]:
        raise FatalError("username/password required in lastfm.toml")
    params = {
        "method": "auth.getMobileSession",
        "api_key": cfg["api_key"],
        "username": cfg["username"],
        "password": cfg["password"],
    }
    params["api_sig"] = sign(params, cfg["api_secret"])
    params["format"] = "json"
    payload = http_call(cfg["api_url"], params, method="POST")
    session = payload.get("session") or {}
    if not session.get("key"):
        raise FatalError("auth.getMobileSession returned no key: %r" % (payload,))
    return {"name": session.get("name", ""), "key": session["key"]}


def api_now_playing(cfg, artist, track, album="", duration=0):
    extra = {"method": "track.updateNowPlaying", "artist": artist, "track": track}
    if album:
        extra["album"] = album
    if duration and duration > 0:
        extra["duration"] = str(int(duration))
    params = authed_params(cfg, extra)
    payload = http_call(cfg["api_url"], params, method="POST")
    nowplaying = (payload.get("nowplaying") or {})
    ignored = (nowplaying.get("ignoredMessage") or {})
    return str(ignored.get("code", "0")), str(ignored.get("#text", ""))


def api_scrobble(cfg, entries):
    params = {"method": "track.scrobble"}
    for index, entry in enumerate(entries):
        params["artist[%d]" % index] = entry["artist"]
        params["track[%d]" % index] = entry["track"]
        params["timestamp[%d]" % index] = str(int(entry["timestamp"]))
        if entry.get("album"):
            params["album[%d]" % index] = entry["album"]
        if entry.get("duration"):
            params["duration[%d]" % index] = str(int(entry["duration"]))
    params = authed_params(cfg, params)
    payload = http_call(cfg["api_url"], params, method="POST")
    block = payload.get("scrobbles") or {}
    attr = block.get("@attr") or {}
    accepted = int(attr.get("accepted", 0))
    ignored = int(attr.get("ignored", 0))
    items = block.get("scrobble")
    if isinstance(items, dict):
        items = [items]
    problems = []
    for item in items or []:
        message = (item.get("ignoredMessage") or {})
        if str(message.get("code", "0")) != "0":
            track = (item.get("track") or {}).get("#text", "?")
            problems.append("%s: %s" % (track, message.get("#text", "")))
    return accepted, ignored, problems


def api_love(cfg, artist, track, album=""):
    extra = {"method": "track.love", "artist": artist, "track": track}
    if album:
        extra["album"] = album
    params = authed_params(cfg, extra)
    http_call(cfg["api_url"], params, method="POST")
    return True


def scrobble_threshold(duration):
    if duration and duration > 0:
        if duration <= 30:
            return None
        return min(duration / 2.0, 240.0)
    return 240.0


def metadata_ok(entry):
    return bool((entry.get("artist") or "").strip()) and bool(
        (entry.get("track") or "").strip()
    )


def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if value is not None else default
    except Exception:
        return default


def write_json_atomic(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False)
    os.replace(tmp, path)


def append_log(log_path, message):
    try:
        if os.path.exists(log_path) and os.path.getsize(log_path) > LOG_ROTATE_BYTES:
            with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.read().splitlines()
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("\n".join(lines[len(lines) // 2:]) + "\n")
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(
                "[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
            )
    except OSError:
        pass


class Daemon:
    def __init__(self, p, cfg):
        self.p = p
        self.cfg = cfg
        self.booted = time.time()
        self.adopted_stale = False
        self.current = None
        self.played = 0.0
        self.last_tick = 0.0
        self.np_sent = False
        self.scrobbled = False
        self.last_flush = 0.0
        self.backoff = 30.0
        self.status = {
            "ok": True,
            "authenticated": bool(cfg.get("session_key")),
            "user": "",
            "enabled": bool(cfg.get("enabled", True)),
            "offline": bool(cfg.get("offline", False)),
            "now_playing": {"artist": "", "track": ""},
            "last_scrobbled": "",
            "last_scrobble_time": 0,
            "pending": 0,
            "needs_auth": False,
            "last_error": "",
            "last_error_time": 0,
            "auth_hint": "",
            "love_last": "",
            "love_time": 0,
            "updated_at": 0,
        }

    def note_error(self, message):
        self.status["last_error"] = str(message)[:300]
        self.status["last_error_time"] = int(time.time())
        append_log(self.p["log"], "error: %s" % message)

    def queue_entry(self, entry):
        queue = read_json(self.p["queue"], [])
        if not isinstance(queue, list):
            queue = []
        queue.append(entry)
        write_json_atomic(self.p["queue"], queue[-500:])
        self.status["pending"] = len(queue)

    def flush_queue(self, now):
        queue = read_json(self.p["queue"], [])
        if not isinstance(queue, list):
            queue = []
        self.status["pending"] = len(queue)
        if (
            not queue
            or not self.cfg.get("enabled", True)
            or self.cfg.get("offline", False)
            or not self.cfg.get("session_key")
        ):
            return
        if now - self.last_flush < self.backoff:
            return
        batch = queue[:BATCH_MAX]
        try:
            accepted, ignored, problems = api_scrobble(self.cfg, batch)
        except AuthNeededError as exc:
            self.status["needs_auth"] = True
            self.note_error("session invalid, re-authenticate: %s" % exc)
            self.last_flush = now
            self.backoff = min(self.backoff * 2, 600.0)
            return
        except TransientError as exc:
            self.note_error("retry later: %s" % exc)
            self.last_flush = now
            self.backoff = min(self.backoff * 2, 600.0)
            return
        except FatalError as exc:
            self.note_error("dropping %d queued: %s" % (len(batch), exc))
            queue = queue[len(batch):]
            write_json_atomic(self.p["queue"], queue)
            self.status["pending"] = len(queue)
            self.last_flush = now
            return
        queue = queue[len(batch):]
        write_json_atomic(self.p["queue"], queue)
        self.status["pending"] = len(queue)
        self.last_flush = now
        self.backoff = 30.0
        append_log(
            self.p["log"],
            "flushed queue: accepted=%d ignored=%d remaining=%d"
            % (accepted, ignored, len(queue)),
        )
        for problem in problems:
            append_log(self.p["log"], "ignored by Last.fm: %s" % problem)

    def send_now_playing(self, entry):
        try:
            code, text = api_now_playing(
                self.cfg,
                entry["artist"],
                entry["track"],
                entry.get("album", ""),
                entry.get("duration") or 0,
            )
        except AuthNeededError as exc:
            self.status["needs_auth"] = True
            self.note_error("session invalid, re-authenticate: %s" % exc)
            return
        except TransientError as exc:
            self.note_error("now playing not sent: %s" % exc)
            return
        except FatalError as exc:
            self.note_error("now playing rejected: %s" % exc)
            return
        if code != "0":
            append_log(
                self.p["log"], "now playing filtered (%s): %s" % (code, text)
            )
            return
        append_log(
            self.p["log"],
            "now playing: %s - %s" % (entry["artist"], entry["track"]),
        )

    def send_scrobble(self, entry):
        if self.cfg.get("offline", False):
            self.queue_entry(entry)
            append_log(
                self.p["log"],
                "offline, queued: %s - %s" % (entry["artist"], entry["track"]),
            )
            return
        try:
            accepted, ignored, problems = api_scrobble(self.cfg, [entry])
        except (TransientError, AuthNeededError) as exc:
            if isinstance(exc, AuthNeededError):
                self.status["needs_auth"] = True
            self.note_error("queuing after failure: %s" % exc)
            self.queue_entry(entry)
            return
        except FatalError as exc:
            self.note_error(
                "dropping scrobble %s - %s: %s"
                % (entry["artist"], entry["track"], exc)
            )
            return
        if accepted > 0:
            self.status["last_scrobbled"] = "%s - %s" % (
                entry["artist"],
                entry["track"],
            )
            self.status["last_scrobble_time"] = int(entry["timestamp"])
            append_log(
                self.p["log"],
                "scrobbled: %s - %s" % (entry["artist"], entry["track"]),
            )
        for problem in problems:
            append_log(self.p["log"], "ignored by Last.fm: %s" % problem)
            self.note_error("Last.fm ignored: %s" % problem)

    def track_started(self, entry):
        self.current = entry
        self.played = 0.0
        self.last_tick = time.time()
        self.np_sent = False
        self.scrobbled = False
        self.status["now_playing"] = {
            "artist": entry["artist"],
            "track": entry["track"],
        }
        if not metadata_ok(entry):
            return
        if not self.cfg.get("enabled", True):
            return
        if self.cfg.get("offline", False):
            return
        if not self.cfg.get("session_key"):
            return
        self.send_now_playing(entry)
        self.np_sent = True

    def tick(self, now):
        state = read_json(self.p["state"], {})
        if not isinstance(state, dict):
            state = {}
        entry = {
            "id": str(state.get("id", "")),
            "artist": str(state.get("artist", "")),
            "track": str(state.get("title", "")),
            "album": str(state.get("album", "")),
            "duration": state.get("duration") or 0,
            "started_at": int(state.get("started_at") or 0),
        }
        try:
            entry["duration"] = float(entry["duration"])
        except (TypeError, ValueError):
            entry["duration"] = 0
        player = str(state.get("player_state", ""))
        fresh = (
            self.current is None
            or entry["id"] != self.current.get("id")
            or entry["started_at"] != self.current.get("started_at")
        )
        if fresh and entry["id"]:
            if self.current is None and not self.adopted_stale:
                self.adopted_stale = True
                try:
                    live = os.path.getmtime(self.p["state"]) >= self.booted - 5
                except OSError:
                    live = True
                if not live:
                    self.current = entry
                    self.played = 0.0
                    self.last_tick = now
                    self.np_sent = True
                    self.scrobbled = True
                    append_log(
                        self.p["log"],
                        "ignoring stale state from previous session",
                    )
                    self.status["updated_at"] = int(now)
                    write_json_atomic(self.p["status"], self.status)
                    return
            self.track_started(entry)
        if self.current and player == "playing":
            if self.last_tick > 0:
                self.played += max(0.0, now - self.last_tick)
        self.last_tick = now
        if (
            self.current
            and not self.scrobbled
            and metadata_ok(self.current)
            and self.cfg.get("enabled", True)
            and self.current.get("id")
        ):
            threshold = scrobble_threshold(self.current.get("duration") or 0)
            if threshold is not None and self.played >= threshold:
                self.scrobbled = True
                self.send_scrobble(
                    {
                        "artist": self.current["artist"],
                        "track": self.current["track"],
                        "album": self.current.get("album", ""),
                        "duration": int(self.current.get("duration") or 0),
                        "timestamp": self.current.get("started_at")
                        or int(now),
                    }
                )
        if not self.cfg.get("session_key"):
            self.status["auth_hint"] = (
                "no session: run `%s --auth`" % os.path.basename(sys.argv[0])
            )
        else:
            self.status["auth_hint"] = ""
        self.status["authenticated"] = bool(self.cfg.get("session_key"))
        self.status["enabled"] = bool(self.cfg.get("enabled", True))
        self.status["offline"] = bool(self.cfg.get("offline", False))
        self.status["updated_at"] = int(now)
        self.flush_queue(now)
        write_json_atomic(self.p["status"], self.status)


def process_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if os.path.exists("/proc/%d" % pid):
        return True
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def read_parent_pid(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return int(handle.read().strip())
    except Exception:
        return None


def cleanup(p):
    for key in ("state", "status", "pid", "parent_pid", "self"):
        try:
            os.remove(p[key])
        except OSError:
            pass


def run_daemon(p):
    cfg_path = p["config"]
    cfg = load_config(cfg_path)
    last_mtime = 0
    try:
        last_mtime = os.path.getmtime(cfg_path)
    except OSError:
        pass
    try:
        with open(p["pid"], "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))
    except OSError:
        pass
    daemon = Daemon(p, cfg)
    append_log(p["log"], "daemon started")
    stopped = []

    def on_signal(signum, frame):
        stopped.append(True)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    while not stopped:
        if not process_alive(read_parent_pid(p["parent_pid"])):
            break
        try:
            mtime = os.path.getmtime(cfg_path)
            if mtime != last_mtime:
                last_mtime = mtime
                cfg = load_config(cfg_path)
                daemon.cfg = cfg
        except OSError:
            pass
        try:
            daemon.tick(time.time())
        except Exception as exc:
            append_log(p["log"], "tick failed: %r" % (exc,))
        time.sleep(POLL_SECS)
    append_log(p["log"], "daemon stopped")
    cleanup(p)


def ensure_api_credentials(p, cfg):
    if cfg.get("api_key") and cfg.get("api_secret"):
        return cfg
    print("Last.fm API key needed (free, one minute):")
    print("  https://www.last.fm/api/account/create")
    try:
        key = input("api_key: ").strip()
        secret = input("api_secret: ").strip()
    except EOFError:
        raise FatalError("cancelled")
    if not key or not secret:
        raise FatalError("api_key/api_secret are required")
    save_config_values(p["config"], {"api_key": key, "api_secret": secret})
    return load_config(p["config"])


def cmd_auth(p, mobile):
    cfg = load_config(p["config"])
    try:
        cfg = ensure_api_credentials(p, cfg)
        if mobile:
            session = api_mobile_session(cfg)
            save_config_values(
                p["config"],
                {"session_key": session["key"], "username": session["name"]},
                remove=("password",),
            )
        else:
            token = api_request_token(cfg)
            print("Open this URL in a browser and allow access:")
            print("  %s?api_key=%s&token=%s" % (AUTH_PAGE, cfg["api_key"], token))
            input("Press Enter here once approved... ")
            session = api_request_session(cfg, token)
            save_config_values(
                p["config"],
                {"session_key": session["key"], "username": session["name"]},
            )
    except (FatalError, TransientError, AuthNeededError) as exc:
        print("auth failed: %s" % exc)
        return 1
    print("authenticated as %s" % session["name"])
    append_log(p["log"], "authenticated as %s" % session["name"])
    return 0


def cmd_love(p, args):
    cfg = load_config(p["config"])
    check_credentials(cfg)
    if not cfg.get("session_key"):
        print("not authenticated, run --auth first")
        return 1
    if len(args) >= 2:
        artist, track = args[0], args[1]
        album = args[2] if len(args) > 2 else ""
    else:
        state = read_json(p["state"], {})
        artist, track = state.get("artist", ""), state.get("title", "")
        album = state.get("album", "")
        if not artist or not track:
            print("nothing playing (or missing metadata)")
            return 1
    try:
        api_love(cfg, artist, track, album)
    except Exception as exc:
        print("love failed: %s" % exc)
        return 1
    print("loved: %s - %s" % (artist, track))
    append_log(p["log"], "loved: %s - %s" % (artist, track))
    status = read_json(p["status"], {})
    if isinstance(status, dict):
        status["love_last"] = "%s - %s" % (artist, track)
        status["love_time"] = int(time.time())
        try:
            write_json_atomic(p["status"], status)
        except OSError:
            pass
    return 0


def cmd_status(p):
    cfg = load_config(p["config"])
    status = read_json(p["status"], {})
    print("enabled: %s" % cfg.get("enabled", True))
    print("offline: %s" % cfg.get("offline", False))
    print("authenticated: %s" % bool(cfg.get("session_key")))
    if cfg.get("username"):
        print("user: %s" % cfg.get("username"))
    if isinstance(status, dict) and status:
        now_playing = status.get("now_playing") or {}
        print(
            "now playing: %s - %s"
            % (now_playing.get("artist", ""), now_playing.get("track", ""))
        )
        print("pending: %s" % status.get("pending", 0))
        if status.get("last_scrobbled"):
            print("last scrobbled: %s" % status.get("last_scrobbled"))
        if status.get("last_error"):
            print("last error: %s" % status.get("last_error"))
        if status.get("auth_hint"):
            print("hint: %s" % status.get("auth_hint"))
    else:
        print("daemon not running (no status file)")
    return 0


def cmd_flush_once(p):
    cfg = load_config(p["config"])
    check_credentials(cfg)
    if not cfg.get("session_key"):
        print("not authenticated, run --auth first")
        return 1
    daemon = Daemon(p, cfg)
    daemon.flush_queue(time.time() - 3600)
    daemon.last_flush = 0
    daemon.backoff = 0
    daemon.flush_queue(time.time())
    print("pending: %s" % daemon.status.get("pending", 0))
    return 0 if daemon.status.get("pending", 0) == 0 else 1


TEMPLATE = """# Last.fm scrobbler for rs-pug.
# 1. Create an API account: https://www.last.fm/api/account/create
# 2. Paste api_key and api_secret below.
# 3. While rs-pug runs: python3 <runtime>/rs-pug-lastfm-helper.py --auth
#    (or set username+password and run with --auth-mobile once).
api_key = ""
api_secret = ""
session_key = ""
enabled = true
offline = false
"""


def ensure_config_template(path):
    if os.path.exists(path):
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(TEMPLATE)
    try:
        os.chmod(path, CONFIG_MODE)
    except OSError:
        pass
    return True


def main(argv):
    p = paths()
    if len(argv) < 2:
        print("usage: %s daemon|--auth|--auth-mobile|--love|--status|--flush-once" % argv[0])
        return 2
    command = argv[1]
    if command == "daemon":
        run_daemon(p)
        return 0
    ensure_config_template(p["config"])
    if command == "--auth":
        return cmd_auth(p, mobile=False)
    if command == "--auth-mobile":
        return cmd_auth(p, mobile=True)
    if command == "--love":
        return cmd_love(p, argv[2:])
    if command == "--status":
        return cmd_status(p)
    if command == "--flush-once":
        return cmd_flush_once(p)
    print("unknown command: %s" % command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
]==]

local runtime_dir = os.getenv("RS_PUG_LASTFM_RUNTIME_DIR")
  or os.getenv("XDG_RUNTIME_DIR")
  or "/tmp"
local home_dir = os.getenv("HOME") or "/tmp"
local config_dir = os.getenv("RS_PUG_LASTFM_CONFIG_DIR")
  or os.getenv("XDG_CONFIG_HOME") and (os.getenv("XDG_CONFIG_HOME") .. "/rs-pug")
  or (home_dir .. "/.config/rs-pug")

local state_file = runtime_dir .. "/rs-pug-lastfm-state.json"
local status_file = runtime_dir .. "/rs-pug-lastfm-status.json"
local helper_file = runtime_dir .. "/rs-pug-lastfm-helper.py"
local pid_file = runtime_dir .. "/rs-pug-lastfm-helper.pid"
local parent_pid_file = runtime_dir .. "/rs-pug-lastfm-parent.pid"
local config_file = config_dir .. "/lastfm.toml"

local helper_written = false
local helper_check_at = 0
local config_notice_shown = false
local last_state_json = nil
local last_player_state = nil
local have_track = false
local status_cache = nil
local status_cache_at = 0

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_suffix_ci(text, suffix)
  local lower_text = text:lower()
  local lower_suffix = suffix:lower()
  if #lower_text > #lower_suffix
    and lower_text:sub(-#lower_suffix) == lower_suffix then
    return trim(text:sub(1, #text - #suffix))
  end
  return text
end

local TITLE_JUNK = {
  "(official music video)", "(official video)", "(official audio)",
  "(official lyric video)", "(official lyrics)", "(official visualizer)",
  "[official music video]", "[official video]", "[official audio]",
  "(lyric video)", "(lyrics)", "(visualizer)", "(audio)",
  "[lyric video]", "[lyrics]", "[audio]",
  "(hd)", "(hq)", "(4k)", "[hd]", "[hq]",
}

local function clean_track_title(title)
  local text = trim(title)
  local changed = true
  while changed do
    changed = false
    for _, suffix in ipairs(TITLE_JUNK) do
      local stripped = strip_suffix_ci(text, suffix)
      if stripped ~= text then
        text = stripped
        changed = true
      end
    end
    local remastered = text:lower()
    for _, pattern in ipairs({
      "%s+%-%s+remaster%s*$", "%s+%-%s+remastered.*$",
      "%s*%(remaster[^%)]*%)%s*$", "%s*%[remaster[^%]]*%]%s*$",
    }) do
      local start = remastered:find(pattern)
      if start and start > 1 then
        text = trim(text:sub(1, start - 1))
        remastered = text:lower()
        changed = true
      end
    end
  end
  if text == "" then
    return trim(title)
  end
  return text
end

local function clean_uploader(uploader)
  local text = trim(uploader or "")
  text = strip_suffix_ci(text, "- Topic")
  if text:find("VEVO$") or text:find("vevo$") then
    text = trim(text:sub(1, #text - 4))
  end
  return text
end

local function split_artist_title(title)
  local artist, track = trim(title):match("^(.-)%s+%-%s+(.+)$")
  if artist and track and artist ~= "" and track ~= "" then
    return trim(artist), trim(track)
  end
  return nil, trim(title)
end

local function parse_song(song)
  if type(song) ~= "table" then
    return nil
  end
  local raw_title = trim(song.title or "")
  if raw_title == "" then
    return nil
  end
  local uploader = clean_uploader(song.uploader)
  local split_artist, split_track = split_artist_title(raw_title)
  local artist = split_artist or (uploader ~= "" and uploader or nil)
  local track = clean_track_title(split_track)
  if not artist or artist == "" or track == "" then
    return nil
  end
  local duration = tonumber(song.duration)
  if not duration or duration <= 0 then
    duration = nil
  end
  return {
    id = tostring(song.id or song.webpage_url or raw_title),
    artist = artist,
    title = track,
    album = "",
    duration = duration,
  }
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

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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

local function write_atomic(path, content)
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    return false
  end
  file:write(content)
  file:close()
  return os.rename(tmp, path) and true or false
end

local function state_json(entry, player_state)
  return "{"
    .. '"id":"' .. json_escape(entry.id) .. '",'
    .. '"artist":"' .. json_escape(entry.artist) .. '",'
    .. '"title":"' .. json_escape(entry.title) .. '",'
    .. '"album":"' .. json_escape(entry.album or "") .. '",'
    .. '"duration":' .. (entry.duration and tostring(entry.duration) or "null") .. ","
    .. '"started_at":' .. tostring(entry.started_at) .. ","
    .. '"player_state":"' .. json_escape(player_state or "unknown") .. '"'
    .. "}"
end

local function config_exists()
  local file = io.open(config_file, "r")
  if file then
    file:close()
    return true
  end
  return false
end

local function create_config_template()
  local file = io.open(config_file, "w")
  if not file then
    os.execute(
      "mkdir -p " .. shell_quote(config_dir) .. " >/dev/null 2>&1"
    )
    file = io.open(config_file, "w")
  end
  if not file then
    return false
  end
  file:write(
    "# Last.fm scrobbler for rs-pug.\n"
      .. "# 1. Create an API account: https://www.last.fm/api/account/create\n"
      .. "# 2. Paste api_key and api_secret below.\n"
      .. "# 3. While rs-pug runs: python3 "
      .. (runtime_dir .. "/rs-pug-lastfm-helper.py")
      .. " --auth\n"
      .. 'api_key = ""\n'
      .. 'api_secret = ""\n'
      .. 'session_key = ""\n'
      .. "enabled = true\n"
      .. "offline = false\n"
  )
  file:close()
  os.execute("chmod 600 " .. shell_quote(config_file) .. " >/dev/null 2>&1")
  return true
end

local function helper_running()
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

local function write_parent_pid()
  local stat = io.open("/proc/self/stat", "r")
  if stat then
    local line = stat:read("*l")
    stat:close()
    local pid = line and line:match("^(%d+)")
    if pid then
      local file = io.open(parent_pid_file, "w")
      if file then
        file:write(pid)
        file:close()
        return
      end
    end
  end
  local handle = io.popen("echo $PPID")
  if handle then
    local pid = handle:read("*l")
    handle:close()
    pid = pid and pid:match("^(%d+)")
    if pid then
      local file = io.open(parent_pid_file, "w")
      if file then
        file:write(pid)
        file:close()
      end
    end
  end
end

local function ensure_helper(force_check)
  local now = os.time()
  if not force_check and now - helper_check_at < HELPER_CHECK_SECS then
    return
  end
  helper_check_at = now
  if not helper_written then
    local file = io.open(helper_file, "w")
    if file then
      file:write(helper_source)
      file:close()
      helper_written = true
    end
  end
  write_parent_pid()
  if helper_running() then
    return
  end
  os.execute(
    "python3 "
      .. shell_quote(helper_file)
      .. " daemon >/dev/null 2>&1 &"
  )
end

local function publish(entry, player_state)
  if not entry then
    return
  end
  local payload = state_json(entry, player_state)
  if payload == last_state_json then
    return
  end
  last_state_json = payload
  write_atomic(state_file, payload)
  ensure_helper(entry.started_at ~= nil)
end

local function read_status()
  local now = os.time()
  if status_cache and now - status_cache_at < STATUS_CACHE_SECS then
    return status_cache
  end
  status_cache_at = now
  local raw = read_file(status_file)
  if not raw then
    status_cache = nil
    return nil
  end
  local user = raw:match('"user"%s*:%s*"([^"]-)"')
  local artist = raw:match('"now_playing"%s*:%s*{[^}]-"artist"%s*:%s*"([^"]-)"')
  local track = raw:match('"now_playing"%s*:%s*{[^}]-"track"%s*:%s*"([^"]-)"')
  local pending = tonumber(raw:match('"pending"%s*:%s*(%d+)') or "0")
  local authed = raw:find('"authenticated"%s*:%s*true') ~= nil
  local offline = raw:find('"offline"%s*:%s*true') ~= nil
  local enabled = raw:find('"enabled"%s*:%s*false') == nil
  local needs_auth = raw:find('"needs_auth"%s*:%s*true') ~= nil
  local last_error = raw:match('"last_error"%s*:%s*"([^"]-)"')
  local last_scrobbled = raw:match('"last_scrobbled"%s*:%s*"([^"]-)"')
  local updated_at = tonumber(raw:match('"updated_at"%s*:%s*(%d+)') or "0")
  status_cache = {
    user = user or "",
    artist = artist or "",
    track = track or "",
    pending = pending or 0,
    authenticated = authed,
    offline = offline,
    enabled = enabled,
    needs_auth = needs_auth,
    last_error = last_error or "",
    last_scrobbled = last_scrobbled or "",
    stale = not updated_at or (now - updated_at) > 30,
  }
  return status_cache
end

local plugin = {}

function plugin.on_song_start(song)
  if not config_exists() then
    create_config_template()
  end
  local entry = parse_song(song)
  if not entry then
    return nil
  end
  entry.started_at = os.time()
  have_track = true
  publish(entry, last_player_state or "playing")
  if not config_notice_shown then
    config_notice_shown = true
    local cfg = read_file(config_file) or ""
    if not cfg:match('api_key%s*=%s*"[^"]%S') then
      return {
        flash = "Last.fm: set api_key in lastfm.toml, then run the helper with --auth",
        flash_seconds = 6,
      }
    end
  end
  return nil
end

function plugin.on_event(event, state)
  if type(event) ~= "table" then
    return nil
  end
  local player_state = (type(state) == "table" and state.player_state)
    or last_player_state
    or "unknown"
  if event.kind == "started" and not have_track and event.message then
    local artist, track = split_artist_title(tostring(event.message))
    if track and track ~= "" then
      have_track = true
      publish({
        id = tostring(event.message),
        artist = artist or "",
        title = clean_track_title(track),
        album = "",
        duration = nil,
        started_at = os.time(),
      }, player_state)
    end
  elseif event.kind ~= "progress" or player_state ~= last_player_state then
    if last_state_json then
      local updated, count = last_state_json:gsub(
        '"player_state"%s*:%s*"[^"]-"',
        function()
          return '"player_state":"' .. json_escape(player_state) .. '"'
        end,
        1
      )
      if updated ~= last_state_json then
        last_state_json = updated
        write_atomic(state_file, updated)
      end
    end
    ensure_helper(false)
  end
  last_player_state = player_state
  return nil
end

function plugin.on_key(key, state)
  local on_tab = type(state) == "table" and state.active_plugin_tab == TAB_ID
  if key == "char:6" and not on_tab then
    return { consume = true, ui = { set_tab = TAB_ID } }
  end
  if LOVE_KEY and key == LOVE_KEY then
    if not on_tab then
      return nil
    end
    ensure_helper(true)
    os.execute(
      "python3 "
        .. shell_quote(helper_file)
        .. " --love >/dev/null 2>&1 &"
    )
    return {
      consume = true,
      flash = "Last.fm: loved the current track",
      flash_seconds = 2,
    }
  end
  return nil
end

function plugin.on_tabs(_state)
  return { { id = TAB_ID, title = "Last.fm" } }
end

function plugin.on_ui_panels(_state)
  local items = { { type = "header", text = "Last.fm scrobbler" } }
  local status = read_status()
  if not status then
    if not config_exists() then
      items[#items + 1] = { type = "info", text = "set api_key in lastfm.toml" }
      items[#items + 1] = { type = "info", text = "then run the helper with --auth" }
    else
      items[#items + 1] = { type = "info", text = "daemon not running" }
    end
    return { { title = "Last.fm", target = "main", items = items } }
  end
  if status.stale then
    items[#items + 1] = { type = "info", text = "daemon not responding" }
    return { { title = "Last.fm", target = "main", items = items } }
  end
  if not status.authenticated or status.needs_auth then
    items[#items + 1] = { type = "stat", label = "user", value = "not authenticated" }
    items[#items + 1] = { type = "info", text = "key: last.fm/api/account/create" }
    items[#items + 1] = { type = "info", text = "auth: run the helper with --auth" }
    return { { title = "Last.fm", target = "main", items = items } }
  end
  local mode = "on"
  if not status.enabled then
    mode = "off"
  elseif status.offline then
    mode = "offline"
  end
  items[#items + 1] = {
    type = "stat",
    label = "user",
    value = (status.user ~= "" and status.user or "ok") .. " [" .. mode .. "]",
  }
  if status.artist ~= "" and status.track ~= "" then
    items[#items + 1] = {
      type = "stat",
      label = "now playing",
      value = (status.artist .. " - " .. status.track):sub(1, 60),
    }
    items[#items + 1] = { type = "keybind", key = "l", action = "love this track" }
  else
    items[#items + 1] = { type = "info", text = "nothing playing" }
  end
  if status.last_scrobbled ~= "" then
    items[#items + 1] = {
      type = "stat",
      label = "last scrobble",
      value = status.last_scrobbled:sub(1, 60),
    }
  end
  if status.pending and status.pending > 0 then
    items[#items + 1] = {
      type = "stat",
      label = "queued",
      value = tostring(status.pending),
    }
  end
  if status.last_error ~= "" then
    items[#items + 1] = {
      type = "info",
      text = status.last_error:sub(1, 60),
    }
  end
  return { { title = "Last.fm", target = "main", items = items } }
end

return plugin
