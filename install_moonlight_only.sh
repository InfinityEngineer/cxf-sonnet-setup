#!/usr/bin/env bash
set -euo pipefail

HOST="nemarion.local"
RES="1600x900"
FPS="60"
BITRATE="20000"
SERVICE_NAME="cxf-moonlight"

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_UID="$(id -u "$TARGET_USER")"
USER_SYSTEMD_DIR="${TARGET_HOME}/.config/systemd/user"
KEYS_DIR="${TARGET_HOME}/.cache/moonlight"
KEY_FILE="${KEYS_DIR}/client.pem"

u() {
  sudo -u "$TARGET_USER" \
    XDG_RUNTIME_DIR="/run/user/${TARGET_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus" \
    "$@"
}

echo "-- Cleaning old Moonlight"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
u systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
u systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
rm -rf "$USER_SYSTEMD_DIR/$SERVICE_NAME.service" /root/.config/moonlight

echo "-- Installing moonlight-embedded"
apt-get update
apt-get install -y ca-certificates curl lsb-release
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash
apt-get update
apt-get install -y moonlight-embedded

mkdir -p "$KEYS_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.cache"

mkdir -p "$USER_SYSTEMD_DIR"
cat > "$USER_SYSTEMD_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Moonlight autostart to stream $HOST
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${TARGET_UID}
ExecStart=/usr/bin/moonlight stream $HOST --resolution $RES --fps $FPS --bitrate $BITRATE
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config"
loginctl enable-linger "$TARGET_USER" || true
u systemctl --user daemon-reload
u systemctl --user enable "$SERVICE_NAME"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "-- Pairing required (PIN will appear in Sunshine on $HOST)"
  u DISPLAY=:0 moonlight pair "$HOST" || true
fi

if [[ -f "$KEY_FILE" ]]; then
  echo "-- Starting Moonlight service"
  u systemctl --user start "$SERVICE_NAME"
else
  echo "Pairing failed: run manually ->"
  echo "sudo -u $TARGET_USER XDG_RUNTIME_DIR=/run/user/$TARGET_UID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$TARGET_UID/bus DISPLAY=:0 moonlight pair $HOST"
fi
Wants=network-online.target
# Only start after pairing exists (user key)
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

# Allow user services to run without an active login session
loginctl enable-linger "${TARGET_USER}" >/dev/null 2>&1 || true

# Reload user units
u systemctl --user daemon-reload
u systemctl --user enable "${SERVICE_NAME}"

# --- Pair if needed (interactive prompt shown here) ---
if [[ ! -f "${KEYS_PATH}" ]]; then
  echo
  echo "-- Pairing required (no key at ${KEYS_PATH})"
  echo "   A PIN will appear in Sunshine on ${HOST}. Approve it there."
  echo
  # DISPLAY is set so Moonlight can capture input if needed
  u DISPLAY=:0 moonlight pair "${HOST}" || true
fi

# Start if paired
if [[ -f "${KEYS_PATH}" ]]; then
  echo "-- Key present. Starting ${SERVICE_NAME}..."
  u systemctl --user start "${SERVICE_NAME}"
  echo "OK: Streaming service started. To watch logs: "
  echo "   sudo -u ${TARGET_USER} journalctl --user -u ${SERVICE_NAME} -f"
else
  echo "NOTE: Pairing didn’t complete (no key found)."
  echo "      Re-run pairing, then start the service:"
  echo "        sudo -u ${TARGET_USER} XDG_RUNTIME_DIR=/run/user/${TARGET_UID} \\"
  echo "          DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${TARGET_UID}/bus \\"
  echo "          DISPLAY=:0 moonlight pair ${HOST}"
  echo "        sudo -u ${TARGET_USER} systemctl --user start ${SERVICE_NAME}"
fi

echo "== Done =="
