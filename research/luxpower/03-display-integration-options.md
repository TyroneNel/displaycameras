# 03 — Display Integration Options for a LuxPower Dashboard

*Research date: 2026-11-17. Scope: how to get a live solar/battery panel (3 parallel LuxPower inverters) onto the same HDMI screen as the `displaycameras` omxplayer tiles. Data acquisition from the inverters is only touched on here; see the other reports in this folder for protocol details.*

---

## TL;DR

**Recommendation: Option B. Render the dashboard as a low-frame-rate H.264 RTSP stream, served locally by MediaMTX, and add it to `camera_feeds` as one more "camera" (for example `LUXPOWER` → `rtsp://127.0.0.1:8554/luxpower`).**

- It needs **no changes to the display path**. `validate_camera_config()` accepts it because it is `rtsp://`. `control_player()`, rotation, `check_stream_health()`, `repair_stream()` and `stop_stream()` all work on it unchanged.
- Everything new runs as **native aarch64** user space (Python + Pillow, Debian `ffmpeg`, MediaMTX arm64 binary). Nothing new depends on the fragile armhf `/opt/vc` DispmanX/OpenMAX stack. Options A and D do depend on it.
- With more cameras than windows, the extra feed **does not add a concurrent GPU decoder**, because off-screen cameras are stopped (`stop_stream`).
- Cost: roughly one extra software H.264 encode of a mostly static image at 2–5 fps, plus 1–3 s of display latency. Neither matters for data that is polled every 10–30 s.

**Runner-up (Option C):** draw straight into `/dev/fb0`. The console framebuffer sits *under* all omxplayer layers, so this works, but only in screen space that no camera window covers. The current layouts tile the whole 1920×1080 screen, so you would first have to shrink the camera windows to free a "status strip". It is cheap, native, and good for a thin ticker bar. It is a poor fit for a full tile.

**Not recommended:** Option A (`pngview`/`omxiv` on DispmanX). It needs armhf builds against deprecated, archived tools, cannot hot-reload the image, and depends on the legacy firmware display stack. Option D (omxplayer subtitles/OSD) is not feasible for live text.

A later phase can add **"pinned window"** support, so the dashboard stays in one fixed tile instead of rotating through the large main window. That is a small, contained change to `camera_display_rank()` (sketched below).

---

## 1. What the codebase constrains (verified from source)

| Fact | Where | Implication |
|---|---|---|
| Every player is launched by `omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --win "$position" "$camera_feed" --live -n -1 --timeout … --dbus_name org.mpris.MediaPlayer2.omxplayer.$camera_name` | `lib/player.sh` `control_player start` | Any new tile that is "just a feed" goes through the existing chokepoint with no edits. No `--layer` is passed, so all videos sit on **DispmanX layer 0** (omxplayer default). |
| Feeds must match `^rtsp://`; names must match `^[A-Za-z0-9_]+$`; `camera_names` and `camera_feeds` must be the same length | `lib/functions.sh` `validate_camera_config` | An `http://`/HLS/file feed is rejected. An RTSP dashboard passes. |
| `camera_display_rank = (idx - DISPLAY_SEQUENCE + n) % n`; rank < `${#window_positions[@]}` means on-screen | `lib/player.sh` | **Every camera rotates through every window**, including the large main window `"0 0 1200 1080"`. There is no pinning today. |
| Off-screen cameras are **stopped** (DBus `quit`, then `kill_stream_process`) and restarted when they rotate back on | `control_player reposition`, `rotate_displays` | A 5th feed with 4 windows keeps the **concurrent decoder count at 4**. GPU memory and decoder budget stay the same. The dashboard player is restarted each time it comes on-screen, so the stream must start fast (short GOP). |
| `check_stream_health` = DBus `PlaybackStatus == Playing` **and** `Position` advancing over 2 s | `lib/service.sh` | The dashboard stream must emit frames continuously. A "push only on change" stream would look frozen and trigger repairs. |
| `repair_stream` uses a **global** lock dir, up to 5 attempts, and runs `check_network_connectivity` (ping + `nc` to host:port from the URL) first | `lib/service.sh`, `lib/network.sh` | `127.0.0.1:8554` parses fine. **Caveat:** if MediaMTX is up but nobody is publishing, the TCP check passes, all 5 attempts fail, and the global lock **blocks camera repairs for about a minute**. See §6. |
| `displaycameras stop`/`handle_signal` run `pkill -f "omxplayer"`; process matching elsewhere uses `pgrep -f "omxplayer.*$camera_name"` (substring) | `displaycameras`, `lib/service.sh`, `lib/stream.sh` | Dashboard helper processes must not contain "omxplayer" in their command line. Pick a camera name that is not a substring of another name (`LUXPOWER`, not `PV`). |
| systemd unit is `KillMode=control-group` | `displaycameras.service` | Anything launched *from* displaycameras is killed on every restart. The dashboard pipeline should be its **own unit(s)**, so a camera-service restart does not tear down the publisher. |
| `blank=true` runs `fbi -T 2 … black.png` at start/stop | `displaycameras` | Relevant to Option C: `fbi` owns VT2 and draws to the framebuffer. |
| The cron job runs `displaycameras repair` every minute | `repaircameras.cron` | It applies to the dashboard feed too. |
| Display: framebuffer console, no X/Wayland. `displaydetect` uses `fbset -s` geometry | `displaycameras`, README | Confirms a console/DispmanX setup with no desktop compositor. |

