#!/bin/bash

# Function to clean up files (remove BOM and ensure Unix line endings)
cleanup_file() {
    local src="$1"
    local dest="$2"
    # Copy file first
    cp -f "$src" "$dest"
    # Remove BOM if exists and ensure Unix line endings
    sed -i '1s/^\xEF\xBB\xBF//' "$dest"
    dos2unix "$dest" 2>/dev/null || true
}

# Function to install or update library files
install_lib_files() {
    local is_upgrade="$1"
    
    # Create lib directory if it doesn't exist
    echo "Creating/verifying library directory structure..."
    mkdir -p /usr/lib/displaycameras
    
    # Install/update library files
    if [ -d "$DIR/lib" ]; then
        echo "Installing/updating library files..."
        # Backup existing files if this is an upgrade
        if [ "$is_upgrade" = "true" ] && [ -d "/usr/lib/displaycameras" ]; then
            echo "Backing up existing library files..."
            mkdir -p /usr/lib/displaycameras/bak
            cp -f /usr/lib/displaycameras/*.sh /usr/lib/displaycameras/bak/ 2>/dev/null || true
        fi
        
        # Install new files
        for lib_file in "$DIR"/lib/*.sh; do
            if [ -r "$lib_file" ]; then
                filename=$(basename "$lib_file")
                echo "Installing $filename..."
                cleanup_file "$lib_file" "/usr/lib/displaycameras/$filename"
                chown root:root "/usr/lib/displaycameras/$filename"
                chmod 0644 "/usr/lib/displaycameras/$filename"
            else
                echo "Warning: Unable to read library file $lib_file"
            fi
        done
    else
        echo "Error: Library directory missing. This is required for modular functionality."
        echo "Verify package contents."
        exit 1
    fi
}

# Exit on error and undefined variables
set -e
set -u

# Run as root to install the displaycameras package for streaming video feeds.
# Systemd init system is presumed.  If installing on 'nix with other init
# systems, you will have to edit this script or enable the displaycameras
# service with available tools for your init system.  The main script,
# normally installed at /usr/bin/displaycameras has an LSB header and will run
# as a systemv init script (if copied to /etc/init.d/).  No other init systems
# have been tested.

# What is the path to the installer?
DIR=`dirname "$(readlink -f "$0")"`

# Ensure prerequisites are installed.
for package in omxplayer fbi logrotate netcat dos2unix bc
do
    if [ "`dpkg-query -s $package | grep Status | awk -v N=4 '{print $4}'`" != "installed" ]; then
        apt-get install $package -y
    fi
done

# Put the files in place and set ownership and permissions.

# Handle library files for both install and upgrade
if [ "${1:-}" = "upgrade" ]; then
    install_lib_files "true"
else
    install_lib_files "false"
fi

if [ -r $DIR/displaycameras ]; then
    echo "Copying the main script and setting permissions."
    cleanup_file "$DIR/displaycameras" "/usr/bin/displaycameras"
    chown root:root /usr/bin/displaycameras && chmod 0755 /usr/bin/displaycameras
    
    # Update the main script to point to the correct lib directory
    sed -i "s|source \"\$(dirname \"\$0\")/lib/|source \"/usr/lib/displaycameras/|g" "/usr/bin/displaycameras"
else
    echo "The displaycameras file is missing or unreadable. This is a critical file."
    echo "Verify package contents."
    exit 2
fi

if [ -r $DIR/displaycameras.service ]; then
    echo "Copying the systemd init file and setting permissions."
    cleanup_file "$DIR/displaycameras.service" "/etc/systemd/system/displaycameras.service"
    chown root:root /etc/systemd/system/displaycameras.service && chmod 0644 /etc/systemd/system/displaycameras.service
else
    echo "The displaycameras.service file is missing or unreadable. This is a critical file."
    echo "Verify package contents."
    exit 3
fi
# Config files, cron job, gpu memory split, and disable overscan support only if not upgrading
if [ "${1:-}" != "upgrade" ]; then
    if [ -r $DIR/displaycameras.conf ]; then
        if [ -r /etc/displaycameras/displaycameras.conf ]; then
            [ -d /etc/displaycameras/bak ] || mkdir /etc/displaycameras/bak
            for i in `find /etc/displaycameras/ -maxdepth 1 -type f`; do
                mv -f $i /etc/displaycameras/bak/
            done
            echo "Your config files were backed up to /etc/displaycameras/bak"
        fi
        echo "Copying the global and layout configuration files."
        [ -d /etc/displaycameras ] || mkdir /etc/displaycameras
        
        # Copy and clean up each config file
        cleanup_file "$DIR/layout.conf.default" "/etc/displaycameras/layout.conf.default"
        cleanup_file "$DIR/displaycameras.conf" "/etc/displaycameras/displaycameras.conf"
        
        # Set permissions
        chown root:root /etc/displaycameras/*.conf /etc/displaycameras/*.default
        chmod 0644 /etc/displaycameras/*.conf /etc/displaycameras/*.default

        # Copy 1920x1080 layout if it exists
        if [ -r "$DIR/layout.conf.1920x1080" ]; then
            cleanup_file "$DIR/layout.conf.1920x1080" "/etc/displaycameras/layout.conf.1920x1080"
            chown root:root /etc/displaycameras/layout.conf.1920x1080
            chmod 0644 /etc/displaycameras/layout.conf.1920x1080
            echo "Copied and cleaned 1920x1080 layout configuration."
        fi
    else
        echo "The displaycameras.conf file is missing or unreadable. This is a critical file."
        echo "Verify package contents."
        exit 4
    fi
    if [ -r $DIR/repaircameras.cron ]; then
        echo "Copying the repaircameras cron job and reloading cron."
        cleanup_file "$DIR/repaircameras.cron" "/etc/cron.d/repaircameras"
        chown root:root /etc/cron.d/repaircameras && chmod 0755 /etc/cron.d/repaircameras
        systemctl restart cron
    else
        echo "The repaircameras.cron file is missing or unreadable. This is a critical file."
        echo "Verify package contents."
        exit 5
    fi
    # Setup logging configuration
    if [ -r $DIR/displaycameras.logrotate ]; then
        echo "Setting up logging configuration..."
        # Create log file with proper permissions if it doesn't exist
        if [ ! -f /var/log/displaycameras.log ]; then
            touch /var/log/displaycameras.log
            chown root:root /var/log/displaycameras.log
            chmod 644 /var/log/displaycameras.log
            echo "Created log file: /var/log/displaycameras.log"
        else
            echo "Log file already exists, ensuring proper permissions..."
            chown root:root /var/log/displaycameras.log
            chmod 644 /var/log/displaycameras.log
        fi

        # Install logrotate configuration
        cleanup_file "$DIR/displaycameras.logrotate" "/etc/logrotate.d/displaycameras"
        chown root:root /etc/logrotate.d/displaycameras
        chmod 644 /etc/logrotate.d/displaycameras
        
        # Validate logrotate config
        if ! logrotate -d /etc/logrotate.d/displaycameras >/dev/null 2>&1; then
            echo "Error: Invalid logrotate configuration"
            exit 6
        fi
        
        echo "Logging configuration completed successfully"
    else
        echo "The displaycameras.logrotate file is missing or unreadable."
        echo "Logging rotation will not be configured."
        echo "Verify package contents."
    fi

    # Set a reasonable GPU memory allocation
    # Determine total physical memory
    # System Memory
    sysmem="`free -m | grep Mem: | awk '$1=$1' | cut -f 2 -d " "`"
    # GPU Memory
    gpumem="`sudo raspi-config nonint get_config_var gpu_mem /boot/config.txt`"
    # Total Mem
    physmem=$((gpumem + sysmem))
    if [ "$physmem" -lt "500" ]; then
        split=96
        else
        if [ "$physmem" -lt "1000" ]; then
            split=192
            else
            split=256
        fi
    fi
    # Ask whether there's a custom split desired
    echo -n "Enter a custom gpu split if desired [gpu memory in MB] or [Enter] to use recommended split: "
    read -r REPLY
    if [ "$REPLY" != "" ]; then
        if [ "$REPLY" -ge "64" -a "$REPLY" -le "512" ]; then
            split="$REPLY"
        fi
    fi
    # Set the split
    if [ "`raspi-config nonint get_config_var gpu_mem /boot/config.txt`" -lt "$split" ]; then
        echo "Setting gpu_mem allocation to "$split"MB"
        raspi-config nonint do_memory_split "$split"
    fi
    # Disable overscan support so that display resolution autodetection works
    if [ "`raspi-config nonint get_overscan`" = "0" ]; then
        echo "Disabling display overscan compensation. Set your monitor not to overscan."
        raspi-config nonint do_overscan 1
    fi
fi
if [ -r $DIR/omxplayer_dbuscontrol ]; then
    echo "Copying the omxplayer control script."
    cleanup_file "$DIR/omxplayer_dbuscontrol" "/usr/bin/omxplayer_dbuscontrol"
    chown root:root /usr/bin/omxplayer_dbuscontrol && chmod 0755 /usr/bin/omxplayer_dbuscontrol
else
    echo "The omxplayer_dbuscontrl file is missing or unreadable. This is a critical file."
    echo "Verify package contents."
    exit 7
fi
if [ -r $DIR/rotatedisplays ]; then
    echo "Copying the display rotating script and setting permissions."
    cleanup_file "$DIR/rotatedisplays" "/usr/bin/rotatedisplays"
    chown root:root /usr/bin/rotatedisplays && chmod 0755 /usr/bin/rotatedisplays
else
    echo "The rotatedisplays file is missing or unreadable. This file is required to support display rotation."
    echo "Verify package contents."
fi
if [ -r $DIR/black.png ]; then
    echo "Copying the black background file and setting ownership."
    cp -f $DIR/black.png /usr/bin/ && chown root:root /usr/bin/black.png
else
    echo "The black.png file is missing or unreadable. Screen blanking will not work"
    echo "with out it.  Verify package contents."
fi

# Update systemd and enable the displaycameras service.
systemctl daemon-reload
systemctl enable displaycameras

# Restart the service if this is an upgrade
if [ "${1:-}" = "upgrade" ]; then
    echo "Restarting displaycameras service..."
    systemctl restart displaycameras || true
fi

# Force an initial logrotate run if config exists (this should run for both install and upgrade)
if [ -f /etc/logrotate.d/displaycameras ]; then
    echo "Running initial logrotate..."
    logrotate -f /etc/logrotate.d/displaycameras >/dev/null 2>&1 || true
fi

echo "Installation/Upgrade Successful!"
read -r -p "See the README.md? [Y/y/N/n] " REPLY
if [ "$REPLY" = "Y" -o "$REPLY" = "y" ]; then
    echo "Use the space bar (or PgDn) to page down, PgUp to page up, q to quit"
    read -r -p "Press Enter to begin." -n 1
    less $DIR/README.md
fi
exit 0
