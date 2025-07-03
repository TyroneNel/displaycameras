#!/bin/bash

# Function to start a camera stream
start_stream() {
    local camera_idx="$1"
    local camera_name="${camera_names[$camera_idx]}"
    local camera_feed="${camera_feeds[$camera_idx]}"
    
    # Calculate window position based on current rotation sequence
    local pos_idx=$(((camera_idx + DISPLAY_SEQUENCE) % ${#window_positions[@]}))
    
    local player_cmd="omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win \"${window_positions[$pos_idx]}\" \"$camera_feed\" --live -n -1 --timeout $omx_timeout --dbus_name \"org.mpris.MediaPlayer2.omxplayer.$camera_name\" >/dev/null 2>&1 &"
    
    log "INFO" "Starting stream for $camera_name"
    eval $player_cmd
}

# Function to monitor and cleanup omxplayer processes
monitor_omxplayer_processes() {
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
