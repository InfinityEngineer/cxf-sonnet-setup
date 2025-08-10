#!/usr/bin/env bash
set -euo pipefail

# =========================
# CXF-Sonnet one-shot setup
# - Installs SSH, mDNS
# - Installs Moonlight (client)
# - Installs BirdNET-Pi
# - (Optional) rotates/forces HDMI mode
# - (Optional) merges BirdNET data from an old microSD via USB reader
# =========================

# ----- User-tweakables (can override via env on the one-liner) -----
PI_HOSTNAME="${PI_HOSTNAME:-sonnet}"
SET_HOSTNAME="${SET_HOSTNAME:-yes}"

# Moonlight stream target (Sunshine host)
NEMARION_HOST="${NEMARION_HOST:-nemarion.local}"
STREAM_RES="${STREAM_RES:-1600x900}"   # matches your 20" monitor
STREAM_FPS="${STREAM_FPS:-60}"
STREAM_BITRATE="${STREAM_BITRATE:-20000}"  # kbps
AUTO_MOONLIGHT="${AUTO_MOONLIGHT:-yes}"    # create autostart service (will run only after pairing)

# Display rotation/EDID forcing (KMS path)
ROTATE_BOOT="${ROTATE_BOOT:-180}"          # set "" to skip
HDMI_MODE_STRING="${HDMI_MODE_STRING:-1600x900@60}"
CONFIG_TXT_FORCE_MODE="${CONFIG_TXT_FORCE_MODE:-yes}"  # force mode in config.txt (helpful with HDMI→VGA)

# Data migration from old BirdNET-Pi microSD (plugged into THIS Pi via USB reader)
MIGRATE_FROM_USB="${MIGRATE_FROM_USB:-yes}"

echo "== CXF-Sonnet setup starting =="
[[ $EUID -eq 0 ]] || { echo "Please run with sudo/root."; exit 1; }

# Helper: echo section
sec(){ echo; echo "---- $* ----"; }

sec "apt update/upgrade"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

sec "Install base packages"
apt-get install -y \
  avahi-daemon avahi-utils curl git htop tmux ufw \
  rsync \
  moonlight-embedded

# Enable services
sec "Enable SSH + mDNS"
systemctl enable --now ssh
systemctl enable --now avahi-daemon

# Hostname
if [[ "$SET_HOSTNAME" == "yes" ]]; then
  cur="$(hostname)"
  if [[ "$cur" != "$PI_HOSTNAME" ]]; then
    sec "Set hostname to ${PI_HOSTNAME}"
    hostnamectl set-hostname "$PI_HOSTNAME"
    # keep 127.0.1.1 mapping sane
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${PI_HOSTNAME}/" /etc/hosts || true
    else
      echo -e "127.0.1.1\t${PI_HOSTNAME}" >> /etc/hosts
    fi
  else
    echo "Hostname already ${PI_HOSTNAME}"
  fi
fi

# OS sanity for BirdNET-Pi
. /etc/os-release
sec "OS: $PRETTY_NAME"
if [[ "${VERSION_CODENAME:-}" == "bookworm" ]]; then
  echo "NOTE: BirdNET-Pi can be finicky on Bookworm for Pi 3B+. If install fails,"
  echo "      consider Bullseye 64-bit. Proceeding anyway…"
fi

# Force HDMI mode & rotation (KMS-friendly)
if [[ -n "$ROTATE_BOOT" || -n "$HDMI_MODE_STRING" ]]; then
  sec "Configure boot-time rotation and HDMI timing (KMS)"
  # Append kernel cmdline (single line)
  if ! grep -q "video=HDMI-A-1:" /boot/cmdline.txt; then
    sed -i "s/$/ video=HDMI-A-1:${HDMI_MODE_STRING},rotate=${ROTATE_BOOT:-0}/" /boot/cmdline.txt
    echo "Added to /boot/cmdline.txt: video=HDMI-A-1:${HDMI_MODE_STRING},rotate=${ROTATE_BOOT:-0}"
  else
    echo "cmdline already has a video=HDMI-A-1:… entry; leaving as-is"
  fi

  # Also hint legacy hdmi_group/mode in config.txt for adapters that need it
  if [[ "$CONFIG_TXT_FORCE_MODE" == "yes" ]]; then
    # 1600x900@60 is CEA mode 85
    if ! grep -q "^hdmi_group=" /boot/config.txt; then
      echo "hdmi_group=2" >> /boot/config.txt
    else
      sed -i 's/^hdmi_group=.*/hdmi_group=2/' /boot/config.txt
    fi
    if ! grep -q "^hdmi_mode=" /boot/config.txt; then
      echo "hdmi_mode=85" >> /boot/config.txt
    else
      sed -i 's/^hdmi_mode=.*/hdmi_mode=85/' /boot/config.txt
    fi
    echo "Forced 1600x900@60 in /boot/config.txt (useful for HDMI→VGA)."
  fi
