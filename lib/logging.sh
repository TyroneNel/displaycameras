#!/bin/bash

# Logging function for consistent log format
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> /var/log/displaycameras.log
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
