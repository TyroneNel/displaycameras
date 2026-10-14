#!/bin/bash

# Parse host and port from an RTSP URL, dynamically derived from the
# configured camera feed (no hardcoded IPs).
# Handles: rtsp://host:port/path, rtsp://host/path,
#          rtsp://user:pass@host:port/path, rtsp://user@host/path,
#          and bracketed IPv6 rtsp://[::1]:554/path.
# Sets: _parsed_host and _parsed_port (empty if no port in URL).
parse_rtsp_host_port() {
    local url="$1"
    _parsed_host=""
    _parsed_port=""

    local without_scheme="${url#*://}"
    local authority="${without_scheme%%/*}"
    case "$authority" in
        *@*) authority="${authority##*@}" ;;
    esac

    case "$authority" in
        \[*\]*)
            _parsed_host="${authority%%\]*}"
            _parsed_host="${_parsed_host#[}"
            local remainder="${authority#*\]}"
            case "$remainder" in
                :*) _parsed_port="${remainder#:}" ;;
            esac
            ;;
        *)
            case "$authority" in
                *:*)
                    _parsed_host="${authority%%:*}"
                    _parsed_port="${authority#*:}"
                    ;;
                *)
                    _parsed_host="$authority"
                    ;;
            esac
            ;;
    esac
}

# Network connectivity check function
check_network_connectivity() {
    local url="$1"
    parse_rtsp_host_port "$url"
    local host="$_parsed_host"
    local port="$_parsed_port"
    local max_attempts=2
    local attempt=1
    
    if [ -z "$port" ]; then
        port_msg=""
    else
        port_msg=":$port"
    fi
    
    while [ $attempt -le $max_attempts ]; do
        if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
            if [ ! -z "$port" ]; then
                if nc -z -w2 "$host" "$port" >/dev/null 2>&1; then
                    return 0
                fi
            else
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 1
    done
    
    error "Failed to reach host $host$port_msg after $max_attempts attempts"
    return 1
}

# Function to measure network latency
measure_network_latency() {
    local url="$1"
    parse_rtsp_host_port "$url"
    local host="$_parsed_host"
    local samples=1
    local total_latency=0
    local successful_pings=0
    
    for ((i=1; i<=samples; i++)); do
        local latency=$(ping -c 1 -W 1 "$host" 2>/dev/null | \
            grep "time=" | \
            awk -F"time=" '{print $2}' | \
            cut -d' ' -f1 | \
            cut -d'.' -f1)
        
        if [ ! -z "$latency" ]; then
            total_latency=$((total_latency + latency))
            successful_pings=$((successful_pings + 1))
        fi
    done
    
    if [ $successful_pings -gt 0 ]; then
        echo $((total_latency / successful_pings))
    else
        echo 1000  # High latency value to indicate poor connection
    fi
}
