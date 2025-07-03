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

# --- Functions ---

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
    exit 1
}

check_network() {
    log_info "Checking for network connectivity..."
    if ! /bin/ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
        log_error "No network connection detected. Please connect to the internet and try again."
    else
        log_info "Network connection confirmed."
    fi
}

command_exists() {
    /usr/bin/command -v "$1" >/dev/null 2>&1
}

is_service_active() {
    /bin/systemctl is-active --quiet "$1"
}

stop_everything() {
    log_info "Stopping all related services and processes..."

    if is_service_active displaycameras; then
        log_info "Stopping displaycameras service..."
        /bin/systemctl stop displaycameras || true
    fi

    if is_service_active cron; then
        log_info "Stopping cron service..."
        /bin/systemctl stop cron || true
    fi

    log_info "Searching for and terminating any lingering processes..."
    /usr/bin/pkill -f "omxplayer" || true
    #/usr/bin/pkill -f "displaycameras" || true
    /bin/sleep 2

    #if /usr/bin/pgrep -f "omxplayer" || /usr/bin/pgrep -f "displaycameras"; then
	if /usr/bin/pgrep -f "omxplayer"; then
        log_error "Failed to stop all related processes. A system reboot may be required."
    fi

    log_info "All related processes have been stopped."

    log_info "Cleaning up old PID files..."
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

log_info "Starting Displaycameras Installer..."

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root. Please use 'sudo'."
fi

if [ -f "$INSTALL_MARKER" ]; then
    log_warn "An existing installation of displaycameras has been detected."
    read -p "Do you want to proceed with overwriting the existing installation? [y/N] " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation aborted by user."
        exit 0
    fi
    stop_everything
fi

check_network
log_info "Checking for and installing prerequisites..."
log_info "Updating package lists with 'apt-get update'..."
/usr/bin/apt-get update

for package in omxplayer fbi logrotate netcat-traditional dos2unix bc; do
    if ! /usr/bin/dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
        log_info "Installing $package..."
        /usr/bin/apt-get install -y "$package"
    else
        log_info "$package is already installed."
    fi
done
log_info "Prerequisite check complete."

log_info "Starting file installation..."

log_info "Creating directories..."
/bin/mkdir -p /usr/lib/displaycameras
/bin/mkdir -p /etc/displaycameras

log_info "Installing library files..."
for lib_file in "$DIR"/lib/*.sh; do
    if [ -r "$lib_file" ]; then
        filename=$(/usr/bin/basename "$lib_file")
        cleanup_file "$lib_file" "/usr/lib/displaycameras/$filename"
        /bin/chown root:root "/usr/lib/displaycameras/$filename"
        /bin/chmod 0644 "/usr/lib/displaycameras/$filename"
    fi
done

log_info "Installing main executable scripts..."
cleanup_file "$DIR/displaycameras" "/usr/bin/displaycameras"
/bin/chmod 0755 /usr/bin/displaycameras
/bin/chown root:root /usr/bin/displaycameras

cleanup_file "$DIR/omxplayer_dbuscontrol" "/usr/bin/omxplayer_dbuscontrol"
/bin/chmod 0755 /usr/bin/omxplayer_dbuscontrol
/bin/chown root:root /usr/bin/omxplayer_dbuscontrol

log_info "Installing systemd service file..."
cleanup_file "$DIR/displaycameras.service" "/etc/systemd/system/displaycameras.service"
/bin/chmod 0644 /etc/systemd/system/displaycameras.service
/bin/chown root:root /etc/systemd/system/displaycameras.service

log_info "Installing configuration files..."
if [ -d "/etc/displaycameras" ]; then
    log_info "Backing up existing configuration to /etc/displaycameras/bak..."
    /bin/mkdir -p /etc/displaycameras/bak
    /bin/mv -f /etc/displaycameras/*.conf* /etc/displaycameras/bak/ 2>/dev/null || true
fi
cleanup_file "$DIR/displaycameras.conf" "/etc/displaycameras/displaycameras.conf"
cleanup_file "$DIR/layout.conf.default" "/etc/displaycameras/layout.conf.default"
cleanup_file "$DIR/layout.conf.1920x1080" "/etc/displaycameras/layout.conf.1920x1080"
/bin/chown root:root /etc/displaycameras/*
/bin/chmod 0644 /etc/displaycameras/*

log_info "Installing cron job and logrotate configuration..."
cleanup_file "$DIR/repaircameras.cron" "/etc/cron.d/repaircameras"
/bin/chmod 0644 /etc/cron.d/repaircameras
/bin/chown root:root /etc/cron.d/repaircameras

cleanup_file "$DIR/displaycameras.logrotate" "/etc/logrotate.d/displaycameras"
/bin/chmod 0644 /etc/logrotate.d/displaycameras
/bin/chown root:root /etc/logrotate.d/displaycameras

log_info "Installing blank screen image..."
/bin/cp -f "$DIR/black.png" "/usr/bin/black.png"
/bin/chown root:root "/usr/bin/black.png"
log_info "File installation complete."

if [ -f /boot/config.txt ] && command_exists raspi-config; then
    log_info "Configuring Raspberry Pi system settings..."
    
    current_gpu_mem=$(/bin/grep -E "^gpu_mem=" /boot/config.txt | /usr/bin/cut -d'=' -f2 || echo "0")
    recommended_split=256
    read -p "Enter desired GPU memory in MB [default: $recommended_split]: " -r
    split=${REPLY:-$recommended_split}
    if [ "$current_gpu_mem" -lt "$split" ]; then
        log_info "Setting GPU memory to ${split}MB..."
        raspi-config nonint do_gpu_mem "$split"
    else
        log_info "GPU memory is already sufficient ($current_gpu_mem MB)."
    fi

    if raspi-config nonint get_overscan | /bin/grep -q "enabled"; then
        log_info "Disabling HDMI overscan..."
        raspi-config nonint do_overscan 1
        log_warn "Overscan has been disabled. A reboot is required for this to take effect."
    fi
else
    log_warn "Not a Raspberry Pi or raspi-config not found. Skipping GPU/Overscan configuration."
fi

log_info "Finalizing installation..."

log_info "Creating installation marker..."
/bin/touch "$INSTALL_MARKER"

log_info "Reloading systemd and enabling services..."
/bin/systemctl daemon-reload
/bin/systemctl enable displaycameras
/bin/systemctl restart cron

log_info "Installation/Upgrade Successful!"
echo "-----------------------------------------------------"
echo "You can now start the service with: sudo systemctl start displaycameras"
echo "Check the status with: sudo systemctl status displaycameras"
echo "Logs are located at: /var/log/displaycameras.log"
echo "-----------------------------------------------------"

read -p "A reboot is recommended to ensure all changes take effect. Reboot now? [y/N] " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Rebooting now..."
    /sbin/reboot
fi

exit 0
