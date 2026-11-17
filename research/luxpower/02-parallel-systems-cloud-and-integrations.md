# LuxPower SNA Parallel Systems: Cloud API, Local Polling and Integrations

Research date: 2026-11-17
Scope: three LuxPower SNA (SNA 3000/4000/5000/6000 WPV) inverters in parallel, read by a Raspberry Pi for a 24/7 wall display with system totals and per-inverter detail.

Confidence markers used below:
- **[Verified]**: stated in a primary source (manual, project README/docs).
- **[Community]**: forum or user report, plausible but not authoritative.
- **[Unverified]**: inference or missing primary confirmation; check on the real hardware.

---

## 1. How LuxPower SNA parallel systems work

### 1.1 Topology
- SNA series supports **up to 16 units** in single-phase or three-phase parallel. **[Verified, SNA 3-6K manual 2025-10]** (A separate Luxpower ACS guide gives 10, but that is a different product line.)
- Every inverter needs **its own PV input**. PV strings must never be shared. **[Verified]**
- Inverters are linked by **parallel communication cables** (RJ45, "Parallel" ports) plus DIP switches. Error codes reference a **CAN** link between units ("E008 CAN communication error in Parallel System"). **[Verified]**
- LCD settings per inverter: *Parallel type* (`NoPL` / `1PH` / `3PH`), *Parallel phase* (`P1/P2/P3`), and *Bat Share* (enable when all units share one battery bank). **[Verified]**
- **Master/slave:** the manual's error list includes "No master in parallel system" and says "there should be one master in the system", so one unit acts as master. Luxpower's hybrid parallel guide calls these "Primary" and "Subordinates". Installers set this in the portal or app. **[Verified/Community]** SNA users report that LCD settings alone were enough to get parallel *operation* working. They also report that a setting changed on one unit propagates to the others, which shows the parallel link is working. **[Community, powerforum]**
- Shared battery: with *Bat Share* on, all inverters see the same bank. The battery BMS (CAN/RS485) is normally cabled to the master. **[Unverified for SNA specifically; typical Lux practice]**
- Forum advice: use **two** parallel comms cables in a ring (not one). If one unit drops, for example during a firmware update, the others then don't raise comms errors. **[Community]**

### 1.2 Monitoring hardware: one dongle per inverter
- Each SNA ships with its own Wi-Fi module. The manual's monitoring setup is: *"Setup the monitor for the system, add all dongles in one station"* → enable share battery → *"Set the system as a parallel group in the monitor system"*. **[Verified]**
- So **each of the 3 inverters has its own dongle** (its own datalog serial and its own IP on the LAN). Each dongle uploads that inverter's data only.
- Forum reports say setting up the **parallel group in the portal needs an installer account**, or a request to Luxpower support (e.g. supportsa@luxpowertek.com in South Africa). The portal parallel setting is for **monitoring only**. It is not needed for the inverters to run in parallel. **[Community]**

### 1.3 Who reports system totals?
- **Locally (Modbus registers via dongle or RS485): each inverter reports only its own values.** No source documents a register set on the master holding parallel-system totals. Solar Assistant says *"With Luxpower inverters you will need to connect each inverter with its own cable"* and sums the units itself. **[Verified for SA; "no totals register" is Unverified]**
- HA users note that **some entities appear only on the master** in parallel mode. Examples are battery/BMS-derived and grid-CT values, because the BMS and CT are cabled to the master. **[Community]** Battery SOC/voltage are bank-wide when *Bat Share* is enabled, so take them from one unit (normally the master). **Do not sum** them.
- **In the cloud**, the "parallel group" is an aggregation the server does. The web portal shows a group row ("Parallel") plus each member, and the API has a dedicated aggregated endpoint (`getInverterEnergyInfoParallel`, see §2). **[Verified via pylxpweb docs + manual screenshot]**

**Implication for the display:** sum PV, load, grid, and charge/discharge power and energy across the three units yourself. Take battery SOC/V from the master (or average them as a sanity check). Show grid/CT values from whichever unit has the CT.