### 1.1 Display stack on this Pi (important, partly unverified)

- Raspberry Pi's Bookworm transition paper says the firmware "legacy" graphics stack was replaced by KMS/DRM, and that only KMS is *supported* in Bookworm. Community reports say `vc4-fkms-v3d` behaves like full KMS on late Bullseye/Bookworm. [1][2]
- omxplayer only renders through the firmware (DispmanX/OpenMAX) path. On this Pi it works (AGENTS.md says the service is active), so the Pi is almost certainly booting **without** `dtoverlay=vc4-kms-v3d`, using the firmware framebuffer (`bcm2708_fb`) and HVS/DispmanX. That is an unsupported but functioning configuration. [2][3]
- The omxplayer README says OpenMAX is "unsupported on 64-bit kernels". Yet this box is aarch64 and runs the armhf omxplayer. Presumably the 32-bit VCHIQ compat path works. **Uncertain. Treat the whole omxplayer layer as fragile, and avoid adding new dependencies on it.** [4]
- **Verify on the Pi before choosing A or C:**
  ```bash
  grep -nE 'dtoverlay|kms|framebuffer' /boot/firmware/config.txt
  ls /dev/dri 2>/dev/null; cat /proc/fb          # expect "BCM2708 FB" without KMS
  fbset -s                                         # geometry + depth (16 or 32 bpp)
  vcgencmd dispmanx_list                           # lists layers; omxplayer = layer 0, fb = -127
  cat /proc/device-tree/model; uname -m
  ```
- Pi model: Bookworm aarch64 + omxplayer rules out a Pi 5 (no legacy stack, no H.264 hardware decoder). This is a Pi 3/4/Zero 2 class device. CPU estimates below assume a Pi 4. **Unverified.**

---

## 2. Option A — Render a PNG and show it on a DispmanX layer (`pngview`, `omxiv`, `fbi`, omxplayer-still)

**How it would work:** a Python/Pillow (or ImageMagick/rsvg) job writes `dash.png` every N seconds. An overlay program puts it on a DispmanX layer above layer 0 at fixed x/y.

