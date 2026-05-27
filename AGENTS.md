# AGENTS.md — displaycameras

Repository-local context for AI coding agents working in this repo.

## What This Repo Is

A Raspberry Pi system service for 24/7 multi-camera CCTV monitoring via hardware-accelerated `omxplayer`. It is a set of shell scripts—**not a compiled application**. There is no build step, package manager, or test suite.

## Architecture

```
/usr/bin/displaycameras          Main control script (start/stop/restart/repair/status)
/usr/bin/omxplayer_dbuscontrol   DBus bridge to control individual omxplayer instances
/usr/lib/displaycameras/*.sh     Sourced library modules (functions.sh, stream.sh, rotation.sh, service.sh, network.sh, system.sh, logging.sh, player.sh)
/etc/displaycameras/             Config files installed by install.sh
displaycameras.service           systemd unit file
```

### Key Library Modules

- `lib/player.sh` — `control_player()` is the *single chokepoint* for launching and repositioning omxplayer windows. It calculates on-screen vs off-screen placement using `DISPLAY_SEQUENCE` and `window_positions[]`. Also handles stopping off-screen streams during rotation via `stop_stream()` and `camera_offscreen_state[]` to save GPU memory.
- `lib/rotation.sh` — `rotate_displays()` runs as a background loop. It increments `DISPLAY_SEQUENCE`, persists it to `/var/run/displaycameras.sequence`, then calls `control_player reposition` for every camera. After rotation, restarts any previously-off-screen cameras that moved on-screen.
- `lib/stream.sh` — `monitor_omxplayer_processes()` runs as a background health-check loop. Calls `check_stream_health()` then `repair_stream()` on failure. Also runs `cleanup_orphan_processes()` to remove zombie wrapper shells with no omxplayer.bin child.
- `lib/service.sh` — `repair_stream()` uses a lockfile (`/var/run/displaycameras.repair.lock`) to prevent concurrent repairs and retries up to 5 times. Also provides `kill_stream_process()` with graduated signal escalation (SIGINT→SIGTERM→SIGKILL) wrapped in timeouts to avoid GPU DMA lock hangs, plus `cleanup_dbus_files()` for DBus cleanup.
- `lib/functions.sh` — `validate_camera_config()` enforces: camera names must match `^[A-Za-z0-9_]+$`, feeds must start with `rtsp://`, and the `camera_names` and `camera_feeds` arrays must be the same length.

## Logging

### Log File

All operational logs go to `/var/log/displaycameras.log`. The `status` command writes console-only output (never to the log file).

### Log Levels

| Level | Value | Description |
|-------|-------|-------------|
| FATAL | 0 | Unrecoverable error, service cannot continue |
| ERROR | 1 | Action failed but service continues |
| WARN  | 2 | Potential problem, attention may be needed |
| INFO  | 3 | Normal operational messages |
| DEBUG | 4 | Detailed trace for troubleshooting |

### Usage

```bash
info "message"                     # normal operational
warn "message"                     # potential issue
error "message"                    # action failure
debug "message"                    # only when debug=true in config
fatal "message"                    # unrecoverable
log_event "action" "key" "val"    # structured key=value event
log_stream_action "action" "cam"  # camera-specific structured event
```

### Structured Logging

Key lifecycle points emit machine-parseable `key=value` entries:

```bash
log_stream_action "stream.start" "FF" "position" "0 0 1200 1080" "window" "0"
log_event "stream.repair.success" "camera" "FF" "attempt" "2"
log_event "rotation.rotate" "sequence" "2"
log_event "service.start"
log_event "stream.cleanup.kill" "camera" "BY"
log_event "stream.stop.force" "camera" "FG"
log_event "stream.cleanup.duplicate" "camera" "SF"
```

### Log Rotation

`/etc/logrotate.d/displaycameras` rotates logs daily, keeps 7 days, compresses with `delaycompress`. Uses `copytruncate` to avoid service restart.

### Runtime Level Control

- Set `debug="true"` in `displaycameras.conf` → enables DEBUG level
- Set `LOG_LEVEL=2` environment variable → shows only WARN and above
- Default: INFO (level 3)

## Configuration

Two files live in `/etc/displaycameras/` (the install script copies them there):

1. `displaycameras.conf` — Global settings:
   - `blank="true"` — blanks screen with `fbi` before starting streams
   - `rotate="true"` + `rotatedelay=70` — enables rotation with 70s delay
   - `displaydetect=true` — auto-detects monitor resolution via `fbset` and loads matching `layout.conf.<RES>`
   - `omx_timeout=30` — omxplayer network timeout
   - `startsleep=6` — seconds to sleep between starting each camera stream
   - `debug="true"` — enables debug logging to `/var/log/displaycameras.log`

