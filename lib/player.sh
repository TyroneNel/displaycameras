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

    # STATEFUL POSITIONING LOGIC
    # Calculate the camera's rank in the current display order based on the rotation sequence.
    # This rank determines if it's on-screen or off-screen.
    local display_rank=$(((camera_idx - DISPLAY_SEQUENCE + num_cameras) % num_cameras))
    
    if [ "$display_rank" -lt "$num_windows" ]; then
        # This camera should be on-screen. Its window is at index 'display_rank'.
        position="${window_positions[$display_rank]}"
        debug "Camera '$camera_name' (idx $camera_idx) is ON-SCREEN in window $display_rank at position '$position'"
    else
        # This camera should be off-screen.
        position="-10000 -10000 -9000 -9000"
        debug "Camera '$camera_name' (idx $camera_idx) is OFF-SCREEN"
    fi

    case "$action" in
    start)
        log "INFO" "Starting stream for $camera_name in position $position"
        local camera_feed="${camera_feeds[$camera_idx]}"
        local player_cmd="omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win \"$position\" \"$camera_feed\" --live -n -1 --timeout $omx_timeout --dbus_name \"org.mpris.MediaPlayer2.omxplayer.$camera_name\" >/dev/null 2>&1 &"
        debug "Executing player command: $player_cmd"
        eval $player_cmd
        ;;
    reposition)
        log "INFO" "Repositioning stream for $camera_name to $position"
        debug "Executing reposition command: timeout 2s omxplayer_dbuscontrol \"$camera_name\" setvideopos $position"
        timeout 2s omxplayer_dbuscontrol "$camera_name" setvideopos $position || true
        ;;
    *)
        log "ERROR" "Unknown action '$action' for control_player"
        return 1
        ;;
    esac
}