| Tool | Findings |
|---|---|
| **pngview** (raspidmx) | `pngview [-b RGBA] [-d display] [-l layer] [-x] [-y] [-t ms] [-n] [-a alpha] file.png`. **Default layer is 1**, which is above omxplayer's 0, so it overlays the videos. The image is **loaded once at startup**. There is no reload; reading stdin (`-`) also happens only once. Updating means kill and relaunch (a brief flash) or patching the code. The repo is **no longer maintained**, and its README says "the DispmanX API is no longer supported in recent versions of Raspberry Pi OS". [5][6] |
| **omxiv** | OpenMAX image viewer with `--win` and `--layer`. **Archived May 2023, deprecated, and does not work on arm64** (no OpenMAX libs). It would need an armhf build. There is no reload either. [7] |
| **fbi** | Draws to the *framebuffer* (layer −127), not a DispmanX layer, so it is really Option C. It is already used for blanking. It is full-screen-oriented, so it cannot place an image in a sub-region. |
| **omxplayer showing a still** | omxplayer decodes video only, not PNG. You could encode the PNG to a short looping MP4 and play it with `--loop`, but every data update would need a re-encode and player restart. Option B does the same job properly. |

**Layer ordering:** the console fb is −127, omxplayer is 0 (no `--layer` is passed), and the overlay goes on ≥1. An overlay at layer ≥1 **covers** whatever camera sits beneath it. With rotation moving cameras through every window, the overlay needs its own window that no camera ever occupies, which requires pinning or layout changes anyway. [8][9]

**Bookworm aarch64 problems:**
- `pngview`/`omxiv` link against `libbcm_host`/`libvcos`/`libvchiq_arm` from `/opt/vc/lib`, which here are **armhf only**. You would need an armhf cross-build (e.g. `gcc-arm-linux-gnueabihf` plus `/opt/vc/include` headers from the legacy firmware/userland tree) and armhf `libpng16-16`. **Unverified that the oldstable firmware branch ships the headers; it may need the `raspberrypi/userland` repo.**
- It only works while the firmware DispmanX stack is active. A future switch to KMS kills it at the same moment it kills omxplayer.

**Verdict:** technically possible, but it adds a second dependency on a dead API, needs custom armhf builds, and still requires pinning work. **Not recommended.**

---

## 3. Option B — Dashboard as a live RTSP "camera" (recommended)

### 3.1 Pipeline

```
LuxPower dongles (x3, TCP :8000)          ┌──────────── luxpower-dashboard.service ────────────┐
   ──► collector (Python, asyncio) ──► state dict ──► renderer (Pillow, WxH RGB frames @ N fps) │
                                                          │ stdout raw rgb24                        │
                                                          ▼                                         │
                                         ffmpeg -f rawvideo … -c:v libx264 … -f rtsp ───────────────┘
                                                          │ rtsp://127.0.0.1:8554/luxpower (publish)
                                              mediamtx.service (RTSP server, :8554)
                                                          │ (read, TCP)
                     displaycameras ── control_player start ── omxplayer --win … rtsp://127.0.0.1:8554/luxpower
```

- **MediaMTX** is a single static binary with arm64 builds. Its default `rtspAddress` is `:8554`. It can run the publisher itself through `runOnInit` + `runOnInitRestart: yes`, which restarts the command if it exits. It also supports `runOnDemand`, which starts the publisher only when a reader connects and sends it SIGINT when no readers remain. [10][11]
  - **Prefer `runOnInit` (always on).** When the dashboard rotates off-screen, `stop_stream` disconnects omxplayer. With on-demand mode, each on-screen return would also pay publisher cold-start time, which pushes against `startsleep`/health checks.
- **Why not `ffmpeg -rtsp_flags listen` with no server?** It accepts a single client and exits when that client disconnects. That breaks on every rotation, stop, or repair. A real server decouples publisher and player.
- **Why pipe raw frames instead of `-loop 1 -i dash.png`?** The image2 demuxer may or may not re-read the file on each loop (**unverified**). A Python process that writes frames to ffmpeg's stdin at a fixed rate is deterministic, avoids half-written PNGs, and gives one process to supervise.

### 3.2 Suggested encoder settings (starting point; measure on the Pi)

```bash
ffmpeg -hide_banner -loglevel warning \
  -f rawvideo -pix_fmt rgb24 -s 1280x720 -r 5 -i - \
  -c:v libx264 -preset ultrafast -tune zerolatency,stillimage \
  -profile:v main -pix_fmt yuv420p -bf 0 -g 10 -keyint_min 10 \
  -x264-params repeat-headers=1 \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/luxpower
```

