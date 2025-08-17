#!/usr/bin/env bash
# cxf-sonnet-setup.sh
# CXF-Sonnet setup for Raspberry Pi 3B+ (Bookworm ARM64)

set -euo pipefail
IFS=$'\n\t'

log() { echo "[CXF] $*"; }

trap 'log "Error on line $LINENO"; exit 1' ERR

# --- Prechecks ---
log "Checking hardware/OS..."
if ! grep -q "Raspberry Pi 3 Model B Plus" /proc/device-tree/model 2>/dev/null; then
  log "Unsupported hardware (need Pi 3B+)."
  exit 1
fi
if [[ "$(uname -m)" != "aarch64" ]]; then
  log "Need 64-bit kernel (aarch64)."
  exit 1
fi
. /etc/os-release
if [[ "$ID" != "raspbian" && "$ID" != "debian" ]]; then
  log "Unsupported OS ID=$ID (need Raspbian/Debian Bookworm)."
  exit 1
fi
if [[ "$VERSION_CODENAME" != "bookworm" ]]; then
  log "Unsupported release $VERSION_CODENAME (need Bookworm)."
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  log "Please run as root."
  exit 1
fi
ping -c1 -W2 8.8.8.8 >/dev/null || { log "No network"; exit 1; }

# --- System update ---
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
log "Running apt full-upgrade..."
apt-get update
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get install "${APT_OPTS[@]}" \
  curl git jq unzip logrotate ca-certificates pkg-config libcec6 cec-utils lsb-release

# --- GPU/KMS ---
CFG=/boot/firmware/config.txt
cp -n "$CFG" "$CFG.bak.$(date +%s)" || true
grep -q "^dtoverlay=vc4-kms-v3d" "$CFG" || echo "dtoverlay=vc4-kms-v3d" >>"$CFG"
grep -q "^gpu_mem=256" "$CFG" || echo "gpu_mem=256" >>"$CFG"

# --- Tailscale ---
log "Installing Tailscale..."
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install "${APT_OPTS[@]}" tailscale
systemctl enable --now tailscaled
log "Tailscale installed. Later run: sudo tailscale up"

# --- BirdNET-Go ---
log "Installing BirdNET-Go..."
install -d -o root -g root /var/lib/birdnet-go
id -u birdnetgo &>/dev/null || useradd -r -d /var/lib/birdnet-go -s /usr/sbin/nologin birdnetgo
cat >/etc/birdnet-go/config.yaml <<'YAML'
db: /var/lib/birdnet-go/birdnet.db
inbox: /var/lib/birdnet-go/inbox
clips: /var/lib/birdnet-go/clips
results: /var/lib/birdnet-go/results
YAML
install -d -o birdnetgo -g birdnetgo /var/lib/birdnet-go/{inbox,clips,results}

if ! curl -fsSL https://github.com/tphakala/birdnet-go/raw/main/install.sh -o /tmp/bngo-install.sh; then
  log "Official install.sh not found, falling back..."
fi
if bash /tmp/bngo-install.sh; then
  log "BirdNET-Go installed via install.sh"
else
  log "Fallback: manual release download..."
  ASSET_URL=$(curl -s https://api.github.com/repos/tphakala/birdnet-go/releases/latest \
    | jq -r '.assets[] | select(.name|test("Linux_arm64")) | .browser_download_url')
  curl -L "$ASSET_URL" -o /usr/local/bin/birdnet-go
  chmod +x /usr/local/bin/birdnet-go
fi

cat >/etc/systemd/system/birdnet-go.service <<'UNIT'
[Unit]
Description=BirdNET-Go Service
After=network.target
[Service]
User=birdnetgo
WorkingDirectory=/var/lib/birdnet-go
ExecStart=/usr/local/bin/birdnet-go -c /etc/birdnet-go/config.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

