#!/bin/bash

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
    # Immediately position streams on first run
    log "INFO" "Performing initial stream positioning"
    for i in ${!camera_names[*]}; do
        debug "Initial reposition for camera_idx: $i"
        control_player "reposition" "$i"
        sleep 0.5 # Brief pause to allow DBus commands to process
    done

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
        debug "New DISPLAY_SEQUENCE: $DISPLAY_SEQUENCE"
        
        # Check system resources before rotation
        if ! check_system_resources; then
            log "WARN" "System resources strained, increasing rotation delay"
            sleep 2
        fi
        
        # Rotate each stream
        for i in ${!camera_names[*]}; do
            debug "Rotation reposition for camera_idx: $i"
            control_player "reposition" "$i"
            sleep 1
        done
        
        log "INFO" "Saving current display sequence: $DISPLAY_SEQUENCE"
        echo $DISPLAY_SEQUENCE > $DISPLAY_SEQUENCE_FILE
    done
}