- **Frame rate:** 2–5 fps. Data changes every ~10 s, but `check_stream_health` needs `Position` to advance within a 2 s window, and omxplayer's `--live` mode behaves better with a steady cadence. Very low rates (≤1 fps) are a known risk with omxplayer/live buffering, and I found **no** confirmed reports of 1 fps working well. 5 fps is a safe default; try 2 fps once it works. [12]
- **GOP ≤ 2 s** (`-g 10` at 5 fps) plus `repeat-headers=1`, so a freshly restarted omxplayer (after rotation back on-screen or a repair) gets SPS/PPS and an IDR frame quickly.
- **Resolution:** with `--win`, omxplayer defaults to *stretch* aspect. [4] The dashboard is shown at 1200×1080 in the main window and 720×360 in small tiles (current example layout), so a single rendering will be distorted in one of them. Use either a layout that holds up under stretching (big numerals, no circles), or **pin** it (§5.2) and render at exactly that window's size.
- **Software vs hardware encode:** `h264_v4l2m2m` (Pi 4 bcm2835-codec) exists. However, it competes with the 4 omxplayer decodes for the same VideoCore codec block and GPU memory. libx264 `ultrafast` on a mostly static 720p image at 5 fps should use only a few % to ~10–15% of one Cortex-A72 core (P-frames are almost all skip blocks). **This is an estimate; measure it with `top`/`pidstat`.** Rendering with Pillow only when data changes (then re-sending the cached frame) keeps Python cost negligible.
- **Latency:** about 1–3 s through ffmpeg → MediaMTX → omxplayer `--live` buffering, plus omxplayer start time (2–6 s) after each on-screen return. That does not matter next to a 10–30 s poll interval. Show a **"data age"** field on the dashboard so stale data is obvious.

### 3.3 Pros and cons

| Pros | Cons |
|---|---|
| No display-path code changes; it reuses validated, battle-tested plumbing | Adds two services (MediaMTX + publisher) and one more omxplayer start/stop cycle per rotation |
| All-native arm64 user space (Pillow, ffmpeg, MediaMTX). Nothing new touches `/opt/vc` | Rotation puts the dashboard in the main window and the small tiles in turn (stretch issue). Pinning fixes this |
| Health checking, repair, logging (`stream.start`, `stream.repair.*`) come for free | Repair-lock starvation if the publisher is down (§6) |
| Survives a future migration away from omxplayer (any player can show RTSP) | Some CPU for encoding (small) |
| Dashboard can be viewed remotely too (VLC → `rtsp://pi:8554/luxpower`) | MediaMTX is not in Debian apt; install a pinned release tarball |

---

## 4. Option C — Draw straight into `/dev/fb0`

- On the firmware stack the Linux console framebuffer is composited at **DispmanX layer −127**, below omxplayer's layer 0. Anything written to `/dev/fb0` (Python `mmap` + Pillow/NumPy, or `fbi`) is **visible only where no video window covers it**. Writing to fb0 does not disturb omxplayer, and omxplayer does not disturb the fb. [8][9]
- **Prerequisite:** the current layouts (`layout.conf.default.example`, `layout.conf.1920x1080.example`) tile the full 1920×1080. You must give up screen area, e.g. shrink the four windows to the top 1920×960 and keep a 1920×120 status strip. Note that `generate_layout_file()` scales `window_positions` by `max_x2/max_y2`. If the windows no longer reach the bottom edge, the inferred source height becomes 960 and **scaling to other resolutions will be wrong**. That logic would need a `layout_source_resolution` override (not in "What Not to Touch", but it is a behaviour change).
- **Practical issues:**
  - Match the fb pixel format (`fbset -s`; legacy is often **16 bpp RGB565** unless `framebuffer_depth=32`).
  - The console on VT1 (cursor blink, kernel messages, getty) will scribble over the strip. Use `consoleblank=0 vt.global_cursor_default=0`, `echo 0 > /sys/class/graphics/fbcon/cursor_blink`, `setterm --cursor off`, quiet kernel log, and redraw periodically.
  - `fbi -T 2` (blanking) switches to VT2 and repaints the whole fb on start/stop. The writer must redraw after that. Run it as its own unit and redraw every refresh.
  - It depends on `/dev/fb0` geometry matching the HDMI mode. That holds here, since `displaydetect` already relies on `fbset`.
  - Under KMS the fb is emulated, and omxplayer would be dead anyway.
