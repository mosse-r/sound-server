#!/usr/bin/env bash
set -euo pipefail

# General PTT setup: install deps, optional Whisper, write config for Telegram (user auth).
# Run from the sound-server repo; paths are derived from the script directory.
#
# Usage:
#   ./setup-ptt.sh --api-id 12345 --api-hash "your_hash" [--target "me"] [--hotkey "Ctrl+Alt+Space"]
#   ./setup-ptt.sh --reset-telegram --api-id 12345 --api-hash "..." [--target "me"]
#
# Get api_id and api_hash from https://my.telegram.org/apps
# After setup, run: python3 telegram_login.py ~/.config/sound-server-ptt/config.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"
HOTKEY_DEFAULT="Ctrl+Alt+Space"
WHISPER_MODEL="base"
INSTALL_WHISPER=true

API_ID=""
API_HASH=""
TARGET="me"
HOTKEY=""
RESET_TELEGRAM=false
RESET_HOTKEY=false
FORCE=false

# Optional beep files: prefer Siri sounds (mp3), else generated ptt-*.wav, else single beep
PTT_BEEPS="$SCRIPT_DIR/ptt-beeps"
START_BEEP=""
STOP_BEEP=""
ERROR_BEEP=""
BEEP_VOLUME="1"
[[ -f "$PTT_BEEPS/siri_open.mp3" ]] && START_BEEP="$PTT_BEEPS/siri_open.mp3"
[[ -f "$PTT_BEEPS/siri_succeed.mp3" ]] && STOP_BEEP="$PTT_BEEPS/siri_succeed.mp3"
[[ -f "$PTT_BEEPS/siri_close.mp3" ]] && ERROR_BEEP="$PTT_BEEPS/siri_close.mp3"
[[ -z "$START_BEEP" && -f "$PTT_BEEPS/ptt-start.wav" ]] && START_BEEP="$PTT_BEEPS/ptt-start.wav"
[[ -z "$STOP_BEEP" && -f "$PTT_BEEPS/ptt-send.wav" ]] && STOP_BEEP="$PTT_BEEPS/ptt-send.wav"
[[ -z "$ERROR_BEEP" && -f "$PTT_BEEPS/ptt-error.wav" ]] && ERROR_BEEP="$PTT_BEEPS/ptt-error.wav"
if [[ -z "$START_BEEP" && -f "$SCRIPT_DIR/test-assets/beep.wav" ]]; then
  START_BEEP="$SCRIPT_DIR/test-assets/beep.wav"
  STOP_BEEP="$SCRIPT_DIR/test-assets/beep.wav"
fi

usage() {
  cat <<'EOF'
Usage:
  ./setup-ptt.sh [options]

Options:
  --api-id <id>            Telegram API id (from https://my.telegram.org/apps)
  --api-hash <hash>        Telegram API hash
  --target <target>        Where to send messages: "me" (Saved Messages), or chat id / username (default: me)
  --hotkey <keys>          Hotkey hint stored in config (default: Ctrl+Alt+Space)
  --config <path>          Config path (default: ~/.config/sound-server-ptt/config.json)
  --model <name>           Whisper model for install-whisper.sh (default: base)
  --skip-whisper           Do not install Whisper
  --reset-telegram         Overwrite telegram settings in existing config
  --reset-hotkey           Overwrite hotkey_hint in existing config
  --force                  Overwrite full config
  -h, --help               Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-id) API_ID="${2:-}"; shift 2;;
    --api-hash) API_HASH="${2:-}"; shift 2;;
    --target) TARGET="${2:-me}"; shift 2;;
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
SESSION_PATH="$(dirname "$CONFIG_PATH")/telegram.session"

# Defaults
[[ -z "$HOTKEY" ]] && HOTKEY="$HOTKEY_DEFAULT"

# Preserve existing unless reset
EXISTING=false
[[ -f "$CONFIG_PATH" ]] && EXISTING=true

