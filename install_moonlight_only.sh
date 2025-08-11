#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
HOST="${NEMARION_HOST:-nemarion.local}"
WIDTH="${STREAM_WIDTH:-1600}"      # Upstar monitor native width
HEIGHT="${STREAM_HEIGHT:-900}"     # Upstar monitor native height
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}" # kbps
SERVICE_NAME="cxf-moonlight"
DISABLE_CEC="${DISABLE_CEC:-0}"    # set to 1 to bypass libcec entirely
# ====================================

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
CACHE_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

u() { sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" "$@"; }

echo "== Moonlight install for ${TARGET_USER} (UID ${TARGET_UID}) =="

# 1) Clean any old unit
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
rm -rf /root/.config/moonlight 2>/dev/null || true

# 2) Packages: moonlight + libcec6 (CEC lib) and refresh loader cache
apt-get update
apt-get install -y ca-certificates curl lsb-release libcec6
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash
apt-get update
apt-get install -y moonlight-embedded
ldconfig

# 3) Directories
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache" "${TARGET_HOME}/.config"

# 4) Compose ExecStart
CEC_FLAG=""
# If CEC keeps being a pain, you can set DISABLE_CEC=1 when running the script.
if [[ "$DISABLE_CEC" == "1" ]]; then
  CEC_FLAG="-nocec"
fi

EXEC_LINE="/usr/bin/moonlight stream -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE} ${CEC_FLAG} ${HOST}"

# 5) User-mode systemd unit (no -app; streams Desktop)
cat > "${SYSTEMD_DIR}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Moonlight autostart to stream ${HOST}
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
ExecStart=${EXEC_LINE}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 6) Force clean pair so we definitely get a fresh key
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "-> Pairing (approve PIN in Sunshine on ${HOST})"
sudo -u "${TARGET_USER}" DISPLAY=:0 moonlight pair "${HOST}" || true

if [[ -f "${KEY_FILE}" ]]; then
  echo "-- Key present; starting service"
  u systemctl --user start "${SERVICE_NAME}"
  echo "OK. Logs: sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
else
  echo "No key at ${KEY_FILE}. If you missed the PIN:"
  echo "  sudo -u ${TARGET_USER} moonlight pair ${HOST}"
  echo "Then: sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
fi
