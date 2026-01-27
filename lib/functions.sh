#!/bin/bash

# Source all function modules
source "/usr/lib/displaycameras/logging.sh"
source "/usr/lib/displaycameras/stream.sh"
source "/usr/lib/displaycameras/network.sh"
source "/usr/lib/displaycameras/system.sh"
source "/usr/lib/displaycameras/rotation.sh"
source "/usr/lib/displaycameras/service.sh"

# Function to validate camera configuration
validate_camera_config() {
    local errors=0
    
    # Check if arrays are defined
    if [ ${#camera_names[@]} -eq 0 ]; then
        log "ERROR" "No camera names defined"
        return 1
    fi
    
    if [ ${#camera_feeds[@]} -eq 0 ]; then
        log "ERROR" "No camera feeds defined"
        return 1
    fi
    
    # Check array length matching
    if [ ${#camera_names[@]} -ne ${#camera_feeds[@]} ]; then
        log "ERROR" "Camera names (${#camera_names[@]}) and feeds (${#camera_feeds[@]}) arrays have different lengths"
        return 1
    fi
    
    # Validate each camera name and feed
    local valid_name_regex='^[A-Za-z0-9_]+$'
    local valid_url_regex='^rtsp://'
    
    for i in ${!camera_names[@]}; do
        local name="${camera_names[$i]}"
        local feed="${camera_feeds[$i]}"
        
        # Check camera name format
        if ! [[ "$name" =~ $valid_name_regex ]]; then
            log "ERROR" "Invalid camera name '$name'. Names must contain only A-Z, a-z, 0-9, and _"
            errors=$((errors + 1))
        fi
        
        # Check RTSP URL format
        if ! [[ "$feed" =~ $valid_url_regex ]]; then
            log "ERROR" "Invalid camera feed URL for '$name': $feed"
            errors=$((errors + 1))
        fi
    done
    
    if [ $errors -gt 0 ]; then
        log "ERROR" "Found $errors validation errors in camera configuration"
        return 1
    fi
    
    log "INFO" "Camera configuration validated: ${#camera_names[@]} cameras"
    return 0
}

# Define PID files and global variables
PIDFILE="/var/run/displaycameras.pid"
ROTATE_PIDFILE="/var/run/displaycameras.rotate.pid"
MONITOR_PIDFILE="/var/run/displaycameras.monitor.pid"
DISPLAY_SEQUENCE_FILE="/var/run/displaycameras.sequence"
