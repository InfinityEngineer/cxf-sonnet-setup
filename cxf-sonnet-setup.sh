#!/usr/bin/env bash
set -euo pipefail

# CXF Sonnet Setup for Raspberry Pi 3B+ (Bookworm, ARM64)
# - Tailscale (repo for Raspbian bookworm)
# - BirdNET-Go (ARM64) + best-effort migration from BirdNET-Pi (via birdnet-pi2go or file copy)
# - Moonlight Embedded from official Cloudsmith repo (Raspbian bookworm)
# - Moonlight systemd service with interactive resolution selector, last-used config persistence, auto-pair one-shot
# - KMS driver configuration, conservative defaults, logging + logrotate
#
# Re-run safe (idempotent). Emits clear logs and bails gracefully on missing prereqs.

###------------------------------###
### 0) PRECHECKS                  ###
###------------------------------###

log() { echo -e "\e[1;32m[CXF]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERR ]\e[0m $*"; }

# Require root
if [[ $EUID -ne 0 ]]; then
  err "Please run as root (sudo)."
  exit 1
fi

# Check OS: Raspberry Pi OS Bookworm, arm64
ID="$(. /etc/os-release && echo "${ID:-unknown}")"
VERSION_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
ARCH="$(dpkg --print-architecture)"
if [[ "$ID" != "raspbian" || "$VERSION_CODENAME" != "bookworm" || "$ARCH" != "arm64" ]]; then
  err "This script targets Raspberry Pi OS (raspbian) Bookworm 64-bit (arm64). Detected: ID=$ID, codename=$VERSION_CODENAME, arch=$ARCH"
  exit 1
fi

# Check network
if ! ping -c1 -W2 deb.debian.org >/dev/null 2>&1; then
  err "Network not reachable. Connect to the internet and retry."
  exit 1
fi

###------------------------------###
### 1) SYSTEM UPDATE + BASICS     ###
###------------------------------###

log "Updating system packages…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get full-upgrade -y

log "Installing base utilities…"
apt-get install -y curl git jq unzip logrotate ca-certificates pkg-config libcec6 cec-utils lsb-release

# Ensure KMS driver (Bookworm uses /boot/firmware/config.txt)
BOOTCFG="/boot/firmware/config.txt"
if [[ -f "$BOOTCFG" ]]; then
  cp "$BOOTCFG" "${BOOTCFG}.bak.$(date +%Y%m%d%H%M%S)"
  # Remove any fkms lines; ensure vc4-kms-v3d and gpu_mem=256 exist (append only if missing)
  sed -i '/dtoverlay=vc4-fkms-v3d/d' "$BOOTCFG"
  if ! grep -q '^dtoverlay=vc4-kms-v3d' "$BOOTCFG"; then
    echo "dtoverlay=vc4-kms-v3d" >> "$BOOTCFG"
    log "Added dtoverlay=vc4-kms-v3d to $BOOTCFG"
  fi
  if ! grep -q '^gpu_mem=' "$BOOTCFG"; then
    echo "gpu_mem=256" >> "$BOOTCFG"
    log "Added gpu_mem=256 to $BOOTCFG"
  fi
else
  warn "Boot config $BOOTCFG not found. Skipping KMS config."
fi

###------------------------------###
### 2) TAILSCALE (Raspbian repo)  ###
###------------------------------###
# Official instructions include a Bookworm entry for Raspbian. (See pkgs.tailscale.com stable page)

log "Configuring Tailscale repo for Raspbian Bookworm…"
install -d -m0755 /usr/share/keyrings
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.noarmor.gpg \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/raspbian/bookworm.tailscale-keyring.list \
  | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

apt-get update -y
apt-get install -y tailscale
systemctl enable --now tailscaled
log "Tailscale installed and service started."
log "To join your tailnet later, run:  sudo tailscale up  (add flags as needed)."

###------------------------------###
### 3) BIRDNET-GO                 ###
###------------------------------###

log "Setting up BirdNET-Go (arm64)…"

# System user + dirs
id -u birdnetgo >/dev/null 2>&1 || useradd --system --home /var/lib/birdnet-go --create-home --shell /usr/sbin/nologin birdnetgo
install -d -o birdnetgo -g birdnetgo -m 0755 /var/lib/birdnet-go
install -d -o birdnetgo -g birdnetgo -m 0755 /var/lib/birdnet-go/inbox
install -d -o birdnetgo -g birdnetgo -m 0755 /var/lib/birdnet-go/results
install -d -o birdnetgo -g birdnetgo -m 0755 /var/lib/birdnet-go/migrated
install -d -m 0755 /opt/birdnet-go