### 1.4 Practical gotchas when polling three dongles
| Gotcha | Detail | Source/confidence |
|---|---|---|
| **Single local client per dongle** | Sharing one dongle or RS485 line between apps (e.g. HA plus a Pi script, or lxp-bridge plus Solar Assistant) causes interleaved responses and corruption. Pick **one** local poller per dongle. | pylxpweb README [Verified] |
| **Cloud and local share the dongle** | The dongle serves the cloud upload and the local TCP client at the same time without clearly separating them. Occasional "response mismatch" frames are expected, and clients must detect them and retry. | pylxpweb README [Verified] |
| **Encrypted dongles (E-WIFI ENC / firmware v3+)** | Newer dongles encrypt the protocol. Port 8000 may open and then reset. Solar Assistant's SNA page says dongle firmware **>2.07 is unsupported** and suggests asking Luxpower for a rollback to 2.07. Its **2026 changelog** says it now supports "Luxpower WiFi dongles over Bluetooth, and over the network on V3 and later firmware, which encrypts the connection". Most open-source tools (lxp-bridge, luxpower-modbus-hacs, pylxpweb dongle transport) do **not** support ENC dongles. | SA docs vs SA changelog **[Contradictory: SA docs page likely stale]**; ant0nkr README; pylxpweb README |
| **Firmware version is not a reliable guide** | Check the dongle *type* in the Lux cloud ("E-WIFI" vs "E-WIFI ENC"). Support has reportedly switched the type on request. | ant0nkr README [Verified]; Telegram claim [Unverified] |
| **Dongle wedges after bad probes** | Malformed probes or port scans can leave a dongle refusing connections until a cold restart (inverter plus dongle power-cycled). Reserve DHCP IPs, and don't port-scan. | ant0nkr README [Verified, user-reported recovery] |
| **Polling speed** | WiFi dongle reads are slow. EG4 Web Monitor defaults to **30 s** over the dongle and 5 s over RS485/Modbus TCP. luxpower-modbus-hacs defaults to **60 s**. Polling 3 dongles every 10-30 s is reasonable. Sub-5 s is asking for trouble. | eg4_web_monitor README, ant0nkr README [Verified defaults] |
| **RS485 port vs dongle** | On many units the RS485 port and dongle can't be used at once. SA notes a cabled connection may require unplugging the dongle, which also loses cloud upload. | SA RS485 page [Verified] |
| **Write endurance** | Repeated writes (e.g. automations toggling settings) can wear inverter EEPROM. A read-only display is unaffected. | HA forum [Community] |
| **Per-inverter entity naming** | When running one integration instance per inverter, use a prefix/serial per unit or entity IDs collide. | HA forum [Community] |

---

## 2. LuxPower cloud / web monitoring API ("WManage")

Unofficial and reverse-engineered. The best current documentation is `docs/api/LUXPOWER_API.md` in **joyfulhouse/pylxpweb**.

### 2.1 Base URLs (same paths on all)
| Region | Base URL |
|---|---|
| China / legacy default | `https://server.luxpowertek.com` |
| Europe | `https://eu.luxpowertek.com` |
| Americas | `https://na.luxpowertek.com` |
| US (Luxpower) | `https://us.luxpowertek.com` |
| Asia Pacific | `https://sea.luxpowertek.com` |
| Middle East & Africa | `https://af.luxpowertek.com` |
| EG4 (US) | `https://monitor.eg4electronics.com` |

Use the server where the account was registered. Accounts are region-specific. South African SNA owners typically use `af.` (or historically `server.`). **[Verified list; regional mapping partly Unverified]**

### 2.2 Authentication
- `POST /WManage/api/login`, form-encoded `account=<user>&password=<pass>`.
- Response sets a `JSESSIONID` cookie (`Path=/WManage`) that must be sent on every later call.
- The session lasts about **2 hours**. Re-login on 401/403 or proactively, and clear the cookie jar before re-auth.

### 2.3 Useful endpoints (all `POST`, form-encoded, cookie required)
| Purpose | Endpoint | Key params |
|---|---|---|
| List stations/plants | `/WManage/web/config/plant/list/viewer` | paging |
| Device hierarchy incl. **parallel groups** | `/WManage/api/inverterOverview/getParallelGroupDetails` | `plantId` |
| Inverter overview list | `/WManage/api/inverterOverview/list` | `plantId` (returns `isParallelEnabled`) |
| **Per-inverter realtime** | `/WManage/api/inverter/getInverterRuntime` | `serialNum` → `ppv`, `soc`, `vBat`, `pCharge`, `pDisCharge`, `batShared`, `isParallelEnabled`, … (scaled ints: V ÷10, Hz ÷100, energy ÷10) |
| Per-inverter energy (today/total) | `/WManage/api/inverter/getInverterEnergyInfo` | `serialNum` |
| **Parallel-group aggregated energy** | `/WManage/api/inverter/getInverterEnergyInfoParallel` | `serialNum` (any member) |
| Battery / BMS modules | `/WManage/api/battery/getBatteryInfo` | `serialNum` |
| Read holding registers remotely | `/WManage/web/maintain/remoteRead/read` | `inverterSn`, `startRegister`, `pointNumber` |

