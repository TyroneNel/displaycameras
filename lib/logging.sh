#!/bin/bash

# Logging function for consistent log format
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> /var/log/displaycameras.log
}

# Helper to produce a structured key=value log string
# Usage: _log_kv "key1" "val1" "key2" "val2" ...
_log_kv() {
    local kv=""
    while (( $# >= 2 )); do
        kv="$kv $1=$2"
        shift 2
    done
    echo "$kv"
}

# Structured event logger for rotation / stream lifecycle / cleanup
# Usage: log_event "action" "key1" "val1" ...
# action: 'rotation.reposition.start', 'rotation.reposition.stop', 'rotation.rotate.success',
#        'stream.cleanup.kill', 'stream.cleanup.dbus', 'stream.repair.start',
#        'stream.repair.ongoing', 'stream.health.ok', 'stream.health.fail',
#        'stream.stop.graceful', 'stream.stop.force' ...
log_event() {
    local action="$1"
    shift 1
    local kv_string
    kv_string="action=$action"
    while (( $# >= 2 )); do
        kv_string="$kv_string $1=$2"
        shift 2
    done
    log "EVENT" "$kv_string"
}

# Helper to log stream control actions with full context
log_stream_action() {
    local action="$1"
    local camera_name="$2"
    shift 2
    local extra=""
    while (( $# >= 2 )); do
        extra="$extra $1=$2"
        shift 2
    done
    log "EVENT" "action=$action camera=$camera_name$extra"
}

# Function to log debug messages
debug() {
    if [ "${debug-}" = "true" ]; then
        local script_name="${BASH_SOURCE[1]}"
        local line_number="${BASH_LINENO[0]}"
        log "DEBUG" "[$script_name:$line_number] $@"
    fi
}

# Function to log info messages
info() {
    log "INFO" "$@"
}

# Function to log warning messages
warn() {
    log "WARN" "$@"
}

# Function to log error messages
error() {
    log "ERROR" "$@"
}

# Function to log fatal messages
fatal() {
    log "FATAL" "$@"
}

# Function to check if logging is working
check_logging() {
    if ! touch /var/log/displaycameras.log 2>/dev/null; then
        echo "ERROR: Cannot write to log file /var/log/displaycameras.log"
        return 1
    fi
    return 0
}