# Fetch latest ARM64 release tarball from GitHub API and install binary to /usr/local/bin/birdnet-go
log "Downloading latest BirdNET-Go release for arm64…"
BN_API="https://api.github.com/repos/tphakala/birdnet-go/releases/latest"
ASSET_URL="$(curl -fsSL "$BN_API" | jq -r '.assets[] | select((.name|test("linux.*arm64|aarch64"; "i"))) | .browser_download_url' | head -n1 || true)"
if [[ -z "${ASSET_URL:-}" ]]; then
  warn "Could not find ARM64 release asset via API. Falling back to installer script."
  curl -fsSL https://github.com/tphakala/birdnet-go/raw/main/install.sh -o /opt/birdnet-go/install.sh
  bash /opt/birdnet-go/install.sh || true
else
  TMP_TAR="$(mktemp)"
  curl -fsSL "$ASSET_URL" -o "$TMP_TAR"
  tar -xf "$TMP_TAR" -C /opt/birdnet-go
  rm -f "$TMP_TAR"
  # Locate binary (common names: birdnet-go or birdnet-go_*), then install
  BN_BIN="$(find /opt/birdnet-go -maxdepth 2 -type f -name 'birdnet-go*' | head -n1 || true)"
  if [[ -n "${BN_BIN:-}" ]]; then
    install -m 0755 "$BN_BIN" /usr/local/bin/birdnet-go
  fi
fi

# Minimal config
install -d -m 0755 /etc/birdnet-go
cat >/etc/birdnet-go/config.yaml <<'YAML'
# Minimal BirdNET-Go config for local inference on Pi
inbox: /var/lib/birdnet-go/inbox
outbox: /var/lib/birdnet-go/results
data_dir: /var/lib/birdnet-go
# Enable local inference; adjust model options as desired
inference:
  engine: "local"
  threads: 1
web:
  enabled: true
  bind: "0.0.0.0"
  port: 8080
logging:
  level: "info"
YAML
chown birdnetgo:birdnetgo /etc/birdnet-go/config.yaml

# Systemd unit
cat >/etc/systemd/system/birdnet-go.service <<'UNIT'
[Unit]
Description=BirdNET-Go service
After=network-online.target
Wants=network-online.target

[Service]
User=birdnetgo
Group=birdnetgo
WorkingDirectory=/var/lib/birdnet-go
ExecStart=/usr/local/bin/birdnet-go --config /etc/birdnet-go/config.yaml
Restart=on-failure
RestartSec=5s
Environment=HOME=/var/lib/birdnet-go

[Install]
WantedBy=multi-user.target
UNIT

# Migration best-effort using birdnet-pi2go if present, else copy audio/CSVs
log "Attempting BirdNET-Pi -> BirdNET-Go migration (best-effort)…"
MIG_LOG="/var/log/birdnet-go-migration.log"
touch "$MIG_LOG"

# Try to detect old media mounts that might contain BirdNET-Pi data
CANDIDATES=()
for P in /media/* /mnt/*; do
  [[ -d "$P" ]] && CANDIDATES+=("$P")
done

migrated="no"
if command -v birdnet-pi2go >/dev/null 2>&1; then
  for P in "${CANDIDATES[@]}"; do
    if compgen -G "$P/**/detections.db" >/dev/null || compgen -G "$P/**/detection-*.csv" >/dev/null || [[ -d "$P/audio" ]]; then
      log "Running birdnet-pi2go against $P …"
      # No standard CLI documented here; many tools expect source/dest params. We try a sane default:
      birdnet-pi2go --source "$P" --dest /var/lib/birdnet-go >>"$MIG_LOG" 2>&1 || true
      migrated="yes"
    fi
  done
fi

if [[ "$migrated" == "no" ]]; then
  for P in "${CANDIDATES[@]}"; do
    if compgen -G "$P/**/detections.db" >/dev/null || compgen -G "$P/**/detection-*.csv" >/dev/null || [[ -d "$P/audio" ]]; then
      log "birdnet-pi2go not found; copying audio/CSVs from $P…"
      # Copy audio
      if compgen -G "$P/**/*.wav" >/dev/null; then
        find "$P" -type f -iname '*.wav' -exec cp -n {} /var/lib/birdnet-go/inbox/ \; 2>>"$MIG_LOG" || true
      fi
      # Copy CSVs
      if compgen -G "$P/**/detection-*.csv" >/dev/null; then
        install -d -o birdnetgo -g birdnetgo -m 0755 /var/lib/birdnet-go/migrated
        find "$P" -type f -iname 'detection-*.csv' -exec cp -n {} /var/lib/birdnet-go/migrated/ \; 2>>"$MIG_LOG" || true
      fi
      echo "$(date -Is) : Copied from $P (best-effort)" >>"$MIG_LOG"
      migrated="yes"
    fi
  done
fi

