#!/usr/bin/env bash
# install_moonlight_only.sh — CXF Sonnet (Pi) Moonlight setup
# - Installs moonlight-embedded (official repo)
# - Cleans old units/keys, FORCE re-pairs
# - Creates user-mode systemd service (autostarts after key exists)
# - Uses -width/-height with host at END (per man page)

set -euo pipefail

# -------- Config (override via env) --------
HOST="${NEMARION_HOST:-nemarion.local}"
WIDTH="${STREAM_WIDTH:-1600}"        # your Upstar 1600x900
HEIGHT="${STREAM_HEIGHT:-900}"
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"   # kbps
SERVICE_NAME="cxf-moonlight"
# ------------------------------------------

[[ $EUID -eq 0 ]] || { echo "Please run with sudo."; exit 1; }

# Figure out the user who should own/run Moonlight
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
CACHE_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

# Helper: run commands as the target user with a valid user DBus/XDG env
u() {
  sudo -u "$TARGET_USER" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

echo "== Moonlight install for ${TARGET_USER} (UID ${TARGET_UID}) =="

# 1) Clean any previous service and root-side configs that could confuse things
echo "-- Cleaning previous unit/key"
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
rm -rf /root/.config/moonlight 2>/dev/null || true

# 2) Install moonlight-embedded from official repo (idempotent)
if ! command -v moonlight >/dev/null 2>&1; then
  echo "-- Installing moonlight-embedded (official repo)"
  apt-get update
  apt-get install -y ca-certificates curl lsb-release
  curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
    | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash
  apt-get update
  apt-get install -y moonlight-embedded
else
  echo "-- moonlight-embedded already installed"
fi

# 3) Ensure key/cache + systemd dirs
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache" "${TARGET_HOME}/.config"

# 4) Write user-mode systemd unit (waits for ~/.cache/moonlight/client.pem)
echo "-- Creating user-mode systemd unit"
cat <<EOF > "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
[Unit]
Description=Moonlight autostart to stream ${HOST}
After=network-online.target
Wants=network-online.target
# Moonlight stores the pairing key in ~/.cache/moonlight/client.pem
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
# Per Moonlight Embedded man page: use -width/-height and put HOST at END
ExecStart=/usr/bin/moonlight stream -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE} ${HOST}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 5) Force a clean pair (unpair → pair) so we always get a fresh key
echo "-- Forcing clean pairing"
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "   -> Initiating pairing with ${HOST} (approve PIN in Sunshine)"
# Pairing doesn’t require the user DBus bus; keep it simple and interactive
sudo -u "${TARGET_USER}" DISPLAY=:0 moonlight pair "${HOST}" || true

# 6) Start the service if pairing key exists
if [[ -f "${KEY_FILE}" ]]; then
  echo "-- Key found at ${KEY_FILE}; starting ${SERVICE_NAME}"
  u systemctl --user start "${SERVICE_NAME}"
  echo "OK: Streaming should be live."
  echo "Logs: sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
else
  echo "NOTE: No key at ${KEY_FILE}."
  echo "If you missed the PIN prompt, re-run:"
  echo "  sudo -u ${TARGET_USER} moonlight pair ${HOST}"
  echo "Then start:"
  echo "  sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
fi

echo "== Done =="
