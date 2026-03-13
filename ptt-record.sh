#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-toggle}"
shift || true

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  echo "Usage: $0 [start|stop|toggle] [--config path]"
  exit 0
fi

CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    -h|--help)
      echo "Usage: $0 [start|stop|toggle] [--config path]"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Config not found: $CONFIG_PATH"
  exit 1
fi

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
require jq
require arecord
require curl

STATE_DIR="${HOME}/.local/state/sound-server-ptt"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/record.pid"
WAV_FILE="$STATE_DIR/recording.wav"
LOCK_FILE="$STATE_DIR/lock"

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "PTT busy"; exit 1; }

BOT_TOKEN=$(jq -r '.telegram.bot_token' "$CONFIG_PATH")
CHAT_ID=$(jq -r '.telegram.chat_id' "$CONFIG_PATH")
RATE=$(jq -r '.audio.rate_hz // 16000' "$CONFIG_PATH")
CHANNELS=$(jq -r '.audio.channels // 1' "$CONFIG_PATH")
FORMAT=$(jq -r '.audio.format // "S16_LE"' "$CONFIG_PATH")
DEVICE=$(jq -r '.audio.device // "default"' "$CONFIG_PATH")
START_BEEP=$(jq -r '.audio.start_beep // empty' "$CONFIG_PATH")
STOP_BEEP=$(jq -r '.audio.stop_beep // empty' "$CONFIG_PATH")
STT_TEMPLATE=$(jq -r '.stt.command_template // empty' "$CONFIG_PATH")
RESULT_TEMPLATE=$(jq -r '.stt.result_file_template // empty' "$CONFIG_PATH")

play_beep() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  if command -v aplay >/dev/null 2>&1; then
    aplay -q "$file" || true
  elif command -v mpv >/dev/null 2>&1; then
    mpv --really-quiet --no-video "$file" || true
  fi
}

send_telegram() {
  local text="$1"
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null
}

is_recording() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_recording() {
  if is_recording; then
    echo "Already recording"
    return 0
  fi
  rm -f "$WAV_FILE"
  play_beep "$START_BEEP"
  arecord -q -D "$DEVICE" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$WAV_FILE" &
  echo $! > "$PID_FILE"
  echo "Recording started"
}

transcribe_and_send() {
  [[ -s "$WAV_FILE" ]] || { echo "No recording captured"; return 1; }

  local outdir="$STATE_DIR/stt"
  mkdir -p "$outdir"
  local stem
  stem=$(basename "$WAV_FILE" .wav)

  if [[ -z "$STT_TEMPLATE" ]]; then
    send_telegram "(PTT) Recording captured but no STT template configured."
    return 1
  fi

  if ! command -v whisper >/dev/null 2>&1; then
    send_telegram "(PTT) STT failed: 'whisper' CLI not installed on this machine."
    return 1
  fi

  local cmd="$STT_TEMPLATE"
  cmd="${cmd//\{input\}/$WAV_FILE}"
  cmd="${cmd//\{output_dir\}/$outdir}"
  cmd="${cmd//\{input_stem\}/$stem}"
  bash -lc "$cmd" >/dev/null 2>&1 || {
    send_telegram "(PTT) STT command failed."
    return 1
  }

  local result="$RESULT_TEMPLATE"
  result="${result//\{output_dir\}/$outdir}"
  result="${result//\{input_stem\}/$stem}"
  [[ -f "$result" ]] || result="$outdir/$stem.txt"

  if [[ ! -s "$result" ]]; then
    send_telegram "(PTT) STT completed but transcript is empty."
    return 1
  fi

  local text
  text=$(cat "$result")
  send_telegram "$text"
  echo "Transcript sent"
}

stop_recording() {
  if ! is_recording; then
    echo "Not recording"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  play_beep "$STOP_BEEP"
  transcribe_and_send || true
  echo "Recording stopped"
}

case "$ACTION" in
  start) start_recording ;;
  stop) stop_recording ;;
  toggle)
    if is_recording; then stop_recording; else start_recording; fi
    ;;
  *) echo "Unknown action: $ACTION"; exit 1 ;;
esac
