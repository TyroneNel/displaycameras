#!/bin/bash

# Installer for the displaycameras service
# This script is designed to be robust, safe, and provide clear feedback.
# It uses absolute paths for system commands to avoid PATH issues.

# Exit on any error AND print each command before executing it
set -e
#set -x

# --- Globals ---
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INSTALL_MARKER="/etc/displaycameras/.install_marker"

# Parse command line arguments
NON_INTERACTIVE=false
SKIP_REBOOT=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --skip-reboot)
            SKIP_REBOOT=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Functions ---

# Standalone logging (consistent format with lib/logging.sh but self-contained)
info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

check_network() {
    info "Checking for network connectivity..."
    if ! /bin/ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
        error "No network connection detected. Please connect to the internet and try again."
    else
        info "Network connection confirmed."
    fi
}

command_exists() {
    /usr/bin/command -v "$1" >/dev/null 2>&1
}

is_service_active() {
    /bin/systemctl is-active --quiet "$1"
}

stop_everything() {
    info "Stopping all related services and processes..."

    # Forcefully terminate all related processes first
    info "Attempting to terminate all omxplayer and displaycameras processes..."
    /usr/bin/pkill -9 -f "omxplayer" || true
    /usr/bin/pkill -9 -f "/usr/bin/displaycameras" || true
    /bin/sleep 2

    # Now, stop the service
    if is_service_active displaycameras.service; then
        info "Stopping displaycameras service..."
        /bin/systemctl stop displaycameras.service
        /bin/sleep 2
    fi

    # Final check to ensure all processes are gone
    if /usr/bin/pgrep -f "omxplayer" || /usr/bin/pgrep -f "/usr/bin/displaycameras"; then
        warn "Lingering processes detected. Retrying termination..."
        /usr/bin/pkill -9 -f "omxplayer" || true
        /usr/bin/pkill -9 -f "/usr/bin/displaycameras" || true
        /bin/sleep 2
    fi

    if /usr/bin/pgrep -f "omxplayer" || /usr/bin/pgrep -f "/usr/bin/displaycameras"; then
        error "Failed to stop all related processes. A system reboot may be required."
    fi

    info "All related processes have been stopped."

    info "Cleaning up old PID and lock files..."
    /bin/rm -f /var/run/displaycameras*.pid /var/run/displaycameras*.lock /var/run/displaycameras*.sequence
}

cleanup_file() {
    local src="$1"
    local dest="$2"
    /bin/cp -f "$src" "$dest"
    /bin/sed -i '1s/^\xEF\xBB\xBF//' "$dest"
    /usr/bin/dos2unix "$dest" 2>/dev/null || true
}

# --- Main Script ---

info "Starting Displaycameras Installer..."

if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root. Please use 'sudo'."
fi

# Check if this is a Raspberry Pi
is_raspberry_pi() {
    if [ -f /proc/device-tree/model ] && grep -q "Raspberry Pi" /proc/device-tree/model; then
        return 0
    else
        return 1
    fi
}

if [ -f "$INSTALL_MARKER" ]; then
    if [ "$NON_INTERACTIVE" = "true" ]; then
        info "Existing installation detected. Proceeding with overwrite due to --non-interactive flag."
    else
        warn "An existing installation of displaycameras has been detected."
        read -p "Do you want to proceed with overwriting the existing installation? [y/N] " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Installation aborted by user."
            exit 0
        fi
    fi
    stop_everything
fi

check_network
info "Checking for and installing prerequisites..."
info "Updating package lists with 'apt-get update'..."
/usr/bin/apt-get update

for package in omxplayer fbi logrotate netcat-traditional dos2unix bc; do
    if ! /usr/bin/dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
        info "Installing $package..."
        /usr/bin/apt-get install -y "$package"
    else
        info "$package is already installed."
    fi
done
info "Prerequisite check complete."

info "Starting file installation..."

info "Creating directories..."
/bin/mkdir -p /usr/lib/displaycameras
/bin/mkdir -p /etc/displaycameras

