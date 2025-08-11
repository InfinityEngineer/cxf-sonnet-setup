#!/usr/bin/env bash
set -euo pipefail

HOST="${NEMARION_HOST:-nemarion.local}"
WIDTH="${STREAM_WIDTH:-1600}"
HEIGHT="${STREAM_HEIGHT:-900}"
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"
SERVICE_NAME="cxf-moonlight"

[[ $EUID -eq 0 ]] || { echo "Please run with sudo."; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
CACHE_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

u() {
  sudo -u "$TARGET_USER" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

echo "== Moonlight install for ${TARGET_USER} =="

# Cleanup old service/key
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" || true
rm -f "${KEY_FILE}" || true

# Install Moonlight if missing
if ! command -v moonlight >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl lsb-release
  curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
    | sudo -E bash
  apt-get update
  apt-get install -y moonlight-embedded
fi

mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache" "${TARGET_HOME}/.config"

# Create service file using width/height flags
cat <<EOF > "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
[Unit]
Description=Moonlight autostart to stream ${HOST}
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
ExecStart=/usr/bin/moonlight stream ${HOST} -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "${TARGET_USER}" || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# Force re-pair
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true
sudo -u "${TARGET_USER}" DISPLAY=:0 moonlight pair "${HOST}" || true

# Start service if key exists
if [[ -f "${KEY_FILE}" ]]; then
  u systemctl --user start "${SERVICE_NAME}"
  echo "Streaming should be live. Logs:"
  echo "  sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
else
  echo "Pairing key not found — re-run 'moonlight pair ${HOST}' then start service."
fi