fi

# Install BirdNET-Pi (runs under 'birdnet' user)
sec "Install BirdNET-Pi (this can take a while)"
# run as the invoking user if present, falls back to 'pi'
TARGET_SUDO_USER="${SUDO_USER:-pi}"
sudo -u "$TARGET_SUDO_USER" bash -lc 'curl -fsSL https://raw.githubusercontent.com/mcguirepr89/BirdNET-Pi/main/newinstaller.sh | bash' || {
  echo "!! BirdNET-Pi installer returned non-zero. You can re-run later."
}

# Paths (after install)
BPN_HOME="/home/birdnet/BirdNET-Pi"
REC_DIR="${BPN_HOME}/recordings"
DATA_DIR="${BPN_HOME}/data"
CFG_DIR="${BPN_HOME}/config"

# Make sure they exist
mkdir -p "$REC_DIR" "$DATA_DIR" "$CFG_DIR" || true
chown -R birdnet:birdnet "$BPN_HOME" || true

# Optional Migration from USB microSD
if [[ "$MIGRATE_FROM_USB" == "yes" ]]; then
  sec "Attempting migration from old BirdNET-Pi microSD (USB reader)"
  echo "Looking for mounted candidates under /media and /mnt…"

  # scan common mount roots
  mapfile -t CANDIDATES < <(find /media /mnt -maxdepth 3 -type d -name "BirdNET-Pi" 2>/dev/null || true)

  # If none found, try to list block devices to help the user
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No obvious /media/*/*/BirdNET-Pi found."
    echo "If your card didn't auto-mount, you can mount it and re-run migration later."
    echo "Helpful commands:"
    echo "  lsblk -f"
    echo "  sudo mkdir -p /mnt/old_birdnet && sudo mount /dev/sdX2 /mnt/old_birdnet"
    echo "  (replace /dev/sdX2 with the ext4 partition from lsblk)"
  else
    echo "Found candidate(s):"
    i=0
    for p in "${CANDIDATES[@]}"; do
      echo " [$i] $p"
      ((i++))
    done
    echo -n "Select index to migrate from (or press Enter to skip): "
    read -r idx
    if [[ -n "${idx:-}" && "$idx" =~ ^[0-9]+$ && "$idx" -ge 0 && "$idx" -lt "${#CANDIDATES[@]}" ]]; then
      SRC="${CANDIDATES[$idx]}"
      echo "Source selected: $SRC"

      # Merge (keep existing newest files on destination)
      echo "Merging recordings (ignore existing)…"
      rsync -a --ignore-existing --info=progress2 "${SRC}/recordings/" "$REC_DIR/" || true

      echo "Merging data (CSV/stats). Keeping existing, adding new…"
      rsync -a --ignore-existing --info=progress2 "${SRC}/data/" "$DATA_DIR/" || true

      # Config: only copy if target missing—don’t overwrite your fresh config by default
      echo "Copying missing config files only…"
      rsync -a --ignore-existing "${SRC}/config/" "$CFG_DIR/" || true

      chown -R birdnet:birdnet "$BPN_HOME" || true
      echo "Migration complete."
    else
      echo "Skipped migration."
    fi
  fi
fi

# Moonlight autostart service (starts only AFTER you pair once)
SERVICE_PATH="/etc/systemd/system/cxf-moonlight.service"
if [[ "$AUTO_MOONLIGHT" == "yes" ]]; then
  sec "Create Moonlight autostart service"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Moonlight autostart (Nemarion desktop)
After=network-online.target
Wants=network-online.target
# Start only if paired keys exist
ConditionPathExists=%h/.config/moonlight/keys/client.pem

[Service]
User=${TARGET_SUDO_USER}
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

# UFW: basic allowances
sec "Configure UFW (allow SSH/HTTP/HTTPS)"
ufw allow ssh || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
echo "y" | ufw enable || true

sec "All done"

echo
echo "NEXT STEPS:"
echo "1) Reboot recommended: sudo reboot"
echo "2) Pair Moonlight once (on the Pi):"
echo "     moonlight pair ${NEMARION_HOST}"
echo "   Confirm the PIN in Sunshine on Nemarion."
echo "3) After pairing, autostart service will run at next boot, or:"
echo "     systemctl start cxf-moonlight"
echo "4) BirdNET UI:  http://${PI_HOSTNAME}.local"
echo
echo "If HDMI is still not rotated/1600x900, verify:"
echo "  - /boot/cmdline.txt contains: video=HDMI-A-1:${HDMI_MODE_STRING},rotate=${ROTATE_BOOT}"
echo "  - /boot/config.txt has: hdmi_group=2 and hdmi_mode=85"
