#!/usr/bin/env bash
set -e

USER_NAME="clay"
USER_HOME="/home/$USER_NAME"
HOST_NAME="nemarion.local"
APP_NAME="Desktop"  # Change if needed

echo "=== Installing Moonlight Embedded for $USER_NAME ==="

# Ensure dependencies (root only)
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl

# Add Moonlight Embedded repo if not already present
if ! grep -q "moonlight-game-streaming" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' | sudo -E bash
fi

# Install Moonlight
sudo apt-get install -y moonlight-embedded

# Remove old service if present
echo "=== Removing old cxf-moonlight service if present ==="
sudo -u "$USER_NAME" systemctl --user stop cxf-moonlight 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/cxf-moonlight.service"

# Export required vars for systemctl --user in non-login shell
export XDG_RUNTIME_DIR="/run/user/$(id -u $USER_NAME)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

# Force pairing
echo "=== Forcing clean pairing with $HOST_NAME ==="
sudo -u "$USER_NAME" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    moonlight pair "$HOST_NAME"

# Create systemd user service
echo "=== Creating new cxf-moonlight service ==="
mkdir -p "$USER_HOME/.config/systemd/user"
cat > "$USER_HOME/.config/systemd/user/cxf-moonlight.service" <<EOF
[Unit]
Description=Moonlight autostart to stream $HOST_NAME
After=network-online.target
Wants=network-online.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
ExecStart=/usr/bin/moonlight stream -width 1600 -height 900 -fps 60 -bitrate 20000 -nocec -app "$APP_NAME" $HOST_NAME
Restart=on-failure
RestartSec=3
TTYPath=/dev/tty1

[Install]
WantedBy=default.target
EOF

# Reload and start service
echo "=== Enabling and starting Moonlight service ==="
sudo -u "$USER_NAME" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    systemctl --user daemon-reload
sudo -u "$USER_NAME" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    systemctl --user enable cxf-moonlight
sudo -u "$USER_NAME" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    systemctl --user start cxf-moonlight

echo "=== Install complete! ==="
echo "Check logs with:"
echo "  sudo -u $USER_NAME env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS systemctl --user status cxf-moonlight"
