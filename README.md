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
```bash
cd /home/frank/.openclaw/workspace/projects/sound-server
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

## Push-to-talk (office hotkey) -> Telegram

This project includes an optional desk workflow for "press key, talk, release, send to Frank":

- `setup-office-ptt.sh` (recommended one-shot setup)
- `install-whisper.sh` (Whisper-only helper)
- `install-ptt.sh` (legacy split setup)
- `ptt-record.sh` (`start|stop|toggle`)

### 1) Setup (one-time, recommended)
```bash
cd /home/frank/.openclaw/workspace/projects/sound-server
./setup-office-ptt.sh
```

Optional overrides:
```bash
./setup-office-ptt.sh --bot-token "<TELEGRAM_BOT_TOKEN>" --chat-id "86332998" --hotkey "Ctrl+Alt+Space"
```

Reset only Telegram/hotkey in an existing config:
```bash
./setup-office-ptt.sh --reset-telegram --bot-token "<NEW_TOKEN>" --chat-id "86332998"
./setup-office-ptt.sh --reset-hotkey --hotkey "Ctrl+Alt+Space"
```

This writes config to:
`~/.config/sound-server-ptt/config.json`

### 2) Bind keyboard shortcut(s)
Bind your desktop hotkey to one of these:

- Toggle mode (single key):
```bash
/home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh toggle
```

- Push-to-talk style (press/release via two bindings):
```bash
/home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh start
/home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh stop
```

### 3) Beeps
`start_beep` and `stop_beep` are configurable in `config.json`.

### STT requirement
Default config expects the `whisper` CLI to be available on the office machine.
If missing, recording still works but transcript send will fail with a Telegram notice.

Install helper included:
```bash
cd /home/frank/.openclaw/workspace/projects/sound-server
./install-whisper.sh --model base
```

## Security notes
- Binds to `127.0.0.1` by default
- All mutating endpoints require token auth
- Non-local clients denied unless `SOUND_SERVER_ALLOW_NON_LOCAL=true`
- Keep token secret and rotate if exposed