I found no documented *runtime* (power) aggregate endpoint for the parallel group, only the energy one. For live system power, sum the three `getInverterRuntime` results. **[Unverified whether a hidden parallel-runtime endpoint exists; the web UI may compute it client-side]**

### 2.4 Refresh rate, rate limits, reliability, ToS
- **Data freshness:** pylxpweb notes "values update every 5-30 s on device side". Integrations default to **30 s** (pylxpweb HA forum post) to **120 s** (eg4_web_monitor README) for cloud polling. I did not find an official Luxpower upload interval. Other brands' dongles upload every ~5 min, but Lux dongles appear to push much more often. **[Unverified exact interval; observe `deviceTime` in runtime responses to measure]**
- **Rate limits:** none documented. pylxpweb recommends TTL caching (runtime 20 s, battery 5 min, discovery 15 min) plus exponential backoff (1 s → 60 s) and a circuit breaker. For 3 inverters, ~3-4 requests per 30-60 s is well within what the HA integrations do.
- **Reliability:** this depends on internet uptime and on Luxpower's servers in China and regional clouds. Historical outages and slow periods have been reported anecdotally. **[Community]** The cloud also keeps working when local access is blocked by encrypted dongles, which is its main strength for SNA owners on new dongle firmware.
- **ToS:** this is an **unofficial, undocumented** API. pylxpweb's disclaimer says it "communicates with the official API using the same endpoints as the official web interface". I found no Luxpower developer program or explicit permission. Automated scraping may breach the portal's terms, and endpoints can change without notice. **[Unverified ToS text; I could not retrieve luxpowertek.com in this session]** Keep polling modest, use your own account, and keep credentials only on the Pi.

### 2.5 Open-source projects using the cloud API
- **pylxpweb** (Python, async, MIT, actively maintained; 0.9.40 stable Aug 2026, 0.10.0 betas Nov 2026). Its object model is `Station → ParallelGroup → Inverter / BatteryBank`. It supports cloud, WiFi dongle, RS485 Modbus, and **hybrid** (local plus cloud fallback). Its docs list FlexBOSS/18kPV/12kPV/XP/LXP. **SNA is not explicitly listed** **[Unverified compatibility; runtime endpoints are generic so cloud mode likely works]**.
- **EG4 Web Monitor** (joyfulhouse/eg4_web_monitor, HA custom integration via HACS, built on pylxpweb; HA ≥ 2026.1). It supports Luxpower endpoints and parallel groups.
- Older and other projects: `eg4_inverter_ha` (twistedroutes, the predecessor), and various "LuxPower Cloud" HACS forks. These are not individually verified here.

### 2.6 Cloud vs local: pros and cons
| | Cloud API | Local (dongle TCP 8000 / RS485) |
|---|---|---|
| Works with encrypted (ENC/v3) dongles | **Yes** | Mostly no (Solar Assistant now claims yes) |
| Parallel-group aggregation | Server-side group + energy aggregate | DIY summing |
| Latency / refresh | ~30-120 s typical | 5-30 s |
| Internet dependency | Yes | No |
| Interference with dongle | None | Risk of mismatched frames and dongle lock-ups; one client only |
| Stability of interface | Can change without notice; unofficial | Modbus register map is stable per firmware |
| Hardware needed | None | None (dongle) or RS485 adapter per inverter |

---

## 3. Ecosystem integrations that give a ready-made data source

