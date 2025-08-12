#!/bin/bash
#
# install_sonnet.sh - Single idempotent installer for Raspberry Pi 3B+
# Installs BirdNET-Pi, Moonlight Embedded, and handles data transfer
#
# Usage: curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install_sonnet.sh | sudo bash
#

set -euo pipefail

# Constants
TARGET_HOSTNAME="sonnet"
SUNSHINE_HOST="nemarion"
DEFAULT_GPU_MEM="256"
TEMP_MOUNT="/mnt/srcbird"

# Colors and symbols
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
CHECK="✔"
WARN="⚠️"
CROSS="✖"

# Trap for cleanup
cleanup() {
    local exit_code=$?
    if mountpoint -q "$TEMP_MOUNT" 2>/dev/null; then
        echo -e "${YELLOW}${WARN}${NC} Unmounting $TEMP_MOUNT..."
        umount "$TEMP_MOUNT" 2>/dev/null || true
    fi
    if [ -d "$TEMP_MOUNT" ]; then
        rmdir "$TEMP_MOUNT" 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT

# Logging functions
log_success() { echo -e "${GREEN}${CHECK}${NC} $1"; }
log_warn() { echo -e "${YELLOW}${WARN}${NC} $1"; }
log_error() { echo -e "${RED}${CROSS}${NC} $1"; }
log_info() { echo -e "ℹ️  $1"; }

# Get primary user (UID 1000)
get_primary_user() {
    local user
    user=$(getent passwd 1000 | cut -d: -f1 2>/dev/null) || user=$(logname 2>/dev/null) || user="pi"
    echo "$user"
}

# Set hostname
set_hostname() {
    log_info "Setting hostname to $TARGET_HOSTNAME..."
    
    if [ "$(hostname)" = "$TARGET_HOSTNAME" ]; then
        log_success "Hostname already set to $TARGET_HOSTNAME"
        return 0
    fi
    
    echo "$TARGET_HOSTNAME" > /etc/hostname
    sed -i "s/127.0.1.1.*/127.0.1.1\t$TARGET_HOSTNAME/" /etc/hosts
    hostnamectl set-hostname "$TARGET_HOSTNAME"
    
    log_success "Hostname set to $(hostname)"
}

# Update system
update_system() {
    log_info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    log_success "System updated"
}

# Install BirdNET-Pi
install_birdnet_pi() {
    log_info "Installing BirdNET-Pi..."
    
    # Check if already installed
    if [ -d "/home/birdnet/BirdNET-Pi" ]; then
        log_warn "BirdNET-Pi already exists at /home/birdnet/BirdNET-Pi"
        if systemctl is-active --quiet birdnet_analysis.service 2>/dev/null; then
            log_success "BirdNET-Pi services are already running"
            return 0
        fi
    fi
    
    # Install dependencies
    apt-get install -y git curl wget
    
    # Create birdnet user if not exists
    if ! id "birdnet" &>/dev/null; then
        useradd -m -s /bin/bash birdnet
        usermod -a -G audio,video birdnet
    fi
    
    # Clone and install BirdNET-Pi
    cd /home/birdnet
    if [ ! -d "BirdNET-Pi" ]; then
        sudo -u birdnet git clone https://github.com/mcguirepr89/BirdNET-Pi.git
    fi
    
    cd BirdNET-Pi
    chmod +x scripts/install_birdnet.sh
    ./scripts/install_birdnet.sh
    
    # Create directories if they don't exist
    sudo -u birdnet mkdir -p /home/birdnet/BirdNET-Pi/recordings
    sudo -u birdnet mkdir -p /home/birdnet/BirdNET-Pi/data
    
    # Enable and start services
    systemctl enable birdnet_analysis.service birdnet_recording.service
    systemctl start birdnet_analysis.service birdnet_recording.service
    
    # Get local IP for web UI
    local ip=$(hostname -I | awk '{print $1}')
    log_success "BirdNET-Pi installed and running"
    log_info "Web UI available at: http://$ip/"
}

# Data transfer from USB SD card
transfer_data() {
    log_info "Looking for USB SD card with BirdNET-Pi data..."
    
    # Find potential source partitions
    local source_dev=""
    local found_devices=()
    
    for dev in /dev/sd[a-z][0-9]*; do
        if [ -b "$dev" ]; then
            # Try to mount read-only and check for BirdNET-Pi structure
            mkdir -p "$TEMP_MOUNT"
            if mount -o ro "$dev" "$TEMP_MOUNT" 2>/dev/null; then
                if [ -d "$TEMP_MOUNT/BirdNET-Pi/recordings" ] || \
                   ([ -d "$TEMP_MOUNT/recordings" ] && [ -d "$TEMP_MOUNT/data" ]); then
                    found_devices+=("$dev")
                    log_info "Found potential source: $dev"
                fi
                umount "$TEMP_MOUNT"
            fi
        fi
    done
    
    if [ ${#found_devices[@]} -eq 0 ]; then
        log_warn "No USB SD card with BirdNET-Pi data found"
        return 0
    fi
    
    # Use first found device
    source_dev="${found_devices[0]}"
    log_info "Using source device: $source_dev"
    
    # Mount source
    mkdir -p "$TEMP_MOUNT"
    mount -o ro "$source_dev" "$TEMP_MOUNT"
    
    # Determine source paths
    local src_recordings src_data
    if [ -d "$TEMP_MOUNT/BirdNET-Pi/recordings" ]; then
        src_recordings="$TEMP_MOUNT/BirdNET-Pi/recordings"
        src_data="$TEMP_MOUNT/BirdNET-Pi/data"
    else
        src_recordings="$TEMP_MOUNT/recordings"
        src_data="$TEMP_MOUNT/data"
    fi
    
    # Destination paths
    local dst_recordings="/home/birdnet/BirdNET-Pi/recordings"
    local dst_data="/home/birdnet/BirdNET-Pi/data"
    
    # Count files before transfer
    local files_before_rec files_before_data
    files_before_rec=$(find "$dst_recordings" -name "*.wav" 2>/dev/null | wc -l)
    files_before_data=$(find "$dst_data" -type f 2>/dev/null | wc -l)
    
    log_info "Files before transfer: $files_before_rec recordings, $files_before_data data files"
    log_info "Starting data transfer..."
    
    # Transfer recordings
    if [ -d "$src_recordings" ]; then
        rsync -aHAX --info=progress2 --inplace --no-inc-recursive \
              --chown=birdnet:birdnet "$src_recordings/" "$dst_recordings/"
    fi
    
    # Transfer data
    if [ -d "$src_data" ]; then
        rsync -aHAX --info=progress2 --inplace --no-inc-recursive \
              --chown=birdnet:birdnet "$src_data/" "$dst_data/"
    fi
    
    # Count files after transfer
    local files_after_rec files_after_data copied_rec copied_data
    files_after_rec=$(find "$dst_recordings" -name "*.wav" 2>/dev/null | wc -l)
    files_after_data=$(find "$dst_data" -type f 2>/dev/null | wc -l)
    copied_rec=$((files_after_rec - files_before_rec))
    copied_data=$((files_after_data - files_before_data))
    
    log_success "Transfer complete!"
    echo "Summary:"
    echo "  $copied_rec audio files copied"
    echo "  $files_before_rec already present"
    echo "  $copied_data data files copied"
    
    echo -n "Press ENTER to confirm and continue..."
    read -r
    
    # Cleanup
    umount "$TEMP_MOUNT"
    rmdir "$TEMP_MOUNT"
    
    log_success "Data transfer completed successfully"
}

# Install Moonlight Embedded
install_moonlight() {
    log_info "Installing Moonlight Embedded..."
    
    # Check if already installed
    if command -v moonlight &> /dev/null; then
        log_success "Moonlight already installed at $(which moonlight)"
        return 0
    fi
    
    # Try package installation first (faster if available)
    log_info "Attempting package installation..."
    if [ ! -f /etc/apt/sources.list.d/moonlight-embedded.list ]; then
        curl -1sLf 'https://dl.cloudsmith.io/public/moonlight-game-streaming/moonlight-embedded/setup.deb.sh' | bash
    fi
    
    apt-get update -qq
    if apt-get install -y moonlight-embedded libcec6 2>/dev/null; then
        ldconfig
        log_success "Moonlight Embedded installed from package"
        return 0
    fi
    
    # Package installation failed, build from source
    log_warn "Package installation failed, building from source..."
    log_info "Installing build dependencies..."
    
    apt-get install -y build-essential cmake git \
        libopus-dev libexpat1-dev libssl-dev libasound2-dev \
        libudev-dev libavahi-client-dev libcurl4-openssl-dev \
        libevdev-dev libcec-dev pkg-config
    
    # Clone and build Moonlight
    log_info "Cloning Moonlight source code..."
    cd /tmp
    if [ -d "moonlight-embedded" ]; then
        rm -rf moonlight-embedded
    fi
    git clone https://github.com/moonlight-stream/moonlight-embedded.git
    cd moonlight-embedded
    
    log_info "Building Moonlight (this may take 10-15 minutes on Pi 3B+)..."
    mkdir build && cd build
    cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
    make -j$(nproc)
    
    log_info "Installing Moonlight..."
    make install
    ldconfig
    
    # Verify installation
    if command -v moonlight &> /dev/null; then
        log_success "Moonlight Embedded built and installed successfully"
        log_info "Moonlight installed at: $(which moonlight)"
    else
        log_error "Moonlight installation failed"
        return 1
    fi
    
    # Cleanup
    cd /
    rm -rf /tmp/moonlight-embedded
}

# Configure Raspberry Pi for Moonlight
configure_pi_video() {
    log_info "Configuring Raspberry Pi video settings..."
    
    # Backup config.txt
    local backup="/boot/config.txt.backup.$(date +%Y%m%d_%H%M%S)"
    cp /boot/config.txt "$backup"
    log_info "Backed up /boot/config.txt to $backup"
    
    # Remove existing dtoverlay lines
    sed -i '/^dtoverlay=vc4-/d' /boot/config.txt
    
    # Add required settings
    {
        echo "# Moonlight streaming configuration"
        echo "dtoverlay=vc4-fkms-v3d"
        echo "gpu_mem=${DEFAULT_GPU_MEM}"
    } >> /boot/config.txt
    
    log_success "Video configuration updated"
    log_warn "Reboot required for video changes to take effect"
}

# Test Moonlight flag position
test_moonlight_nocec() {
    local user="$1"
    local test_cmd
    
    # Try -nocec before stream
    test_cmd="moonlight -nocec stream -720 -fps 30 -bitrate 5000 $SUNSHINE_HOST"
    if sudo -u "$user" timeout 5 $test_cmd --help &>/dev/null 2>&1; then
        echo "before"
    else
        echo "after"
    fi
}

# Pair with Moonlight
pair_moonlight() {
    local user="$1"
    
    log_info "Pairing with Sunshine host: $SUNSHINE_HOST"
    
    if [ -f "/home/$user/.cache/moonlight/client.pem" ]; then
        log_success "Already paired with $SUNSHINE_HOST"
        return 0
    fi
    
    echo "Starting pairing process..."
    echo "You will need to approve the PIN on the Sunshine host ($SUNSHINE_HOST)"
    
    if ! sudo -u "$user" moonlight pair "$SUNSHINE_HOST"; then
        log_error "Pairing failed"
        return 1
    fi
    
    log_success "Pairing completed successfully"
}

# Test Moonlight streaming
test_moonlight() {
    local user="$1"
    local nocec_pos
    
    nocec_pos=$(test_moonlight_nocec "$user")
    
    log_info "Testing Moonlight streaming..."
    
    # Construct test command based on nocec position
    local test_cmd
    if [ "$nocec_pos" = "before" ]; then
        test_cmd="moonlight -nocec stream -720 -fps 30 -bitrate 5000 $SUNSHINE_HOST"
    else
        test_cmd="moonlight stream -nocec -720 -fps 30 -bitrate 5000 $SUNSHINE_HOST"
    fi
    
    echo "Running test command: $test_cmd"
    echo "Press Ctrl+C to stop the test stream"
    echo "Press ENTER to start test..."
    read -r
    
    if sudo -u "$user" DISPLAY=:0 $test_cmd; then
        log_success "Test stream completed successfully"
        return 0
    else
        log_error "Test stream failed"
        show_moonlight_diagnostics "$user"
        return 1
    fi
}

# Show Moonlight diagnostics
show_moonlight_diagnostics() {
    local user="$1"
    
    log_info "Moonlight Diagnostics:"
    
    echo "Available apps on $SUNSHINE_HOST:"
    sudo -u "$user" moonlight list "$SUNSHINE_HOST" 2>/dev/null || echo "  Failed to list apps"
    
    echo ""
    echo "Suggested troubleshooting:"
    echo "1. Ensure Sunshine is running on $SUNSHINE_HOST"
    echo "2. Check firewall settings"
    echo "3. Try different resolution/bitrate"
    echo "4. Run with debug logging:"
    echo "   MOONLIGHT_LOG_LEVEL=debug moonlight [args] 2>&1 | tee ~/moonlight_debug.log"
}

# Create Moonlight systemd service
create_moonlight_service() {
    local user="$1"
    local uid user_home nocec_pos
    
    uid=$(id -u "$user")
    user_home="/home/$user"
    nocec_pos=$(test_moonlight_nocec "$user")
    
    # Enable lingering for user
    loginctl enable-linger "$user"
    systemctl start "user@$uid"
    
    # Create user systemd directory
    sudo -u "$user" mkdir -p "$user_home/.config/systemd/user"
    
    # Construct ExecStart command based on nocec position
    local exec_start
    if [ "$nocec_pos" = "before" ]; then
        exec_start="moonlight -nocec stream -width 1600 -height 900 -fps 60 -bitrate 20000 -app Desktop $SUNSHINE_HOST"
    else
        exec_start="moonlight stream -nocec -width 1600 -height 900 -fps 60 -bitrate 20000 -app Desktop $SUNSHINE_HOST"
    fi
    
    # Create service file
    cat > "$user_home/.config/systemd/user/cxf-moonlight.service" << 'EOF'
[Unit]
Description=Moonlight Game Streaming Client
After=graphical-session.target
ConditionPathExists=%h/.cache/moonlight/client.pem

[Service]
Type=simple
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/%i
ExecStart=EXEC_START_PLACEHOLDER
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    
    # Replace placeholder
    sed -i "s|EXEC_START_PLACEHOLDER|$exec_start|" "$user_home/.config/systemd/user/cxf-moonlight.service"
    
    # Set ownership
    chown "$user:$user" "$user_home/.config/systemd/user/cxf-moonlight.service"
    
    # Reload and enable service
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user daemon-reload
    
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user enable cxf-moonlight.service
    
    sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user start cxf-moonlight.service
    
    log_success "Moonlight autostart service created and enabled"
    
    echo ""
    echo "Service file contents:"
    cat "$user_home/.config/systemd/user/cxf-moonlight.service"
    echo ""
    echo "To view service logs:"
    echo "  journalctl --user -u cxf-moonlight -f"
}

# Interactive menu
show_menu() {
    echo "========================================"
    echo "  Raspberry Pi 3B+ Sonnet Installer"
    echo "========================================"
    echo ""
    echo "Select installation mode:"
    echo "0) Install ALL (DEFAULT) - BirdNET-Pi + Data Transfer + Moonlight + Autostart"
    echo "1) BirdNET-Pi ONLY"
    echo "2) Moonlight ONLY"
    echo "3) Data Transfer ONLY"
    echo ""
    
    # Handle both interactive and non-interactive execution
    if [ -t 0 ]; then
        # Interactive - can read from stdin
        echo -n "Enter your choice [0]: "
        read -r choice
        choice=${choice:-0}
    else
        # Non-interactive (piped execution) - use environment variable or default
        choice=${INSTALL_MODE:-0}
        echo "Non-interactive mode detected, using mode: $choice"
    fi
    echo ""
}

# Mode implementations
mode_all() {
    local user reboot_needed=false
    user=$(get_primary_user)
    
    log_info "Installing ALL components for user: $user"
    
    set_hostname
    update_system
    install_birdnet_pi
    
    echo ""
    if [ -t 0 ]; then
        read -p "Transfer data from USB SD card? [Y/n]: " -r transfer
    else
        transfer=${AUTO_TRANSFER:-Y}
        echo "Transfer data from USB SD card? [Y/n]: $transfer (auto-selected)"
    fi
    if [[ ! $transfer =~ ^[Nn]$ ]]; then
        transfer_data
    fi
    
    install_moonlight
    configure_pi_video
    reboot_needed=true
    
    if [ "$reboot_needed" = true ]; then
        echo ""
        echo "Reboot required for video configuration changes."
        if [ -t 0 ]; then
            read -p "Reboot now? [Y/n]: " -r reboot_now
        else
            reboot_now=${AUTO_REBOOT:-Y}
            echo "Reboot now? [Y/n]: $reboot_now (auto-selected)"
        fi
        if [[ ! $reboot_now =~ ^[Nn]$ ]]; then
            log_info "Rebooting in 10 seconds..."
            sleep 10
            reboot
        else
            log_warn "Please reboot manually before testing Moonlight"
            return 0
        fi
    fi
    
    # Continue after reboot (this won't execute if we rebooted)
    if pair_moonlight "$user" && test_moonlight "$user"; then
        if [ -t 0 ]; then
            read -p "Enable Moonlight autostart? [Y/n]: " -r autostart
        else
            autostart=${AUTO_START:-Y}
            echo "Enable Moonlight autostart? [Y/n]: $autostart (auto-selected)"
        fi
        if [[ ! $autostart =~ ^[Nn]$ ]]; then
            create_moonlight_service "$user"
        fi
    fi
    
    log_success "All components installed successfully"
}

mode_birdnet_only() {
    log_info "Installing BirdNET-Pi only"
    
    set_hostname
    update_system
    install_birdnet_pi
    
    log_success "BirdNET-Pi installation completed"
}

mode_moonlight_only() {
    local user reboot_needed=false
    user=$(get_primary_user)
    
    log_info "Installing Moonlight only for user: $user"
    
    set_hostname
    update_system
    install_moonlight
    configure_pi_video
    reboot_needed=true
    
    if [ "$reboot_needed" = true ]; then
        echo ""
        log_warn "Reboot required for video configuration changes."
        log_warn "Please reboot and then run the following commands:"
        echo ""
        echo "  moonlight pair $SUNSHINE_HOST"
        echo "  moonlight -nocec stream -720 -fps 30 -bitrate 5000 $SUNSHINE_HOST"
        echo ""
        return 0
    fi
    
    if pair_moonlight "$user" && test_moonlight "$user"; then
        if [ -t 0 ]; then
            read -p "Enable Moonlight autostart? [Y/n]: " -r autostart
        else
            autostart=${AUTO_START:-Y}
            echo "Enable Moonlight autostart? [Y/n]: $autostart (auto-selected)"
        fi
        if [[ ! $autostart =~ ^[Nn]$ ]]; then
            create_moonlight_service "$user"
        fi
    fi
    
    log_success "Moonlight installation completed"
}

mode_transfer_only() {
    log_info "Data transfer only mode"
    
    if [ -t 0 ]; then
        read -p "Transfer data from USB SD card? [Y/n]: " -r transfer
    else
        transfer=${AUTO_TRANSFER:-Y}
        echo "Transfer data from USB SD card? [Y/n]: $transfer (auto-selected)"
    fi
    if [[ ! $transfer =~ ^[Nn]$ ]]; then
        transfer_data
    else
        log_info "Data transfer skipped"
    fi
    
    log_success "Data transfer mode completed"
}

# Main execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    show_menu
    
    case $choice in
        0)
            mode_all
            ;;
        1)
            mode_birdnet_only
            ;;
        2)
            mode_moonlight_only
            ;;
        3)
            mode_transfer_only
            ;;
        *)
            log_error "Invalid choice: $choice"
            exit 1
            ;;
    esac
    
    echo ""
    log_success "Installation completed successfully!"
    echo ""
    echo "Acceptance Checks:"
    
    # Hostname check
    if [ "$(hostname)" = "$TARGET_HOSTNAME" ]; then
        log_success "Hostname set to $TARGET_HOSTNAME"
    else
        log_error "Hostname not set correctly"
    fi
    
    # BirdNET-Pi check
    if systemctl is-active --quiet birdnet_analysis.service 2>/dev/null; then
        log_success "BirdNET-Pi service active"
        local ip=$(hostname -I | awk '{print $1}')
        log_info "Web UI: http://$ip/"
    fi
    
    # Moonlight pairing check
    local user=$(get_primary_user)
    if [ -f "/home/$user/.cache/moonlight/client.pem" ]; then
        log_success "Moonlight paired successfully"
    fi
    
    # Moonlight service check
    if systemctl --user -M "$user@" is-active --quiet cxf-moonlight.service 2>/dev/null; then
        log_success "Moonlight autostart service active"
        log_info "Service logs: journalctl --user -u cxf-moonlight -f"
    fi
}

# Run main function
main "$@"
