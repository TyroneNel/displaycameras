#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Define lock file for repair process
REPAIR_LOCKFILE="/var/run/displaycameras.repair.lock"

# Function to check service status
check_service_status() {
    if [ ! -f "$PIDFILE" ]; then
        return 1
    fi
    
    local pid=$(cat "$PIDFILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        # PID file is stale, remove it
        rm -f "$PIDFILE"
        return 1
    fi
    
    return 0
}

# Write PID file for systemd
write_pid_file() {
    log "INFO" "Creating PID file at $PIDFILE"
    echo $ > "$PIDFILE"
}

# Clean up PID files
cleanup_pid_files() {
    log "INFO" "Cleaning up PID files..."
    rm -f "$PIDFILE" "$ROTATE_PIDFILE" "$MONITOR_PIDFILE" "$DISPLAY_SEQUENCE_FILE" "$REPAIR_LOCKFILE"
}

# Function to repair stream
repair_stream() {
    local camera_idx="$1"
    
    # Check for lock file
    if [ -f "$REPAIR_LOCKFILE" ]; then
        log "INFO" "Repair process already running. Skipping."
        return 1
    fi
    
    # Create lock file
    touch "$REPAIR_LOCKFILE"
    
    local max_repair_attempts=5
    local attempt=1
    
    log "INFO" "Attempting to repair stream for camera ${camera_names[$camera_idx]}"
    
    while [ $attempt -le $max_repair_attempts ]; do
        log "INFO" "Repair attempt $attempt for ${camera_names[$camera_idx]}"
        
        # Check network connectivity first
        if ! check_network_connectivity "${camera_feeds[$camera_idx]}"; then
            log "ERROR" "Network connectivity check failed for ${camera_names[$camera_idx]}"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi
        
        # Stop existing stream
        omxplayer_dbuscontrol "${camera_names[$camera_idx]}" quit >/dev/null 2>&1
        sleep 2
        
        # Start new stream
        start_stream "$camera_idx"
        
        sleep $startsleep
        
        # Check if stream is healthy
        if check_stream_health "${camera_names[$camera_idx]}"; then
            log "INFO" "Successfully repaired stream for ${camera_names[$camera_idx]}"
            rm -f "$REPAIR_LOCKFILE"
            return 0
        fi
        
        log "WARN" "Repair attempt $attempt failed for ${camera_names[$camera_idx]}"
        attempt=$((attempt + 1))
        sleep 3
    done
    
    log "ERROR" "Failed to repair stream for ${camera_names[$camera_idx]} after $max_repair_attempts attempts"
    rm -f "$REPAIR_LOCKFILE"
    return 1
}

# Stream health check function
check_stream_health() {
    local camera_name="$1"
    local max_checks=3
    local check=1
    
    while [ $check -le $max_checks ]; do
        local status=$(omxplayer_dbuscontrol "$camera_name" getplaystatus 2>/dev/null || echo "Not running")
        local position=$(omxplayer_dbuscontrol "$camera_name" getposition 2>/dev/null || echo "0s")
        
        if [ "$status" = "Playing" ] && [ "$position" != "0s" ]; then
            return 0
        fi
        check=$((check + 1))
        sleep 1
    done
    
    log "ERROR" "Stream health check failed for camera $camera_name"
    return 1
}
