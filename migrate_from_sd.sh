#!/usr/bin/env bash
# migrate_from_sd.sh — copy BirdNET‑Pi data from an attached microSD (USB reader) to this Pi
# Usage:
#   sudo ./migrate_from_sd.sh                # copy recordings + data
#   sudo ./migrate_from_sd.sh --config       # also copy config/
#   sudo ./migrate_from_sd.sh --dry-run      # show what would copy
#   sudo ./migrate_from_sd.sh --src /mnt/X   # use a specific mountpoint (skips auto-detect)

set -euo pipefail

INCLUDE_CONFIG="no"
DRY_RUN="no"
USER_SRC=""
DST_BASE="/home/birdnet/BirdNET-Pi"
MOUNT_DIR="/mnt/birdnet-old"
WE_MOUNTED="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   INCLUDE_CONFIG="yes"; shift ;;
    --dry-run)  DRY_RUN="yes"; shift ;;
    --src)      USER_SRC="${2:-}"; shift 2 ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo."
  exit 1
fi

# --- helper: pick the birdnet user for chown (fallback to pi) ---
BN_USER="birdnet"
if ! id -u "$BN_USER" &>/dev/null; then BN_USER="${SUDO_USER:-pi}"; fi

# --- ensure destination dirs exist ---
mkdir -p "${DST_BASE}/recordings" "${DST_BASE}/data"
[[ "$INCLUDE_CONFIG" == "yes" ]] && mkdir -p "${DST_BASE}/config"

# --- find source root containing BirdNET-Pi ---
SRC_ROOT=""
if [[ -n "$USER_SRC" ]]; then
  [[ -d "$USER_SRC" ]] || { echo "Given --src not a dir: $USER_SRC"; exit 1; }
  SRC_ROOT="$USER_SRC"
else
  # Find an ext* removable partition (likely the rootfs of the old card)
  echo ">> Scanning for removable ext* partitions..."
  PART=$(lsblk -rpno NAME,TYPE,RM,FSTYPE | awk '$2=="part" && $3==1 && $4 ~ /^ext/ {print $1; exit}')
  if [[ -z "${PART:-}" ]]; then
    echo "No removable ext* partition found. If the card is inserted, it may not be readable."
    echo "You can mount it manually and pass --src <mountpoint>."
    exit 1
  fi

  # Check if already mounted
  MP=$(lsblk -rpno MOUNTPOINT "$PART")
  if [[ -n "$MP" ]]; then
    echo ">> Found already-mounted partition at: $MP"
    SRC_ROOT="$MP"
  else
    echo ">> Mounting $PART read-only at ${MOUNT_DIR}"
    mkdir -p "$MOUNT_DIR"
    # safer read-only for possibly dirty ext4: ro,noload
    mount -o ro,noload "$PART" "$MOUNT_DIR"
    WE_MOUNTED="yes"
    SRC_ROOT="$MOUNT_DIR"
  fi
fi

# --- locate BirdNET-Pi folder on the source ---
echo ">> Looking for BirdNET-Pi directory under: $SRC_ROOT"
CANDIDATES=()
if [[ -d "$SRC_ROOT/home/birdnet/BirdNET-Pi" ]]; then
  CANDIDATES+=("$SRC_ROOT/home/birdnet/BirdNET-Pi")
fi
# fallback: search shallowly
while IFS= read -r d; do CANDIDATES+=("$d"); done < <(find "$SRC_ROOT" -maxdepth 3 -type d -name "BirdNET-Pi" 2>/dev/null | head -n 3)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "Could not find a BirdNET-Pi directory on the card."
  [[ "$WE_MOUNTED" == "yes" ]] && umount "$MOUNT_DIR"
  exit 1
fi

SRC_BASE="${CANDIDATES[0]}"
echo ">> Using source: $SRC_BASE"

# --- build rsync flags ---
RSYNC_FLAGS=(-avh --info=progress2 --no-perms --no-owner --no-group)
[[ "$DRY_RUN" == "yes" ]] && RSYNC_FLAGS+=(--dry-run)

# --- copy recordings ---
if [[ -d "$SRC_BASE/recordings" ]]; then
  echo ">> Copying recordings..."
  rsync "${RSYNC_FLAGS[@]}" "$SRC_BASE/recordings/" "$DST_BASE/recordings/"
else
  echo ">> No recordings/ found on source."
fi

# --- copy data ---
if [[ -d "$SRC_BASE/data" ]]; then
  echo ">> Copying data..."
  rsync "${RSYNC_FLAGS[@]}" "$SRC_BASE/data/" "$DST_BASE/data/"
else
  echo ">> No data/ found on source."
fi

# --- copy config (optional) ---
if [[ "$INCLUDE_CONFIG" == "yes" ]]; then
  if [[ -d "$SRC_BASE/config" ]]; then
    echo ">> Copying config..."
    rsync "${RSYNC_FLAGS[@]}" "$SRC_BASE/config/" "$DST_BASE/config/"
  else
    echo ">> No config/ found on source."
  fi
fi

# --- fix ownership ---
echo ">> Fixing ownership to ${BN_USER}:${BN_USER}"
chown -R "${BN_USER}:${BN_USER}" "$DST_BASE/recordings" "$DST_BASE/data" 2>/dev/null || true
[[ "$INCLUDE_CONFIG" == "yes" ]] && chown -R "${BN_USER}:${BN_USER}" "$DST_BASE/config" 2>/dev/null || true

# --- cleanup ---
if [[ "$WE_MOUNTED" == "yes" ]]; then
  echo ">> Unmounting ${MOUNT_DIR}"
  umount "$MOUNT_DIR" || echo "!! Could not unmount (in use?)."
fi

echo ">> Migration complete."
echo "Check the BirdNET-Pi UI: http://$(hostname).local  → Tools/Stats for historic detections."
