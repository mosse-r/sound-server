#!/usr/bin/env bash
set -euo pipefail
# Ensure jq, arecord, python3 are found when run from a keyboard shortcut (minimal env)
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

ACTION="${1:-toggle}"
shift || true

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
  echo "Usage: $0 [start|stop|toggle] [--config path]"
  exit 0
fi

CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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

STATE_DIR="${HOME}/.local/state/sound-server-ptt"
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/ptt.log"
log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE" 2>/dev/null || true; }
log "invoked: $ACTION"
PID_FILE="$STATE_DIR/record.pid"
WAV_FILE="$STATE_DIR/recording.wav"
LOCK_FILE="$STATE_DIR/lock"

# Hold lock only for the quick start/stop critical section; release before beeps/transcribe
acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || { echo "PTT busy"; exit 1; }
}
release_lock() { exec 9>&-; }

TELEGRAM_MODE=$(jq -r '.telegram.mode // "user"' "$CONFIG_PATH")
RATE=$(jq -r '.audio.rate_hz // 16000' "$CONFIG_PATH")
CHANNELS=$(jq -r '.audio.channels // 1' "$CONFIG_PATH")
FORMAT=$(jq -r '.audio.format // "S16_LE"' "$CONFIG_PATH")
DEVICE=$(jq -r '.audio.device // "default"' "$CONFIG_PATH")
START_BEEP=$(jq -r '.audio.start_beep // empty' "$CONFIG_PATH")
STOP_BEEP=$(jq -r '.audio.stop_beep // empty' "$CONFIG_PATH")
ERROR_BEEP=$(jq -r '.audio.error_beep // empty' "$CONFIG_PATH")
BEEP_VOLUME=$(jq -r '.audio.beep_volume // 1' "$CONFIG_PATH")
DIM_VOLUME_ON_RECORD=$(jq -r '.audio.dim_volume_on_record // false' "$CONFIG_PATH")
DIM_VOLUME_PERCENT=$(jq -r '.audio.dim_volume_percent // 25' "$CONFIG_PATH")
NOTIFY_ENABLED=$(jq -r '.notifications.enabled // true' "$CONFIG_PATH")
NOTIFY_SENT_TIMEOUT_SEC=$(jq -r '.notifications.sent_timeout_sec // 10' "$CONFIG_PATH")
NOTIFY_RECORDING_TIMEOUT_SEC=$(jq -r '.notifications.recording_timeout_sec // 60' "$CONFIG_PATH")
STT_TEMPLATE=$(jq -r '.stt.command_template // empty' "$CONFIG_PATH")
RESULT_TEMPLATE=$(jq -r '.stt.result_file_template // empty' "$CONFIG_PATH")

SAVED_VOLUME_FILE="$STATE_DIR/saved_volume"

# Toast notification (notify-send). Timeout in seconds; 0 = use default.
notify_toast() {
  [[ "$NOTIFY_ENABLED" == "true" ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  local title="$1" body="$2" timeout_sec="${3:-0}" icon="${4:-}"
  local timeout_ms=0
  [[ "$timeout_sec" -gt 0 ]] 2>/dev/null && timeout_ms=$((timeout_sec * 1000))
  local args=(-c "ptt-record")
  [[ -n "$icon" ]] && args+=(-i "$icon")
  [[ "$timeout_ms" -gt 0 ]] && args+=(-t "$timeout_ms")
  notify-send "${args[@]}" "$title" "$body" 2>/dev/null || true
}

dim_speaker_volume() {
  [[ "$DIM_VOLUME_ON_RECORD" == "true" ]] || return 0
  command -v pactl >/dev/null 2>&1 || return 0
  # Only save current volume if we're not already dimmed (e.g. first start, or after a crash)
  if [[ ! -f "$SAVED_VOLUME_FILE" ]]; then
    local pct
    pct=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+%' | head -1)
    [[ -n "$pct" ]] && echo "$pct" > "$SAVED_VOLUME_FILE"
  fi
  pactl set-sink-volume @DEFAULT_SINK@ "${DIM_VOLUME_PERCENT}%" 2>/dev/null || true
  log "Speaker volume dimmed to ${DIM_VOLUME_PERCENT}%"
}

restore_speaker_volume() {
  [[ -f "$SAVED_VOLUME_FILE" ]] || return 0
  command -v pactl >/dev/null 2>&1 || return 0
  local pct
  pct=$(cat "$SAVED_VOLUME_FILE")
  rm -f "$SAVED_VOLUME_FILE"
  pactl set-sink-volume @DEFAULT_SINK@ "$pct" 2>/dev/null || true
  log "Speaker volume restored to $pct"
}

play_beep() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  case "$file" in
    *.wav)
      if command -v aplay >/dev/null 2>&1; then
        if [[ "$BEEP_VOLUME" != "1" && "$BEEP_VOLUME" != "1.0" ]] && command -v ffmpeg >/dev/null 2>&1; then
          ffmpeg -nostdin -y -i "$file" -filter:a "volume=${BEEP_VOLUME}" -f s16le -ac 1 -ar 44100 - 2>/dev/null | aplay -q 2>/dev/null || true
        else
          aplay -q "$file" || true
        fi
      fi
      ;;
    *)
      if command -v mpv >/dev/null 2>&1; then
        if [[ "$BEEP_VOLUME" != "1" && "$BEEP_VOLUME" != "1.0" ]]; then
          mpv --really-quiet --no-video --af="volume=${BEEP_VOLUME}" "$file" || true
        else
          mpv --really-quiet --no-video "$file" || true
        fi
      elif command -v ffmpeg >/dev/null 2>&1 && command -v aplay >/dev/null 2>&1; then
        if [[ "$BEEP_VOLUME" != "1" && "$BEEP_VOLUME" != "1.0" ]]; then
          ffmpeg -nostdin -y -i "$file" -filter:a "volume=${BEEP_VOLUME}" -f s16le -ac 1 -ar 44100 - 2>/dev/null | aplay -q 2>/dev/null || true
        else
          ffmpeg -nostdin -y -i "$file" -f s16le -ac 1 -ar 44100 - 2>/dev/null | aplay -q 2>/dev/null || true
        fi
      else
        aplay -q "$file" 2>/dev/null || true
      fi
      ;;
  esac
}