| Option | How it talks to SNA | Parallel / 3 units | Output the Pi can read | Notes |
|---|---|---|---|---|
| **Solar Assistant** (commercial, runs on a Pi or now Docker) | RS485 cable per inverter, WiFi dongle (network, now incl. V3 encrypted per 2026 changelog), Bluetooth, or Modbus TCP gateway | **Yes**: multi-select one USB port per inverter. It computes totals and per-inverter values | **MQTT** (`solar_assistant/...` with totals and `inverter_1..n`), **REST API**, **WebSocket API**, Cloud API; HA via MQTT discovery | SNA 3000-6000 officially listed ("Connects as luxpower"). The most turnkey option. Could itself be the Pi driving the display (it has a "Video output" mode). One-off licence fee. |
| **Home Assistant + EG4 Web Monitor** (pylxpweb) | Cloud, dongle, RS485/Modbus TCP, hybrid | Station → Parallel Group → Inverter hierarchy | HA REST/WebSocket API, or HA → MQTT/InfluxDB | Best open-source cloud option. SNA support not explicitly claimed. |
| **Home Assistant + luxpower-modbus-hacs** (ant0nkr) | Local dongle TCP 8000 (E-WIFI only, not ENC) | One config entry per inverter/dongle | HA entities | Default 60 s polling. Good troubleshooting docs. |
| **lxp-bridge** (celsworth, Rust) | Local dongle TCP 8000 | `inverters:` list, one entry per dongle (host, serial, datalog) | **MQTT** (+ HA discovery), **InfluxDB**, Postgres/MySQL/SQLite | **Unmaintained**. The maintained fork is **jaredmauch/eg4-bridge** (focus: InfluxDB v1). Doesn't support ENC dongles. Publishes per-inverter topics only, so totals must be computed downstream. |
| **InfluxDB + Grafana** | Fed by lxp-bridge/eg4-bridge, HA, Solar Assistant (older SA versions shipped Grafana; the Nov 2026 beta replaces it with native charts) | Depends on feeder | Grafana kiosk page, or the Pi queries InfluxDB | Good for history and trends on the wall display. Grafana kiosk in Chromium is an easy display layer. |
| **OpenLux** (f-garofalo) | RS485 bridge (ESP-based) | Per-inverter | MQTT/HA | Mentioned by luxpower-modbus-hacs as the RS485 route for ENC-dongle owners. **[Not researched in depth]** |

**Ready-made sources the Pi could just read** (no direct inverter talk): Solar Assistant MQTT/REST/WebSocket, HA REST/WebSocket API (`/api/states`), an MQTT broker fed by lxp-bridge/eg4-bridge/SA, or InfluxDB. If the user already runs any of these, the display should **subscribe to it** rather than open a second connection to the dongles (single-client rule).

---

## 4. Recommendation for a 24/7 wall display (3 × SNA in parallel)

**Decision tree**

