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
if [[ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]]; then
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | \
    sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
fi
TS_LIST="/etc/apt/sources.list.d/tailscale.list"
backup_file_once "$TS_LIST"
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" | \
  sudo tee "$TS_LIST" >/dev/null
sudo apt-get update -qq || true
sudo apt-get install "${APT_OPTS[@]}" tailscale >/dev/null || true
sudo systemctl enable --now tailscaled >/dev/null

# --- Moonlight Embedded ----------------------------------------------------------
log "Configuring Moonlight Embedded repo/key"
ensure_dir "/usr/share/keyrings" 0755
# Fix: if distro already installed an alternate keyring, remove duplicate list to avoid conflicts.
sudo rm -f /etc/apt/sources.list.d/moonlight-embedded.list /etc/apt/sources.list.d/*moonlight* || true

if [[ ! -f /usr/share/keyrings/moonlight-embedded.gpg ]]; then
  curl -fsSL https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/gpg.key | \
    sudo gpg --dearmor -o /usr/share/keyrings/moonlight-embedded.gpg
fi
ML_LIST="/etc/apt/sources.list.d/moonlight-embedded.list"
echo "deb [signed-by=/usr/share/keyrings/moonlight-embedded.gpg] https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/deb/debian bookworm main" | sudo tee "$ML_LIST" >/dev/null

sudo apt-get update -qq || true
sudo apt-get install "${APT_OPTS[@]}" moonlight-embedded >/dev/null || warn "Moonlight install may have failed, check apt logs."

# --- rest of script remains unchanged ---