send_telegram() {
  local text="$1"
  if [[ "$TELEGRAM_MODE" != "user" ]]; then
    echo "Telegram not configured (telegram.mode=user required). Message: $text" >&2
    return 1
  fi
  local sender="$SCRIPT_DIR/telegram_send.py"
  [[ -f "$sender" ]] || sender="telegram_send.py"
  if ! python3 "$sender" "$CONFIG_PATH" "$text"; then
    echo "(PTT) Could not send to Telegram. Run telegram_login.py if needed." >&2
    return 1
  fi
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
  # Beep in background; close fd 9 so subshell doesn't hold the lock
  ( exec 9>&-; play_beep "$START_BEEP" ) &
  disown 2>/dev/null || true
  # Run arecord in subshell that closes fd 9 so it doesn't inherit the lock.
  # Redirect stderr so killing it doesn't print "read error: Interrupted system call"
  ( exec 9>&-; exec arecord -q -D "$DEVICE" -f "$FORMAT" -r "$RATE" -c "$CHANNELS" "$WAV_FILE" 2>/dev/null ) &
  echo $! > "$PID_FILE"
  disown 2>/dev/null || true
  dim_speaker_volume
  notify_toast "Recording" "PTT recording…" "$NOTIFY_RECORDING_TIMEOUT_SEC" "audio-input-microphone"
  log "Recording started"
  echo "Recording started"
}

transcribe_and_send() {
  if [[ ! -s "$WAV_FILE" ]]; then
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "No recording captured" 3 "dialog-error"
    echo "No recording captured"
    return 1
  fi

  local outdir="$STATE_DIR/stt"
  mkdir -p "$outdir"
  local stem
  stem=$(basename "$WAV_FILE" .wav)

  if [[ -z "$STT_TEMPLATE" ]]; then
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "No STT configured" 3 "dialog-error"
    log "No STT template configured"
    return 1
  fi

  if ! command -v whisper >/dev/null 2>&1; then
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "Whisper not installed" 3 "dialog-error"
    log "Whisper CLI not installed"
    return 1
  fi

  local cmd="$STT_TEMPLATE"
  cmd="${cmd//\{input\}/$WAV_FILE}"
  cmd="${cmd//\{output_dir\}/$outdir}"
  cmd="${cmd//\{input_stem\}/$stem}"
  if ! bash -lc "$cmd" >/dev/null 2>&1; then
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "Transcription failed" 3 "dialog-error"
    log "STT command failed"
    return 1
  fi

  local result="$RESULT_TEMPLATE"
  result="${result//\{output_dir\}/$outdir}"
  result="${result//\{input_stem\}/$stem}"
  [[ -f "$result" ]] || result="$outdir/$stem.txt"

  if [[ ! -s "$result" ]]; then
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "Transcript empty" 3 "dialog-error"
    log "Transcript empty, not sending"
    return 1
  fi

  local text
  text=$(cat "$result")
  if send_telegram "$text"; then
    local body="$text"
    [[ ${#body} -gt 400 ]] && body="${body:0:397}..."
    notify_toast "Message sent" "$body" "$NOTIFY_SENT_TIMEOUT_SEC" "emblem-ok-symbolic"
    echo "Transcript sent"
  else
    play_beep "$ERROR_BEEP"
    notify_toast "Recording cancelled" "Could not send to Telegram" 3 "dialog-error"
    return 1
  fi
}

# Only stop the recorder and update state (call while holding lock). Caller does beep + transcribe after.
stop_recorder_only() {
  if ! is_recording; then
    echo "Not recording"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  log "Recording stopped"
  echo "Recording stopped"
}

# Full stop: beep, transcribe, restore speaker volume
stop_recording_finish() {
  play_beep "$STOP_BEEP"
  transcribe_and_send || true
  restore_speaker_volume
}

acquire_lock

DID_STOP=false
case "$ACTION" in
  start) start_recording ;;
  stop)
    if is_recording; then
      stop_recorder_only
      DID_STOP=true
    else
      stop_recorder_only
    fi
    ;;
  toggle)
    if is_recording; then
      stop_recorder_only
      DID_STOP=true
    else
      start_recording
    fi
    ;;
  *) release_lock; echo "Unknown action: $ACTION"; exit 1 ;;
esac

release_lock

# Long-running work after lock is released so a second toggle isn't blocked
if [[ "$DID_STOP" == true ]]; then
  stop_recording_finish
fi
