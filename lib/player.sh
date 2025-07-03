#!/bin/bash

# Centralized function to control all omxplayer instances
# ACTION: "start" or "reposition"
# CAMERA_IDX: The index of the camera in the camera_names array
control_player() {
    local action="$1"
    local camera_idx="$2"
    
    debug "control_player called with action: $action, camera_idx: $camera_idx"
    
    local camera_name="${camera_names[$camera_idx]}"
    local num_cameras=${#camera_names[@]}
    local num_windows=${#window_positions[@]}
    local position

    if [ "$action" = "start" ]; then
        # On initial start, place cameras sequentially. If there are more cameras
        # than windows, start the extra ones off-screen.
        if [ "$camera_idx" -lt "$num_windows" ]; then
            position="${window_positions[$camera_idx]}"
            debug "START: Camera '$camera_name' is ON-SCREEN in window $camera_idx at position '$position'"
        else
            position="-10000 -10000 -9000 -9000"
            debug "START: Camera '$camera_name' is OFF-SCREEN (more cameras than windows)"
        fi
        
        log "INFO" "Starting stream for $camera_name in position $position"
        local camera_feed="${camera_feeds[$camera_idx]}"
        local player_cmd="omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win \"$position\" \"$camera_feed\" --live -n -1 --timeout $omx_timeout --dbus_name \"org.mpris.MediaPlayer2.omxplayer.$camera_name\" >/dev/null 2>&1 &"
        debug "Executing player command: $player_cmd"
        eval $player_cmd

    elif [ "$action" = "reposition" ]; then
        # For rotation, calculate the camera's rank in the current display order.
        # The rank determines if it's on-screen or off-screen.
        local display_rank=$(((camera_idx - DISPLAY_SEQUENCE + num_cameras) % num_cameras))
        
        if [ "$display_rank" -lt "$num_windows" ]; then
            # This camera should be on-screen. Its window is at index 'display_rank'.
            position="${window_positions[$display_rank]}"
            debug "REPOSITION: Camera '$camera_name' (idx $camera_idx) is ON-SCREEN in window $display_rank at position '$position'"
        else
            # This camera should be off-screen.
            position="-10000 -10000 -9000 -9000"
            debug "REPOSITION: Camera '$camera_name' (idx $camera_idx) is OFF-SCREEN"
        fi
        
        log "INFO" "Repositioning stream for $camera_name to $position"
        debug "Executing reposition command: omxplayer_dbuscontrol \"$camera_name\" setvideopos $position"
        omxplayer_dbuscontrol "$camera_name" setvideopos $position
    
    else
        log "ERROR" "Unknown action '$action' for control_player"
        return 1
    fi
}