info "Installing library files..."
for lib_file in "$DIR"/lib/*.sh; do
    if [ -r "$lib_file" ]; then
        filename=$(/usr/bin/basename "$lib_file")
        cleanup_file "$lib_file" "/usr/lib/displaycameras/$filename"
        /bin/chown root:root "/usr/lib/displaycameras/$filename"
        /bin/chmod 0644 "/usr/lib/displaycameras/$filename"
    fi
done
cleanup_file "$DIR/lib/player.sh" "/usr/lib/displaycameras/player.sh"
/bin/chown root:root "/usr/lib/displaycameras/player.sh"
/bin/chmod 0644 "/usr/lib/displaycameras/player.sh"

info "Installing main executable scripts..."
cleanup_file "$DIR/displaycameras" "/usr/bin/displaycameras"
/bin/chmod 0755 /usr/bin/displaycameras
/bin/chown root:root /usr/bin/displaycameras

cleanup_file "$DIR/omxplayer_dbuscontrol" "/usr/bin/omxplayer_dbuscontrol"
/bin/chmod 0755 /usr/bin/omxplayer_dbuscontrol
/bin/chown root:root /usr/bin/omxplayer_dbuscontrol

info "Installing systemd service file..."
cleanup_file "$DIR/displaycameras.service" "/etc/systemd/system/displaycameras.service"
/bin/chmod 0644 /etc/systemd/system/displaycameras.service
/bin/chown root:root /etc/systemd/system/displaycameras.service

info "Installing configuration files..."
if [ -d "/etc/displaycameras" ]; then
    info "Backing up existing configuration to /etc/displaycameras/bak..."
    /bin/mkdir -p /etc/displaycameras/bak
    /bin/mv -f /etc/displaycameras/*.conf* /etc/displaycameras/bak/ 2>/dev/null || true
fi
cleanup_file "$DIR/displaycameras.conf" "/etc/displaycameras/displaycameras.conf"
cleanup_file "$DIR/layout.conf.default" "/etc/displaycameras/layout.conf.default"
cleanup_file "$DIR/layout.conf.1920x1080" "/etc/displaycameras/layout.conf.1920x1080"
/bin/chown root:root /etc/displaycameras/*
/bin/chmod 0644 /etc/displaycameras/*

info "Installing cron job and logrotate configuration..."
cleanup_file "$DIR/repaircameras.cron" "/etc/cron.d/repaircameras"
/bin/chmod 0644 /etc/cron.d/repaircameras
/bin/chown root:root /etc/cron.d/repaircameras

cleanup_file "$DIR/displaycameras.logrotate" "/etc/logrotate.d/displaycameras"
/bin/chmod 0644 /etc/logrotate.d/displaycameras
/bin/chown root:root /etc/logrotate.d/displaycameras

info "Installing blank screen image..."
/bin/cp -f "$DIR/black.png" "/usr/bin/black.png"
/bin/chown root:root "/usr/bin/black.png"
info "File installation complete."

if is_raspberry_pi && command_exists /usr/bin/raspi-config; then
    info "Configuring Raspberry Pi system settings..."
    
    # Find the correct path for config.txt
    if [ -f /boot/firmware/config.txt ]; then
        config_path="/boot/firmware/config.txt"
    elif [ -f /boot/config.txt ]; then
        config_path="/boot/config.txt"
    else
        warn "Could not find config.txt. Skipping GPU/Overscan configuration."
        config_path=""
    fi

    if [ -n "$config_path" ]; then
        current_gpu_mem=$(/bin/grep -E "^gpu_mem=" "$config_path" | /usr/bin/cut -d'=' -f2 || echo "0")
        recommended_split=256
        if [ "$NON_INTERACTIVE" = "true" ]; then
            split=$recommended_split
        else
            read -p "Enter desired GPU memory in MB [default: $recommended_split]: " -r
            split=${REPLY:-$recommended_split}
        fi
        if [ "$current_gpu_mem" -lt "$split" ]; then
            info "Setting GPU memory to ${split}MB..."
            /usr/bin/raspi-config nonint do_gpu_mem "$split"
        else
            info "GPU memory is already sufficient ($current_gpu_mem MB)."
        fi

        if /usr/bin/raspi-config nonint get_overscan | /bin/grep -q "enabled"; then
            info "Disabling HDMI overscan..."
            /usr/bin/raspi-config nonint do_overscan 1
            warn "Overscan has been disabled. A reboot is required for this to take effect."
        fi
    fi
else
    warn "Not a Raspberry Pi or raspi-config not found. Skipping GPU/Overscan configuration."
fi

info "Finalizing installation..."

info "Creating installation marker..."
/bin/touch "$INSTALL_MARKER"

info "Reloading systemd and enabling services..."
/bin/systemctl daemon-reload
/bin/systemctl enable displaycameras
/bin/systemctl restart cron

info "Installation/Upgrade Successful!"
echo "-----------------------------------------------------"
echo "You can now start the service with: sudo systemctl start displaycameras"
echo "Check the status with: sudo systemctl status displaycameras"
echo "Logs are located at: /var/log/displaycameras.log"
echo "-----------------------------------------------------"

if [ "$SKIP_REBOOT" = "true" ]; then
    info "Skipping reboot as requested."
elif [ "$NON_INTERACTIVE" = "true" ]; then
    info "Rebooting now..."
    /sbin/reboot
else
    read -p "A reboot is recommended to ensure all changes take effect. Reboot now? [y/N] " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Rebooting now..."
        /sbin/reboot
    fi
fi

exit 0
