#!/usr/bin/env bash
set -euo pipefail

# ===== User-tweakables =====
PI_HOSTNAME="${PI_HOSTNAME:-sonnet}"
SET_HOSTNAME="${SET_HOSTNAME:-yes}"        # "yes" to set hostname to $PI_HOSTNAME
NEMARION_HOST="${NEMARION_HOST:-nemarion.local}"
STREAM_RES="${STREAM_RES:-2560x1080}"
STREAM_FPS="${STREAM_FPS:-60}"
STREAM_BITRATE="${STREAM_BITRATE:-20000}"   # kbps
AUTO_MOONLIGHT="${AUTO_MOONLIGHT:-yes}"     # create systemd service (activates after pairing)
ROTATE_BOOT="${ROTATE_BOOT:-}"              # "180" to rotate from boot; leave blank to skip

echo "== CXF-Sonnet setup starting =="
[[ $EUID -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }

# ---- Basic packages, SSH, mDNS ----
echo "-- apt update/upgrade"
apt-get update
apt-get -y upgrade

echo "-- install base tools"
apt-get install -y \
  avahi-daemon avahi-utils curl git htop tmux ufw ca-certificates lsb-release

echo "-- enable SSH"
systemctl enable --now ssh

echo "-- enable mDNS (sonnet.local)"
systemctl enable --now avahi-daemon

# ---- Hostname (optional) ----
if [[ "${SET_HOSTNAME}" == "yes" ]]; then
  current="$(hostname)"
  if [[ "$current" != "$PI_HOSTNAME" ]]; then
    echo "-- setting hostname to ${PI_HOSTNAME}"
    hostnamectl set-hostname "${PI_HOSTNAME}"
    # ensure /etc/hosts has the 127.0.1.1 line for this hostname
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${PI_HOSTNAME}/" /etc/hosts
    else
      echo -e "127.0.1.1\t${PI_HOSTNAME}" >> /etc/hosts
    fi
  else
    echo "-- hostname already ${PI_HOSTNAME}"
  fi
fi

# ---- OS sanity check for BirdNET-Pi ----
. /etc/os-release
echo "-- OS: $PRETTY_NAME"
if [[ "${VERSION_CODENAME:-}" == "bookworm" ]]; then
  echo "!! NOTE: BirdNET-Pi can be finicky on Bookworm on Pi 3B+. If installer fails, use Bullseye."
fi

# ---- BirdNET-Pi install ----
echo "-- installing BirdNET-Pi (this may take a while)"
# Official installer:
# ref: https://github.com/mcguirepr89/BirdNET-Pi
sudo -u "${SUDO_USER:-pi}" bash -lc 'curl -fsSL https://raw.githubusercontent.com/mcguirepr89/BirdNET-Pi/main/newinstaller.sh | bash' || {
  echo "!! BirdNET-Pi installer exited with error. You can re-run later."
}

# ---- Moonlight (add official repo, then install) ----
echo "-- adding Moonlight Embedded APT repository"
# Cloudsmith-hosted repo from the Moonlight project:
# https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian codename="$(lsb_release -cs)" sudo -E bash

echo "-- installing moonlight-embedded"
apt-get update
if ! apt-get install -y moonlight-embedded; then
  echo "!! Failed to install moonlight-embedded from repo."
  echo "   You can try again later or build from source:"
  echo "   https://github.com/moonlight-stream/moonlight-embedded"
fi

# ---- Optional: rotate display from boot via KMS kernel arg ----
if [[ -n "${ROTATE_BOOT}" ]]; then
  echo "-- configuring boot-time rotation: ${ROTATE_BOOT} degrees"
  # Append once to /boot/cmdline.txt (single line)
  if ! grep -q "video=HDMI-A-1:" /boot/cmdline.txt; then
    sed -i "s/$/ video=HDMI-A-1:rotate=${ROTATE_BOOT}/" /boot/cmdline.txt
    echo "   Added 'video=HDMI-A-1:rotate=${ROTATE_BOOT}' to /boot/cmdline.txt"
  else
    echo "   Skipped: a video=HDMI-A-1:... parameter already exists"
  fi
fi

# ---- Moonlight autostart (after pairing) ----
SERVICE_PATH="/etc/systemd/system/cxf-moonlight.service"
if [[ "${AUTO_MOONLIGHT}" == "yes" ]]; then
  echo "-- creating Moonlight systemd service at ${SERVICE_PATH}"
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Moonlight autostart to stream Nemarion
After=network-online.target
Wants=network-online.target
# only start if Moonlight has been paired (client key exists)
ConditionPathExists=%h/.config/moonlight/keys/client.pem

[Service]
User=${SUDO_USER:-pi}
Environment=DISPLAY=:0
ExecStart=/usr/bin/moonlight stream ${NEMARION_HOST} --resolution ${STREAM_RES} --fps ${STREAM_FPS} --bitrate ${STREAM_BITRATE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

  systemctl daemon-reload
  systemctl enable cxf-moonlight.service || true
fi

# ---- UFW: allow local HTTP(S) and SSH ----
echo "-- configuring ufw (allow SSH, HTTP, HTTPS)"
ufw allow ssh || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
echo "y" | ufw enable || true

echo "== Setup complete =="
echo
echo "NEXT STEPS:"
echo "1) (Optional) Reboot now: sudo reboot"
echo "2) Pair Moonlight with Nemarion:"
echo "     moonlight pair ${NEMARION_HOST}"
echo "   Then confirm the PIN on Nemarion (Sunshine UI)."
echo "3) After pairing, the cxf-moonlight service will auto-start on next boot (or run:"
echo "     systemctl start cxf-moonlight"
echo "   )"
echo "4) BirdNET-Pi UI: http://${PI_HOSTNAME}.local  (or the Pi's IP)"
echo
echo "Tuning:"
echo "  - To change stream settings, edit ${SERVICE_PATH}"
echo "  - To force 1600x900@60 and rotate at boot, set ROTATE_BOOT=180 and add to cmdline as above."
