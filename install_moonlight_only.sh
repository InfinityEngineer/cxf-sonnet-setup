#!/usr/bin/env bash
set -e

USER_NAME="clay"
SERVICE_NAME="cxf-moonlight"
SERVER_HOSTNAME="nemarion.local"

echo "[INFO] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y curl apt-transport-https ca-certificates libcec6

echo "[INFO] Adding Moonlight Embedded repository..."
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' | sudo -E bash

echo "[INFO] Installing Moonlight Embedded..."
sudo apt-get install -y moonlight-embedded

echo "[INFO] Pairing with $SERVER_HOSTNAME..."
sudo -u "$USER_NAME" bash -c "moonlight pair $SERVER_HOSTNAME"

echo "[INFO] Creating systemd user service for autostart..."
SYSTEMD_USER_DIR="/home/$USER_NAME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SYSTEMD_USER_DIR/$SERVICE_NAME.service" <<EOL
[Unit]
Description=Moonlight autostart to stream $SERVER_HOSTNAME
After=network-online.target

[Service]
ExecStartPre=/usr/bin/test -f /usr/lib/aarch64-linux-gnu/libcec.so.6
ExecStart=/usr/bin/moonlight stream -app Steam -1080 -fps 60 $SERVER_HOSTNAME
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOL

echo "[INFO] Enabling and starting Moonlight service..."
sudo -u "$USER_NAME" systemctl --user daemon-reload
sudo -u "$USER_NAME" systemctl --user enable "$SERVICE_NAME"
sudo -u "$USER_NAME" systemctl --user start "$SERVICE_NAME"

echo "[INFO] Done. To check logs, run:"
echo "       sudo -u $USER_NAME journalctl --user -u $SERVICE_NAME -f"
