#!/usr/bin/env bash
set -euo pipefail

# ===== Config you can override via env when invoking =====
HOST="${NEMARION_HOST:-nemarion.local}"   # Sunshine host
USER_NAME="${TARGET_USER:-clay}"          # login user on the Pi
WIDTH="${STREAM_WIDTH:-1600}"             # Upstar monitor native width
HEIGHT="${STREAM_HEIGHT:-900}"            # Upstar monitor native height
FPS="${STREAM_FPS:-60}"
BITRATE="${STREAM_BITRATE:-20000}"        # kbps
APP_NAME="${APP_NAME:-Desktop}"           # must match Sunshine app name
DISABLE_CEC="${DISABLE_CEC:-1}"           # 1 = add -nocec (recommended on Pi3B+)
SERVICE_NAME="cxf-moonlight"
# ========================================================

USER_HOME="$(eval echo "~${USER_NAME}")"
USER_UID="$(id -u "${USER_NAME}")"
SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
CACHE_DIR="${USER_HOME}/.cache/moonlight"
KEY_FILE="${CACHE_DIR}/client.pem"

# Helper: run as user with a valid session bus/runtime
u() {
  sudo -u "${USER_NAME}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    "$@"
}

echo "== Moonlight Embedded install for ${USER_NAME} (Pi 3B+) =="

# 1) Packages (Moonlight + CEC library) and refresh loader cache
sudo apt-get update
sudo apt-get install -y ca-certificates curl lsb-release libcec6
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash
sudo apt-get update
sudo apt-get install -y moonlight-embedded
sudo ldconfig   # make sure libcec.so.6 is on the loader path

# 2) Clean any old unit/config that might conflict
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
rm -f "${SYSTEMD_DIR}/${SERVICE_NAME}.service" 2>/dev/null || true
rm -rf /root/.config/moonlight 2>/dev/null || true

# 3) Ensure dirs and ownership
mkdir -p "${CACHE_DIR}" "${SYSTEMD_DIR}"
sudo chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.cache" "${USER_HOME}/.config"

# 4) Build ExecStart (Desktop app, width/height, no CEC by default)
CEC_FLAG=""
[[ "${DISABLE_CEC}" == "1" ]] && CEC_FLAG="-nocec"
EXEC_LINE="/usr/bin/moonlight stream -width ${WIDTH} -height ${HEIGHT} -fps ${FPS} -bitrate ${BITRATE} ${CEC_FLAG} -app \"${APP_NAME}\" ${HOST}"

# 5) Write user‑mode systemd unit (waits for ~/.cache/moonlight/client.pem)
cat > "${SYSTEMD_DIR}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Moonlight autostart to stream ${HOST}
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStart=${EXEC_LINE}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "${USER_NAME}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 6) Force a clean pair (unpair -> pair) to avoid stale state
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "-> Pairing (approve PIN in Sunshine on ${HOST})"
sudo -u "${USER_NAME}" DISPLAY=:0 moonlight pair "${HOST}" || true

# 7) Start if key exists; otherwise print next steps
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
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
ExecStart=${EXEC_LINE}
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "${USER_NAME}" >/dev/null 2>&1 || true
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# 6) Force a clean pair (unpair -> pair) to avoid stale state
u systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
u rm -f "${KEY_FILE}" || true
u moonlight unpair "${HOST}" >/dev/null 2>&1 || true

echo "-> Pairing (approve PIN in Sunshine on ${HOST})"
sudo -u "${USER_NAME}" DISPLAY=:0 moonlight pair "${HOST}" || true

# 7) Start if key exists; otherwise print next steps
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
