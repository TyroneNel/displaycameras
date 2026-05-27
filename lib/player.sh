#!/bin/bash

# Array to track off-screen state for each camera
declare -A camera_offscreen_state

# Stop a stream entirely (for off-screen rotation)
stop_stream() {
    local camera_idx="$1"
    local camera_name="${camera_names[$camera_idx]}"
    
    info "Stopping stream for $camera_name (off-screen)"
    log_stream_action "stream.stop" "$camera_name" "reason" "off-screen-rotation"
    
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
        warn "$camera_name did not stop cleanly, forcing cleanup"
        kill_stream_process "$camera_name"
        log_event "stream.stop.force" "camera" "$camera_name"
    fi
    
    # DBus daemon and socket files are shared across all cameras via a
    # single per-user session bus. They must NOT be killed/cleaned here
    # (that would break all other cameras). They are cleaned during full
    # service shutdown by handle_signal() and the stop command.
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
        # If an existing omxplayer.bin is still running for this camera, kill it first.
        # This prevents duplicate/overlapping streams that can happen when a camera
        # was stopped off-screen and is now being restarted on-screen.
        if pgrep -f "omxplayer\.bin.*$camera_name" >/dev/null 2>&1; then
            warn "Old omxplayer for $camera_name is still running, stopping before restart"
            log_event "stream.cleanup.duplicate" "camera" "$camera_name"
            kill_stream_process "$camera_name"
        fi
        if [ "${camera_offscreen_state[$camera_name]}" = "true" ]; then
            # Camera was off-screen and is now being started on-screen.
            info "Restarting off-screen stream for $camera_name on-screen"
            camera_offscreen_state[$camera_name]="false"
        fi
        info "Starting stream for $camera_name in position $position"
        log_stream_action "stream.start" "$camera_name" "position" "$position" "window" "$display_rank"
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
        
        info "Repositioning stream for $camera_name to $position"
        log_stream_action "stream.reposition" "$camera_name" "position" "$position" "window" "$display_rank"
        debug "Executing reposition command: timeout 2s omxplayer_dbuscontrol \"$camera_name\" setvideopos $position"
        timeout 2s omxplayer_dbuscontrol "$camera_name" setvideopos $position || warn "DBus reposition failed for $camera_name"
        ;;
    *)
        error "Unknown action '$action' for control_player"
        return 1
        ;;
    esac
}
