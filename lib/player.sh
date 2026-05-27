#!/bin/bash

# Array to track off-screen state for each camera
declare -A camera_offscreen_state

# Stop a stream entirely (for off-screen rotation)
stop_stream() {
    local camera_idx="$1"
    local camera_name="${camera_names[$camera_idx]}"
    
    log "INFO" "Stopping stream for $camera_name (off-screen)"
    
    # Prefer DBus quit for clean shutdown, but don't fail if DBus is already gone.
    # This covers both graceful stop and force-kill fallback via kill_stream_process().
    timeout 2s omxplayer_dbuscontrol "$camera_name" quit 2>/dev/null || true
    
    local -i waited=0
    while (( waited < 5 )); do
        if ! pgrep -f "omxplayer.bin.*$camera_name" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        ((waited++))
    done
    
    # If still alive, force clean-up.
    if pgrep -f "omxplayer.bin.*$camera_name" >/dev/null 2>&1; then
        log "WARN" "$camera_name did not stop cleanly, forcing cleanup"
        kill_stream_process "$camera_name"
    fi
}

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
        # Reset off-screen state when camera should be on-screen
        camera_offscreen_state[$camera_name]="false"
    else
        # This camera should be off-screen.
        position="-10000 -10000 -9000 -9000"
        debug "Camera '$camera_name' (idx $camera_idx) is OFF-SCREEN"
    fi

    case "$action" in
    start)
        if [ "${camera_offscreen_state[$camera_name]}" = "true" ]; then
            # Camera was off-screen and is now being started on-screen.
            log "INFO" "Restarting off-screen stream for $camera_name on-screen"
            camera_offscreen_state[$camera_name]="false"
        fi
        log "INFO" "Starting stream for $camera_name in position $position"
        local camera_feed="${camera_feeds[$camera_idx]}"
        debug "Starting omxplayer for $camera_name with feed: $camera_feed"
        omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win "$position" "$camera_feed" --live -n -1 --timeout "$omx_timeout" --dbus_name "org.mpris.MediaPlayer2.omxplayer.$camera_name" >/dev/null 2>&1 &
        ;;
    reposition)
        if [ "$display_rank" -ge "$num_windows" ]; then
            # Moving off-screen: stop the stream instead of repositioning
            if [ "${camera_offscreen_state[$camera_name]}" != "true" ]; then
                stop_stream "$camera_idx"
                camera_offscreen_state[$camera_name]="true"
            fi
            return
        fi
        
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
