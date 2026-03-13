#!/usr/bin/env bash
# Print PTT key-binding commands and optional xbindkeys snippet.
# Usage: ./ptt-bind-keys.sh [--xbindkeys]
# Run from the sound-server repo.
#
# Modes:
#   (a) One button: bind "toggle" to one key — press to start, press again to stop.
#   (b) Hold-to-talk: bind "start" to key-down and "stop" to key-up (needs xbindkeys or similar).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG="${HOME}/.config/sound-server-ptt/config.json"

PTT_TOGGLE="$SCRIPT_DIR/ptt-record.sh toggle --config $CONFIG"
PTT_START="$SCRIPT_DIR/ptt-record.sh start --config $CONFIG"
PTT_STOP="$SCRIPT_DIR/ptt-record.sh stop --config $CONFIG"

echo "PTT commands (use in keyboard shortcut settings or xbindkeys):"
echo ""
echo "  (a) One button — press to start, press again to stop:"
echo "      Toggle:  $PTT_TOGGLE"
echo ""
echo "  (b) Hold-to-talk — start on key down, stop on key up:"
echo "      Start:   $PTT_START"
echo "      Stop:    $PTT_STOP"
echo ""

if [[ "${1:-}" == "--xbindkeys" ]]; then
  XB="$HOME/.xbindkeysrc"
  echo "Appending to $XB (Ctrl+Alt+Space = toggle)"
  if ! command -v xbindkeys >/dev/null 2>&1; then
    echo "Install xbindkeys: sudo apt install xbindkeys"
    exit 1
  fi
  {
    echo ""
    echo "# PTT (sound-server) — one-button toggle"
    echo "\"$PTT_TOGGLE\""
    echo "  control+alt + space"
  } >> "$XB"
  echo "Done. Run 'xbindkeys' to reload (or restart your session)."
  echo "For hold-to-talk, add a second binding with key release (see xbindkeys -k)."
fi
