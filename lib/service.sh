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
    info "Received $signal, initiating graceful shutdown..."
    
    # Clean up PID files
    cleanup_pid_files
    
    info "Terminating omxplayer processes..."
    timeout 10 pkill -f "omxplayer" 2>/dev/null || true
    sleep 1
    # Ensure dbus-daemon cleanup
    timeout 5 pkill -f "dbus-daemon.*omxplayer" 2>/dev/null || true
    cleanup_dbus_files
    
    # Exit gracefully
    info "Shutdown complete"
    exit 0
}

# Clean up stale DBus address files
cleanup_dbus_files() {
    rm -f /tmp/omxplayerdbus.root* /tmp/omxplayerdbus.pi* 2>/dev/null || true
}

# Register signal handlers
trap 'handle_signal "SIGTERM"' SIGTERM
trap 'handle_signal "SIGINT"' SIGINT
trap 'handle_signal "SIGHUP"' SIGHUP

# Kill a stream process with graduated signals (SIGINT -> SIGTERM -> SIGKILL)
# Also cleans up associated dbus-daemon
# NOTE: kill -9 can block indefinitely on omxplayer.bin when it is in GPU DMA
#       lock state (process in SLl).  Every kill attempt is wrapped in timeout
#       so the caller never waits more than 9 s total per PID.
kill_stream_process() {
    local camera_name="$1"
    local -i KILL_TIMEOUT=3
    
    log_event "stream.cleanup.kill" "camera" "$camera_name"
    
    # Find the shell wrapper PID(s) (omxplayer is a bash wrapper script)
    local wrapper_pid
    while IFS= read -r wrapper_pid; do
        if [ -z "$wrapper_pid" ]; then
            continue
        fi
        # Try SIGINT first
        timeout "$KILL_TIMEOUT" kill -2 "$wrapper_pid" 2>/dev/null || true
        sleep 2
        
        # Check if still alive
        if kill -0 "$wrapper_pid" 2>/dev/null; then
            # Try SIGTERM
            timeout "$KILL_TIMEOUT" kill -15 "$wrapper_pid" 2>/dev/null || true
            sleep 1
        fi
        
        # Final SIGKILL
        if kill -0 "$wrapper_pid" 2>/dev/null; then
            timeout "$KILL_TIMEOUT" kill -9 "$wrapper_pid" 2>/dev/null || true
            
            # If still alive after SIGKILL (likely stuck in GPU DMA),
            # log and move on – orphan cleanup will catch it later.
            if kill -0 "$wrapper_pid" 2>/dev/null; then
                warn "PID $wrapper_pid ($camera_name) survived SIGKILL (probably GPU DMA lock); leaving for orphan cleanup"
            fi
        fi
    done < <(pgrep -f "omxplayer.*$camera_name" 2>/dev/null)
    
    # Kill any orphaned dbus-daemon that might be associated
    # The dbus-daemon reads from /tmp/omxplayerdbus.root
    pkill -f "dbus-daemon.*omxplayer" 2>/dev/null || true
}

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
    info "Creating PID file at $PIDFILE"
    echo $$ > "$PIDFILE"
}

# Clean up PID files
cleanup_pid_files() {
    info "Cleaning up PID files..."
    rm -f "$PIDFILE" "$ROTATE_PIDFILE" "$MONITOR_PIDFILE" "$DISPLAY_SEQUENCE_FILE" "$REPAIR_LOCKFILE"
}

# Function to repair stream
repair_stream() {
    local camera_idx="$1"
    
    # Check for lock file
    if [ -f "$REPAIR_LOCKFILE" ]; then
        info "Repair process already running. Skipping."
        return 1
    fi
    
    # Create lock file
    touch "$REPAIR_LOCKFILE"
    
    # Early exit if no omxplayer processes are running
    local omxplayer_running=false
    for name in "${camera_names[@]}"; do
        if pgrep -f "omxplayer.bin.*$name" >/dev/null 2>&1; then
            omxplayer_running=true
            break
        fi
    done

    if [ "$omxplayer_running" = "false" ]; then
        local repair_camera_name="${camera_names[$1]}"
        info "No omxplayer processes running for $repair_camera_name. Skipping repair."
        rm -f "$REPAIR_LOCKFILE" 2>/dev/null || true
        return 0
    fi
    
    local max_repair_attempts=5
    local attempt=1
    
    info "Attempting to repair stream for camera ${camera_names[$camera_idx]}"
    log_stream_action "stream.repair.start" "${camera_names[$camera_idx]}"
    
    while [ $attempt -le $max_repair_attempts ]; do
        info "Repair attempt $attempt for ${camera_names[$camera_idx]}"
        log_stream_action "stream.repair.attempt" "${camera_names[$camera_idx]}" "attempt" "$attempt"
        
        # Check network connectivity first
        if ! check_network_connectivity "${camera_feeds[$camera_idx]}" ; then
            error "Network connectivity check failed for ${camera_names[$camera_idx]}"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi
        
        # Stop existing stream - use graduated kill
        kill_stream_process "${camera_names[$camera_idx]}"
        sleep 1
        cleanup_dbus_files
        
        # Start new stream
        start_stream "$camera_idx"
        
        sleep $startsleep
        
        # Check if stream is healthy
        if check_stream_health "${camera_names[$camera_idx]}"; then
            info "Successfully repaired stream for ${camera_names[$camera_idx]}"
            log_event "stream.repair.success" "camera" "${camera_names[$camera_idx]}" "attempt" "$attempt"
            rm -f "$REPAIR_LOCKFILE"
            return 0
        fi
        
        warn "Repair attempt $attempt failed for ${camera_names[$camera_idx]}"
        attempt=$((attempt + 1))
        sleep 3
    done
    
    error "Failed to repair stream for ${camera_names[$camera_idx]} after $max_repair_attempts attempts"
    log_event "stream.repair.failure" "camera" "${camera_names[$camera_idx]}" "max_attempts" "$max_repair_attempts"
    rm -f "$REPAIR_LOCKFILE"
    return 1
}

# Stream health check function
check_stream_health() {
    local camera_name="$1"
    
    # First, check if the player is reporting a "Playing" status.
    local status=$(timeout 2s omxplayer_dbuscontrol "$camera_name" getplaystatus 2>/dev/null || echo "Not running")
    if [ "$status" != "Playing" ]; then
        warn "Stream health check for '$camera_name' failed: Status is '$status'."
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
        error "Stream health check failed for '$camera_name': Stream appears to be frozen at position ${position1}s."
        return 1
    fi

    debug "Stream health check passed for '$camera_name' (Position changed from ${position1}s to ${position2}s)."
    return 0
}

