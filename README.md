# sound-server

Minimal local audio endpoint service for Pop!_OS/Ubuntu.

## Features
- HTTP API with token auth
- Endpoints:
  - `GET /health` (no auth)
  - `GET /status` (auth)
  - `POST /play-file` with JSON `{ "path": "/abs/path/file.wav" }`
  - `POST /speak` with JSON `{ "text": "hello" }`
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

curl -s -X POST http://127.0.0.1:8088/play-file \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"/home/frank/Music/test.mp3"}'
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

## Security notes
- Binds to `127.0.0.1` by default
- All mutating endpoints require token auth
- Non-local clients denied unless `SOUND_SERVER_ALLOW_NON_LOCAL=true`
- Keep token secret and rotate if exposed