- **Verdict:** a solid, very cheap choice for a **thin always-visible status bar** (SOC %, PV kW, grid ±kW, load kW). It is complementary to Option B. It is not suited to a rotating tile.

---

## 5. Option D — omxplayer subtitles / OSD

- `--subtitles <file.srt>` (UTF-8 SRT), `--font-size` (1/1000 of screen height), `--align`. DBus only offers `ListSubtitles`/`SelectSubtitle`/`ShowSubtitles`/`HideSubtitles`. There is **no DBus method to set arbitrary text**. [4]
- Subtitles are loaded at start and timed against media PTS. A live RTSP stream has no stable timeline to put cue times on, and changing text means restarting the player. The OSD only shows player status, and `--no-osd` is passed deliberately (it also avoids known grey-screen issues).
- Subtitles/OSD render through OpenVG from the same armhf `/opt/vc` stack. **Unverified whether `libbrcmOpenVG` is even present/working in this install.**
- **Verdict: not feasible** for live data.

---

## 6. Recommended integration design (Option B, phased)

### 6.1 Phase 1: zero display-code changes

Only config and packaging change. The user adds the feed to the layout file:

```bash
# /etc/displaycameras/layout.conf.default (and the per-resolution copy)
camera_names=(FF FG SF BY LUXPOWER)
camera_feeds=( "rtsp://…/1" "rtsp://…/2" "rtsp://…/3" "rtsp://…/4" "rtsp://127.0.0.1:8554/luxpower" )
camera_timeouts=(45 45 45 45 20)
```

With 5 cameras and 4 windows, one camera is always off-screen and stopped, so concurrent decodes stay at 4. `DISPLAY_SEQUENCE` wraps at 5, and the dashboard takes each window in turn, including the main one.

### 6.2 Phase 2: `lib/luxpower.sh` with auto-append and pinning

New module, sourced from `lib/functions.sh` (AGENTS.md: "Adding a new library requires adding it there"). Also add it to the `for lib in …` existence check in `displaycameras`. `install.sh` already copies every `lib/*.sh`.

**New keys in `displaycameras.conf`:**

```bash
# LuxPower dashboard tile
luxpower_enabled="false"
luxpower_camera_name="LUXPOWER"                      # must not be a substring of another camera name
luxpower_feed="rtsp://127.0.0.1:8554/luxpower"
luxpower_timeout=20
luxpower_window=""            # empty = rotate like a camera; N = pin to window_positions[N]
luxpower_stale_after=120      # seconds; warn + on-screen banner if data older than this
```

Inverter connection settings (hosts, ports, serials, poll interval, render size/fps) live in a separate **`/etc/displaycameras/luxpower.conf`** (or YAML/TOML) read only by the Python collector:

```bash
luxpower_hosts=("192.168.1.51:8000" "192.168.1.52:8000" "192.168.1.53:8000")
luxpower_poll_interval=10
luxpower_render_size="1200x1080"   # match the pinned window
luxpower_fps=5
```

The collector should **not** source shell config with arbitrary code. Parse it as `key=value` or use a TOML file.

**`lib/luxpower.sh` responsibilities:**

