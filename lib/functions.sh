#!/bin/bash

# Source all function modules
source "/usr/lib/displaycameras/logging.sh"
source "/usr/lib/displaycameras/stream.sh"
source "/usr/lib/displaycameras/network.sh"
source "/usr/lib/displaycameras/system.sh"
source "/usr/lib/displaycameras/rotation.sh"
source "/usr/lib/displaycameras/service.sh"

# Define PID files and global variables
PIDFILE="/var/run/displaycameras.pid"
ROTATE_PIDFILE="/var/run/displaycameras.rotate.pid"
MONITOR_PIDFILE="/var/run/displaycameras.monitor.pid"
DISPLAY_SEQUENCE_FILE="/var/run/displaycameras.sequence"
