# Last.fm scrobbler for rs-pug

Scrobbles everything you play (YouTube, SoundCloud, Sonum, local files)
following the same rules as Strawberry: `track.updateNowPlaying` is sent
when a track starts, `track.scrobble` is sent after half the track duration
or 4 minutes, whichever comes first. Tracks of 30 seconds or less are never
scrobbled. Failed scrobbles are queued locally and retried later.

Status lives in a dedicated `Last.fm` tab next to the main tabs. Open it with
`6` (the number shown next to it in the tab bar).

## Setup

1. Get a free API key: https://www.last.fm/api/account/create
2. While rs-pug is running, run:
   `python3 "$XDG_RUNTIME_DIR/rs-pug-lastfm-helper.py" --auth`

   Paste the key and secret when asked, open the printed URL in a browser,
   approve, press Enter. The session is stored, you do this once.

   Without a browser: put `username` and `password` in `lastfm.toml` and run
   the helper with `--auth-mobile` instead (the password is erased after).

## Config

`~/.config/rs-pug/lastfm.toml` (mode 0600, hot-reloaded, no restart needed):

| Key | Default | Meaning |
|---|---|---|
| `api_key` / `api_secret` | empty | from the Last.fm API account |
| `session_key` | empty | filled by `--auth` |
| `enabled` | true | `false` disables scrobbling entirely |
| `offline` | false | `true` queues scrobbles without sending |
| `api_url` | Last.fm | override for compatible services (e.g. Libre.fm) |

Optional `track.love`: press `l` while the `Last.fm` tab is active. The tab
shows the hint next to the current track. To disable, set `LOVE_KEY` to nil
at the top of `lastfm.lua`.

## Helper commands

`python3 "$XDG_RUNTIME_DIR/rs-pug-lastfm-helper.py" ...`

| Command | Meaning |
|---|---|
| `--auth` | browser authorization (asks for API key if missing) |
| `--auth-mobile` | authorize with `username`/`password` from the config |
| `--status` | show auth state, now playing, queued count |
| `--love ["artist" "track"]` | love the current (or given) track |
| `--flush-once` | retry the queued scrobbles once and exit |

## Files

| File | Purpose |
|---|---|
| `~/.config/rs-pug/lastfm.toml` | config + secrets |
| `~/.config/rs-pug/lastfm-queue.json` | pending scrobbles (survives restarts) |
| `~/.config/rs-pug/lastfm.log` | what was sent, ignored, or failed |
| `$XDG_RUNTIME_DIR/rs-pug-lastfm-state.json` | current track, written by the plugin |
| `$XDG_RUNTIME_DIR/rs-pug-lastfm-status.json` | feeds the `Last.fm` tab |

## Troubleshooting

* Nothing scrobbles: open the `Last.fm` tab or run `--status`. No session
  means `--auth` was not completed. `pending` above zero with errors means
  the queue is waiting (offline mode, no network, or bad session).
* Short jingles and tracks without an identifiable artist are skipped on
  purpose. YouTube titles are split as `Artist - Title`, falling back to
  the channel name; "Official Video" style suffixes are stripped.
* Only stdlib Python is used, there is nothing to install.