1. `luxpower_inject_camera()` is called right after the layout is sourced and **before** `validate_camera_config`. When `luxpower_enabled=true` and the name is not already present, it appends `luxpower_camera_name`/`luxpower_feed`/`luxpower_timeout` to `camera_names`/`camera_feeds`/`camera_timeouts`. Layout files and `generate_layout_file()` stay untouched. It must run before the `camera_timeouts` backfill and the `cameras`/`max_seq` computation in `displaycameras`.
2. `luxpower_publisher_ready()` checks `systemctl is-active --quiet luxpower-dashboard` and/or the MediaMTX API (`api: yes` → `GET http://127.0.0.1:9997/v3/paths/get/luxpower`, `ready: true`). **Verify the API path against the pinned MediaMTX version.** It is used to short-circuit `repair_stream` for the dashboard, so a missing publisher does not hold the **global repair lock** for 5 attempts × (startsleep + health) ≈ 60 s+ while real cameras wait. Add one guarded line near the top of `repair_stream` (or in the monitor loop) that skips the dashboard index with `warn`/`log_event "luxpower.publisher.down"` when not ready.
3. `luxpower_check_staleness()` is called from `monitor_omxplayer_processes` every N loops. It reads `/run/luxpower/state.json` (`updated_at`) written by the collector, and on staleness emits `warn` + `log_event "luxpower.data.stale" "age" "$age"`. **Stream health ≠ data health:** the frames keep advancing even when the inverters are unreachable, so this check is the only thing that catches a dead collector.

**Pinning (optional): change `camera_display_rank()` only**, keeping it the single source of truth:

```bash
camera_display_rank() {
    local idx="$1" n=${#camera_names[@]}
    [ "$n" -eq 0 ] && { echo 0; return 1; }
    local pin_idx="${LUXPOWER_PIN_IDX:-}"        # set by lib/luxpower.sh, empty when not pinned
    local pin_win="${luxpower_window:-}"
    if [ -z "$pin_idx" ] || [ -z "$pin_win" ] || [ "$n" -lt 2 ]; then
        echo $(( (idx - DISPLAY_SEQUENCE + n) % n )); return 0
    fi
    if [ "$idx" -eq "$pin_idx" ]; then echo "$pin_win"; return 0; fi
    local m=$(( n - 1 ))
    local j=$(( idx > pin_idx ? idx - 1 : idx ))  # compact index without the pinned camera
    local r=$(( (j - DISPLAY_SEQUENCE % m + m) % m ))
    (( r >= pin_win )) && r=$(( r + 1 ))          # skip the pinned window slot
    echo "$r"
}
```

- `rotate_displays` still wraps `DISPLAY_SEQUENCE` at `n`. With modulo `m = n−1`, one step per cycle is a no-op (sequence `n−1 ≡ 0`). That is acceptable, or the wrap can be made `m` when pinned.
- `seq_step`/`max_seq` checks stay valid.
- `reposition_all` will issue a harmless `setvideopos` to the pinned player each rotation. You can skip it in `control_player reposition` when the rank is unchanged, but that is not required.
- Validate `luxpower_window < ${#window_positions[@]}` at startup.
- The DBus name convention (`org.mpris.MediaPlayer2.omxplayer.<name>`) and `omxplayer_dbuscontrol` are untouched.

### 6.3 New files

| Path (repo) | Installed to | Purpose |
|---|---|---|
| `lib/luxpower.sh` | `/usr/lib/displaycameras/luxpower.sh` | Inject/pin/health helpers (Phase 2) |
| `luxpower/luxpower_dashboard.py` | `/usr/lib/displaycameras/luxpower/` | asyncio collector for 3 inverters → aggregated state → Pillow renderer → raw frames on stdout (or spawns ffmpeg itself) |
| `luxpower/mediamtx.yml` | `/etc/displaycameras/mediamtx.yml` | `rtspAddress: :8554`, bind/allow localhost, one path `luxpower` with `runOnInit: /usr/lib/displaycameras/luxpower/run-publisher.sh`, `runOnInitRestart: yes` (or publish from the dashboard unit instead) |
| `luxpower.conf.example` | `/etc/displaycameras/luxpower.conf` | Hosts, poll interval, render size, fps (preserved on reinstall, like the other configs) |
| `mediamtx.service`, `luxpower-dashboard.service` | `/etc/systemd/system/` | Separate units, so `KillMode=control-group` on displaycameras does not kill them |

