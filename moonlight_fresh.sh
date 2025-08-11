#!/usr/bin/env bash
# Fresh install moonlight script - avoids CEC issues entirely
set -euo pipefail

# Config
HOST="${NEMARION_HOST:-nemarion.local}"
USER_NAME="${TARGET_USER:-clay}"
WIDTH="${STREAM_WIDTH:-1600}"
HEIGHT="${STREAM_HEIGHT:-900}"
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"
APP_NAME="${APP_NAME:-Desktop}"
SERVICE_NAME="cxf-moonlight"

USER_UID="$(id -u "${USER_NAME}")"
SYSTEMD_DIR="/home/${USER_NAME}/.config/systemd/user"
CACHE_DIR="/home/${USER_NAME}/.cache/moonlight"

# Helper function
u() {
  sudo -u "${USER_NAME}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    "$@"
}

echo "== Fresh Moonlight Install (CEC-free) =="

# 1) Install moonlight WITHOUT any CEC packages
sudo apt-get update
sudo apt-get install -y ca-certificates curl lsb-release

# Add moonlight repo
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash

sudo apt-get update
sudo apt-get install -y moonlight-embedded

# DO NOT install any libcec packages

# 2) Set up user session properly  
sudo systemctl start user@${USER_UID}
sudo systemctl enable user@${USER_UID}
sudo loginctl enable-linger "${USER_NAME}"

# 3) Create directories
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
sudo chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.cache" "/home/${USER_NAME}/.config"

# 4) Create service file
EXEC_LINE="/usr/bin/moonlight -nocec stream -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE} -app ${APP_NAME} ${HOST}"

cat > "${SYSTEMD_DIR}/${SERVICE_NAME}.service" << 'EOF'
[Unit]
Description=Moonlight stream to nemarion.local
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=EXEC_PLACEHOLDER
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

sed -i "s|EXEC_PLACEHOLDER|${EXEC_LINE}|g" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# 5) Enable service
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 6) Pair with host
echo "-> Pairing with ${HOST} (approve PIN prompt)"
sudo -u "${USER_NAME}" DISPLAY=:0 moonlight pair "${HOST}"

# 7) Start service if pairing worked
if [[ -f "${CACHE_DIR}/client.pem" ]]; then
  echo "-> Starting service"
  u systemctl --user start "${SERVICE_NAME}"
  echo "✓ Moonlight should be streaming!"
else
  echo "Pairing failed. Run: sudo -u ${USER_NAME} moonlight pair ${HOST}"
fi

echo "Check status: sudo -u ${USER_NAME} systemctl --user status ${SERVICE_NAME}"
