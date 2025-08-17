#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CXF‑Sonnet one‑shot setup for Raspberry Pi 3B+ (Raspberry Pi OS Bookworm arm64)
# Idempotent, logged, strict mode. Creates Moonlight + BirdNET-Go + Tailscale.
#
# Usage (after you upload this file to your repo):
#   curl -fsSL https://raw.githubusercontent.com/InfinityEngineer/cxf-sonnet-setup/main/sonnet-setup.sh | sudo bash
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

CXF_TAG="[CXF]"
SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=("-y" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")

log() { echo "${CXF_TAG} $*"; }
ensure_dir() { $SUDO install -d -m "${3:-0755}" "$2" 2>/dev/null || true; $SUDO chown "${4:-root:root}" "$2" || true; }
backup_file_once() { local f="$1"; if [[ -f "$f" && ! -f "$f.cxf.bak" ]]; then $SUDO cp -a "$f" "$f.cxf.bak"; fi }
append_if_missing() { local line="$1" file="$2"; grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" | $SUDO tee -a "$file" >/dev/null; }
replace_or_append_kv() { local file="$1" key="$2" val="$3"; backup_file_once "$file"; if grep -Eq "^\s*${key}\s*=" "$file" 2>/dev/null; then $SUDO sed -i "s|^\s*${key}\s*=.*|${key}=${val}|" "$file"; else echo "${key}=${val}" | $SUDO tee -a "$file" >/dev/null; fi }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# --- Base OS Prep ----------------------------------------------------------------
log "Updating apt package lists"
$SUDO apt-get update -qq || true
log "Installing base packages"
$SUDO apt-get install "${APT_OPTS[@]}" \
  curl wget unzip git vim ca-certificates gnupg lsb-release build-essential cmake \
  libasound2-dev logrotate jq >/dev/null

# Ensure KMS and GPU mem on Bookworm
CONFIG_TXT="/boot/firmware/config.txt"
if [[ -f "$CONFIG_TXT" ]]; then
  backup_file_once "$CONFIG_TXT"
  append_if_missing "dtoverlay=vc4-kms-v3d" "$CONFIG_TXT"
  # ensure only one gpu_mem= entry and set to 256
  if grep -Eq "^gpu_mem=" "$CONFIG_TXT"; then $SUDO sed -i "s/^gpu_mem=.*/gpu_mem=256/" "$CONFIG_TXT"; else echo "gpu_mem=256" | $SUDO tee -a "$CONFIG_TXT" >/dev/null; fi
else
  log "WARN: $CONFIG_TXT not found (non‑standard image?). Skipping KMS tweak."
fi

# --- Tailscale -------------------------------------------------------------------
log "Configuring Tailscale repo/key"
ensure_dir "/usr/share/keyrings" 0755
if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | \
    $SUDO tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
fi
TS_LIST="/etc/apt/sources.list.d/tailscale.list"
backup_file_once "$TS_LIST"
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" | \
  $SUDO tee "$TS_LIST" >/dev/null
$SUDO apt-get update -qq || true
$SUDO apt-get install "${APT_OPTS[@]}" tailscale >/dev/null || true
$SUDO systemctl enable --now tailscaled >/dev/null

# --- Moonlight Embedded ----------------------------------------------------------
log "Configuring Moonlight Embedded repo/key"
ensure_dir "/usr/share/keyrings" 0755
# Moonlight Embedded official Cloudsmith repo (Debian/Bookworm)
if [[ ! -f /usr/share/keyrings/moonlight-embedded.gpg ]]; then
  curl -fsSL https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key | \
    $SUDO gpg --dearmor -o /usr/share/keyrings/moonlight-embedded.gpg
fi
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"
backup_file_once "$ML_LIST"
echo "deb [signed-by=/usr/share/keyrings/moonlight-embedded.gpg] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/debian bookworm main" | $SUDO tee "$ML_LIST" >/dev/null
$SUDO apt-get update -qq || true
$SUDO apt-get install "${APT_OPTS[@]}" moonlight-embedded >/dev/null

# Moonlight config and helpers
ensure_dir "/etc" 0755
CONF="/etc/moonlight-sonnet.conf"
backup_file_once "$CONF"
if [[ ! -f "$CONF" ]]; then
  cat | $SUDO tee "$CONF" >/dev/null <<'CFG'
# Moonlight (Sonnet) config (key=value)
HOST=nemarion.local
APP=Desktop
WIDTH=1920
HEIGHT=1080
FPS=60
BITRATE=20000
NOCEC=1
CFG
fi

# Logging
ensure_dir "/var/log/moonlight" 0755
$SUDO touch /var/log/moonlight/sonnet.log /var/log/moonlight/pair.log

# Helper: moonlight-resolution.sh (optional boot override with 10s prompt)
cat | $SUDO tee /usr/local/sbin/moonlight-resolution.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
CONF="/etc/moonlight-sonnet.conf"
TMP="/run/moonlight-override.res"
# Show prompt with 10s timeout: press any key to enter custom WxH@FPS
printf "[CXF] Within 10 seconds, press any key to set a temporary resolution (format: WIDTHxHEIGHT@FPS) ...\n"
read -r -t 10 -n 1 ANY && {
  echo "\n[CXF] Enter resolution (e.g., 1280x720@60): "
  read -r RES
  if [[ "$RES" =~ ^([0-9]{3,5})x([0-9]{3,5})@([0-9]{2,3})$ ]]; then
    echo "$RES" > "$TMP"
    echo "[CXF] Override set: $RES"
  else
    echo "[CXF] Invalid format. Ignoring override."
  fi
} || true
exit 0
SH
$SUDO chmod +x /usr/local/sbin/moonlight-resolution.sh

# Helper: moonlight-start.sh
cat | $SUDO tee /usr/local/sbin/moonlight-start.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
CONF="/etc/moonlight-sonnet.conf"
LOG_DIR="/var/log/moonlight"
PAIR_KEYS_DIR="/var/lib/moonlight"
OVR="/run/moonlight-override.res"
mkdir -p "$LOG_DIR" "$PAIR_KEYS_DIR"
source "$CONF"
# Pull possible override
if [[ -f "$OVR" ]]; then
  RES=$(cat "$OVR"); rm -f "$OVR"
  WIDTH=${RES%x*}; tmp=${RES#*x}; HEIGHT=${tmp%@*}; FPS=${RES##*@}
fi
# Build args
ARGS=("stream" "$HOST" "-app" "$APP" "-fps" "$FPS" "-bitrate" "$BITRATE" "-width" "$WIDTH" "-height" "$HEIGHT")
if [[ "${NOCEC:-0}" == "1" ]]; then ARGS+=("-nolaunch") ; fi
# Prefer ALSA default. If audio issues, drop -audio flag to let moonlight auto-detect.
# Pair check: if no keys, attempt non-interactive list to trigger helpful error.
if [[ ! -d "$PAIR_KEYS_DIR" || -z "$(ls -A "$PAIR_KEYS_DIR" 2>/dev/null || true)" ]]; then
  echo "[CXF] No Moonlight keys found; try pairing service or run: moonlight pair $HOST" | tee -a "$LOG_DIR/sonnet.log"
fi
exec /usr/bin/moonlight "${ARGS[@]}" >>"$LOG_DIR/sonnet.log" 2>&1
SH
$SUDO chmod +x /usr/local/sbin/moonlight-start.sh

# Systemd: moonlight-pair-once (attempt pair if keys missing)
cat | $SUDO tee /etc/systemd/system/moonlight-pair-once.service >/dev/null <<'UNIT'
[Unit]
Description=Moonlight one-time pairing helper
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/moonlight/.paired

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -e; LOG=/var/log/moonlight/pair.log; HOST=$(sed -n "s/^HOST=//p" /etc/moonlight-sonnet.conf); mkdir -p /var/lib/moonlight; if moonlight list "$HOST" >>"$LOG" 2>&1; then touch /var/lib/moonlight/.paired; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# Systemd: moonlight-sonnet (autostart)
cat | $SUDO tee /etc/systemd/system/moonlight-sonnet.service >/dev/null <<'UNIT'
[Unit]
Description=Moonlight streaming (Sonnet)
After=network-online.target systemd-user-sessions.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/moonlight-resolution.sh
ExecStart=/usr/local/sbin/moonlight-start.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# Logrotate for moonlight logs
cat | $SUDO tee /etc/logrotate.d/moonlight >/dev/null <<'ROT'
/var/log/moonlight/*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
ROT

# --- BirdNET-Go ------------------------------------------------------------------
BNG_DIR="/opt/birdnet-go"
BNG_BIN="$BNG_DIR/birdnet-go"
BNG_DATA="/var/lib/birdnet-go"
BNG_USER="birdnetgo"
BNG_SVC="/etc/systemd/system/birdnet-go.service"

log "Installing BirdNET-Go (latest release)"
if ! id -u "$BNG_USER" >/dev/null 2>&1; then $SUDO useradd -r -s /usr/sbin/nologin "$BNG_USER"; fi
ensure_dir "$BNG_DIR" 0755 "$BNG_USER:$BNG_USER"
ensure_dir "$BNG_DATA" 0755 "$BNG_USER:$BNG_USER"

# Fetch latest arm64 release tarball via GitHub API
TMPD=$(mktemp -d)
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

if [[ ! -x "$BNG_BIN" ]]; then
  API_JSON="$TMPD/release.json"
  curl -fsSL https://api.github.com/repos/tphakala/birdnet-go/releases/latest -o "$API_JSON"
  ASSET_URL=$(jq -r '.assets[] | select(.name|test("linux-arm64.*tar.gz$")) | .browser_download_url' "$API_JSON" | head -n1)
  if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    log "ERROR: Could not find arm64 tarball for BirdNET-Go."; exit 1
  fi
  log "Downloading: $ASSET_URL"
  curl -fsSL "$ASSET_URL" -o "$TMPD/birdnet-go.tar.gz"
  tar -xzf "$TMPD/birdnet-go.tar.gz" -C "$TMPD"
  # Find extracted binary
  BNG_EXTRACT=$(find "$TMPD" -type f -name 'birdnet-go' | head -n1)
  $SUDO install -m 0755 "$BNG_EXTRACT" "$BNG_BIN"
  $SUDO chown "$BNG_USER:$BNG_USER" "$BNG_BIN"
fi

# BirdNET-Go service (realtime + HTTP 8080)
cat | $SUDO tee "$BNG_SVC" >/dev/null <<UNIT
[Unit]
Description=BirdNET-Go realtime with HTTP
After=network-online.target
Wants=network-online.target

[Service]
User=$BNG_USER
Group=$BNG_USER
WorkingDirectory=$BNG_DIR
ExecStart=$BNG_BIN realtime --http :8080 --data $BNG_DATA
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- birdnet-pi2go (migration helper) ------------------------------------------
log "Installing birdnet-pi2go migration helper (latest)"
if ! cmd_exists birdnet-pi2go; then
  BNPI_JSON="$TMPD/pi2go.json"
  curl -fsSL https://api.github.com/repos/tphakala/birdnet-pi2go/releases/latest -o "$BNPI_JSON"
  PI2GO_URL=$(jq -r '.assets[] | select(.name|test("linux-arm64$")) | .browser_download_url' "$BNPI_JSON" | head -n1)
  if [[ -z "$PI2GO_URL" || "$PI2GO_URL" == "null" ]]; then
    log "WARN: Could not find arm64 birdnet-pi2go binary. Skipping install."
  else
    curl -fsSL "$PI2GO_URL" -o "$TMPD/birdnet-pi2go"
    $SUDO install -m 0755 "$TMPD/birdnet-pi2go" /usr/local/bin/birdnet-pi2go
  fi
fi

# Example migration notes (not executed):
MIG_HINT="/usr/local/share/cxf-birdnet-migration.txt"
cat | $SUDO tee "$MIG_HINT" >/dev/null <<'TXT'
Example migration from old BirdNET-Pi USB stick (adjust paths):

# Ensure target DB does not exist or is backed up first
sudo systemctl stop birdnet-go
sudo mv /var/lib/birdnet-go/birdnet.db /var/lib/birdnet-go/birdnet.db.bak 2>/dev/null || true

# Copy DB and clips
sudo birdnet-pi2go \
  -source-db /media/usb/birds.db \
  -target-db /var/lib/birdnet-go/birdnet.db \
  -source-dir /media/usb/recordings \
  -target-dir /var/lib/birdnet-go/clips \
  -operation copy | sudo tee -a /var/log/cxf-pi2go.log

sudo chown -R birdnetgo:birdnetgo /var/lib/birdnet-go
sudo systemctl start birdnet-go
TXT

# Ensure migration log exists
$SUDO touch /var/log/cxf-pi2go.log

# --- Enable services & reload ----------------------------------------------------
log "Enabling services"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now moonlight-pair-once.service >/dev/null || true
$SUDO systemctl enable --now moonlight-sonnet.service >/dev/null || true
$SUDO systemctl enable --now birdnet-go.service >/dev/null || true

# --- Summary --------------------------------------------------------------------
log "Setup complete"
# IP summary
IP_A=$(hostname -I 2>/dev/null || true)
TS_STATE=$(tailscale status --peers=false 2>/dev/null || echo "tailscale not up")
cat <<EOS
${CXF_TAG} Setup complete.
${CXF_TAG} Local IP(s): ${IP_A}
${CXF_TAG} Tailscale: ${TS_STATE}
${CXF_TAG} To enable remote SSH via Tailscale, run on Sonnet:
${CXF_TAG}   sudo tailscale up --ssh --accept-routes=true
${CXF_TAG} Moonlight quick check (on Sonnet):
${CXF_TAG}   moonlight list "+" 
${CXF_TAG} or: moonlight list \$(sed -n 's/^HOST=//p' /etc/moonlight-sonnet.conf)
${CXF_TAG} BirdNET-Go logs:
${CXF_TAG}   journalctl -u birdnet-go -e --no-pager
${CXF_TAG} BirdNET-Go web UI (if enabled by build/flags): http://<sonnet>:8080/
${CXF_TAG} Migration notes: sudo nano $MIG_HINT
${CXF_TAG} Reminder: reboot is recommended for KMS/HDMI overlay changes to apply.
EOS