1. **Something already polls the inverters** (Solar Assistant, HA, or lxp-bridge): have the Pi read from that (MQTT subscribe is best: push-based, low overhead, survives restarts with retained messages). Don't poll the dongles a second time.
2. **Nothing in place, and you want maximum robustness:** **RS485 per inverter → Solar Assistant (or an open-source Modbus poller) → MQTT → display.** A wired RS485 link to each SNA gives 5 s updates and no internet dependency, and it isn't affected by dongle firmware or encryption. Solar Assistant already handles Luxpower parallel summing. The trade-off is that SA notes the RS485 port may conflict with the dongle, so you may lose the Lux cloud/app unless the unit allows both. Check on the actual units.
3. **Nothing in place and you want zero hardware:** check the dongle type in the Lux portal.
   - **E-WIFI (unencrypted):** local TCP via lxp-bridge/eg4-bridge (MQTT/InfluxDB) or pylxpweb dongle transport, one client per dongle, polling every 15-30 s. Watch for dongle lock-ups and use a watchdog that reconnects with backoff.
   - **E-WIFI ENC:** use the **cloud API via pylxpweb** (or Solar Assistant's newer V3 support), polling `getInverterRuntime` ×3 every 30-60 s plus `getInverterEnergyInfoParallel` every few minutes. Accept a 30-120 s lag and internet dependency.
4. **Hybrid fallback (recommended in a custom Pi app):** local as the primary source, cloud as the fallback when a dongle stops responding. pylxpweb has a "hybrid" transport built for this.

**Why:** a wall display must degrade gracefully. Local wired RS485 avoids the three biggest failure modes found in this research: dongle firmware encryption, dongle lock-ups under concurrent access, and cloud or internet outages. MQTT decouples the display from the poller, so a display restart never touches the inverters. Whatever the source, the display must **sum power and energy across the 3 units itself** and take **battery SOC/voltage once** (shared bank). Show per-unit "last update" timestamps and a stale-data indicator.

---

## Open questions / to verify on site
- Dongle type (E-WIFI vs E-WIFI ENC) and firmware for all three units.
- Whether SNA RS485 ("MPPT485/CT" port on older units) and the Wi-Fi dongle can be used at the same time on this firmware.
- Which unit holds the BMS and CT connections (it determines where battery and grid values come from).
- Whether the cloud account has a parallel group configured (it may need installer or support help).
- The actual cloud refresh cadence (watch the `deviceTime` field over several polls).
- Luxpower portal Terms of Service regarding automated access (luxpowertek.com could not be fetched in this session).

## Sources
- Luxpower SNA 3-6K User Manual (2025-10-22): https://luxpowertek.com/wp-content/uploads/2025/10/SNA-3-6K-User-Manual-25.10.22.pdf
- Luxpower SNA 3-6K User Manual (2024-07-12): https://luxpowertek.com/wp-content/uploads/2024/07/SNA-3-6K-User-Manual-2024.07.12.pdf
- Lux Power Hybrid Parallel Install Manual: https://cdn.shopify.com/s/files/1/0536/3964/3304/files/Lux-Power-Hybrid-Parallel-Install-Manual.pdf
- Luxpower Hybrid Parallel Connection Guidance: https://luxpowertek.com/wp-content/uploads/2022/02/Hybrid-Parallel-Connection-Guidance.pdf
- Luxpower ACS Parallel Connection: https://luxpowertek.com/wp-content/uploads/2022/02/ACS-Parallel-Connection.pdf
- Powerforum, "Luxpower SNA 5000 Parallel set up": https://powerforum.co.za/topic/25799-luxpower-sna-5000-parallel-set-up/
- Powerforum, "Luxpower SNA 5000 Raspberry Pi/MQTT": https://powerforum.co.za/topic/12303-luxpower-sna-5000-raspberrypimqtt/
- pylxpweb on PyPI: https://pypi.org/project/pylxpweb/
- pylxpweb API reference (LUXPOWER_API.md): https://github.com/joyfulhouse/pylxpweb/blob/main/docs/api/LUXPOWER_API.md
- EG4 Web Monitor (HA integration): https://github.com/joyfulhouse/eg4_web_monitor
- HA Community, EG4/Luxpower Web Monitor thread: https://community.home-assistant.io/t/integration-eg4-luxpower-web-monitor-home-assistant-integration/929930
- luxpower-modbus-hacs (ant0nkr): https://github.com/ant0nkr/luxpower-modbus-hacs
- HA Community, "Luxpower Inverter Integration": https://community.home-assistant.io/t/luxpower-inverter-integration/911796 (and ?page=2, ?page=3)
- HA Community, "Luxpower ac inverter integration?" (parallel entity notes): https://community.home-assistant.io/t/luxpower-ac-inverter-integration/283656?page=16
- lxp-bridge: https://github.com/celsworth/lxp-bridge and wiki https://github.com/celsworth/lxp-bridge/wiki ; config example https://raw.githubusercontent.com/celsworth/lxp-bridge/master/config.yaml.example
- eg4-bridge (maintained fork): https://github.com/jaredmauch/eg4-bridge
- OpenLux: https://github.com/f-garofalo/openlux
- Solar Assistant, Luxpower SNA: https://solar-assistant.io/help/inverters/luxpower/SNA-5000
- Solar Assistant, SNA RS485: https://solar-assistant.io/help/inverters/luxpower/SNA/rs485
- Solar Assistant, SNA WiFi dongle: https://solar-assistant.io/help/inverters/luxpower/SNA/dongle
- Solar Assistant changelog: https://solar-assistant.io/help/updates/changelog
- Luxpower WL Link Dongle manual: https://luxpowertek.com/wp-content/uploads/2025/10/WL-Link-Dongle-User-Manual-Communication-Dongle-Luxpowertek-1.pdf

### Contradictions / caveats flagged
- **Solar Assistant dongle support:** the SNA dongle page says firmware >2.07 is unsupported, but the changelog (2026) adds V3+ encrypted dongle support. The changelog is newer, but check it with the user's SA version.
- **Max parallel units:** SNA manual says 16; an ACS guide says 10 (different product).
- **Cloud refresh interval:** no official figure. Integration defaults range from 30 s to 120 s.
- **pylxpweb SNA support:** not explicitly listed; cloud endpoints are model-agnostic, so it probably works but is unverified.
- **No local "system totals" register:** I found no documentation of one. This is inferred from Solar Assistant needing one cable per inverter and from HA user reports.
