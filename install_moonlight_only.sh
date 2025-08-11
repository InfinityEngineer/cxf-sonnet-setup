#!/usr/bin/env bash
set -euo pipefail

# ----------- CONFIGURATION ------------
HOST="${NEMARION_HOST:-nemarion.local}"
RES="${STREAM_RES:-1600x900}"
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"
SERVICE_NAME="cxf-moonlight"
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
CACHE_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"
# ---------------------------------------

echo "### Moonlight installer for ${TARGET_USER} (${TARGET_UID})"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

# Helper to run user-mode commands with correct bus/runtime
u() {
  sudo -u "$TARGET_USER" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

echo "[1/5] Cleaning old configs"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
rm -rf /root/.config/moonlight

echo "[2/5] Installing moonlight-embedded"
apt-get update
apt-get install -y ca-certificates curl lsb-release
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | sudo -E bash
apt-get update
apt-get install -y moonlight-embedded

echo "[3/5] Ensuring pairing directory exists"
mkdir -p "${CACHE_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${CACHE_DIR}"

echo "[4/5] Creating user-level systemd unit"
mkdir -p "${SYSTEMD_DIR}"
cat <<EOF > "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
[Unit]
Description=Moonlight service to stream ${HOST}
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
ExecStart=/usr/bin/moonlight stream ${HOST} --resolution ${RES} --fps ${FPS} --bitrate ${BITRATE}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.config"
loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

echo "[5/5] Pairing and starting service"
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "-- Pairing needed. Approve PIN in Sunshine."
  u DISPLAY=:0 moonlight pair "${HOST}" || true
fi

if [[ -f "${KEY_FILE}" ]]; then
  u systemctl --user start "${SERVICE_NAME}" && echo "Streaming started!"
else
  echo "Pairing failed or key missing. Run:"
  echo "  sudo -u ${TARGET_USER} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} \\"
  echo "    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TARGET_UID}/bus \\"
  echo "    DISPLAY=:0 moonlight pair ${HOST}"
  echo "Then start the service manually:"
  echo "  sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
fi

echo "### Done!"