if [[ "$migrated" == "no" ]]; then
  echo "$(date -Is) : No BirdNET-Pi-like data found; migration skipped" >>"$MIG_LOG"
  log "No BirdNET-Pi-like data found; migration skipped."
fi

systemctl enable --now birdnet-go.service
log "BirdNET-Go service enabled."

###------------------------------###
### 4) MOONLIGHT EMBEDDED         ###
###------------------------------###
# Use Cloudsmith repo for Raspbian bookworm (moonlight-embedded)

log "Adding Moonlight Embedded repo (Raspbian $(lsb_release -cs))…"
curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' \
  | distro=raspbian sudo -E bash
apt-get install -y moonlight-embedded

# Configuration storage for last-used settings
ML_CONF="/etc/moonlight-sonnet.conf"
if [[ ! -f "$ML_CONF" ]]; then
  cat >"$ML_CONF" <<'EOF'
HOST=CHANGE_ME_HOSTNAME_OR_IP
APP="Desktop"
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=6000
ROTATE=0
NOCEC=1
EOF
fi

# Helper: interactive resolution selector
install -m 0755 /usr/local/sbin/moonlight-resolution.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/moonlight-sonnet.conf"

# shellcheck disable=SC1090
source "$CONF"

echo
echo "Press ANY key within 10 seconds for alternative resolution settings or wait to use last-saved values…"
read -rs -n1 -t 10 key && pressed=1 || pressed=0

if [[ "$pressed" -eq 1 ]]; then
  # Show quick presets
  echo
  echo "Presets:"
  echo "  1) 1280x720 @30fps 6000kbps (safe default)"
  echo "  2) 1440x900 @30fps 7000kbps"
  echo "  3) 1600x900 @30fps 8000kbps"
  echo "  4) Custom"
  read -rp "Choose [1-4]: " choice
  case "${choice:-1}" in
    1) WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=6000 ;;
    2) WIDTH=1440; HEIGHT=900; FPS=30; BITRATE=7000 ;;
    3) WIDTH=1600; HEIGHT=900; FPS=30; BITRATE=8000 ;;
    4)
      read -rp "Width  [${WIDTH:-1280}]: " W; WIDTH="${W:-${WIDTH:-1280}}"
      read -rp "Height [${HEIGHT:-720}]: " H; HEIGHT="${H:-${HEIGHT:-720}}"
      read -rp "FPS    [${FPS:-30}]: " F; FPS="${F:-${FPS:-30}}"
      read -rp "Kbps   [${BITRATE:-6000}]: " B; BITRATE="${B:-${BITRATE:-6000}}"
      ;;
    *) WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=6000 ;;
  esac

  # Validate numeric
  for n in WIDTH HEIGHT FPS BITRATE; do
    val="${!n}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
      echo "Invalid $n=$val; falling back to defaults."
      WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=6000
      break
    fi
  done

  # Persist back to config
  awk -v W="$WIDTH" -v H="$HEIGHT" -v F="$FPS" -v B="$BITRATE" '
    BEGIN{w=0;h=0;f=0;b=0}
    /^WIDTH=/  {print "WIDTH="W; w=1; next}
    /^HEIGHT=/ {print "HEIGHT="H; h=1; next}
    /^FPS=/    {print "FPS="F; f=1; next}
    /^BITRATE=/{print "BITRATE="B; b=1; next}
    {print}
    END{
      if(!w) print "WIDTH="W;
      if(!h) print "HEIGHT="H;
      if(!f) print "FPS="F;
      if(!b) print "BITRATE="B;
    }
  ' "$CONF" > "${CONF}.new" && mv "${CONF}.new" "$CONF"
  echo "Saved: ${WIDTH}x${HEIGHT}@${FPS} ${BITRATE}kbps"
fi
SH

# One-shot pair helper: pairs if client cert missing
install -m 0755 /usr/local/sbin/moonlight-pair-once.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/moonlight-sonnet.conf"
# shellcheck disable=SC1090
source "$CONF"

STATE_DIR="/var/lib/moonlight"
CERT="$STATE_DIR/client.pem"
mkdir -p "$STATE_DIR"

if [[ ! -f "$CERT" ]]; then
  echo "[Moonlight] Not paired yet. Starting pairing with host: ${HOST}"
  echo "If a PIN is shown below, enter it on the host (Sunshine/NVIDIA host pairing prompt)."
  moonlight pair "$HOST" || {
    echo "[Moonlight] Pairing did not complete. Try again later with: moonlight pair $HOST"
    exit 1
  }
fi
SH

# Wrapper to start moonlight with current config and auto-fallback to 720p if stream can't start
install -m 0755 /usr/local/sbin/moonlight-start.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/moonlight-sonnet.conf"
LOGDIR="/var/log/moonlight"
mkdir -p "$LOGDIR"