# --- BirdNET-Pi Migration (birdnet-pi2go only) ---
log "Attempting BirdNET-Pi migration with birdnet-pi2go..."
for dev in /dev/sd*; do
  mkdir -p /mnt/oldbnpi
  mount -o ro "$dev" /mnt/oldbnpi 2>/dev/null || continue
  if [[ -f /mnt/oldbnpi/home/pi/BirdNET-Pi/scripts/birds.db ]]; then
    SRCDB=/mnt/oldbnpi/home/pi/BirdNET-Pi/scripts/birds.db
    SRC_AUDIO=/mnt/oldbnpi/home/pi/BirdNET-Pi/BirdSongs
    log "Found BirdNET-Pi DB at $dev"
    ASSET_URL=$(curl -s https://api.github.com/repos/tphakala/birdnet-pi2go/releases/latest \
      | jq -r '.assets[] | select(.name|test("Linux_arm64")) | .browser_download_url')
    curl -L "$ASSET_URL" -o /usr/local/bin/birdnet-pi2go
    chmod +x /usr/local/bin/birdnet-pi2go
    mv /var/lib/birdnet-go/birdnet.db /var/lib/birdnet-go/birdnet.db.bak.$(date +%s) || true
    if /usr/local/bin/birdnet-pi2go \
      -source-db "$SRCDB" \
      -target-db /var/lib/birdnet-go/birdnet.db \
      -source-dir "$SRC_AUDIO" \
      -target-dir /var/lib/birdnet-go/clips \
      -operation copy; then
      log "Migration succeeded."
    else
      log "Migration failed, see logs."
    fi
    umount /mnt/oldbnpi
    break
  fi
done

# --- Moonlight ---
log "Installing Moonlight..."
curl -1sLf \
  'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | bash
apt-get install "${APT_OPTS[@]}" moonlight-embedded

# Config
cat >/etc/moonlight-sonnet.conf <<'CONF'
HOST=Nemarion.local
APP=Desktop
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=6000
ROTATE=0
NOCEC=1
CONF

install -d /var/log/moonlight

# Resolution helper
cat >/usr/local/sbin/moonlight-resolution.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/moonlight-sonnet.conf
read_kv() { grep "^$1=" "$CONF" | cut -d= -f2; }
W=$(read_kv WIDTH); H=$(read_kv HEIGHT); F=$(read_kv FPS); B=$(read_kv BITRATE)
echo "Press ANY key within 10s for alternative resolution..."
if read -t 10 -n 1; then
  read -p "Width [$W]: " nw; W=${nw:-$W}
  read -p "Height [$H]: " nh; H=${nh:-$H}
  read -p "FPS [$F]: " nf; F=${nf:-$F}
  read -p "Bitrate [$B]: " nb; B=${nb:-$B}
  sed -i "s/^WIDTH=.*/WIDTH=$W/" "$CONF"
  sed -i "s/^HEIGHT=.*/HEIGHT=$H/" "$CONF"
  sed -i "s/^FPS=.*/FPS=$F/" "$CONF"
  sed -i "s/^BITRATE=.*/BITRATE=$B/" "$CONF"
fi
SH
chmod +x /usr/local/sbin/moonlight-resolution.sh

# Start wrapper
cat >/usr/local/sbin/moonlight-start.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/moonlight-sonnet.conf
. "$CONF"
LOG=/var/log/moonlight/moonlight.log
mkdir -p "$(dirname "$LOG")"
exec moonlight -nocec stream \
  -width "$WIDTH" -height "$HEIGHT" -fps "$FPS" -bitrate "$BITRATE" \
  ${ROTATE:+-rotate "$ROTATE"} -app "$APP" "$HOST" -verbose \
  >>"$LOG" 2>&1
SH
chmod +x /usr/local/sbin/moonlight-start.sh

# Services
cat >/etc/systemd/system/moonlight-pair-once.service <<'UNIT'
[Unit]
Description=Moonlight Pair Once
Before=moonlight-sonnet.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ ! -f /var/lib/moonlight/client.pem ]; then moonlight pair Nemarion.local; exit 1; fi'
UNIT

cat >/etc/systemd/system/moonlight-sonnet.service <<'UNIT'
[Unit]
Description=Moonlight Sonnet Stream
After=network-online.target
Wants=network-online.target moonlight-pair-once.service
[Service]
ExecStart=/usr/local/sbin/moonlight-start.sh
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

# Logrotate
cat >/etc/logrotate.d/moonlight <<'ROT'
/var/log/moonlight/*.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
ROT

# --- Finalize ---
systemctl daemon-reload
systemctl enable birdnet-go.service
systemctl enable moonlight-sonnet.service
log "Setup complete."

# Optional reboot if all succeeded
log "Rebooting now..."
reboot
