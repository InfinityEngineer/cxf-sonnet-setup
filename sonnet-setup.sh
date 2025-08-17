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
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=("-y" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")

log() { echo "${CXF_TAG} $*"; }
warn() { echo "${CXF_TAG} WARN: $*"; }
ensure_dir() { sudo install -d -m "${2:-0755}" "$1" 2>/dev/null || true; sudo chown "${3:-root:root}" "$1" || true; }
backup_file_once() { local f="$1"; if [[ -f "$f" && ! -f "$f.cxf.bak" ]]; then sudo cp -a "$f" "$f.cxf.bak"; fi }
append_if_missing() { local line="$1" file="$2"; grep -Fqx "$line" "$file" 2>/dev/null || echo "$line" | sudo tee -a "$file" >/dev/null; }
replace_or_append_kv() { local file="$1" key="$2" val="$3"; backup_file_once "$file"; if grep -Eq "^\s*${key}\s*=" "$file" 2>/dev/null; then sudo sed -i "s|^\s*${key}\s*=.*|${key}=${val}|" "$file"; else echo "${key}=${val}" | sudo tee -a "$file" >/dev/null; fi }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# --- Base OS Prep ----------------------------------------------------------------
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

# --- Tailscale -------------------------------------------------------------------
log "Configuring Tailscale repo/key"
ensure_dir "/usr/share/keyrings" 0755
# Detect RPi OS vs Debian to pick correct path (raspbian vs debian)
OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"') || OS_ID="debian"
TS_PATH="debian"
[[ "$OS_ID" =~ (raspbian|raspberrypi) ]] && TS_PATH="raspbian"

# Install/refresh keyring (dearmored) at a consistent path
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
log "Configuring Moonlight Embedded repo/key (normalize signed-by, prefer raspbian path)"
ensure_dir "/usr/share/keyrings" 0755

# 1) Choose a single keyring path. If an existing Moonlight list has signed-by, reuse it.
ML_EXISTING_KEYRING=$(grep -RhoE 'signed-by=([^]]+)' /etc/apt/sources.list.d/*.list 2>/dev/null | \
  grep -E 'moonlight|game-streaming' | head -n1 | cut -d= -f2 || true)
ML_KEYRING="${ML_EXISTING_KEYRING:-/usr/share/keyrings/moonlight-game-streaming_moonlight-embedded-archive-keyring.gpg}"

# 2) Ensure the keyring file exists at ML_KEYRING
if [[ ! -f "$ML_KEYRING" ]]; then
  # Prefer armored and dearmor to our path
  curl -fsSL https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key | \
    sudo gpg --dearmor -o "$ML_KEYRING"
  sudo chmod 0644 "$ML_KEYRING"
fi

# 3) Canonical source: use raspbian/bookworm (works on RPi OS) with our chosen keyring
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"
backup_file_once "$ML_LIST"
echo "deb [signed-by=$ML_KEYRING] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/raspbian bookworm main" | \
  sudo tee "$ML_LIST" >/dev/null

# 4) Normalize ANY stray Moonlight entries to use the same signed-by AND raspbian path to avoid conflicts
for f in /etc/apt/sources.list.d/*.list; do
  [[ -e "$f" ]] || continue
  if grep -q "moonlight-game-streaming/moonlight-embedded" "$f"; then
    sudo sed -i -E \
      -e "s|signed-by=[^]]*|signed-by=$ML_KEYRING|g" \
      -e "s|/deb/debian |/deb/raspbian |g" "$f"
  fi
done

sudo apt-get update -qq || true
if ! dpkg -s moonlight-embedded >/dev/null 2>&1; then
  sudo apt-get install "${APT_OPTS[@]}" moonlight-embedded || warn "Moonlight install may have failed; run 'apt-cache policy moonlight-embedded' to inspect."
fi
 ----------------------------------------------------------
log "Configuring Moonlight Embedded repo/key"
ensure_dir "/usr/share/keyrings" 0755
# Remove any stale or conflicting moonlight list files
sudo rm -f /etc/apt/sources.list.d/moonlight-embedded.list /etc/apt/sources.list.d/*moonlight* || true

if [[ ! -f /usr/share/keyrings/moonlight-embedded.gpg ]]; then
  log "Fetching Moonlight repo key from Cloudsmith"
  if ! curl -fsSL https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/moonlight-embedded.gpg; then
    warn "Failed to fetch Moonlight key. Check network or URL."
  fi
fi
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"
echo "deb [signed-by=/usr/share/keyrings/moonlight-embedded.gpg] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/debian bookworm main" | sudo tee "$ML_LIST" >/dev/null

log "Running apt-get update for Moonlight"
sudo apt-get update || warn "apt-get update had issues"

log "Installing Moonlight Embedded"
if ! sudo apt-get install "${APT_OPTS[@]}" moonlight-embedded; then
  warn "Moonlight install failed. Run 'apt-get install moonlight-embedded' manually to debug."
fi

# --- rest of script remains unchanged ---
