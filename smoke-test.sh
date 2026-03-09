#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8088}"
TOKEN="${SOUND_SERVER_TOKEN:-${2:-}}"

if [[ -z "${TOKEN}" ]]; then
  echo "Usage: SOUND_SERVER_TOKEN=... $0 [base_url]"
  exit 1
fi

echo "[1/4] Health"
curl -fsS "${BASE_URL}/health" | jq .

echo "[2/4] Status (auth)"
curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/status" | jq .

echo "[3/4] Speak queue"
curl -fsS -X POST "${BASE_URL}/speak" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"text":"Sound server smoke test"}' | jq .

echo "[4/4] Done"
