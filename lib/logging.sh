#!/bin/bash

# Logging module for displaycameras
# =================================
# Log levels (numeric, higher = more verbose):
#   0 FATAL - Unrecoverable error, service cannot continue
#   1 ERROR - Action failed but service continues
#   2 WARN  - Potential problem, attention may be needed
#   3 INFO  - Normal operational messages
#   4 DEBUG - Detailed trace for troubleshooting
#
# Runtime log level is controlled by:
#   - LOG_LEVEL env var (overrides everything)
#   - debug=true in displaycameras.conf sets level to 4
#   - Default: 3 (INFO)
#
# Usage:
#   fatal "msg"                       # always written
#   error "msg"                       # level >= 1
#   warn "msg"                        # level >= 2
#   info "msg"                        # level >= 3
#   debug "msg"                       # level >= 4 (includes file:line)
#   log_event "action" "key" "val"    # structured key=value (at INFO priority)
#   log_stream_action "action" "cam"  # camera-specific structured entry
#
# Backward-compatible: log "INFO" "msg" still works.

LOG_LEVEL_SILENT=0
LOG_LEVEL_ERROR=1
LOG_LEVEL_WARN=2
LOG_LEVEL_INFO=3
LOG_LEVEL_DEBUG=4

# Determine default log level
if [ -n "${LOG_LEVEL-}" ]; then
    : # use explicitly set LOG_LEVEL
elif [ "${debug-}" = "true" ]; then
    LOG_LEVEL=$LOG_LEVEL_DEBUG
else
    LOG_LEVEL=$LOG_LEVEL_INFO
fi

# Core logging function.  Accepts either a numeric level (0-4) or a
# string label ("INFO", "WARN", ...) for backward compatibility.
log() {
    local level="$1"
    local label
    local -i level_num
    shift

    case "$level" in
        0) label="FATAL"; level_num=0 ;;
        1) label="ERROR"; level_num=1 ;;
        2) label="WARN";  level_num=2 ;;
        3) label="INFO";  level_num=3 ;;
        4) label="DEBUG"; level_num=4 ;;
        EVENT) label="EVENT"; level_num=3 ;;
        *)
            label="$level"
            case "$label" in
                FATAL) level_num=0 ;;
                ERROR) level_num=1 ;;
                WARN)  level_num=2 ;;
                INFO)  level_num=3 ;;
                DEBUG) level_num=4 ;;
                EVENT) level_num=3 ;;
                *)     level_num=3 ;;  # unknown labels treated as INFO
            esac
            ;;
    esac

    [ "$level_num" -le "$LOG_LEVEL" ] || return 0

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local entry="$timestamp [$label] $*"

    echo "$entry" >> /var/log/displaycameras.log

    # Also echo to stderr when running with a terminal attached
    if [ -t 2 ]; then
        echo "$entry" >&2
    fi
}

# ── Convenience wrappers (use numeric levels for efficiency) ──

fatal() { log 0 "$@"; }
error() { log 1 "$@"; }
warn()  { log 2 "$@"; }
info()  { log 3 "$@"; }

debug() {
    [ "$LOG_LEVEL" -ge 4 ] || return 0
    log 4 "[${BASH_SOURCE[1]}:${BASH_LINENO[0]}] $@"
}

# ── Structured logging helpers ──

# Build a key=value string from alternating key/value args.
# Usage: _log_kv "key1" "val1" "key2" "val2" ...
_log_kv() {
    local kv=""
    while (( $# >= 2 )); do
        kv="$kv $1=$2"
        shift 2
    done
    printf '%s' "$kv"
}

# Structured event logger.  All events are written at the INFO
# priority level.
#
# Usage: log_event "action" ["key" "val" ...]
#
# Example:
#   log_event "stream.repair.success" "camera" "FF" "attempt" "2"
#
# Recommended action prefixes:
#   service.{start,stop,restart,repair}
#   stream.{start,stop,reposition,repair.{start,success,failure},health.{ok,fail}}
#   rotation.{rotate,restart}
#   stream.cleanup.{kill,orphan,dbus}
log_event() {
    local action="$1"
    shift
    local kv
    kv="action=$action$(_log_kv "$@")"
    log 3 "${kv# }"
}

# Camera-specific structured log helper.  Includes the camera name
# as a first-class field and appends any extra key=value pairs.
#
# Usage: log_stream_action "action" "camera_name" ["key" "val" ...]
#
# Example:
#   log_stream_action "stream.start" "FF" "position" "0 0 1200 1080"
log_stream_action() {
    local action="$1"
    local camera="$2"
    shift 2
    local kv
    kv="action=$action camera=$camera$(_log_kv "$@")"
    log 3 "${kv# }"
}

# ── Console-only output (never logged to file) ──

# For the 'status' command: writes to stdout only.
status_echo() {
    echo "$@"
}

# ── Log file health ──

check_logging() {
    if ! touch /var/log/displaycameras.log 2>/dev/null; then
        echo "ERROR: Cannot write to log file /var/log/displaycameras.log" >&2
        return 1
    fi
    return 0
}
