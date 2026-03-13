# sound-server

Minimal local audio endpoint service for Pop!_OS/Ubuntu.

## Features
- HTTP API with token auth
- Endpoints:
  - `GET /health` (no auth)
  - `GET /status` (auth)
  - `POST /play` with raw audio body (preferred, path-free, network-safe)
  - `POST /play-bytes` with raw audio body (legacy alias for /play)
  - `POST /speak` with JSON `{ "text": "hello" }`
  - `POST /stop` to stop current playback and clear queue
- Single worker queue (no overlapping playback)
- Playback backend auto-detection: `mpv` (default) → `ffplay` → `aplay`
- Optional audio device selection (`SOUND_SERVER_AUDIO_DEVICE`)
- Systemd service + installer
- Security defaults: localhost bind + shared token required

## Quick install (server)
Clone the repo and run the installer on the machine where the service will run:
```bash
cd /path/to/sound-server
sudo bash install.sh
```

## Configure
Env file: `/etc/sound-server.env`

```env
SOUND_SERVER_HOST=127.0.0.1
SOUND_SERVER_PORT=8088
SOUND_SERVER_TOKEN=REPLACE_ME
SOUND_SERVER_BACKEND=auto
SOUND_SERVER_AUDIO_DEVICE=
SOUND_SERVER_ALLOW_NON_LOCAL=false
SOUND_SERVER_MAX_TEXT_LEN=500
```

Then:
```bash
sudo systemctl restart sound-server
sudo systemctl status sound-server --no-pager
```

## API examples
```bash
export TOKEN="$(grep '^SOUND_SERVER_TOKEN=' /etc/sound-server.env | cut -d= -f2-)"

curl -s http://127.0.0.1:8088/health

curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8088/status

curl -s -X POST http://127.0.0.1:8088/speak \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello from sound server"}'

# Emergency stop: stop current playback + clear queue
curl -s -X POST http://127.0.0.1:8088/stop \
  -H "Authorization: Bearer $TOKEN"

# Path-free upload (bytes only; recommended)
curl -s -X POST http://127.0.0.1:8088/play \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: audio/wav" \
  -H "X-Filename: beep.wav" \
  --data-binary @test-assets/beep.wav

# Legacy alias (same as /play)
curl -s -X POST http://127.0.0.1:8088/play-bytes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: audio/mpeg" \
  -H "X-Filename: voice.mp3" \
  --data-binary @your-file.mp3
```

## Bluetooth / specific output device
- **mpv + PulseAudio/PipeWire** device example:
  - `SOUND_SERVER_AUDIO_DEVICE=pulse/bluez_output.XX_XX_XX_XX_XX_XX.a2dp-sink`
- **aplay + ALSA** device example:
  - `SOUND_SERVER_AUDIO_DEVICE=hw:0,0`

To discover mpv devices:
```bash
mpv --audio-device=help --no-config --idle=yes --no-video 2>&1 | sed -n '1,80p'
```

## Logs
```bash
journalctl -u sound-server -f
```

## Smoke test
Requires `jq`:
```bash
sudo apt-get install -y jq
export SOUND_SERVER_TOKEN="$(grep '^SOUND_SERVER_TOKEN=' /etc/sound-server.env | cut -d= -f2-)"
./smoke-test.sh
```

## End-to-end play test
Uses `test-assets/beep.wav` to confirm `/play` and playback work:
```bash
export SOUND_SERVER_TOKEN="$(grep '^SOUND_SERVER_TOKEN=' /etc/sound-server.env | cut -d= -f2-)"
./test-e2e-play.sh
```
You should hear a short beep and see "E2E play test passed."

## Push-to-talk (hotkey) → Telegram (as yourself)

Optional workflow: press key, talk, release → recording is transcribed and sent to Telegram **as you** (user account, not a bot).

- `setup-ptt.sh` — one-shot setup (deps, Whisper, config)
- `install-ptt.sh` — minimal install (config only, no Whisper)
- `install-whisper.sh` — Whisper CLI only
- `ptt-record.sh` — `start` / `stop` / `toggle` recording
- `telegram_login.py` — one-time login to create session
- `telegram_send.py` — send one message (used by ptt-record)

### 1) Get Telegram API credentials
Create an app at https://my.telegram.org/apps and note **api_id** and **api_hash**.

### 2) Setup (one-time)
From the repo directory on the machine where you’ll use PTT:
```bash
cd /path/to/sound-server
./setup-ptt.sh --api-id YOUR_API_ID --api-hash "YOUR_API_HASH" [--target "me"] [--hotkey "Ctrl+Alt+Space"]
```
`--target "me"` sends to your Saved Messages; you can use a chat id or username instead.

### 3) Log in as yourself (one-time)
Messages are sent from your Telegram account, not a bot. Create a session once:
```bash
python3 telegram_login.py ~/.config/sound-server-ptt/config.json
```
Enter your phone number and the code Telegram sends you (and 2FA password if enabled).

### 4) Bind keyboard shortcut(s)
Two styles:

- **(a) One button** — Press to start recording, press again to stop. Bind the **toggle** command.
- **(b) Hold-to-talk** — Hold the key while talking, release to stop. Bind **start** on key-down and **stop** on key-up (requires a tool that supports key release, e.g. xbindkeys).

Use the **full path** to `ptt-record.sh`. Run `./ptt-bind-keys.sh` to print the exact commands for your install. Config: `~/.config/sound-server-ptt/config.json`.

**Ubuntu / Pop!_OS / GNOME (one-button toggle):**
1. **Settings → Keyboard → Keyboard Shortcuts** (or **Custom Shortcuts**).
2. Add shortcut: name e.g. “PTT Toggle”, command:
   ```bash
   /path/to/sound-server/ptt-record.sh toggle --config ~/.config/sound-server-ptt/config.json
   ```
3. Assign a key (e.g. **Ctrl+Alt+Space**).

**Hold-to-talk:** Most DE shortcuts only fire on key press. For key-down → start, key-up → stop, use **xbindkeys** and bind `start` to the key press and `stop` to the key release (see `xbindkeys -k` to get key codes).

**Test:** Run `./test-ptt-toggle.sh` to verify toggle start/stop without “PTT busy”.

### 5) Beeps and STT
- `start_beep` and `stop_beep` in config are optional (leave empty for none). If `test-assets/beep.wav` exists in the repo, setup uses it.
- STT uses the `whisper` CLI. Setup installs it by default; or run `./install-whisper.sh --model base` separately. If Whisper is missing, recording works but sending the transcript will fail.

## Security notes
- Binds to `127.0.0.1` by default
- All mutating endpoints require token auth
- Non-local clients denied unless `SOUND_SERVER_ALLOW_NON_LOCAL=true`
- Keep token secret and rotate if exposed
