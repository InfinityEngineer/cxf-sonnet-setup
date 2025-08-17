#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CXF‑Sonnet one‑shot setup for Raspberry Pi 3B+ (Raspberry Pi OS Bookworm arm64)
# Idempotent, logged, strict mode. Creates Moonlight + BirdNET-Go + Tailscale.
#
# Usage (after you upload this file to your repo):
#   curl -fsSL https://raw.githubusercontent.com/InfinityEngineer/cxf-sonnet-setup/main/sonnet-setup.sh | sudo bash
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'
	'

CXF_TAG="[CXF]"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=("-y" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")

log()  { echo "${CXF_TAG} $*"; }
warn() { echo "${CXF_TAG} WARN: $*"; }
ensure_dir() { sudo install -d -m "${2:-0755}" "$1" 2>/dev/null || true; sudo chown "${3:-root:root}" "$1" || true; }
backup_file_once() { local f="$1"; if [[ -f "$f" && ! -f "$f.cxf.bak" ]]; then sudo cp -a "$f" "$f.cxf.bak"; fi }
append_if_missing() { local line="$1" file="$2"; grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" | sudo tee -a "$file" >/dev/null; }
replace_or_append_kv() { local file="$1" key="$2" val="$3"; backup_file_once "$file"; if grep -Eq "^\s*${key}\s*=" "$file" 2>/dev/null; then sudo sed -i "s|^\s*${key}\s*=.*|${key}=${val}|" "$file"; else echo "${key}=${val}" | sudo tee -a "$file" >/dev/null; fi }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

umask 022

# --- APT Preflight: quarantine conflicting Moonlight sources --------------------
ensure_dir "/etc/apt/sources.list.d.disabled" 0755
shopt -s nullglob || true
for f in /etc/apt/sources.list.d/*moonlight*; do
  sudo mv -f "$f" "/etc/apt/sources.list.d.disabled/$(basename "$f").cxf.disabled" || true
done
shopt -u nullglob || true

# --- Base OS Prep ---------------------------------------------------------------
log "Updating apt package lists"
sudo apt-get update -qq || true

log "Installing base packages"
sudo apt-get install "${APT_OPTS[@]}" \
  curl wget unzip git vim ca-certificates gnupg lsb-release build-essential cmake \
  libasound2-dev logrotate jq >/dev/null

# Ensure KMS and GPU mem on Bookworm
CONFIG_TXT="/boot/firmware/config.txt"
if [[ -f "$CONFIG_TXT" ]]; then
  backup_file_once "$CONFIG_TXT"
  append_if_missing "dtoverlay=vc4-kms-v3d" "$CONFIG_TXT"
  if grep -Eq "^gpu_mem=" "$CONFIG_TXT"; then sudo sed -i "s/^gpu_mem=.*/gpu_mem=256/" "$CONFIG_TXT"; else echo "gpu_mem=256" | sudo tee -a "$CONFIG_TXT" >/dev/null; fi
else
  warn "$CONFIG_TXT not found (non‑standard image?). Skipping KMS tweak."
fi

# --- Tailscale ------------------------------------------------------------------
log "Configuring Tailscale repo/key"
ensure_dir "/usr/share/keyrings" 0755
OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)
TS_PATH="debian"
[[ "${OS_ID:-debian}" =~ (raspbian|raspberrypi) ]] && TS_PATH="raspbian"

if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.tailscale.com/stable/${TS_PATH}/bookworm.noarmor.gpg" | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null || true
fi

TS_LIST="/etc/apt/sources.list.d/tailscale.list"
backup_file_once "$TS_LIST"
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${TS_PATH} bookworm main" | \
  sudo tee "$TS_LIST" >/dev/null

sudo apt-get update -qq || true
sudo apt-get install "${APT_OPTS[@]}" tailscale tailscale-archive-keyring >/dev/null || true
sudo systemctl enable --now tailscaled >/dev/null || true

# --- Moonlight Embedded ---------------------------------------------------------
log "Configuring Moonlight Embedded repo/key (normalize + pin keyring)"
ensure_dir "/usr/share/keyrings" 0755

# Pick correct Cloudsmith path for RPi images
ML_PATH="debian"
[[ "${OS_ID:-debian}" =~ (raspbian|raspberrypi) ]] && ML_PATH="raspbian"

ML_KEYRING="/usr/share/keyrings/moonlight-embedded-archive-keyring.gpg"
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"

# Clean any stale keyring & lists to avoid 'Signed-By' conflicts
sudo rm -f /usr/share/keyrings/moonlight-embedded*.gpg* || true
sudo rm -f /etc/apt/sources.list.d/*moonlight* || true

# Always refresh the keyring (no prompts, atomic)
TMP_KEY=$(mktemp)
if curl -fsSL "https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key" | gpg --dearmor >"${TMP_KEY}"; then
  sudo install -m 0644 -o root -g root "${TMP_KEY}" "$ML_KEYRING"
  rm -f "${TMP_KEY}"
else
  warn "Failed to fetch Moonlight GPG key; apt will likely fail until key present."
fi

backup_file_once "$ML_LIST"
echo "deb [signed-by=$ML_KEYRING] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/${ML_PATH} bookworm main" | \
  sudo tee "$ML_LIST" >/dev/null

log "Running apt-get update for Moonlight"
if ! sudo apt-get update -qq; then
  warn "apt-get update reported issues for Moonlight; continuing (package may already be installed)."
fi

log "Installing Moonlight Embedded"
if ! dpkg -s moonlight-embedded >/dev/null 2>&1; then
  sudo apt-get install "${APT_OPTS[@]}" moonlight-embedded || warn "Moonlight install may have failed; run 'apt-cache policy moonlight-embedded' to inspect."
else
  log "moonlight-embedded already installed"
fi

# --- Moonlight config + helpers -------------------------------------------------
ensure_dir "/var/log/moonlight" 0755
CFG="/etc/moonlight-sonnet.conf"
if [[ ! -f "$CFG" ]]; then
  log "Writing default Moonlight config"
  sudo tee "$CFG" >/dev/null <<'EOF'
HOST=nemarion.local
APP=Desktop
WIDTH=1920
HEIGHT=1080
FPS=60
BITRATE=10000
# 1 = add -nocec, 0 = allow CEC
NOCEC=1
EOF
fi

install_exec() { # install_exec <path> 
<content>
  local dst="$1"; shift
  sudo tee "$dst" >/dev/null <<'SH'
PLACEHOLDER
SH
  # Replace placeholder with caller-provided heredoc via sed-safe approach
}

# moonlight-start.sh
sudo tee /usr/local/sbin/moonlight-start.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'
	'
CFG=/etc/moonlight-sonnet.conf
# shellcheck disable=SC1090
[[ -f "$CFG" ]] && . "$CFG"

HOST="${HOST:-nemarion.local}"
APP="${APP:-Desktop}"
WIDTH="${WIDTH:-1920}"
HEIGHT="${HEIGHT:-1080}"
FPS="${FPS:-60}"
BITRATE="${BITRATE:-10000}"
NOCEC="${NOCEC:-1}"

LOG=/var/log/moonlight/stream.log
mkdir -p "$(dirname "$LOG")"

FALLBACK_FLAG=/run/moonlight-fallback
[[ -f "$FALLBACK_FLAG" ]] && WIDTH=1280 HEIGHT=720 FPS=30 BITRATE=6000

ARGS=(-app "$APP" -fps "$FPS" -bitrate "$BITRATE" -width "$WIDTH" -height "$HEIGHT")
[[ "$NOCEC" = "1" ]] && ARGS=(-nocec "${ARGS[@]}")

{
  echo "[CXF] $(date -Is) starting Moonlight → $HOST ${ARGS[*]}"
  if moonlight stream "$HOST" "${ARGS[@]}"; then
    echo "[CXF] $(date -Is) Moonlight session ended normally"
  else
    echo "[CXF] $(date -Is) Primary stream failed — trying 1280x720@30 fallback"
    moonlight stream "$HOST" -app "$APP" -fps 30 -bitrate 6000 -width 1280 -height 720 ${NOCEC:+-nocec} || true
  fi
} >>"$LOG" 2>&1
SH
sudo chmod +x /usr/local/sbin/moonlight-start.sh

# moonlight-resolution.sh (10s prompt on TTY1 to force 720p fallback for this boot)
sudo tee /usr/local/sbin/moonlight-resolution.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
  exec </dev/tty1 >/dev/tty1 2>&1 || true
  echo "[CXF] Press ENTER within 10s to use 1280x720@30 fallback for this boot..."
  if read -r -t 10 _; then
    echo "[CXF] Fallback selected"
    touch /run/moonlight-fallback
  else
    rm -f /run/moonlight-fallback 2>/dev/null || true
  fi
} || true
SH
sudo chmod +x /usr/local/sbin/moonlight-resolution.sh

# Pair-once helper
sudo tee /usr/local/sbin/moonlight-pair-once.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CFG=/etc/moonlight-sonnet.conf
[[ -f "$CFG" ]] && . "$CFG"
HOST="${HOST:-nemarion.local}"
# If listing fails (not paired), attempt a pair. User must confirm PIN on host.
if ! moonlight list "$HOST" >/dev/null 2>&1; then
  echo "[CXF] Moonlight not paired. Attempting 'moonlight pair $HOST'..."
  moonlight pair "$HOST" || true
else
  echo "[CXF] Moonlight already paired with $HOST"
fi
SH
sudo chmod +x /usr/local/sbin/moonlight-pair-once.sh

# --- Systemd units for Moonlight ------------------------------------------------
ensure_dir "/etc/systemd/system" 0755
sudo tee /etc/systemd/system/moonlight-pair-once.service >/dev/null <<'UNIT'
[Unit]
Description=Moonlight: Pair with host once if needed
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/moonlight-pair-once.sh

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/moonlight-sonnet.service >/dev/null <<'UNIT'
[Unit]
Description=Moonlight: CXF Sonnet autostart stream
After=moonlight-pair-once.service network-online.target
Wants=moonlight-pair-once.service network-online.target

[Service]
Type=simple
Environment=TERM=linux
StandardOutput=journal
StandardError=journal
ExecStartPre=-/usr/local/sbin/moonlight-resolution.sh
ExecStart=/usr/local/sbin/moonlight-start.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# --- Logging: logrotate for Moonlight ------------------------------------------
sudo tee /etc/logrotate.d/moonlight >/dev/null <<'ROT'
/var/log/moonlight/*.log {
  weekly
  rotate 7
  missingok
  compress
  delaycompress
  notifempty
  copytruncate
}
ROT

# --- BirdNET-Go -----------------------------------------------------------------
log "Installing/refreshing BirdNET-Go"
ensure_dir "/opt/birdnet-go" 0755
ensure_dir "/var/lib/birdnet-go" 0755 birdnetgo:birdnetgo
if ! id -u birdnetgo >/dev/null 2>&1; then sudo useradd --system --home /var/lib/birdnet-go --shell /usr/sbin/nologin birdnetgo; fi
sudo chown -R birdnetgo:birdnetgo /var/lib/birdnet-go

BIRDNET_REPO_SLUG="${BIRDNET_REPO_SLUG:-tphakala/birdnet-go}"
BN_ASSET_URL=$(curl -fsSL "https://api.github.com/repos/${BIRDNET_REPO_SLUG}/releases/latest" \
  | jq -r '.assets[]? | select((.name|test("(?i)(linux|rasp).*a(arch)?64.*(tar.gz|tgz)$"))) | .browser_download_url' | head -n1 || true)
if [[ -n "${BN_ASSET_URL:-}" ]]; then
  TMP_TGZ=$(mktemp)
  curl -fsSL "$BN_ASSET_URL" -o "$TMP_TGZ"
  sudo tar -xzf "$TMP_TGZ" -C /opt/birdnet-go --strip-components=0 || true
  rm -f "$TMP_TGZ"
  # try to find the binary path
  if [[ -x /opt/birdnet-go/birdnet-go ]]; then
    sudo ln -sf /opt/birdnet-go/birdnet-go /usr/local/bin/birdnet-go
  else
    # find by name
    BN_BIN=$(sudo find /opt/birdnet-go -maxdepth 2 -type f -name 'birdnet-go*' -perm -111 | head -n1 || true)
    [[ -n "${BN_BIN:-}" ]] && sudo ln -sf "$BN_BIN" /usr/local/bin/birdnet-go || warn "birdnet-go binary not found after extract"
  fi
else
  warn "Could not resolve latest BirdNET-Go arm64 asset from ${BIRDNET_REPO_SLUG}; set BIRDNET_REPO_SLUG and re-run."
fi

# Service for BirdNET-Go realtime
sudo tee /etc/systemd/system/birdnet-go.service >/dev/null <<'UNIT'
[Unit]
Description=BirdNET-Go realtime service
After=network-online.target
Wants=network-online.target

[Service]
User=birdnetgo
Group=birdnetgo
WorkingDirectory=/var/lib/birdnet-go
ExecStart=/usr/local/bin/birdnet-go realtime --http :8080 --data /var/lib/birdnet-go
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- birdnet-pi2go (optional helper) -------------------------------------------
log "Installing birdnet-pi2go helper (best-effort)"
BNP2G_REPO_SLUG="${BNP2G_REPO_SLUG:-birdnet-pi/birdnet-pi2go}"
P2G_URL=$(curl -fsSL "https://api.github.com/repos/${BNP2G_REPO_SLUG}/releases/latest" 2>/dev/null \
  | jq -r '.assets[]? | select((.name|test("(?i)(linux|arm64|aarch64)$"))) | .browser_download_url' | head -n1 || true)
if [[ -n "${P2G_URL:-}" ]]; then
  TMP_BIN=$(mktemp)
  curl -fsSL "$P2G_URL" -o "$TMP_BIN" && sudo install -m 0755 "$TMP_BIN" /usr/local/bin/birdnet-pi2go && rm -f "$TMP_BIN" || warn "Failed to install birdnet-pi2go"
else
  warn "Could not auto-detect birdnet-pi2go arm64 asset from ${BNP2G_REPO_SLUG}. You can place the binary at /usr/local/bin/birdnet-pi2go manually."
fi

# Provide example migration helper script + log path
sudo tee /usr/local/sbin/birdnet-pi2go-migrate-example.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
LOG=/var/log/cxf-pi2go.log
exec > >(tee -a "$LOG") 2>&1

echo "[CXF] Example migration from BirdNET-Pi USB → BirdNET-Go"
echo "[CXF] NOTE: Target DB must not exist; back it up or remove first."

birdnet-pi2go -source-db /media/usb/birds.db \
  -target-db /var/lib/birdnet-go/birdnet.db \
  -source-dir /media/usb/recordings \
  -target-dir /var/lib/birdnet-go/clips \
  -operation copy
SH
sudo chmod +x /usr/local/sbin/birdnet-pi2go-migrate-example.sh
ensure_dir "/var/log" 0755
: >/var/log/cxf-pi2go.log || true

# --- Enable services ------------------------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable --now moonlight-pair-once.service >/dev/null 2>&1 || true
sudo systemctl enable --now moonlight-sonnet.service     >/dev/null 2>&1 || true
sudo systemctl enable --now birdnet-go.service           >/dev/null 2>&1 || true

# --- Summary Output -------------------------------------------------------------
IP4S=$(hostname -I 2>/dev/null | xargs || true)
TSIP=$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | xargs || true)
CFG_HOST=$(awk -F= '/^HOST=/{print $2}' "$CFG" 2>/dev/null || echo nemarion.local)

echo
log "Setup complete"
[[ -n "$IP4S" ]] && echo "${CXF_TAG} LAN IPs: $IP4S"
[[ -n "$TSIP" ]] && echo "${CXF_TAG} Tailscale IP: $TSIP"
echo "${CXF_TAG} To bring Tailscale up (if not already):
  sudo tailscale up --ssh --accept-routes=true"
echo "${CXF_TAG} Moonlight check:
  moonlight list $CFG_HOST"
echo "${CXF_TAG} BirdNET-Go logs:
  journalctl -u birdnet-go -f"
echo "${CXF_TAG} Reminder: reboot if you just changed HDMI/KMS overlay."
  curl wget unzip git vim ca-certificates gnupg lsb-release build-essential cmake \
  libasound2-dev logrotate jq >/dev/null

# Ensure KMS and GPU mem on Bookworm
CONFIG_TXT="/boot/firmware/config.txt"
if [[ -f "$CONFIG_TXT" ]]; then
  backup_file_once "$CONFIG_TXT"
  append_if_missing "dtoverlay=vc4-kms-v3d" "$CONFIG_TXT"
  if grep -Eq "^gpu_mem=" "$CONFIG_TXT"; then sudo sed -i "s/^gpu_mem=.*/gpu_mem=256/" "$CONFIG_TXT"; else echo "gpu_mem=256" | sudo tee -a "$CONFIG_TXT" >/dev/null; fi
else
  warn "$CONFIG_TXT not found (non‑standard image?). Skipping KMS tweak."
fi

# --- Tailscale -------------------------------------------------------------------
log "Configuring Tailscale repo/key"
ensure_dir "/usr/share/keyrings" 0755
OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"') || OS_ID="debian"
TS_PATH="debian"
[[ "$OS_ID" =~ (raspbian|raspberrypi) ]] && TS_PATH="raspbian"

if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.tailscale.com/stable/${TS_PATH}/bookworm.noarmor.gpg" | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null || true
fi

TS_LIST="/etc/apt/sources.list.d/tailscale.list"
backup_file_once "$TS_LIST"
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${TS_PATH} bookworm main" | \
  sudo tee "$TS_LIST" >/dev/null

sudo apt-get update -qq || true
sudo apt-get install "${APT_OPTS[@]}" tailscale tailscale-archive-keyring >/dev/null || true
sudo systemctl enable --now tailscaled >/dev/null

# --- Moonlight Embedded ----------------------------------------------------------
log "Configuring Moonlight Embedded repo/key"
ensure_dir "/usr/share/keyrings" 0755

ML_KEYRING="/usr/share/keyrings/moonlight-embedded-archive-keyring.gpg"
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"

# Cleanup old/broken keyrings first
sudo rm -f "$ML_KEYRING"* || true

# Always refresh the keyring from Cloudsmith canonical location
curl -fsSL "https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key" | \
  gpg --dearmor | sudo tee "$ML_KEYRING" >/dev/null
sudo chmod 0644 "$ML_KEYRING"

backup_file_once "$ML_LIST"
echo "deb [signed-by=$ML_KEYRING] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/debian bookworm main" | \
  sudo tee "$ML_LIST" >/dev/null

for f in /etc/apt/sources.list.d/*.list; do
  [[ -e "$f" ]] || continue
  if grep -q "moonlight-game-streaming/moonlight-embedded" "$f"; then
    sudo sed -i -E \
      -e "s|signed-by=[^]]*|signed-by=$ML_KEYRING|g" \
      -e "s|/deb/raspbian |/deb/debian |g" "$f"
  fi
done

sudo apt-get update -qq || true
if ! dpkg -s moonlight-embedded >/dev/null 2>&1; then
  sudo apt-get install "${APT_OPTS[@]}" moonlight-embedded || warn "Moonlight install may have failed; run 'apt-cache policy moonlight-embedded' to inspect."
fi
