#!/usr/bin/env bash
# Quick test for PTT toggle: start → stop without "PTT busy".
# Run from repo. Uses default config ~/.config/sound-server-ptt/config.json.
# Optional: --no-telegram to skip sending (only test start/stop).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG="${HOME}/.config/sound-server-ptt/config.json"
PTT="$SCRIPT_DIR/ptt-record.sh"

if [[ ! -f "$CONFIG" ]]; then
  echo "No config at $CONFIG. Run setup-ptt.sh first."
  exit 1
fi

echo "=== PTT toggle test ==="
echo "0) Cleanup (stop any existing recording)..."
"$PTT" stop --config "$CONFIG" 2>/dev/null || true
sleep 0.5
echo "1) Toggle (start)..."
out_start=$("$PTT" toggle --config "$CONFIG" 2>&1) || true
echo "   $out_start"
if echo "$out_start" | grep -q "PTT busy"; then
  echo "   FAIL: got 'PTT busy' on start"
  exit 1
fi
if ! echo "$out_start" | grep -q "Recording started"; then
  echo "   FAIL: expected 'Recording started', got: $out_start"
  exit 1
fi

echo "2) Wait 1s (recording)..."
sleep 1

echo "3) Toggle (stop)..."
out_stop=$("$PTT" toggle --config "$CONFIG" 2>&1) || true
echo "   $out_stop"
if echo "$out_stop" | grep -q "PTT busy"; then
  echo "   FAIL: got 'PTT busy' on stop (lock not released)"
  exit 1
fi
if ! echo "$out_stop" | grep -q "Recording stopped"; then
  echo "   FAIL: expected 'Recording stopped', got: $out_stop"
  exit 1
fi

echo "4) Toggle again (should start, no PTT busy)..."
out_again=$("$PTT" toggle --config "$CONFIG" 2>&1) || true
echo "   $out_again"
if echo "$out_again" | grep -q "PTT busy"; then
  echo "   FAIL: got 'PTT busy' on second start"
  exit 1
fi
if ! echo "$out_again" | grep -q "Recording started"; then
  echo "   FAIL: expected 'Recording started' on second toggle"
  exit 1
fi

echo "5) Stop so we leave clean..."
"$PTT" stop --config "$CONFIG" 2>/dev/null || true

echo "=== Toggle test passed (no PTT busy) ==="
