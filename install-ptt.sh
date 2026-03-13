#!/usr/bin/env bash
set -euo pipefail

# User-level PTT install: installs deps and writes config for Telegram (user auth).
# Usage:
#   ./install-ptt.sh --api-id <id> --api-hash <hash> [--target "me"] [--hotkey "Ctrl+Alt+Space"]
#
# Get api_id and api_hash from https://my.telegram.org/apps
# Then run: python3 telegram_login.py ~/.config/sound-server-ptt/config.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONFIG_PATH="${HOME}/.config/sound-server-ptt/config.json"

API_ID=""
API_HASH=""
TARGET="me"
HOTKEY="Ctrl+Alt+Space"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-id) API_ID="${2:-}"; shift 2;;
    --api-hash) API_HASH="${2:-}"; shift 2;;
    --target) TARGET="${2:-me}"; shift 2;;
    --hotkey) HOTKEY="${2:-}"; shift 2;;
    --config) CONFIG_PATH="${2:-}"; shift 2;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./install-ptt.sh --api-id <id> --api-hash <hash> [--target "me"] [--hotkey "Ctrl+Alt+Space"] [--config path]

  Get API credentials from https://my.telegram.org/apps
  Then run: python3 telegram_login.py <config_path>
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$API_ID" || -z "$API_HASH" ]]; then
  echo "Missing required args. Example:"
  echo "  ./install-ptt.sh --api-id 12345 --api-hash your_api_hash --target me"
  exit 1
fi

# Delegate to full setup
exec "$SCRIPT_DIR/setup-ptt.sh" \
  --api-id "$API_ID" \
  --api-hash "$API_HASH" \
  --target "$TARGET" \
  --hotkey "$HOTKEY" \
  --config "$CONFIG_PATH" \
  --skip-whisper
