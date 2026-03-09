#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/sound-server"
ENV_FILE="/etc/sound-server.env"
SERVICE_FILE="/etc/systemd/system/sound-server.service"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apt-get update
apt-get install -y python3 python3-venv python3-pip mpv ffmpeg espeak-ng alsa-utils curl

id -u soundsvc >/dev/null 2>&1 || useradd --system --home-dir /var/lib/sound-server --create-home --shell /usr/sbin/nologin soundsvc
usermod -aG audio soundsvc || true

mkdir -p "${APP_DIR}"
cp "${SCRIPT_DIR}/sound_server.py" "${APP_DIR}/sound_server.py"
cp "${SCRIPT_DIR}/requirements.txt" "${APP_DIR}/requirements.txt"

python3 -m venv "${APP_DIR}/.venv"
"${APP_DIR}/.venv/bin/pip" install --upgrade pip
"${APP_DIR}/.venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${SCRIPT_DIR}/.env.example" "${ENV_FILE}"
  # Generate a strong token and inject it automatically
  TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
  sed -i "s|^SOUND_SERVER_TOKEN=.*$|SOUND_SERVER_TOKEN=${TOKEN}|" "${ENV_FILE}"
  echo "Created ${ENV_FILE} with generated token."
else
  echo "Using existing ${ENV_FILE}"
fi

cp "${SCRIPT_DIR}/sound-server.service" "${SERVICE_FILE}"

chown -R soundsvc:audio "${APP_DIR}"
chmod 750 "${APP_DIR}"
chmod 640 "${ENV_FILE}"
chmod 644 "${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable sound-server
systemctl restart sound-server

echo ""
echo "Install complete."
echo "Service status:"
systemctl --no-pager --full status sound-server | sed -n '1,20p'
echo ""
echo "Token file: ${ENV_FILE}"
echo "Health: curl -s http://127.0.0.1:8088/health"
