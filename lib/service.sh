#!/bin/bash

# Function to check service status
check_service_status() {
    if [ ! -f "$PIDFILE" ]; then
        return 1
    fi
    
    local pid=$(cat "$PIDFILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# Write PID file for systemd
write_pid_file() {
    echo $$ > "$PIDFILE"
}

# Clean up PID files
cleanup_pid_files() {
    rm -f "$PIDFILE" "$ROTATE_PIDFILE" "$MONITOR_PIDFILE" "$DISPLAY_SEQUENCE_FILE"
}

# Function to repair stream
repair_stream() {
    local camera_idx="$1"
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
        x=$((camera_idx+$DISPLAY_SEQUENCE))
        if [ "$x" -ge "${#camera_names[@]}" ]; then 
            x=$((x-${#camera_names[@]}))
        fi
        
        player="omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win \"${window_positions[$x]}\" \"${camera_feeds[$camera_idx]}\" --live -n -1 --timeout $omx_timeout --dbus_name \"org.mpris.MediaPlayer2.omxplayer.${camera_names[$camera_idx]}\" >/dev/null 2>&1 &"
        log "INFO" "Restarting stream for ${camera_names[$camera_idx]}"
        eval $player
        
        sleep $startsleep
        
        # Check if stream is healthy
        if check_stream_health "${camera_names[$camera_idx]}"; then
            log "INFO" "Successfully repaired stream for ${camera_names[$camera_idx]}"
            return 0
        fi
        
        log "WARN" "Repair attempt $attempt failed for ${camera_names[$camera_idx]}"
        attempt=$((attempt + 1))
        sleep 3
    done
    
    log "ERROR" "Failed to repair stream for ${camera_names[$camera_idx]} after $max_repair_attempts attempts"
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
