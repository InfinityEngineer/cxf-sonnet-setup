#!/usr/bin/env bash
# Moonlight install for Raspberry Pi 3B+ (Bullseye 64-bit Lite)
# - Switch to fkms, set GPU memory
# - Add Moonlight Embedded apt repo
# - Install moonlight-embedded (+ libcec6), then exit
# No pairing, no systemd services.

set -euo pipefail

# ---------- Tunables (can override via env on the one-liner) ----------
RUN_RPI_UPDATE="${RUN_RPI_UPDATE:-1}"    # 1 = run rpi-update (recommended for Bullseye fkms switch), 0 = skip
GPU_MEM="${GPU_MEM:-256}"                # gpu_mem split for 1080p decode headroom
MOONLIGHT_REPO_URL="https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh"
# ---------------------------------------------------------------------

need_root() { [[ $EUID -eq 0 ]] || { echo "Please run with sudo/root."; exit 1; }; }
bkup_cfg() { cp -a /boot/config.txt "/boot/config.txt.bak.$(date +%Y%m%d-%H%M%S)"; }

edit_config_txt() {
  echo "[*] Updating /boot/config.txt (fkms + gpu_mem=${GPU_MEM})"
  bkup_cfg

  # Remove any existing vc4 overlay lines (kms or fkms) to avoid duplicates
  sed -i -E '/^dtoverlay=vc4-(fkms|kms)-v3d/d' /boot/config.txt
  # Add fkms
  printf '%s\n' 'dtoverlay=vc4-fkms-v3d' >> /boot/config.txt

  # Set/replace gpu_mem
  if grep -qE '^gpu_mem=' /boot/config.txt; then
    sed -i -E "s/^gpu_mem=.*/gpu_mem=${GPU_MEM}/" /boot/config.txt
  else
    printf '%s\n' "gpu_mem=${GPU_MEM}" >> /boot/config.txt
  fi
}

install_rpi_update_and_update_fw() {
  echo "[*] Installing rpi-update and updating firmware (this uses pre-release firmware)"
  apt-get update -y
  apt-get install -y rpi-update
  yes | rpi-update
}

add_moonlight_repo_and_install() {
  echo "[*] Adding Moonlight Embedded apt repo"
  # lsb-release is typically present on Bullseye; install if missing
  apt-get install -y ca-certificates curl lsb-release
  # Add repo (distro=raspbian is required for Pi OS)
  curl -1sLf "${MOONLIGHT_REPO_URL}" | distro=raspbian codename="$(lsb_release -cs)" bash

  echo "[*] Installing moonlight-embedded (and libcec6 to quiet CEC loader errors)"
  apt-get update -y
  apt-get install -y moonlight-embedded libcec6
  ldconfig
}

post_notes() {
  cat <<'EOF'

== Moonlight installed successfully ==

Next steps (after REBOOT):
  1) Pair with your host (Sunshine/GeForce):
       moonlight pair <HOSTNAME_OR_IP>

  2) Test a stream (examples):
       # Conservative:
       moonlight -nocec stream -720 -fps 30 -bitrate 5000 <HOST>
       # Your VGA panel:
       moonlight -nocec stream -width 1600 -height 900 -fps 60 -bitrate 20000 -app Desktop <HOST>
       # 1080p try (may be heavy on Pi 3B+):
       moonlight -nocec stream -1080 -fps 60 -bitrate 20000 -app Desktop <HOST>

Notes:
 - We switched to fkms and set gpu_mem for hardware H.264 decode stability.
 - libcec is installed, but VGA adapters have no CEC; '-nocec' avoids init noise.
 - If display is upside-down later, add to /boot/config.txt:  display_rotate=2
 - If 1600x900 doesn’t sync, consider forcing it:
       echo -e "hdmi_group=2\nhdmi_mode=83" | sudo tee -a /boot/config.txt
   (then reboot)

Reboot now to apply fkms + gpu_mem changes:
  sudo reboot
EOF
}

main() {
  need_root

  # Sanity: warn if not aarch64 or not Pi 3*, but continue anyway
  ARCH="$(uname -m || true)"
  if [[ "${ARCH}" != "aarch64" ]]; then
    echo "[!] Warning: expected aarch64 (64-bit). You have: ${ARCH}"
  fi

  # Configure firmware/driver bits
  if [[ "${RUN_RPI_UPDATE}" == "1" ]]; then
    install_rpi_update_and_update_fw
  else
    echo "[*] Skipping rpi-update (RUN_RPI_UPDATE=0). If you see black screen, re-run with RUN_RPI_UPDATE=1."
  fi

  edit_config_txt
  add_moonlight_repo_and_install
  post_notes
}

main "$@"
