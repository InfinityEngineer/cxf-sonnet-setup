#!/usr/bin/env bash
# cxf-sonnet-setup.sh
# CXF Sonnet Setup (Bookworm/ARM64) — Moonlight + BirdNET-Go + Tailscale
# Host: Nemarion.local (fixed); Stream: 1280x720@30fps, 6000 Kbps; Rotation 0; Audio disabled (no local playback)

set -euo pipefail
IFS=$'\n\t'

log(){ echo "[CXF] $*"; }
fail(){ log "ERROR: $*"; exit 1; }
trap 'fail "Line $LINENO"' ERR

# -----------------------
# Prechecks
# -----------------------
log "Checking hardware/OS..."
if ! grep -q "Raspberry Pi 3 Model B Plus" /proc/device-tree/model 2>/dev/null; then
  fail "Unsupported hardware. This script targets Raspberry Pi 3B+."
fi
[[ "$(uname -m)" == "aarch64" ]] || fail "Need 64-bit kernel (aarch64)."
source /etc/os-release || fail "Cannot read /etc/os-release"
if [[ "$ID" != "raspbian" && "$ID" != "debian" ]]; then
  fail "Unsupported OS ($ID). Need Raspbian/Debian Bookworm on Raspberry Pi."
fi
[[ "${VERSION_CODENAME:-}" == "bookworm" ]] || fail "Unsupported release ($VERSION_CODENAME). Need Bookworm."
[[ $EUID -eq 0 ]] || fail "Please run as root (use: sudo bash cxf-sonnet-setup.sh)."
ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 || fail "No network connectivity."

# -----------------------
# System update & basics
# -----------------------
log "Running safe full-upgrade and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get install "${APT_OPTS[@]}" \
  curl git jq unzip logrotate ca-certificates pkg-config libcec6 cec-utils lsb-release gpg

# -----------------------
# Ensure KMS on Bookworm
# -----------------------
CFG=/boot/firmware/config.txt
if [[ -f "$CFG" ]]; then
  cp -n "$CFG" "$CFG.bak.$(date +%s)" || true
  grep -q "^dtoverlay=vc4-kms-v3d" "$CFG" || echo "dtoverlay=vc4-kms-v3d" >>"$CFG"
  grep -q "^gpu_mem=256" "$CFG" || echo "gpu_mem=256" >>"$CFG"
else
  log "Warning: $CFG not found (continuing)."
fi

# -----------------------
# Tailscale (install & enable daemon only)
# -----------------------
log "Installing Tailscale (repo w/ dearmored key)..."
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.gpg \
  | gpg --dearmor | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
cat >/etc/apt/sources.list.d/tailscale.list <<'LIST'
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/raspbian bookworm main
LIST
apt-get update
apt-get install "${APT_OPTS[@]}" tailscale
systemctl enable --now tailscaled
log "Tailscale installed. To join later: sudo tailscale up"

# -----------------------
# BirdNET-Go (manual Linux_arm64 binary install — avoids Docker/interactive installer)
# -----------------------
log "Installing BirdNET-Go (manual ARM64 release)..."
install -d -o root -g root /var/lib/birdnet-go
id -u birdnetgo &>/dev/null || useradd -r -d /var/lib/birdnet-go -s /usr/sbin/nologin birdnetgo
install -d -o birdnetgo -g birdnetgo /var/lib/birdnet-go/{inbox,clips,results}
install -d -o root -g root /etc/birdnet-go

cat >/etc/birdnet-go/config.yaml <<'YAML'
db: /var/lib/birdnet-go/birdnet.db
inbox: /var/lib/birdnet-go/inbox
clips: /var/lib/birdnet-go/clips
results: /var/lib/birdnet-go/results
YAML

BNGO_URL=$(curl -s https://api.github.com/repos/tphakala/birdnet-go/releases/latest \
  | jq -r '.assets[] | select(.name|test("Linux_arm64")) | .browser_download_url')
[[ -n "$BNGO_URL" && "$BNGO_URL" != "null" ]] || fail "Could not find BirdNET-Go Linux_arm64 asset."
curl -fL "$BNGO_URL" -o /usr/local/bin/birdnet-go
chmod +x /usr/local/bin/birdnet-go

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

# -----------------------
# Migration from BirdNET-Pi via birdnet-pi2go (mandatory path if DB found)
# -----------------------
log "Attempting BirdNET-Pi migration with birdnet-pi2go (best-effort)..."
PI2GO_URL=$(curl -s https://api.github.com/repos/tphakala/birdnet-pi2go/releases/latest \
  | jq -r '.assets[] | select(.name|test("Linux_arm64")) | .browser_download_url')
if [[ -n "$PI2GO_URL" && "$PI2GO_URL" != "null" ]]; then
  curl -fL "$PI2GO_URL" -o /usr/local/bin/birdnet-pi2go
  chmod +x /usr/local/bin/birdnet-pi2go
else
  log "Warning: Could not locate birdnet-pi2go Linux_arm64 asset; skipping migration."
fi

