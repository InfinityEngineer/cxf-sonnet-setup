#!/usr/bin/env bash
# install_moonlight_only.sh — CXF Sonnet (Pi 3B+) Moonlight setup
# Fixed version with proper heredoc handling and -nocec placement

set -euo pipefail

# ===== Config (override via env) =====
HOST="${NEMARION_HOST:-nemarion.local}"   # Sunshine host
USER_NAME="${TARGET_USER:-clay}"          # login user on the Pi
WIDTH="${STREAM_WIDTH:-1600}"             # Upstar native
HEIGHT="${STREAM_HEIGHT:-900}"
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"        # kbps
APP_NAME="${APP_NAME:-Desktop}"           # must match Sunshine app name
SERVICE_NAME="cxf-moonlight"
# =====================================

USER_HOME="$(eval echo "~${USER_NAME}")"
USER_UID="$(id -u "${USER_NAME}")"
SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
CACHE_DIR="${USER_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

# Run as the target user with a valid user session bus/runtime
u() {
  sudo -u "${USER_NAME}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    "$@"
}

echo "== Moonlight Embedded install for ${USER_NAME} (Pi 3B+) =="

# 1) Clean CEC packages first (fixes config file issues)
sudo apt-get remove --purge libcec libcec3 libcec4 libcec6 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get update

# 2) Install Moonlight repository and packages
sudo apt-get install -y ca-certificates curl lsb-release
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash
sudo apt-get update
sudo apt-get install -y moonlight-embedded

# 3) Clean install CEC library (prevents config file errors)
sudo apt-get install -y libcec6
sudo ldconfig

# 2) Clean old unit/config
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
rm -rf /root/.config/moonlight 2>/dev/null || true

# 3) Ensure dirs and ownership
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
sudo chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.cache" "${USER_HOME}/.config"

# 4) Clean moonlight config completely to avoid stale CEC settings
rm -rf "${USER_HOME}/.config/moonlight" 2>/dev/null || true
rm -rf "${CACHE_DIR}" 2>/dev/null || true

# 5) ExecStart line - IMPORTANT: -nocec comes BEFORE 'stream'
EXEC_LINE="/usr/bin/moonlight -nocec stream -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE} -app ${APP_NAME} ${HOST}"

# 6) Write user-mode systemd unit using safe method (no heredoc issues)
cat > "${SYSTEMD_DIR}/${SERVICE_NAME}.service" << 'SYSTEMD_EOF'
[Unit]
Description=Moonlight autostart to stream __HOST__
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/__UID__
ExecStart=__EXEC__
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
SYSTEMD_EOF

# Replace placeholders safely
sed -i "s|__HOST__|${HOST}|g" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
sed -i "s|__UID__|${USER_UID}|g" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
# Escape special characters in EXEC_LINE for sed
ESC_EXEC=$(printf '%s\n' "${EXEC_LINE}" | sed 's|[[\\/.*^$()+?{}\|]|\\&|g')
sed -i "s|__EXEC__|${ESC_EXEC}|g" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"

loginctl enable-linger "${USER_NAME}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 7) Force clean pair (unpair -> pair)
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "-> Pairing (approve PIN in Sunshine on ${HOST})"
sudo -u "${USER_NAME}" DISPLAY=:0 moonlight pair "${HOST}" || true

# 8) Start if key exists; otherwise print next steps
if [[ -f "${KEY_FILE}" ]]; then
  echo "-- Key present at ${KEY_FILE}; starting ${SERVICE_NAME}"
  u systemctl --user start "${SERVICE_NAME}"
  echo "OK: Streaming should be live."
else
  echo "No key at ${KEY_FILE}. If you missed the PIN prompt, run:"
  echo "  sudo -u ${USER_NAME} moonlight pair ${HOST}"
  echo "Then start:"
  echo "  sudo -u ${USER_NAME} systemctl --user start ${SERVICE_NAME}"
fi

echo "Logs: sudo -u ${USER_NAME} journalctl --user -u ${SERVICE_NAME} -f"