**Aggregation note for 3 parallel inverters:** PV, load, grid import/export and inverter output are **summed** across units. In a parallel system the battery bank is usually shared, so take SOC from the master unit or average it, and do **not** sum it. Show per-inverter mini-rows so a dropped dongle is visible. **Check your system's wiring (shared vs separate banks).** The dongles speak the LuxPower TCP protocol on port 8000. Community projects (lxp-bridge; the maintained fork eg4-bridge) document it and can publish to MQTT. Reports of dongle firmware closing port 8000 immediately also exist. [13][14][15]

**Collector design options:** (a) talk to the dongles directly in Python, or (b) run `lxp-bridge`/`eg4-bridge` → MQTT and have the renderer subscribe. (b) keeps protocol code out of this repo, but adds a broker. Note that the dongle may allow **only a limited number of concurrent TCP clients**, so one collector must own the connection. **Unverified; see the protocol report.**

### 6.4 systemd

```ini
# luxpower-dashboard.service (sketch)
[Unit]
Description=LuxPower dashboard renderer/publisher
After=network-online.target mediamtx.service
Wants=network-online.target
Requires=mediamtx.service
[Service]
Type=simple
ExecStart=/usr/lib/displaycameras/luxpower/luxpower_dashboard.py --config /etc/displaycameras/luxpower.conf
Restart=always
RestartSec=5
Nice=10                       # keep encode below omxplayer/control loops
CPUQuota=40%                  # safety cap; tune after measuring
RuntimeDirectory=luxpower     # /run/luxpower/state.json
[Install]
WantedBy=multi-user.target
```

- `displaycameras.service` may add `Wants=luxpower-dashboard.service` + `After=` (optional). Ordering is not critical, because the repair loop and cron retry, but it shortens the first-start failure window.
- Run as a dedicated non-root user if possible. Only displaycameras needs root.

### 6.5 install.sh changes

- apt packages (native arm64): `python3`, `python3-pil`, `ffmpeg`, `fonts-dejavu-core` (or another TTF), optionally `python3-paho-mqtt` (MQTT route) and `curl` (MediaMTX API probe).
- MediaMTX: download a **pinned** `mediamtx_vX.Y.Z_linux_arm64.tar.gz` (arm64v8) from GitHub releases, verify its checksum, and install to `/usr/local/bin/mediamtx`. It is not in Debian apt. Gate all of this behind a `--with-luxpower` flag, or behind `luxpower_enabled`, so existing installs are unaffected.
- Copy `luxpower/` files, install units, preserve `/etc/displaycameras/luxpower.conf` using the same backup-don't-overwrite logic used for the other configs, and run `systemctl enable mediamtx luxpower-dashboard`.
- **GPU memory:** unchanged if the dashboard rotates with cameras > windows. If pinned, concurrent decodes go up by 1 only when the number of on-screen windows increases. Re-check `gpu_mem=256` with 5 simultaneous decodes.

### 6.6 Testing checklist (per AGENTS.md)

1. `bash -n lib/luxpower.sh lib/player.sh displaycameras`.
2. Off-Pi: `ffplay rtsp://pi:8554/luxpower` / VLC to check the stream, cadence and GOP.
3. On the Pi: `omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp --live -n -1 --timeout 20 --win "0 0 1200 1080" rtsp://127.0.0.1:8554/luxpower`. Check start time and that `omxplayer_dbuscontrol LUXPOWER getposition` advances.
4. `sudo displaycameras restart`. Watch `/var/log/displaycameras.log` through more than one full rotation cycle: `stream.stop` on off-screen, restart on-screen, no repair loops.
5. Kill the publisher. Confirm repairs skip or time out without starving camera repairs, and that `luxpower.data.stale`/publisher-down events are logged.
6. Measure CPU (`pidstat -p $(pgrep -d, -f 'ffmpeg|luxpower|mediamtx') 5`) and `vcgencmd get_mem gpu`.

---

## 7. Comparison matrix

