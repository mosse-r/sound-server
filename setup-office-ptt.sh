#!/usr/bin/env bash
set -euo pipefail

# One-shot setup for office push-to-talk:
# - installs Whisper CLI (optional skip)
# - writes/updates PTT config (Telegram token/chat + hotkey hint)
#
# Usage examples:
#   ./setup-office-ptt.sh
#   ./setup-office-ptt.sh --bot-token "123:ABC" --chat-id "86332998" --hotkey "Ctrl+Alt+Space"
#   ./setup-office-ptt.sh --reset-telegram --reset-hotkey
#
# Notes:
# - If config already exists, values are kept unless reset flags are passed.
# - Bot token can be auto-detected from /home/frank/.openclaw/openclaw.json.

CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"
HOTKEY_DEFAULT="Ctrl+Alt+Space"
WHISPER_MODEL="base"
INSTALL_WHISPER=true

BOT_TOKEN=""
CHAT_ID=""
HOTKEY=""
RESET_TELEGRAM=false
RESET_HOTKEY=false
FORCE=false

OPENCLAW_CONFIG="/home/frank/.openclaw/openclaw.json"
BASE_DIR="/home/frank/.openclaw/workspace/projects/sound-server"

usage() {
  cat <<'EOF'
Usage:
  ./setup-office-ptt.sh [options]

Options:
  --bot-token <token>      Telegram bot token (optional; auto-detect attempted)
  --chat-id <id>           Telegram chat id (default: 86332998)
  --hotkey <keys>          Hotkey hint to store in config (default: Ctrl+Alt+Space)
  --config <path>          Config path (default: ~/.config/sound-server-ptt/config.json)
  --model <name>           Whisper model for install-whisper.sh (default: base)
  --skip-whisper           Do not install Whisper
  --reset-telegram         Overwrite telegram.bot_token/chat_id in existing config
  --reset-hotkey           Overwrite hotkey_hint in existing config
  --force                  Overwrite full config payload
  -h, --help               Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bot-token) BOT_TOKEN="${2:-}"; shift 2;;
    --chat-id) CHAT_ID="${2:-}"; shift 2;;
    --hotkey) HOTKEY="${2:-}"; shift 2;;
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    --model) WHISPER_MODEL="${2:-}"; shift 2;;
    --skip-whisper) INSTALL_WHISPER=false; shift;;
    --reset-telegram) RESET_TELEGRAM=true; shift;;
    --reset-hotkey) RESET_HOTKEY=true; shift;;
    --force) FORCE=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

mkdir -p "$(dirname "$CONFIG_PATH")"

# Auto-detect token if missing
if [[ -z "$BOT_TOKEN" && -f "$OPENCLAW_CONFIG" ]]; then
  BOT_TOKEN="$(node -e "const fs=require('fs');const p='$OPENCLAW_CONFIG';const c=JSON.parse(fs.readFileSync(p,'utf8'));process.stdout.write((c.channels&&c.channels.telegram&&c.channels.telegram.botToken)||'')" 2>/dev/null || true)"
fi

# Defaults
if [[ -z "$CHAT_ID" ]]; then CHAT_ID="86332998"; fi
if [[ -z "$HOTKEY" ]]; then HOTKEY="$HOTKEY_DEFAULT"; fi

# Existing values (preserve unless reset)
EXISTING=false
if [[ -f "$CONFIG_PATH" ]]; then
  EXISTING=true
fi

if [[ "$EXISTING" == true && "$FORCE" == false ]]; then
  if [[ "$RESET_TELEGRAM" == false ]]; then
    EXIST_TOKEN="$(jq -r '.telegram.bot_token // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_CHAT="$(jq -r '.telegram.chat_id // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [[ -n "$EXIST_TOKEN" ]] && BOT_TOKEN="$EXIST_TOKEN"
    [[ -n "$EXIST_CHAT" ]] && CHAT_ID="$EXIST_CHAT"
  fi

  if [[ "$RESET_HOTKEY" == false ]]; then
    EXIST_HOTKEY="$(jq -r '.hotkey_hint // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [[ -n "$EXIST_HOTKEY" ]] && HOTKEY="$EXIST_HOTKEY"
  fi
fi

if [[ -z "$BOT_TOKEN" ]]; then
  echo "❌ Telegram bot token is missing. Provide --bot-token or configure channels.telegram.botToken in $OPENCLAW_CONFIG"
  exit 1
fi

# Install whisper first (optional)
if [[ "$INSTALL_WHISPER" == true ]]; then
  "$BASE_DIR/install-whisper.sh" --model "$WHISPER_MODEL"
fi

# Ensure runtime deps for PTT
sudo apt-get update
sudo apt-get install -y jq curl alsa-utils ffmpeg

# Write config
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
✅ Office PTT setup complete.
Config: $CONFIG_PATH
Telegram chat: $CHAT_ID
Hotkey hint: $HOTKEY

Bind your keyboard shortcut(s) to:
  Start:  /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh start --config "$CONFIG_PATH"
  Stop:   /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh stop --config "$CONFIG_PATH"
  Toggle: /home/frank/.openclaw/workspace/projects/sound-server/ptt-record.sh toggle --config "$CONFIG_PATH"

Reset examples:
  $0 --reset-telegram --bot-token '<new token>' --chat-id '$CHAT_ID'
  $0 --reset-hotkey --hotkey 'Ctrl+Alt+Space'
EOF
