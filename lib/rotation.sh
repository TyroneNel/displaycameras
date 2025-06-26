#!/bin/bash

# Function to validate and normalize transition speed
validate_transition_speed() {
    # Default values
    local min_speed=0.01
    local max_speed=1.0
    local default_speed=0.1
    
    # If transitionspeed is not set or invalid, use default
    if [ -z "$transitionspeed" ] || ! [[ "$transitionspeed" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log "WARN" "Invalid transition speed value, using default: $default_speed"
        transitionspeed=$default_speed
        return
    fi
    
    # Ensure value is within bounds
    if (( $(echo "$transitionspeed < $min_speed" | bc -l) )); then
        log "WARN" "Transition speed too low, using minimum: $min_speed"
        transitionspeed=$min_speed
    elif (( $(echo "$transitionspeed > $max_speed" | bc -l) )); then
        log "WARN" "Transition speed too high, using maximum: $max_speed"
        transitionspeed=$max_speed
    fi
}

# Function to check if rotation is active
check_rotation_status() {
    # Check if rotation is enabled in config
    if [ "$rotate" != "true" ]; then
        return 1
    fi
    
    # Check if rotation process is running
    if [ -f "$ROTATE_PIDFILE" ]; then
        local pid=$(cat "$ROTATE_PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$ROTATE_PIDFILE"
        fi
    fi
    
    return 1
}

# Function to start rotation
start_rotation() {
    if [ "$rotate" != "true" ]; then
        log "INFO" "Rotation not enabled in config"
        return 1
    fi
    
    if check_rotation_status; then
        log "INFO" "Rotation already running"
        return 0
    fi
    
    # Start rotation in background
    rotate_displays &
    echo $! > "$ROTATE_PIDFILE"
    log "INFO" "Started rotation process (PID: $(cat $ROTATE_PIDFILE))"
}

# Function to rotate displays
rotate_displays() {
    while true; do
        # Check if main service is still running
        if [ ! -f "$PIDFILE" ]; then
            log "INFO" "Main service stopped, ending rotation"
            rm -f "$ROTATE_PIDFILE"
            exit 0
        fi
        
        # Adjust rotation delay based on system conditions
        local adjusted_delay=$(adjust_timing "$rotatedelay")
        log "INFO" "Using adjusted rotation delay: $adjusted_delay seconds"
        sleep "$adjusted_delay"
        
        # Store current sequence
        DISPLAY_SEQUENCE=$((DISPLAY_SEQUENCE+$seq_step))
        if [ "$DISPLAY_SEQUENCE" -ge "${#camera_names[@]}" ]; then
            DISPLAY_SEQUENCE=0
        fi
        
        # Check system resources before rotation
        if ! check_system_resources; then
            log "WARN" "System resources strained, increasing rotation delay"
            sleep 2
        fi
        
        # Clean up any stray NEXT_ streams first
        pkill -f "org.mpris.MediaPlayer2.omxplayer.NEXT_" || true
        sleep 1
        
        # Rotate each stream
        for i in ${!camera_names[*]}; do
            log "INFO" "Rotating stream ${camera_names[$i]}"
            
            # Calculate next position
            local next_idx=$(((i + 1) % ${#camera_names[@]}))
            
            # Preload next stream
            if preload_next_stream "$i"; then
                # Perform smooth transition
                smooth_transition "$i" "$next_idx"
            else
                log "ERROR" "Failed to preload next stream for ${camera_names[$i]}, using direct position change"
                # Fallback to direct position change
                eval omxplayer_dbuscontrol "${camera_names[$i]}" setvideopos \"${window_positions[$next_idx]}\"
            fi
            
            sleep 1
        done
        
        echo $DISPLAY_SEQUENCE > $DISPLAY_SEQUENCE_FILE
    done
}
