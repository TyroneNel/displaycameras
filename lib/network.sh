#!/bin/bash

# Network connectivity check function
check_network_connectivity() {
    local url="$1"
    local host=$(echo "$url" | awk -F[/:] '{print $4}')
    local port=$(echo "$url" | awk -F[/:] '{print $5}')
    local max_attempts=3
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
        sleep 1
    done
    
    log "ERROR" "Failed to reach host $host$port_msg after $max_attempts attempts"
    return 1
}

# Function to measure network latency
measure_network_latency() {
    local url="$1"
    local host=$(echo "$url" | awk -F[/:] '{print $4}')
    local samples=3
    local total_latency=0
    local successful_pings=0
    
    for ((i=1; i<=samples; i++)); do
        local latency=$(ping -c 1 -W 2 "$host" 2>/dev/null | \
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
