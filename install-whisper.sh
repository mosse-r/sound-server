#!/usr/bin/env bash
set -euo pipefail

# Installs Whisper CLI in an isolated venv and symlinks `whisper` into ~/.local/bin
# Usage:
#   ./install-whisper.sh [--venv ~/.local/share/sound-server/whisper-venv] [--model base]

VENV_PATH="${HOME}/.local/share/sound-server/whisper-venv"
MODEL="base"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv) VENV_PATH="${2:-}"; shift 2;;
    --model) MODEL="${2:-}"; shift 2;;
    -h|--help)
      cat <<'EOF'
Usage:
  ./install-whisper.sh [--venv ~/.local/share/sound-server/whisper-venv] [--model base]
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

sudo apt-get update
sudo apt-get install -y python3 python3-venv python3-pip ffmpeg

mkdir -p "$(dirname "$VENV_PATH")" "${HOME}/.local/bin"
python3 -m venv "$VENV_PATH"
"$VENV_PATH/bin/pip" install --upgrade pip wheel
"$VENV_PATH/bin/pip" install -U openai-whisper

ln -sf "$VENV_PATH/bin/whisper" "${HOME}/.local/bin/whisper"

if ! grep -q 'HOME/.local/bin' <<<":${PATH}:"; then
  echo "⚠️ ~/.local/bin is not on PATH in this shell. Add this to your shell rc:"
  echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

TMP_WAV="/tmp/sound-server-whisper-test.wav"
ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 1 "$TMP_WAV" -y -loglevel error || true
"${HOME}/.local/bin/whisper" "$TMP_WAV" --model "$MODEL" --language en --output_format txt --output_dir /tmp >/dev/null 2>&1 || true

cat <<EOF
✅ Whisper CLI installed.
- venv: $VENV_PATH
- binary: ${HOME}/.local/bin/whisper
- test model primed: $MODEL (first real transcription may still download model assets)

Quick test:
  whisper /path/to/audio.wav --model $MODEL --language en --output_format txt --output_dir /tmp
EOF
