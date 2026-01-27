#!/bin/bash

# Function to check system resources
check_system_resources() {
    local cpu_threshold=90
    local mem_threshold=90
    
    # Get CPU usage from /proc/stat (more reliable than top)
    local cpu_line=$(head -n 1 /proc/stat)
    local user=$(echo "$cpu_line" | awk '{print $2}')
    local nice=$(echo "$cpu_line" | awk '{print $3}')
    local system=$(echo "$cpu_line" | awk '{print $4}')
    local idle=$(echo "$cpu_line" | awk '{print $5}')
    local iowait=$(echo "$cpu_line" | awk '{print $6}')
    local irq=$(echo "$cpu_line" | awk '{print $7}')
    local softirq=$(echo "$cpu_line" | awk '{print $8}')
    
    local total=$((user + nice + system + idle + iowait + irq + softirq))
    local active=$((total - idle))
    local cpu_usage=$((active * 100 / total))
    
    # Get memory usage percentage
    local mem_total=$(free | grep Mem: | awk '{print $2}')
    local mem_used=$(free | grep Mem: | awk '{print $3}')
    local mem_usage=$((mem_used * 100 / mem_total))
    
    # Log resource usage
    log "INFO" "System resources - CPU: $cpu_usage%, Memory: $mem_usage%"
    
    # Check against thresholds
    if [ "$cpu_usage" -ge "$cpu_threshold" ] || [ "$mem_usage" -ge "$mem_threshold" ]; then
        log "WARN" "System resources critical - CPU: $cpu_usage%, Memory: $mem_usage%"
        return 1
    fi
    
    return 0
}

# Function to adjust timing based on conditions
adjust_timing() {
    local base_delay="$1"
    local multiplier=1
    
    # Check system resources
    if ! check_system_resources; then
        multiplier=$((multiplier + 1))
        log "INFO" "Increasing delay due to system load"
    fi
    
    # Check network conditions
    local total_latency=0
    local camera_count=0
    
    for feed in "${camera_feeds[@]}"; do
        local latency=$(measure_network_latency "$feed")
        total_latency=$((total_latency + latency))
        camera_count=$((camera_count + 1))
    done
    
    local avg_latency=$((total_latency / camera_count))
    
    # Adjust multiplier based on latency
    if [ "$avg_latency" -gt 100 ]; then
        multiplier=$((multiplier + 1))
        log "INFO" "Increasing delay due to network latency ($avg_latency ms)"
    fi
    
    # Calculate final delay
    local adjusted_delay=$((base_delay * multiplier))
    echo "$adjusted_delay"
}
