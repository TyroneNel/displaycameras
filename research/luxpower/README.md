# LuxPower SNA Integration — Research Index

Goal: pull live data from **3 LuxPower SNA inverters running in parallel** on the LAN and show it on the displaycameras screen.

| # | Report | Covers |
|---|--------|--------|
| 01 | [Local protocol & registers](01-local-protocol-and-registers.md) | Wi-Fi dongle TCP:8000 protocol (A1 1A frames, CRC16), input/holding register map with scaling, SNA specifics, open-source projects, RS485 fallback |
| 02 | [Parallel systems, cloud & integrations](02-parallel-systems-cloud-and-integrations.md) | Master/slave behaviour, per-inverter polling & aggregation, unofficial cloud API, Solar Assistant / Home Assistant / MQTT options |
| 03 | [Display integration options](03-display-integration-options.md) | How to put a dashboard on screen alongside omxplayer tiles; recommended architecture for this repo |

## Key findings

- **No system-wide totals locally.** Each inverter has its own dongle and reports only its own data. The Pi must poll all three, **sum** power/energy values, and read battery SOC/voltage **once** (shared bank). Register 113 identifies the master.
- **Local TCP (port 8000) is the primary data path,** but it is not standard Modbus TCP. Caveats:
  - Only **one local client per dongle**. A second client (e.g. Home Assistant + the Pi) causes cross-talk.
  - **Encrypted dongles ("E-WIFI ENC", firmware v3+)** reject local connections. LuxPower support can switch them to plain "E-WIFI".
  - Don't port-scan dongles; they can hang until power-cycled.
- **Fallbacks:**
  - The unofficial cloud API (via pylxpweb). It is session-cookie based and polled every 30–120 s; its terms of service are unverified.
  - RS485 per inverter (19200 8N1).
  - Solar Assistant, which officially supports parallel SNA and offers MQTT.
- **Display: render the dashboard as an RTSP stream.**
  - Python/Pillow renders the dashboard, ffmpeg encodes it (2–5 fps) and a local MediaMTX server publishes it at `rtsp://127.0.0.1:8554/luxpower`.
  - It is added as another entry in `camera_feeds`, so it passes `validate_camera_config` and reuses the existing rotation, health and repair code unchanged.
  - Option: drawing straight to `/dev/fb0` suits a thin status bar only.
- **Code follow-ups identified:**
  - Optional "pinned window" support in `camera_display_rank()`, so the dashboard isn't rotated into windows of different shapes.
  - Readiness check so a down publisher doesn't hold the shared repair lock.
  - Separate data-staleness check.

## Proposed architecture (not yet implemented)

```
3x dongle :8000 ──► luxpower-collector (Python, polls + aggregates, writes JSON)
                         │
                         ▼
               luxpower-dashboard (Pillow → ffmpeg → MediaMTX rtsp://127.0.0.1:8554/luxpower)
                         │
                         ▼
               displaycameras: camera "LUXPOWER" in camera_feeds (existing omxplayer pipeline)
```

New pieces:
- **Files:** `lib/luxpower.sh` (sourced from `functions.sh`) and the collector and dashboard scripts.
- **Config keys:** `luxpower_enabled`, `luxpower_hosts`, `luxpower_window` and others.
- **Services:** separate systemd units for MediaMTX and the dashboard.
- **`install.sh` dependencies:** `python3-pil`, `ffmpeg`, fonts and a pinned MediaMTX release.

## Open questions to confirm on site

- Exact SNA model, plus the dongle type and firmware (plain or encrypted) for each unit.
- Whether anything else (Home Assistant, Solar Assistant) already polls the dongles.
- Pi model and display driver mode (legacy vs fkms vs KMS).
- Whether register 24 (EPS/backup output) matches house load on this install.
