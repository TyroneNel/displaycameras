#!/bin/bash

# Function to start a camera stream
start_stream() {
    local camera_idx="$1"
    debug "start_stream called for camera_idx: $camera_idx"
    control_player "start" "$camera_idx"
}

# Clean up zombie/defunct omxplayer wrapper processes
# (wrappers that have no omxplayer.bin child)
cleanup_orphan_processes() {
    for name in "${camera_names[@]}"; do
        # Find shell wrappers that have no omxplayer.bin child
        pgrep -f "omxplayer.*$name" 2>/dev/null | while read -r wrapper_pid; do
            [ -n "$wrapper_pid" ] || continue
            # Verify this is the wrapper script, not the binary
            local cmdline
            cmdline=$(cat /proc/$wrapper_pid/cmdline 2>/dev/null | tr '\0' ' ')
            case "$cmdline" in
                *omxplayer.bin*)
                    continue
                    ;;
            esac
            local child_count
            child_count=$(pgrep -P "$wrapper_pid" 2>/dev/null | wc -l)
            if [ "$child_count" -eq 0 ]; then
                warn "Cleaning up defunct wrapper process $wrapper_pid for $name"
                kill -9 "$wrapper_pid" 2>/dev/null || true
            fi
        done
    done
}

# Function to monitor and cleanup omxplayer processes
monitor_omxplayer_processes() {
    # Set up signal handling
    trap 'info "Monitor loop received shutdown signal"; exit 0' SIGTERM SIGINT
    
    # Set a default for monitorinterval if it's not defined.
    : ${monitorinterval:=10}
    while true; do
        # Check if main service is still running
        if [ ! -f "$PIDFILE" ]; then
            info "Main service stopped, ending monitoring"
            exit 0
        fi

        # Detect and clean zombie/defunct wrapper processes
        cleanup_orphan_processes

        for i in ${!camera_names[@]}; do
            if ! check_stream_health "${camera_names[$i]}"; then
                warn "Stream ${camera_names[$i]} appears unhealthy"
                repair_stream "$i"
            fi
        done
        sleep $monitorinterval
    done
}
