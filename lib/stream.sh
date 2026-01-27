#!/bin/bash

# Function to start a camera stream
start_stream() {
    local camera_idx="$1"
    debug "start_stream called for camera_idx: $camera_idx"
    control_player "start" "$camera_idx"
}

# Function to monitor and cleanup omxplayer processes
monitor_omxplayer_processes() {
    # Set up signal handling
    trap 'log "INFO" "Monitor loop received shutdown signal"; exit 0' SIGTERM SIGINT
    
    # Set a default for monitorinterval if it's not defined.
    : ${monitorinterval:=10}
    while true; do
        # Check if main service is still running
        if [ ! -f "$PIDFILE" ]; then
            log "INFO" "Main service stopped, ending monitoring"
            exit 0
        fi

        for i in ${!camera_names[@]}; do
            if ! check_stream_health "${camera_names[$i]}"; then
                log "WARN" "Stream ${camera_names[$i]} appears unhealthy"
                repair_stream "$i"
            fi
        done
        sleep $monitorinterval
    done
}
