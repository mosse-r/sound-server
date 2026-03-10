#!/usr/bin/env bash
# End-to-end test: POST test-assets/beep.wav to /play and confirm task completes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEEP_FILE="${SCRIPT_DIR}/test-assets/beep.wav"
BASE_URL="${1:-http://127.0.0.1:8088}"
TOKEN="${SOUND_SERVER_TOKEN:-${2:-}}"

if [[ -z "${TOKEN}" ]]; then
  echo "Usage: SOUND_SERVER_TOKEN=... $0 [base_url]"
  echo "  Or: $0 <base_url> <token>"
  exit 1
fi

if [[ ! -f "${BEEP_FILE}" ]]; then
  echo "Missing ${BEEP_FILE}"
  exit 1
fi

echo "[1/3] Health"
curl -fsS "${BASE_URL}/health" | jq -e '.ok == true' >/dev/null
echo "  OK"

echo "[2/3] POST /play (beep.wav)"
RESP=$(curl -fsS -X POST "${BASE_URL}/play" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: audio/wav" \
  -H "X-Filename: beep.wav" \
  --data-binary @"${BEEP_FILE}")
TASK_ID=$(echo "${RESP}" | jq -r '.task_id')
echo "  task_id=${TASK_ID}"

echo "[3/3] Wait for task to finish"
for i in {1..15}; do
  STATUS=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${BASE_URL}/status" | jq -r '.status.recent[0]')
  S=$(echo "${STATUS}" | jq -r '.status')
  K=$(echo "${STATUS}" | jq -r '.id')
  if [[ "${K}" == "${TASK_ID}" ]]; then
    if [[ "${S}" == "done" ]]; then
      echo "  Task ${TASK_ID} done."
      echo ""
      echo "E2E play test passed."
      exit 0
    fi
    if [[ "${S}" == "failed" ]]; then
      echo "  Task ${TASK_ID} failed: $(echo "${STATUS}" | jq -r '.error')"
      exit 1
    fi
  fi
  sleep 0.5
done
echo "  Timeout waiting for task ${TASK_ID}"
exit 1
