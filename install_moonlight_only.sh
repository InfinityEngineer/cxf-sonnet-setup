#!/bin/bash
set -e

# === CONFIGURATION ===
HOST="nemarion.local"        # Hostname or IP of the Sunshine PC
RES="1920x1080"               # Resolution
FPS="60"                      # FPS
BITRATE="20000"               # Bitrate kbps
SERVICE_NAME="cxf-moonlight"  # Systemd service name
TARGET_USER="clay"            # Pi user that will run Moonlight

# === PREPARE SYSTEM ===
echo "[*] Updating system..."
sudo apt-get update
sudo apt-get install -y curl apt-transport-https ca-certificates gpg

echo "[*] Adding Moonlight Embedded repository..."
curl -1sLf \
  'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | sudo -E bash

echo "[*] Installing Moonlight Embedded..."
sudo apt-get install -y moonlight-embedded

# === PAIR WITH HOST ===
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_HOME=$(eval echo "~$TARGET_USER")

echo "[*] Starting pairing with $HOST..."
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR=/run/user/$TARGET_UID \
  DISPLAY=:0 moonlight pair "$HOST" || true

echo "[*] Please approve the pairing on your Sunshine PC if prompted."

# === CREATE SYSTEMD SERVICE ===
USER_SYSTEMD_DIR="$TARGET_HOME/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"

echo "[*] Creating systemd service at $USER_SYSTEMD_DIR/${SERVICE_NAME}.service..."
cat <<EOF > "$USER_SYSTEMD_DIR/${SERVICE_NAME}.service"
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

# === ENABLE SERVICE ===
echo "[*] Enabling Moonlight autostart service for $TARGET_USER..."
sudo -u "$TARGET_USER" systemctl --user daemon-reload
sudo -u "$TARGET_USER" systemctl --user enable "$SERVICE_NAME"

echo
echo "========================================================"
echo "Moonlight installed and service created."
echo "Run the following to start streaming now:"
echo "sudo -u $TARGET_USER systemctl --user start $SERVICE_NAME"
echo "========================================================"
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
