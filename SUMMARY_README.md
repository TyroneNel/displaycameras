# DisplayCameras Application Summary

This document provides a detailed, step-by-step explanation of the `displaycameras` application, covering its functionality, components, and operational flow.

## Core Purpose

The `displaycameras` application is a robust system designed for continuous, multi-camera CCTV monitoring on a Raspberry Pi. It uses `omxplayer` for low-overhead video playback and features a sophisticated shell script framework for managing streams, handling failures, and rotating camera views on screen.

## File-by-File Breakdown

### Main Executables & Scripts

-   **`/usr/bin/displaycameras`**: The main control script and service entry point. It handles the `start`, `stop`, `restart`, `repair`, and `status` commands. It's responsible for initializing the environment, loading configurations, and launching the various processes (streams, rotation, monitoring).

-   **`omxplayer_dbuscontrol`**: A critical utility script that acts as a bridge to control `omxplayer` instances. Since `omxplayer` runs in the background, this script uses the DBus messaging system to send commands to specific player instances (e.g., `play`, `pause`, `quit`, `setvideopos`). It is customized to target the uniquely named DBus addresses that the `displaycameras` script assigns to each stream, allowing for individual control.

-   **`rotatedisplays`**: A standalone script that provides an alternative, simpler rotation mechanism. It runs in a loop, sleeping for a specified time and then calling the main `displaycameras` script with the `rotate` or `rotaterev` command. It appears to be a legacy or alternative method for rotation, as the primary rotation logic is now built into the main service via the `rotate_displays` function.

-   **`install.sh`**: The installation script responsible for setting up the application, placing files in their correct locations (`/usr/bin`, `/usr/lib/displaycameras`, `/etc/displaycameras`), and installing the systemd service.

### Configuration Files

-   **`/etc/displaycameras/displaycameras.conf`**: The **main configuration file**. This is where the user defines the core settings:
    -   `camera_names`: An array of short, descriptive names for each camera.
    -   `camera_feeds`: An array of RTSP or other stream URLs, corresponding to the `camera_names`.
    -   `rotate`: Set to `"true"` to enable the automatic rotation feature.
    -   `rotatedelay`: The number of seconds between each rotation cycle.
    -   Other operational parameters like `startsleep`, `omx_timeout`, and `blank`.

-   **`/etc/displaycameras/layout.conf.default`** and **`layout.conf.1920x1080`**: These are **layout configuration files**. They define the `window_positions` array, which specifies the screen coordinates (`x1 y1 x2 y2`) for each video window. The main script loads `layout.conf` if it exists, otherwise it falls back to `layout.conf.default`. This allows for different screen layouts to be saved and used.

### Systemd and Cron Files

-   **`displaycameras.service`**: The systemd unit file. This file tells the system's service manager how to start, stop, and manage the `displaycameras` script as a background service, enabling it to start automatically on boot.

-   **`repaircameras.cron`**: A cron job definition that runs the command `/usr/bin/displaycameras repair` every minute. This provides a scheduled, fallback mechanism to ensure that any failed camera streams are detected and restarted, complementing the real-time monitoring process.

-   **`displaycameras.logrotate`**: The logrotate configuration file. It manages the log file at `/var/log/displaycameras.log`, preventing it from growing indefinitely by rotating it (archiving and compressing the old log) on a regular basis.

### Library Functions (`/usr/lib/displaycameras/`)

This directory contains the modular shell script libraries that provide the core logic.

-   **`functions.sh`**: The central library file that simply sources all the other function modules (`logging.sh`, `stream.sh`, etc.) to make them available to the main script.
-   **`logging.sh`**: Provides standardized logging functions (`log`, `info`, `warn`, `error`) that write timestamped messages to `/var/log/displaycameras.log`.
-   **`stream.sh`**: Manages the lifecycle of camera streams. Contains `start_stream` to launch `omxplayer` instances and `monitor_omxplayer_processes` to periodically check stream health.
-   **`rotation.sh`**: Contains the core logic for the camera rotation feature. The `rotate_displays` function runs as a background process, looping continuously to shift the camera positions.
-   **`service.sh`**: Handles service-related tasks, including PID file management (`write_pid_file`, `cleanup_pid_files`), stream health checks (`check_stream_health`), and the primary `repair_stream` logic.
-   **`network.sh`**: Provides network utility functions like `check_network_connectivity` and `measure_network_latency` to diagnose connection issues before attempting to restart a stream.
-   **`system.sh`**: Includes functions for monitoring system health (`check_system_resources`) and adjusting rotation delays based on CPU/memory load and network latency (`adjust_timing`).

## Step-by-Step Operational Flow

1.  **Service Start (`displaycameras start`)**:
    1.  The systemd service manager (or a user) runs `/usr/bin/displaycameras start`.
    2.  The script loads the `displaycameras.conf` and a `layout.conf` file.
    3.  It sources all functions from the `/usr/lib/displaycameras/` directory.
    4.  It kills any old `omxplayer` processes to ensure a clean slate.
    5.  It iterates through the `camera_feeds` array and calls `start_stream` for each one. `start_stream` launches `omxplayer` with a unique DBus name (e.g., `org.mpris.MediaPlayer2.omxplayer.Camera1`) and sets its initial window position based on the `window_positions` array.
    6.  If `rotate` is enabled, it calls `start_rotation`, which launches the `rotate_displays` function in the background.
    7.  It launches the `monitor_omxplayer_processes` function in the background to begin periodic health checks.

2.  **The Rotation Process (`rotate_displays` function)**:
    1.  This function, running in the background, enters an infinite loop.
    2.  It sleeps for the `rotatedelay` period. This delay is dynamically adjusted based on system load and network latency.
    3.  It increments a global `DISPLAY_SEQUENCE` counter, which acts as an offset.
    4.  It then loops through each active camera stream. For each camera, it calculates a new target window position by adding the `DISPLAY_SEQUENCE` offset to the camera's original index.
    5.  It uses `omxplayer_dbuscontrol setvideopos` to command the specific `omxplayer` instance to instantly move to its new screen coordinates.
    6.  The new sequence number is saved to a file, so the state persists across restarts.

3.  **Monitoring and Repair**:
    -   **Real-time**: The `monitor_omxplayer_processes` loop runs continuously, calling `check_stream_health` for each camera. If a stream is found to be unhealthy, it triggers the `repair_stream` function.
    -   **Scheduled**: The `repaircameras.cron` job runs every minute, executing `/usr/bin/displaycameras repair`. This command also calls `check_stream_health` and triggers `repair_stream` for any failed streams, providing a redundant safety net.
    -   **Repair Logic (`repair_stream`)**: When a stream fails, this function first checks network connectivity to the camera. If the network is reachable, it quits the failed `omxplayer` instance and attempts to restart it by calling `start_stream` again.
