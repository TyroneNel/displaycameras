#!/bin/bash

# Function to preload next stream
preload_next_stream() {
    local camera_idx="$1"
    local next_pos=$((($camera_idx + 1) % ${#camera_names[@]}))
    local next_feed="${camera_feeds[$next_pos]}"
    local next_name="NEXT_${camera_names[$camera_idx]}"
    
    log "INFO" "Preloading next stream for camera ${camera_names[$camera_idx]}"
    
    # Start preload stream
    omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp \
        --win "${window_positions[$next_pos]}" \
        "$next_feed" --live -n -1 --timeout $omx_timeout \
        --dbus_name "org.mpris.MediaPlayer2.omxplayer.$next_name" \
        >/dev/null 2>&1 &
    
    # Wait for preload to initialize
    sleep $startsleep
    
    # Check if preload was successful
    if pgrep -f "org.mpris.MediaPlayer2.omxplayer.$next_name" >/dev/null; then
        return 0
    else
        log "ERROR" "Failed to preload stream for ${camera_names[$camera_idx]}"
        return 1
    fi
}

# Function to perform smooth transition
smooth_transition() {
    local current_idx="$1"
    local next_idx="$2"
    local current_name="${camera_names[$current_idx]}"
    local next_name="NEXT_$current_name"
    
    # Calculate intermediate positions
    local steps=10
    local current_pos=(${window_positions[$current_idx]})
    local next_pos=(${window_positions[$next_idx]})
    
    # Perform transition
    for ((step=1; step<=steps; step++)); do
        local progress=$(echo "scale=2; $step/$steps" | bc)
        local x=$(echo "scale=0; (${next_pos[0]}-${current_pos[0]})*$progress+${current_pos[0]}" | bc)
        local y=$(echo "scale=0; (${next_pos[1]}-${current_pos[1]})*$progress+${current_pos[1]}" | bc)
        local w=$(echo "scale=0; (${next_pos[2]}-${current_pos[2]})*$progress+${current_pos[2]}" | bc)
        local h=$(echo "scale=0; (${next_pos[3]}-${current_pos[3]})*$progress+${current_pos[3]}" | bc)
        
        # Move both streams
        eval omxplayer_dbuscontrol "$current_name" setvideopos \"$x $y $w $h\"
        eval omxplayer_dbuscontrol "$next_name" setvideopos \"$x $y $w $h\"
        
        sleep $transitionspeed
    done
    
    # Stop original stream
    omxplayer_dbuscontrol "$current_name" quit
    
    # Rename preloaded stream to take over
    pkill -f "org.mpris.MediaPlayer2.omxplayer.$next_name"
}

# Function to monitor and cleanup omxplayer processes
monitor_omxplayer_processes() {
    while true; do
        for i in ${!camera_names[@]}; do
            if ! check_stream_health "${camera_names[$i]}"; then
                log "WARN" "Stream ${camera_names[$i]} appears unhealthy"
                repair_stream "$i"
            fi
        done
        sleep $monitorinterval
    done
}
