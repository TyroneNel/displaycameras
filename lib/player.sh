#!/bin/bash

# Centralized function to control all omxplayer instances
# ACTION: "start" or "reposition"
# CAMERA_IDX: The index of the camera in the camera_names array
control_player() {
    local action="$1"
    local camera_idx="$2"
    
    debug "control_player called with action: $action, camera_idx: $camera_idx"
    
    local camera_name="${camera_names[$camera_idx]}"
    
    # Calculate the correct window position based on the current rotation sequence
    local pos_idx=$(((camera_idx + DISPLAY_SEQUENCE) % ${#window_positions[@]}))
    local position="${window_positions[$pos_idx]}"
    debug "Calculated pos_idx: $pos_idx, position: '$position'"

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
        debug "Executing reposition command: omxplayer_dbuscontrol \"$camera_name\" setvideopos $position"
        omxplayer_dbuscontrol "$camera_name" setvideopos $position
        ;;
    *)
        log "ERROR" "Unknown action '$action' for control_player"
        return 1
        ;;
    esac
}
