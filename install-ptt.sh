#!/usr/bin/env bash
set -euo pipefail

# User-level setup for push-to-talk recording -> STT -> Telegram send
# Usage:
#   ./install-ptt.sh --bot-token <token> --chat-id <id> [--hotkey "Ctrl+Alt+Space"] [--config ~/.config/sound-server-ptt/config.json]

BOT_TOKEN=""
CHAT_ID=""
HOTKEY="Ctrl+Alt+Space"
CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bot-token) BOT_TOKEN="${2:-}"; shift 2;;
    --chat-id) CHAT_ID="${2:-}"; shift 2;;
    --hotkey) HOTKEY="${2:-}"; shift 2;;
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./install-ptt.sh --bot-token <token> --chat-id <id> [--hotkey "Ctrl+Alt+Space"] [--config ~/.config/sound-server-ptt/config.json]
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "Missing required args. Example:"
  echo "  ./install-ptt.sh --bot-token 123:ABC --chat-id 86332998 --hotkey 'Ctrl+Alt+Space'"
  exit 1
fi

sudo apt-get update
sudo apt-get install -y jq curl alsa-utils ffmpeg

mkdir -p "$(dirname "$CONFIG_PATH")"
cat > "$CONFIG_PATH" <<JSON
{
  "telegram": {
    "bot_token": "$BOT_TOKEN",
    "chat_id": "$CHAT_ID"
  },
  "audio": {
    "device": "default",
    "rate_hz": 16000,
    "channels": 1,
    "format": "S16_LE",
    "start_beep": "/home/frank/.openclaw/workspace/projects/sound-server/test-assets/beep.wav",
    "stop_beep": "/home/frank/.openclaw/workspace/projects/sound-server/test-assets/beep.wav"
  },
  "stt": {
    "command_template": "whisper '{input}' --model base --language en --output_format txt --output_dir '{output_dir}' --fp16 False",
    "result_file_template": "{output_dir}/{input_stem}.txt"
  },
  "hotkey_hint": "$HOTKEY"
}
JSON
chmod 600 "$CONFIG_PATH"

cat <<EOF

✅ PTT setup complete.
Config: $CONFIG_PATH
Hotkey hint: $HOTKEY

Bind your keyboard shortcut(s) to:
  Start recording: /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh start --config "$CONFIG_PATH"
  Stop  recording: /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh stop  --config "$CONFIG_PATH"

Tip (single toggle key): bind to
  /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh toggle --config "$CONFIG_PATH"

If Whisper CLI is not installed yet, run:
  /home/frank/.openclaw/workspace/projects/sound-server/install-whisper.sh --model base

EOF