MNTBASE=/mnt/oldbnpi
mkdir -p "$MNTBASE"
MIG_DONE=0
for part in /dev/sd*[0-9] /dev/mmcblk*p 2>/dev/null; do
  [[ -e "$part" ]] || continue
  MP="$MNTBASE/$(basename "$part")"
  mkdir -p "$MP"
  if mount -o ro "$part" "$MP" 2>/dev/null; then
    CAND_DB="$MP/home/pi/BirdNET-Pi/scripts/birds.db"
    CAND_AUDIO="$MP/home/pi/BirdNET-Pi/BirdSongs"
    if [[ -f "$CAND_DB" && -x /usr/local/bin/birdnet-pi2go ]]; then
      log "Found BirdNET-Pi DB on $part, running birdnet-pi2go..."
      mv /var/lib/birdnet-go/birdnet.db /var/lib/birdnet-go/birdnet.db.bak.$(date +%s) 2>/dev/null || true
      if /usr/local/bin/birdnet-pi2go \
        -source-db "$CAND_DB" \
        -target-db /var/lib/birdnet-go/birdnet.db \
        -source-dir "$CAND_AUDIO" \
        -target-dir /var/lib/birdnet-go/clips \
        -operation copy; then
        log "Migration succeeded."
        MIG_DONE=1
        umount "$MP" || true
        break
      else
        log "Migration failed on $part (continuing)."
      fi
    fi
    umount "$MP" || true
  fi
done
if [[ "$MIG_DONE" -eq 0 ]]; then
  log "No migratable BirdNET-Pi DB detected, or migration skipped."
fi

# -----------------------
# Moonlight Embedded (Cloudsmith repo)
# -----------------------
log "Installing Moonlight Embedded..."
if ! dpkg -s moonlight-embedded >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' | bash
  apt-get install "${APT_OPTS[@]}" moonlight-embedded
fi

# Persisted config
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

# Interactive resolution helper
cat >/usr/local/sbin/moonlight-resolution.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/moonlight-sonnet.conf
read_kv(){ grep "^$1=" "$CONF" | cut -d= -f2; }
W=$(read_kv WIDTH); H=$(read_kv HEIGHT); F=$(read_kv FPS); B=$(read_kv BITRATE)
echo "Press ANY key within 10 seconds for alternative resolution settings…"
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

# Start wrapper: no local audio on the Pi
cat >/usr/local/sbin/moonlight-start.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/moonlight-sonnet.conf
. "$CONF"
LOG=/var/log/moonlight/moonlight.log
mkdir -p "$(dirname "$LOG")"

# Avoid local audio by pointing Pulse to a nonexistent socket (benign)
export PULSE_SERVER="unix:/tmp/moonlight-nonexistent-sink"

# Stream; on failure, fall back to 1280x720@30/6000
if ! moonlight -nocec stream \
  -width "$WIDTH" -height "$HEIGHT" -fps "$FPS" -bitrate "$BITRATE" \
  ${ROTATE:+-rotate "$ROTATE"} -app "$APP" "$HOST" -verbose >>"$LOG" 2>&1; then
  echo "[CXF] Primary mode failed; falling back to 1280x720@30fps, 6000kbps" >>"$LOG"
  moonlight -nocec stream -width 1280 -height 720 -fps 30 -bitrate 6000 \
    ${ROTATE:+-rotate "$ROTATE"} -app "$APP" "$HOST" -verbose >>"$LOG" 2>&1
fi
SH
chmod +x /usr/local/sbin/moonlight-start.sh

# Optional HDMI/KMS helper
cat >/usr/local/sbin/set-hdmi-mode.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CFG=/boot/firmware/config.txt
cp -n "$CFG" "$CFG.bak.$(date +%s)" || true
grep -q '^dtoverlay=vc4-kms-v3d' "$CFG" || echo 'dtoverlay=vc4-kms-v3d' >>"$CFG"
grep -q '^hdmi_enable_4kp60=' "$CFG" || echo 'hdmi_enable_4kp60=1' >>"$CFG"
echo "[set-hdmi-mode] Applied safe HDMI options. Reboot required."
SH
chmod +x /usr/local/sbin/set-hdmi-mode.sh

# Services
cat >/etc/systemd/system/moonlight-pair-once.service <<'UNIT'
[Unit]
Description=Moonlight Pair Once
Before=moonlight-sonnet.service
[Service]
Type=oneshot
# Pair on first boot if client cert is missing; exit non-zero so user sees PIN on console
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

# Logrotate for Moonlight
cat >/etc/logrotate.d/moonlight <<'ROT'
/var/log/moonlight/*.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
ROT

# -----------------------
# Finalize
# -----------------------
log "Reloading units and enabling services..."
systemctl daemon-reload
systemctl enable --now birdnet-go.service
systemctl enable --now moonlight-sonnet.service

log "All done."
log "Next steps:"
log " - Join Tailscale (optional): sudo tailscale up"
log " - If 'Desktop' not listed: moonlight list Nemarion.local"
log " - Pairing: if prompted on boot, enter the PIN in Sunshine on Nemarion.local"

# Auto-reboot on success (per your preference)
log "Rebooting now to apply kernel/firmware/display changes..."
reboot
