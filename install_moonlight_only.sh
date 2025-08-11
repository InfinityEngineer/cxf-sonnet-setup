#!/usr/bin/env bash
# Moonlight-only clean installer for Raspberry Pi (CXF-Sonnet)
# - Removes previous cxf-moonlight units/keys
# - Installs moonlight-embedded from official repo
# - Creates a USER-MODE systemd service for the login user (no sudo prompts)
# - Autostarts after pairing exists

set -euo pipefail

# ---------- Config (edit if you like) ----------
HOST="${NEMARION_HOST:-nemarion.local}"
RES="${STREAM_RES:-1600x900}"   # native for your Upstar VGA monitor
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"  # kbps
SERVICE_NAME="cxf-moonlight"
# ----------------------------------------------

[[ $EUID -eq 0 ]] || { echo "Please run with sudo."; exit 1; }

# Figure out target (desktop) user to own/run Moonlight
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
USER_SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
KEYS_PATH="${TARGET_HOME}/.config/moonlight/keys/client.pem"

echo "== Moonlight clean install for user: ${TARGET_USER} (UID ${TARGET_UID}) =="

# ---------- Stop & remove any old services/keys ----------
echo "-- Stopping/removing any previous ${SERVICE_NAME} services"

# system-mode unit
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  systemctl stop "${SERVICE_NAME}" || true
  systemctl disable "${SERVICE_NAME}" || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
fi

# user-mode unit (old)
sudo -u "$TARGET_USER" bash -lc "
  systemctl --user stop ${SERVICE_NAME} 2>/dev/null || true
  systemctl --user disable ${SERVICE_NAME} 2>/dev/null || true
"
rm -f "${USER_SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true

# legacy root key that caused confusion
rm -rf /root/.config/moonlight 2>/dev/null || true

# ---------- Install Moonlight from official repo ----------
echo "-- Installing Moonlight (official repo)"
apt-get update
apt-get install -y ca-certificates curl lsb-release

# Add/refresh Cloudsmith repo (idempotent)
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash

apt-get update
apt-get install -y moonlight-embedded

# ---------- Create user-mode systemd service ----------
echo "-- Creating user-mode systemd service for ${TARGET_USER}"
mkdir -p "${USER_SYSTEMD_DIR}"

cat > "${USER_SYSTEMD_DIR}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Moonlight autostart to stream ${HOST}
After=network-online.target
Wants=network-online.target
# only start after pairing exists (user key)
ConditionPathExists=%h/.config/moonlight/keys/client.pem

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

# Let user services run without an active login session
loginctl enable-linger "${TARGET_USER}" >/dev/null

# Reload/enable user service
sudo -u "$TARGET_USER" bash -lc "
  systemctl --user daemon-reload
  systemctl --user enable ${SERVICE_NAME}
"

echo
echo "== Install complete =="
echo "Next steps:"
echo "1) Pair once (this creates your user key so the service can start):"
echo "     sudo -u ${TARGET_USER} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} DISPLAY=:0 \\"
echo "       moonlight pair ${HOST}"
echo "   (Approve the PIN in Sunshine on Nemarion.)"
echo
echo "2) Test manually (optional):"
echo "     sudo -u ${TARGET_USER} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} DISPLAY=:0 \\"
echo "       moonlight stream ${HOST} --resolution ${RES} --fps ${FPS} --bitrate ${BITRATE}"
echo
echo "3) Start the autostart service (it will also run on next boot automatically):"
echo "     sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
echo
echo "Troubleshooting:"
echo "  - If the service doesn't start, check pairing key exists:"
echo "      ls -l ${KEYS_PATH}"
echo "  - View logs:"
echo "      sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
