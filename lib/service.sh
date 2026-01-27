#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Define lock file for repair process
REPAIR_LOCKFILE="/var/run/displaycameras.repair.lock"

# Signal handler for graceful shutdown
handle_signal() {
    local signal="$1"
    log "INFO" "Received $signal, initiating graceful shutdown..."
    
    # Clean up PID files
    cleanup_pid_files
    
    # Kill all omxplayer processes
    pkill -f "omxplayer" || true
    
    # Exit gracefully
    log "INFO" "Shutdown complete"
    exit 0
}

# Register signal handlers
trap 'handle_signal "SIGTERM"' SIGTERM
trap 'handle_signal "SIGINT"' SIGINT
trap 'handle_signal "SIGHUP"' SIGHUP

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
    echo $$ > "$PIDFILE"
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
        timeout 2s omxplayer_dbuscontrol "${camera_names[$camera_idx]}" quit >/dev/null 2>&1 || true
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
    
    # First, check if the player is reporting a "Playing" status.
    local status=$(timeout 2s omxplayer_dbuscontrol "$camera_name" getplaystatus 2>/dev/null || echo "Not running")
    if [ "$status" != "Playing" ]; then
        log "WARN" "Stream health check for '$camera_name' failed: Status is '$status'."
        return 1
    fi

    # Now, check for a frozen stream by comparing position over time.
    local position1_str=$(timeout 2s omxplayer_dbuscontrol "$camera_name" getposition 2>/dev/null || echo "0s")
    
    # The position is returned as "123s". We need to strip the 's' for comparison.
    local position1=${position1_str%s} 

    # Wait a moment to see if the stream progresses.
    sleep 2 

    local position2_str=$(timeout 2s omxplayer_dbuscontrol "$camera_name" getposition 2>/dev/null || echo "0s")
    local position2=${position2_str%s}

    # If the position is greater than 0 and hasn't changed, the stream is frozen.
    # The > 0 check avoids false positives right at the very start of a stream.
    if [ "$position1" -gt 0 ] && [ "$position1" -eq "$position2" ]; then
        log "ERROR" "Stream health check failed for '$camera_name': Stream appears to be frozen at position ${position1}s."
        return 1
    fi

    debug "Stream health check passed for '$camera_name' (Position changed from ${position1}s to ${position2}s)."
    return 0
}