| Criterion | A: pngview/omxiv | **B: RTSP stream** | C: /dev/fb0 | D: subtitles/OSD |
|---|---|---|---|---|
| Display-code changes | Pinning/layout + new launcher | **None (Phase 1)** | Layout shrink + scaling fix | n/a |
| Depends on armhf `/opt/vc` | Yes (new build) | No (reuses omxplayer only) | No | Yes |
| Live updates | Restart per update (flash) | Smooth | Smooth | No |
| Works with rotation | Needs reserved slot | **Yes, natively** | Needs reserved area | n/a |
| Health/repair | Custom | **Existing** | Custom | n/a |
| CPU | Very low | Low (x264 still image) | Very low | — |
| Survives move away from omxplayer | No | **Yes** | Partly | No |
| Best use | — | **Full tile** | Thin status bar | — |

---

## 8. Uncertainties / things to verify

1. **Display driver mode** on this Pi (no KMS overlay assumed). Run the commands in §1.1.
2. **omxplayer with low-fps live RTSP** (2–5 fps): no direct evidence either way. Test 5 fps first.
3. **CPU cost** of libx264 at the chosen size/fps: estimate only.
4. **MediaMTX API path/version** for the readiness probe; pin a release and check `mediamtx.yml` defaults for that version.
5. **image2 `-loop 1` re-reading an updated PNG**: unverified, so the design avoids it.
6. **Header availability for armhf pngview builds** (Option A only).
7. **LuxPower dongle concurrency / port-8000 behaviour** and whether the 3 inverters share one battery bank.
8. **Pi model** (assumed Pi 4).

---

## Sources

1. Raspberry Pi Ltd, *Transitioning from Bullseye to Bookworm* (white paper): https://pip-assets.raspberrypi.com/categories/1261-transitioning/documents/RP-006519-WP-1-Transitioning%20from%20Bullseye%20to%20Bookworm.pdf
2. RetroPie forum, Bookworm / FKMS discussion: https://retropie.org.uk/forum/post/295959 and https://retropie.org.uk/forum/topic/37208/retropie-doesn-t-load-games-on-manual-installation-in-raspberry-pi-os-bookworm-64-bit
3. MagicMirror forum, omxplayer works without `vc4-kms-v3d`: https://forum.magicmirror.builders/topic/8774/omxplayer-with-open-gl
4. omxplayer README (options `--layer`, `--win`, `--subtitles`, DBus API, 64-bit note): https://github.com/popcornmix/omxplayer
5. raspidmx README (pngview; DispmanX unsupported in recent OS; unmaintained): https://github.com/AndrewFromMelbourne/raspidmx
6. pngview source (options, default layer 1, load-once): https://raw.githubusercontent.com/AndrewFromMelbourne/raspidmx/master/pngview/pngview.c
7. omxiv (archived, no arm64): https://github.com/HaarigerHarald/omxiv
8. Raspberry Pi DispmanX layering notes (fb at layer −127; draw at n+1 over omxplayer): https://raspberry-projects.com/pi/programming-in-c/display/dispmanx-api/dispmanx-api-general and https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/53722977/render-gui-above-omxplayer-on-raspberry-pi-3
9. Overlay over omxplayer example (fox / fb copy to layer): https://www.github.com/fernandorpardo/DispmanX and https://peanball-net.pages.dev/2016/09/raspberrypi-video-overlay-omxplayer-kivy
10. MediaMTX: https://github.com/bluenviron/mediamtx
11. MediaMTX default config (`rtspAddress :8554`, `runOnInit`, `runOnDemand`): https://raw.githubusercontent.com/bluenviron/mediamtx/main/mediamtx.yml
12. Reports on omxplayer RTSP delays/buffering (indirect): https://redlib.librenode.com/r/raspberry_pi/comments/1k363a4/rtsp_feed_with_rpi_zero_2w and https://github.com/chrippa/livestreamer/issues/455
13. lxp-bridge wiki (port 8000, MQTT): https://github.com/celsworth/lxp-bridge/wiki and https://github.com/celsworth/lxp-bridge/wiki/MQTT-Publishes
14. eg4-bridge (maintained fork): https://gh.r-mj.com/jaredmauch/eg4-bridge
15. Home Assistant community, LuxPower integration / port-8000 dongle issues: https://community.home-assistant.io/t/luxpower-ac-inverter-integration/283656
