#!/usr/bin/env bash
# install_moonlight_only.sh
# Moonlight-only installer for CXF-Sonnet (Pi)
# - Installs moonlight-embedded from official repo (if missing)
# - Creates user-mode systemd service (runs as login user)
# - FORCE re-pairs (unpair -> pair) to avoid stale state
# - Starts streaming after key exists

set -euo pipefail

# -------- Config (override via env when calling) --------
HOST="${NEMARION_HOST:-nemarion.local}"       # Sunshine host (Nemarion)
RES="${STREAM_RES:-1600x900}"                  # Your 20" monitor native res
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"             # kbps
SERVICE_NAME="cxf-moonlight"
# -------------------------------------------------------

[[ $EUID -eq 0 ]] || { echo "Please run with sudo."; exit 1; }

# Pick the user who will own/run Moonlight
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
CACHE_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

# Helper: run as TARGET_USER with a valid user bus/runtime
u() {
  sudo -u "$TARGET_USER" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

echo "== Moonlight install for ${TARGET_USER} (UID ${TARGET_UID}) =="

# 1) Clean any previous units/keys to avoid conflicts
echo "-- Cleaning old unit/key (if any)"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
# nuke legacy root-side moonlight dir to prevent confusion
rm -rf /root/.config/moonlight 2>/dev/null || true

# 2) Install Moonlight (official repo) if missing
if ! command -v moonlight >/dev/null 2>&1; then
  echo "-- Installing moonlight-embedded (official repo)"
  apt-get update
  apt-get install -y ca-certificates curl lsb-release
  curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
    | sudo -E bash
  apt-get update
  apt-get install -y moonlight-embedded
else
  echo "-- moonlight-embedded already present"
fi

# 3) Ensure directories
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache" "${TARGET_HOME}/.config"

# 4) Create user-mode systemd unit (waits for ~/.cache/moonlight/client.pem)
echo "-- Writing user-mode systemd unit"
cat <<EOF > "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
[Unit]
Description=Moonlight autostart to stream ${HOST}
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

loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 5) FORCE re-pair: stop service, remove key, unpair, then pair
echo "-- Forcing clean pairing"
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
# 'unpair' may fail if not paired yet; that's fine
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "   -> Initiating pairing with ${HOST} (approve PIN in Sunshine)"
# Plain user context is fine for pairing; no DBUS needed
sudo -u "${TARGET_USER}" DISPLAY=:0 moonlight pair "${HOST}" || true

# 6) Start service if key exists
if [[ -f "${KEY_FILE}" ]]; then
  echo "-- Key found at ${KEY_FILE}; starting ${SERVICE_NAME}"
  u systemctl --user start "${SERVICE_NAME}"
  echo "OK: Streaming should be live. Logs:"
  echo "  sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
else
  echo "NOTE: Pairing key not found at ${KEY_FILE}."
  echo "If you missed the PIN prompt, run:"
  echo "  sudo -u ${TARGET_USER} moonlight pair ${HOST}"
  echo "Then start the service:"
  echo "  sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
fi

echo "== Done =="