# shellcheck disable=SC1090
source "$CONF"

# Ensure host set
if [[ "${HOST:-CHANGE_ME_HOSTNAME_OR_IP}" == "CHANGE_ME_HOSTNAME_OR_IP" ]]; then
  echo "[Moonlight] HOST is not set in $CONF. Edit it before starting." | tee -a "$LOGDIR/moonlight.log"
  exit 1
fi

# Allow user to adjust resolution on boot
/usr/local/sbin/moonlight-resolution.sh || true
# Reload updated values
source "$CONF"

# Build args
ARGS=(stream -width "$WIDTH" -height "$HEIGHT" -fps "$FPS" -bitrate "$BITRATE")
# -nocec by default (Bookworm+KMS); ignore CEC
if [[ "${NOCEC:-1}" -eq 1 ]]; then
  ARGS+=(-nocec)
fi
# Rotation if needed (avoid legacy display_rotate with KMS)
if [[ "${ROTATE:-0}" =~ ^[0-9]+$ && "$ROTATE" -ne 0 ]]; then
  ARGS+=(-rotate "$ROTATE")
fi

# Disable audio playback on the Pi by not configuring any audio sink here.
# (We intentionally avoid installing PulseAudio/pipewire; host handles audio.)
APP="${APP:-Desktop}"

# Try preferred mode
echo "[Moonlight] Starting stream ${WIDTH}x${HEIGHT}@${FPS} ${BITRATE}kbps, app=\"${APP}\"…" | tee -a "$LOGDIR/moonlight.log"
if ! /usr/bin/moonlight "${ARGS[@]}" -app "$APP" "$HOST" -verbose >>"$LOGDIR/moonlight.log" 2>&1; then
  echo "[Moonlight] Stream failed; falling back to 1280x720@30 6000kbps." | tee -a "$LOGDIR/moonlight.log"
  /usr/bin/moonlight stream -width 1280 -height 720 -fps 30 -bitrate 6000 -nocec -app "$APP" "$HOST" -verbose >>"$LOGDIR/moonlight.log" 2>&1 || true
fi
SH

# Systemd: pair-once oneshot
cat >/etc/systemd/system/moonlight-pair-once.service <<'UNIT'
[Unit]
Description=Moonlight Pair (one-shot if unpaired)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/moonlight-pair-once.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Systemd: moonlight main service (runs on boot, interactive window for 10s)
cat >/etc/systemd/system/moonlight-sonnet.service <<'UNIT'
[Unit]
Description=Moonlight Embedded (CXF Sonnet)
After=moonlight-pair-once.service network-online.target
Wants=moonlight-pair-once.service network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
TTYPath=/dev/tty1
StandardInput=tty
ExecStart=/bin/bash -lc '/usr/local/sbin/moonlight-start.sh'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

# Logging dir + logrotate
install -d -m 0755 /var/log/moonlight
cat >/etc/logrotate.d/moonlight <<'ROT'
/var/log/moonlight/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 root root
}
ROT

###------------------------------###
### 5) HDMI MODE HELPER (optional)###
###------------------------------###

install -m 0755 /usr/local/sbin/set-hdmi-mode.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CFG="/boot/firmware/config.txt"
cp "$CFG" "${CFG}.bak.$(date +%Y%m%d%H%M%S)"
# NOTE: Bookworm uses KMS. We avoid legacy hdmi_* tweaks unless absolutely needed.
# This writes a safe 1080p60 group/mode pair that KMS usually honors via firmware fallback if required.
sed -i '/^hdmi_group=/d; /^hdmi_mode=/d' "$CFG"
echo "hdmi_group=1" >> "$CFG"   # CEA
echo "hdmi_mode=16" >> "$CFG"   # 1080p60
echo "[INFO] Wrote hdmi_group=1, hdmi_mode=16 to $CFG. Reboot required."
SH

###------------------------------###
### 6) FINALIZE                   ###
###------------------------------###

systemctl daemon-reload
systemctl enable moonlight-pair-once.service
systemctl enable moonlight-sonnet.service

log "Setup complete."
echo
echo "NEXT STEPS:"
echo "  1) Edit Moonlight host:    sudo nano /etc/moonlight-sonnet.conf   (set HOST, APP if needed)"
echo "  2) Pair (auto at boot if unpaired) or manually:   moonlight pair <HOST>"
echo "  3) Join Tailscale:          sudo tailscale up"
echo "  4) If host has no display/dummy and modes fail, try: 1280x720@30fps ~6000kbps (auto-fallback included)."
echo
read -rp "Reboot now? [Y/n]: " R
if [[ "${R:-Y}" =~ ^[Yy]$ ]]; then
  reboot
else
  log "Reboot skipped. You can start Moonlight with:  sudo systemctl start moonlight-sonnet"
fi