if [[ "$EXISTING" == true && "$FORCE" == false ]]; then
  if [[ "$RESET_TELEGRAM" == false ]]; then
    EXIST_API_ID="$(jq -r '.telegram.api_id // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_API_HASH="$(jq -r '.telegram.api_hash // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_TARGET="$(jq -r '.telegram.target // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_SESSION="$(jq -r '.telegram.session_path // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [[ -n "$EXIST_API_ID" ]] && API_ID="$EXIST_API_ID"
    [[ -n "$EXIST_API_HASH" ]] && API_HASH="$EXIST_API_HASH"
    [[ -n "$EXIST_TARGET" ]] && TARGET="$EXIST_TARGET"
    [[ -n "$EXIST_SESSION" ]] && SESSION_PATH="$EXIST_SESSION"
  fi
  if [[ "$RESET_HOTKEY" == false ]]; then
    EXIST_HOTKEY="$(jq -r '.hotkey_hint // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [[ -n "$EXIST_HOTKEY" ]] && HOTKEY="$EXIST_HOTKEY"
  fi
  if [[ "$RESET_TELEGRAM" == false && "$RESET_HOTKEY" == false ]]; then
    EXIST_START="$(jq -r '.audio.start_beep // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_STOP="$(jq -r '.audio.stop_beep // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_ERROR="$(jq -r '.audio.error_beep // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    EXIST_BEEP_VOL="$(jq -r '.audio.beep_volume // empty' "$CONFIG_PATH" 2>/dev/null || true)"
    [[ -n "$EXIST_START" ]] && START_BEEP="$EXIST_START"
    [[ -n "$EXIST_STOP" ]] && STOP_BEEP="$EXIST_STOP"
    [[ -n "$EXIST_ERROR" ]] && ERROR_BEEP="$EXIST_ERROR"
    [[ -n "$EXIST_BEEP_VOL" ]] && BEEP_VOLUME="$EXIST_BEEP_VOL"
  fi
fi

if [[ -z "$API_ID" || -z "$API_HASH" ]]; then
  echo "❌ Telegram user auth requires --api-id and --api-hash (from https://my.telegram.org/apps)"
  exit 1
fi

# Install Whisper if requested
if [[ "$INSTALL_WHISPER" == true ]]; then
  "$SCRIPT_DIR/install-whisper.sh" --model "$WHISPER_MODEL"
fi

# Runtime deps
sudo apt-get update
sudo apt-get install -y jq python3 python3-pip alsa-utils ffmpeg libnotify-bin

# Telethon for user-mode Telegram
pip3 install --user -r "$SCRIPT_DIR/requirements-telegram.txt" 2>/dev/null || \
  python3 -m pip install --user -r "$SCRIPT_DIR/requirements-telegram.txt"

# Write config (api_id as number)
jq -n \
  --arg api_id "$API_ID" \
  --arg api_hash "$API_HASH" \
  --arg session_path "$SESSION_PATH" \
  --arg target "$TARGET" \
  --arg start_beep "$START_BEEP" \
  --arg stop_beep "$STOP_BEEP" \
  --arg error_beep "$ERROR_BEEP" \
  --arg beep_volume "${BEEP_VOLUME:-1}" \
  --arg hotkey "$HOTKEY" \
  '{
    telegram: {
      mode: "user",
      api_id: ($api_id | tonumber),
      api_hash: $api_hash,
      session_path: $session_path,
      target: $target
    },
    audio: {
      device: "default",
      rate_hz: 16000,
      channels: 1,
      format: "S16_LE",
      start_beep: $start_beep,
      stop_beep: $stop_beep,
      error_beep: $error_beep,
      beep_volume: ($beep_volume | tonumber)
    },
    stt: {
      command_template: "whisper \"{input}\" --model base --language en --output_format txt --output_dir \"{output_dir}\" --fp16 False",
      result_file_template: "{output_dir}/{input_stem}.txt"
    },
    hotkey_hint: $hotkey
  }' > "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"

cat <<EOF
✅ PTT setup complete.
Config: $CONFIG_PATH
Telegram: user mode, target=$TARGET
Hotkey hint: $HOTKEY

Next: log in as yourself (one-time):
  python3 $SCRIPT_DIR/telegram_login.py $CONFIG_PATH

Bind keyboard shortcuts to:
  Start:  $SCRIPT_DIR/ptt-record.sh start --config "$CONFIG_PATH"
  Stop:   $SCRIPT_DIR/ptt-record.sh stop --config "$CONFIG_PATH"
  Toggle: $SCRIPT_DIR/ptt-record.sh toggle --config "$CONFIG_PATH"
EOF