2. `layout.conf.default` (or `layout.conf.1920x1080`, etc.):
   - Defines `camera_names`, `camera_feeds`, `window_positions` (format: `"x1 y1 x2 y2"`), and `rotate`
   - If `displaydetect=true`, the service will attempt to generate a new `layout.conf.<RES>` from the default layout by scaling window positions

**Critical constraint:** `camera_names` length must match `camera_feeds` length. Names must contain only `A-Z`, `a-z`, `0-9`, `_`.

## How to Run / Verify

No build step. Scripts are executed directly.

```bash
# Install (copies files to system paths, sets up systemd service)
sudo ./install.sh

# Manual service control
sudo systemctl {start|stop|restart|status} displaycameras
sudo /usr/bin/displaycameras {start|stop|restart|repair|status}

# Check logs
tail -f /var/log/displaycameras.log

# Test a single RTSP stream manually
omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp "rtsp://..." --live -n -1 --timeout 30

# Validate configuration syntax
bash -n /etc/displaycameras/displaycameras.conf
bash -n /etc/displaycameras/layout.conf.default
```

## Operational Gotchas

- **Requires root:** All scripts and the systemd service run as root. `omxplayer_dbuscontrol` checks `EUID` and exits if not root.
- **omxplayer deprecation:** `omxplayer` was removed from Raspberry Pi OS after Bullseye. If on Bullseye or newer, legacy firmware libraries must be manually installed first. The README details this.
- **DBus addresses:** Each omxplayer instance registers at `org.mpris.MediaPlayer2.omxplayer.<camera_name>`. `omxplayer_dbuscontrol` uses these addresses.
- **PID state files:** The service writes PID files to `/var/run/displaycameras.*`. If these become stale, the service may misreport its status.
- **Repair lockfile:** `/var/run/displaycameras.repair.lock` prevents concurrent repairs attempts. If a repair crashes, this lockfile may need manual removal.
- **Display sequence persistence:** `DISPLAY_SEQUENCE` is saved to `/var/run/displaycameras.sequence` so rotation state survives restarts.
- **Stream health:** `check_stream_health()` checks both DBus `Playing` status *and* whether the playback position is advancing (catches frozen streams).
- **GPU memory:** `install.sh` sets `gpu_mem` via `raspi-config`. Too little GPU memory causes omxplayer to fail.

## What Not to Touch

- Do not rename `omxplayer_dbuscontrol` — the main script and libraries invoke it by exact name.
- Do not change the DBus naming convention in `player.sh` without updating `omxplayer_dbuscontrol` to match.
- The `window_positions` array is the *source of truth* for screen geometry in `layout.conf.default`. The display-detect feature (in `displaycameras` main script) generates other resolution layouts by scaling these coordinates with `bc`.
- `lib/functions.sh` sources all other modules. Adding a new library requires adding it there.

## Testing

There is no automated test suite. Changes should be validated manually:

1. Run `bash -n` on any modified script to check for syntax errors.
2. Run `sudo /usr/bin/displaycameras status` to verify the service reports correctly.
3. Run `sudo /usr/bin/displaycameras restart` and monitor `/var/log/displaycameras.log` for a few rotation cycles.
4. For RTSP feed issues, test the URL directly with the omxplayer command in the README Troubleshooting section.

## Raspberry Pi Bookworm aarch64 Note

This system runs Debian 12 (Bookworm) aarch64. `omxplayer` was removed after Bullseye and requires 32-bit armhf libraries that are not shipped in Bookworm. Here is how it was set up on this machine:

1. **Added armhf architecture** — `sudo dpkg --add-architecture armhf`
2. **Added bullseye armhf repos** — `raspi.list` (raspberrypi.org bullseye) and `debian bullseye` repos for armhf dependencies
3. **Cloned oldstable firmware** — `git clone --depth 1 --branch oldstable https://github.com/raspberrypi/firmware`
4. **Copied firmware libraries** — `/opt/vc/lib/` contents from `oldstable/opt/vc/lib/`
5. **Created soname symlinks** — e.g. `libmmal_core.so.0 → libmmal_core.so`
6. **Added `/opt/vc/lib` to ldconfig** — created `/etc/ld.so.conf.d/vc.conf`, ran `ldconfig`
7. **Installed omxplayer .deb** — force-installed the bullseye armhf `.deb`
8. **Installed armhf dependencies** — `libdbus-1-3`, `libfreetype6`, `libasound2`, `libpcre3`, `libstdc++6`, `libgcc-s1`, the full `libavcodec58`/`libavformat58`/`libavutil56`/`libswresample3` chain, and `libraspberrypi0`
9. **Ran `sudo ./install.sh -y --skip-reboot`** — to install the displaycameras service itself

The service is now active (`systemctl status displaycameras`).
Logs are at `/var/log/displaycameras.log`.
