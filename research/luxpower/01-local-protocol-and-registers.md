# LuxPower SNA: local data access, protocol and register map

Research date: 2026-11-17
Purpose: let a Raspberry Pi (Debian 12 Bookworm, aarch64) read live data from three
LuxPower SNA inverters running in parallel on the home LAN, and show it on screen.

Confidence markers used below:

- **[V]**: verified in two or more independent sources, or in working source code read for this report.
- **[S]**: single source.
- **[U]**: unverified or contradictory. Test it on the real hardware before relying on it.

---

## 0. TL;DR

1. **Use the WiFi dongle's local TCP server on port 8000.** Each SNA has its own
   datalogger dongle (serial like `BA12345678` / `DG...`). On a compatible dongle,
   port 8000 speaks LuxPower's proprietary `A1 1A` framed protocol. That protocol
   wraps Modbus-style read-input (0x04), read-hold (0x03) and write-single (0x06)
   requests. It is **not** standard Modbus TCP, so `modpoll`/`pymodbus` against port 8000 will fail. [V]
2. **Poll each of the three inverters separately.** Use its own dongle IP, its own
   10-char dongle serial and its own 10-char inverter serial. Every mature tool takes
   a list of inverters (lxp-bridge `inverters:` list, one HA config entry per
   inverter, and so on). Totals across the parallel bank must be summed by the
   client. Input register 113 reports master/slave role and parallel count. [V]
3. **Read 4 to 5 input-register blocks of 40** (0-39, 40-79, 80-119, 120-159,
   160-199). Newer firmware accepts blocks of up to about 125. Values are uint16
   little-endian in the TCP payload. 32-bit counters are split L/H across consecutive registers. [V]
4. **Main risk is dongle firmware / variant.** Dongles the LuxPower cloud labels
   **"E-WIFI ENC"** (encrypted) and reportedly 3.x firmware reset connections on 8000.
   **"E-WIFI"** (unencrypted) 2.x firmware up to v2.12 is reported working.
   LuxPower support can switch ENC to non-ENC on request. Ethernet dongles reportedly
   expose no local server at all. [V community reports, U for exact firmware boundaries]
5. **Plan on one local client per dongle.** The dongle keeps serving the LuxPower cloud
   while you poll it. A second *local* client (for example HA plus your Pi script) causes
   evictions and cross-routed replies. [V]
6. **Fallback: RS485.** Wire into each inverter's RS485 port (Modbus RTU, 19200 8N1
   per the protocol doc). Each inverter needs its own cable or channel. On many units the
   port is shared with the dongle, so the dongle must be unplugged. [V for 19200, U for per-SNA port naming]

**Recommended stack for the Pi:** pick one.

- A small Python poller of your own. About 150 lines: asyncio sockets plus the frame
  format in section 2, modelled on `ant0nkr/luxpower-ha-integration`'s
  `lxp_request_builder.py` and `lxp_response.py`, MIT licensed.
- `lxp-bridge` / `eg4-bridge`, publishing to MQTT. The display subscribes to MQTT.

Both handle multiple inverters.

---

## 1. How LuxPower exposes data locally

### 1.1 The datalogger dongle

- Each inverter carries a WiFi (or GPRS/Ethernet) "datalogger" dongle. It is an
  Espressif/MXCHIP (MiCO OS) device. Out of the box it is a **TCP client** to the
  LuxPower cloud: older units default to `120.79.53.27:4346`, and region servers
  include `eu/na/sea/af.luxpowertek.com`. [V: lxp-bridge screenshot, issue logs]
- Older dongle firmware also has an embedded web UI at the dongle's LAN IP. Default
  login is `admin` / `admin`, and an English toggle sits at the top right. The
  **Network Setting** page has two slots:

  | Slot | Protocol | Port / address | Purpose |
  |---|---|---|---|
  | Network Connection 1 | `TCP Client` | Remote port `4346`, server `120.79.53.27` (or region host) | LuxPower cloud upload. Leave alone. |
  | Network Connection 2 | **`TCP Server`** | **Local port `8000`** | Local access for lxp-bridge, HA and so on. |

  Save, and the dongle reboots in a few seconds; the inverter keeps running. Port 8000
  then accepts local clients. Source: the lxp-bridge wiki "Inverter Setup" page and its
  `doc/lux_network_setting.png`, which shows exactly this two-slot layout.
  [V: also matches ant0nkr issue #69, where a user enabled the 2nd slot as TCP Server :8000 to fix "could not read model"]
- **Newer "E-WIFI" v2 dongles (firmware 2.03 to 2.12)** reportedly have *no* local web UI.
  Port 8000 is open by default and fixed. Contributors to ant0nkr issue #69 (Sep 2026)
  report v2.03, 2.07, 2.10 and 2.12 working on port 8000 without any configuration
  page; you only need a DHCP reservation. [S/U: community]
- The official LuxPower "Dongle Local Connect Guideline" (2024) covers only the phone
  app path: join the dongle's `B********` hotspot, then in LuxPowerView choose
  "LOCAL CONNECT", then "TCP Connect". It confirms a local TCP mode exists but never
  documents port 8000 or the frame format. LuxPower support has told integrators
  the dongle protocol is "not shareable". [V]

### 1.2 Firmware and variant caveats (important)

| Symptom | Cause (reported) | Fix (reported) |
|---|---|---|
| Port 8000 open, any request yields `Connection reset by peer` | Dongle is the **"E-WIFI ENC"** (encrypted) variant. Check *Configuration, then Dongles, then "Dongle Type"* on the LuxPower portal. | Ask LuxPower support to downgrade or disable encryption so the type shows "E-WIFI". [V: several users in ant0nkr #69, HA forum] |
| Same, with 3.x dongle firmware | 3.x reportedly disables local Modbus | Downgrade to 2.x via support. [U: forum claims only] |
| Port 8000 stops answering after `nmap` / modpoll / malformed probes | Dongle "locks" its server after unexpected traffic | Remove and reinsert the dongle (power-cycle). One user needed a full inverter cold start. Never port-scan it. [S/U: ant0nkr #69, README "Port 8000 connects, then resets"] |
| Local port is 4346 not 8000 | Slot 2 misconfigured | Set slot 2 to TCP Server :8000. [S: HA forum] |
| Large block reads fail | Old inverter firmware | Use 40-register blocks, not 125. [V: ant0nkr "Register Block Size" option] |
| Ethernet dongle | Exposes no local Modbus at all | Use RS485 (section 5). [S: Yippy in ant0nkr #69, diysolarforum] |

Firmware version alone does not reliably predict local capability; the ENC/non-ENC
dongle type is the better indicator (ant0nkr README).

### 1.3 Multiple clients and the cloud

- **Cloud and one local client coexist.** The dongle keeps uploading to the cloud while
  serving port 8000. However, it does not cleanly separate who asked what. Replies to
  cloud-originated requests are also pushed to the local socket, and vice versa. Expect
  unsolicited frames, and match replies by function + start register (+ inverter
  serial). pylxpweb logs "Response mismatch", and ant0nkr's discovery code explicitly
  "skips frames the dongle pushes". [V]
- **Do not run two local clients against one dongle.** pylxpweb's `dongle.py` says:
  > "The WiFi dongle sustains only ONE TCP client. A second client is accepted but
  > repeatedly evicted, sees cross-routed replies, and degrades the first client's poll cadence."

  The pylxpweb README says the same. Practically: if the user already runs Home
  Assistant or SolarAssistant on these dongles, either feed the Pi from that system
  (MQTT/HA API) or stop the other client. [V]
- A side effect, reported once: running SolarAssistant against the dongle stopped the
  LuxPower phone app updating until SA was halted (powerforum, 2023). [S]
- **Heartbeats:** the dongle sends `0xC1` heartbeat frames. Some clients echo them back:
  lxp-bridge does with `heartbeats: true`, as do paulsteigel's ESPHome component and
  andrew867's integration. Echoing is optional in lxp-bridge (default `false`). [V]
- lxp-bridge reconnects if no data arrives for 15 minutes (CHANGELOG). Plan the same
  idle-watchdog in a custom poller. [S]

---

## 2. Packet format (port 8000, "A1 1A" protocol)

All multi-byte header and length fields are **little-endian**. Register *values* in the
payload are also little-endian uint16. This differs from standard Modbus RTU on the wire,
which is big-endian.

### 2.1 Outer TCP header (20 bytes for translated-data frames)

| Offset | Len | Field | Notes |
|---|---|---|---|
| 0 | 2 | Prefix `A1 1A` | Magic |
| 2 | 2 | Protocol version | Requests: `01 00` (ant0nkr, pylxpweb) or `02 00` (paulsteigel ESPHome, lxp-bridge). Responses: typically `02 00`, sometimes `05 00`. [V, U: which is "correct" for requests, since both are reported to work] |
| 4 | 2 | Frame length | Bytes **after** this field = total_len − 6. A read request is `32` (0x20). |
| 6 | 1 | Address | Usually `0x01` |
| 7 | 1 | TCP function | `0xC1` heartbeat, `0xC2` translated data, `0xC3` read param, `0xC4` write param |
| 8 | 10 | Datalog (dongle) serial | ASCII, exactly 10 chars, for example `BA12345678` |
| 18 | 2 | Data length | Length of the data frame that follows, **including** the 2-byte CRC. 18 for a read request. |
| 20 | n | Data frame | See 2.2 |
| 20+n−2 | 2 | CRC16/Modbus | Covers **the data frame only** (from offset 20 up to the CRC), **not** the TCP header. Little-endian. |

Heartbeat example (lxp-bridge wiki): `a1 1a 02 00 0d 00 01 c1 <10-byte datalog> 00`

### 2.2 Inner data frame (`0xC2` translated data)

**Request (read input / read hold / write single):** 16 bytes, then CRC, so 38 bytes total.

| Offset in data frame | Len | Field |
|---|---|---|
| 0 | 1 | Action: `0x00` = request/write to inverter, `0x01` = reply from inverter |
| 1 | 1 | Device function: `0x03` read holding, `0x04` read input, `0x06` write single holding, `0x10` write multiple holding |
| 2 | 10 | Inverter serial (ASCII, 10 chars). A wrong serial gives CRC errors or no reply. |
| 12 | 2 | Start register (LE) |
| 14 | 2 | Read: register count (LE). Write single: value (LE). |
| 16 | 2 | CRC16/Modbus over bytes 0-15 |

**Response (read):** `action(1) func(1) serial(10) start_reg(2) byte_count(1) values(byte_count) CRC(2)`.
The 1-byte `byte_count` is present for protocol 2/5 replies; ant0nkr's parser also
heuristically handles protocol-1 replies with and without it. A device function of `>= 0x80`
is a Modbus exception, and the next byte is the exception code. [V: code]

**Worked example: read input regs 0-39** (dongle `BA12345678`, inverter `1234567890`):
```
A1 1A | 01 00 | 20 00 | 01 | C2 | "BA12345678" | 12 00 |
00 | 04 | "1234567890" | 00 00 | 28 00 | CRC_lo CRC_hi
```
CRC: standard Modbus CRC-16 (init 0xFFFF, poly 0xA001 reflected) over the 16 bytes
`00 04 "1234567890" 00 00 28 00`.

### 2.3 Read blocks

- lxp-bridge reads inputs as **4 blocks of 40**: 0-39, 40-79, 80-119, 120-159. It reads
  holdings 0-239 in blocks of 40. [V: source `coordinator/mod.rs`]
- paulsteigel's SNA ESPHome component reads **5 input banks**: 0-39 live, 40-79 totals,
  80-119 BMS, 120-159 generator/EPS L1/L2, 160-199 load power and load energy. [V: source]
- ant0nkr defaults to 125-register blocks, with 40 for old firmware. [V]
- Practical throughput: about 1.5 s per full poll cycle per inverter over the dongle. Users
  poll every 15-30 s. Polling much faster is not recommended. [S: ivanfmartinez in ant0nkr #41]

### 2.4 Holding registers useful for identification

- Hold 7-8: model code as 4 ASCII chars, high byte first, for example `CBAA` (SNA
  3000-6000), `CCAA` (SNA-US 6000), `CFAA` (SNA 12K), `CEAA` (SNA-US 12K). Codes are from
  andrew867/LuxPower-Advanced README. [S/U]
- Hold 7-10: firmware version (format used by ant0nkr `format_firmware_version`).
- Hold 15: Modbus "Com Addr" (0-150), the RS485 slave address. [S: protocol doc]
- Input 115-119: inverter serial in ASCII. [V]

---

## 3. Input register map (function 0x04) for live data

The source is the LuxPower "Modbus RTU Protocol" (V16-V23, 2025). It is transcribed in
OwlBawl/Luxpower-Modbus-RTU and cross-checked against lxp-bridge `inputs.md` and
ant0nkr `constants/input_registers.py`. All three agree on registers 0-107. Raw units
are shown; divide as indicated. Unsigned unless noted.

### 3.1 Block 0 (regs 0-39): live power, the core of the dashboard

| Reg | Name | Raw unit | Scale | Meaning |
|---|---|---|---|---|
| 0 | State | enum | — | Operating mode (see 3.5) |
| 1 / 2 / 3 | Vpv1 / Vpv2 / Vpv3 | 0.1 V | ÷10 | PV string voltages |
| 4 | Vbat | 0.1 V | ÷10 | Battery voltage |
| 5 | SOC / SOH | % | low byte = SOC, high byte = SOH | Battery state of charge and health |
| 6 | Internal fault | code | — | |
| 7 / 8 | Ppv1 / Ppv2 | W | 1 | PV string power |
| 9 | Ppv3 | W | 1 | PV3 power. The **protocol doc says "total PV (PV1+2+3)"**, while lxp-bridge/ant0nkr label it PV3. [U: verify on SNA, see 3.6] |
| 10 | Pcharge | W | 1 | Battery charge power |
| 11 | Pdischarge | W | 1 | Battery discharge power |
| 12 / 13 / 14 | VacR / VacS / VacT | 0.1 V | ÷10 | Grid (AC input) voltage per phase |
| 15 | Fac | 0.01 Hz | ÷100 | Grid frequency |
| 16 | Pinv | W | 1 | Inverter (on-grid) output power |
| 17 | Prec | W | 1 | AC-charging (rectifier) power from grid |
| 18 | IinvRMS | 0.01 A | ÷100 | Inverter RMS current |
| 19 | PF | 0.001 | (0,1000] gives x/1000; (1000,2000) gives (1000−x)/1000 | Power factor |
| 20 / 21 / 22 | VepsR / S / T | 0.1 V | ÷10 | EPS / off-grid (AC output) voltage |
| 23 | Feps | 0.01 Hz | ÷100 | EPS output frequency |
| 24 | Peps | W | 1 | **EPS / off-grid output active power** |
| 25 | Seps | VA | 1 | EPS apparent power |
| 26 | Ptogrid | W | 1 | Export to grid |
| 27 | Ptouser | W | 1 | Import from grid |
| 28 / 29 / 30 | Epv1/2/3_day | 0.1 kWh | ÷10 | PV energy today (30: doc says "total PV today") |
| 31 | Einv_day | 0.1 kWh | ÷10 | Inverter output energy today |
| 32 | Erec_day | 0.1 kWh | ÷10 | AC-charge energy today |
| 33 | Echg_day | 0.1 kWh | ÷10 | Battery charged today |
| 34 | Edischg_day | 0.1 kWh | ÷10 | Battery discharged today |
| 35 | Eeps_day | 0.1 kWh | ÷10 | EPS output energy today |
| 36 | Etogrid_day | 0.1 kWh | ÷10 | Exported today |
| 37 | Etouser_day | 0.1 kWh | ÷10 | Imported today |
| 38 / 39 | Vbus1 / Vbus2 | 0.1 V | ÷10 | Internal DC bus |

### 3.2 Block 1 (regs 40-79): lifetime totals, faults, temperatures

32-bit counters are stored **low word first**: value = L + (H << 16), unit 0.1 kWh.

| Regs | Name | Notes |
|---|---|---|
| 40-41 / 42-43 / 44-45 | Epv1/2/3_all | PV lifetime (44-45 = total PV per protocol doc) |
| 46-47 | Einv_all | Inverter output lifetime |
| 48-49 | Erec_all | AC charge lifetime |
| 50-51 | Echg_all | Battery charge lifetime |
| 52-53 | Edischg_all | Battery discharge lifetime |
| 54-55 | Eeps_all | EPS output lifetime |
| 56-57 | Etogrid_all | Export lifetime |
| 58-59 | Etouser_all | Import lifetime |
| 60-61 | FaultCode (32-bit bitmask) | Map in ant0nkr `constants/fault_codes.py` |
| 62-63 | WarningCode (32-bit bitmask) | Map in ant0nkr `constants/warning_codes.py` |
| 64 | Tinner | °C, internal |
| 65 / 66 | Tradiator1 / 2 | °C |
| 67 | Tbat | °C, battery NTC |
| 69-70 | RunningTime | seconds (32-bit) |
| 77 | AC input flags | bit0: 0 = Grid, 1 = Generator; bit2: AC-couple enable; bits 5-7: EPS/Grid/Pload "show" flags |

### 3.3 Block 2 (regs 80-119): BMS, parallel, serial

| Reg | Name | Unit / scale |
|---|---|---|
| 80 | Battery type / comm type (CAN=0, 485=1) | — |
| 81 / 82 | BMS max charge / discharge current | 0.01 A (lxp-bridge note: some models use 0.1 A, see the paulsteigel troubleshooting table) [U] |
| 83 / 84 | BMS charge volt ref / discharge cut-off | 0.1 V |
| 85-94 | BMS status 0-9 | bitfields |
| 95 | Battery status as seen by inverter | |
| 96 | Battery count (parallel) | |
| 97 | Battery capacity | Ah |
| 98 | BMS battery current | 0.01 A, **signed** |
| 99 / 100 | BMS fault / warning | |
| 101 / 102 | Max / min cell voltage | 0.001 V |
| 103 / 104 | Max / min cell temperature | 0.1 °C, signed |
| 106 | BMS cycle count | |
| 107 | Inverter-sampled battery voltage | 0.1 V |
| **113** | **Master/Slave/Parallel** | bits0-1: 1 = Master, 2 = Slave; bits2-3: phase (1 = R, 2 = S, 3 = T); bits8+: parallel count |
| 114 | On-grid load power ("12K" models) | W |
| 115-119 | Inverter serial (ASCII) | |

### 3.4 Blocks 3-5 (regs 120-232): generator, split-phase, load

| Reg | Name | Unit |
|---|---|---|
| 120 | Half-bus voltage | 0.1 V |
| 121 / 122 / 123 | Generator V / f / P | 0.1 V / 0.01 Hz / W |
| 124, 125-126 | Generator energy today / total | 0.1 kWh |
| 127 / 128 | EPS L1N / L2N voltage (US split-phase) | 0.1 V |
| 129 / 130 | EPS L1N / L2N active power | W |
| 131 / 132 | EPS L1N / L2N apparent power | VA |
| 133-138 | EPS L1N/L2N energy day/total | 0.1 kWh |
| 153 | AC-couple power | W, signed |
| **170** | **Pload: load consumption (on-grid mode)** | W |
| 171, 172-173 | Load energy today / total | 0.1 kWh |
| 180-205 | 3-phase S/T and US L1N/L2N grid, inverter, rectifier, import and export powers | W |
| 214-216 | Extra NTC temperatures | °C |
| 217-231 | PV4-PV6 voltage, power, energy | as PV1-3 |
| 232 | Smart-load power | W |

Registers above 160 are only present on newer firmware or models. Unsupported ranges
may return zeros or an exception.

### 3.5 Operating state (input reg 0)

From the protocol doc appendix and ant0nkr, which agree. [V]

| Hex | Dec | Meaning |
|---|---|---|
| 0x00 | 0 | Standby |
| 0x01 | 1 | Fault |
| 0x02 | 2 | Programming / FW update |
| 0x04 | 4 | PV on-grid (PV powering load, surplus to grid) |
| 0x08 | 8 | PV charging battery |
| 0x0C | 12 | PV charging + on-grid |
| 0x10 | 16 | Battery discharging on-grid |
| 0x14 | 20 | PV + battery discharging on-grid |
| 0x20 | 32 | AC (grid) charging |
| 0x28 | 40 | PV + AC charging |
| 0x40 | 64 | Battery off-grid (battery powering load, no grid) |
| 0x60 | 96 | Off-grid + battery charging (AC-coupled PV) |
| 0x80 | 128 | PV off-grid |
| 0x88 | 136 | PV charging + off-grid |
| 0xC0 | 192 | PV + battery off-grid |

ant0nkr also maps 17 to "Standby" (bypass) [S]. paulsteigel's ESPHome table indexes
these differently and looks mis-aligned for codes ≥ 0x20 [U]. Use the hex table above.

### 3.6 SNA-specific notes and differences from the LXP hybrid / 12K

**Model family (to confirm against the user's nameplates):**

- SNA 3000 / 4000 / 5000 / 6000 **WPV**: single-phase off-grid "eco-hybrid", 230 V,
  EU/Africa/Asia. Up to 10 units in parallel, single- or three-phase (SNA5000WPV manual).
- SNA-US 6000, SNA 12K (EU), SNA-US 12K / 15K: split-phase US versions with generator
  input and smart load.
- SNA PRO (2026, up to 16 in parallel) and SNA-G2 (referenced by paulsteigel).
- EG4 **6000XP / 12000XP** are rebadged SNA-platform units. pylxpweb calls this the
  "EG4_OFFGRID (SNA PLATFORM)" family, device type code 54.
- The SolarAssistant page lists SNA-3000/4000/5000/6000 as "SNA Single-Phase Hybrid".

**Register differences:**

- The **same input map** applies. lxp-bridge, ant0nkr and paulsteigel's
  *SNA-specific* ESPHome component all use registers 0-79 unchanged on SNA, and users
  confirm lxp-bridge working on SNA5000 (powerforum, 2022-2023). [V]
- **Load power on SNA.** The SNA's household loads are on its **AC output (EPS) terminal**.
  For a "house load" figure on SNA, use **Peps (reg 24)**, plus the Seps/Eeps registers.
  ant0nkr's "Load Percentage" uses Peps when state = 0x40 (off-grid) and Pload (170)
  otherwise. Reg 170 is populated only on newer firmware, and Reg 114 is "12K only".
  [V that 24 is EPS output power; **U** whether Peps includes bypass (grid pass-through)
  power while the SNA is in AC-first/bypass mode. Verify on-site by comparing reg 24
  against reg 27 and reg 170 with the grid present.]
- **Grid on an off-grid SNA.** The "grid" registers (12-17, 26-27) describe the **AC input**
  (utility or generator) used for bypass and AC charging. **Ptouser (27)** is the useful
  grid-import figure; **Prec (17)** is the AC-charging share. On WPV units with no export
  enabled, **Ptogrid (26) and Etogrid (36, 56-57) should read 0**. The SNA-US 12K and
  SNA Pro have grid-sell features, so they may be non-zero there. Hold 226 bit 2
  "Grid CT connection enable" is noted as "observed on SNA6000". [S/U]
- **Grid voltage reads 0** when the AC input is absent (off-grid mode, state 0x40/0x80/0xC0). Display "No grid" rather than 0 V.
- **PV strings:** SNA 3-6K WPV have **one or two MPPT inputs** (model dependent), so
  PV3 (reg 3/9) may be unused or may carry total PV. lxp-bridge's doc says "PV
  voltages only present on hybrid inverters", but that predates SNA testing. Use
  PV1 + PV2 (7 + 8) and sanity-check against reg 9. [U]
- **SOH (reg 5 high byte)** is often 0 on older firmware (lxp-bridge note). One
  SolarAssistant user saw SOC like `25648%`, meaning the SOC/SOH bytes were not split.
  Always mask: `soc = r5 & 0xFF; soh = r5 >> 8`. [V]
- **Hold 21** bit flags differ in meaning on SNA ("Normal/Standby" is bit 9). Writing
  the wrong value to hold 21 can put the inverter into **Standby** (ant0nkr
  `entity.py` warning). **Make the display read-only.**

**Parallel (3 × SNA):**

- Each inverter reports **only its own** power and energy. Sum Ppv, Peps, Pcharge,
  Pdischarge, Ptouser and so on across all three for system totals.
- With a shared battery bank, SOC, Vbat and BMS data are shared. Show them once,
  preferably from the master (reg 113 bits0-1 = 1), and do not sum them. Battery
  charge/discharge power is per inverter and *should* be summed. [S/U: reasoned from
  register semantics and ant0nkr's `master_only` flag; verify on site]
- Settings propagate from master to slaves (powerforum parallel thread). The cloud
  portal parallel-group view needs an installer account. Neither affects local reads.

---

## 4. Existing open-source projects

| Project | Lang / form | Transport | Multi-inverter | SNA support | Licence | Activity (as of 2026-11) |
|---|---|---|---|---|---|---|
| **celsworth/lxp-bridge** — https://github.com/celsworth/lxp-bridge | Rust daemon; MQTT (+ HA discovery), InfluxDB, Postgres/MySQL/SQLite, HA add-on | Dongle :8000 | **Yes**, `inverters:` list in `config.yaml` | Works on SNA5000 per users; not mentioned in README | MIT | **Unmaintained.** README says "no longer being maintained", recommends eg4-bridge. Last commit 2025-03-20; last release 0.13.0 (Oct 2023), master 0.14.0-dev. |
| **jaredmauch/eg4-bridge** — https://github.com/jaredmauch/eg4-bridge | Rust fork of lxp-bridge | Dongle :8000 | Yes | Implicit (EG4 = Lux platform) | MIT (inherited) | Active; last commit 2026-09-29, v0.20.0-dev. Focus on Influx v1; HA add-on unmaintained. |
| **ant0nkr/luxpower-ha-integration** (`lxp_modbus`) — https://github.com/ant0nkr/luxpower-ha-integration | Python HA custom integration (HACS default) | Dongle :8000 | Yes, one config entry per inverter; master-only entity handling | Yes (SNA6000 referenced in code; users on SNA-12K) | MIT | **Very active**: last commit 2026-11-11, v1.x, about 80 stars, has a test suite. **Best reference implementation** for frame building, parsing and register constants. |
| **joyfulhouse/pylxpweb** — https://github.com/joyfulhouse/pylxpweb | Python library (PyPI `pylxpweb`, py ≥ 3.13) | Cloud API, **dongle :8000**, RS485 Modbus (pymodbus), hybrid | Yes (`Station`, `ParallelGroup`) | Yes, SNA/EG4-offgrid family code 54 | MIT | Very active: last commit 2026-11-16, 0.10.0b15. Needs Python 3.13 (Bookworm ships 3.11, so use `uv` or pyenv). |
| **joyfulhouse/eg4_web_monitor** — https://github.com/joyfulhouse/eg4_web_monitor | HA integration on pylxpweb | Same as pylxpweb | Yes | Yes (SNA working-mode issue #295) | MIT (assumed, same author) [U] | Active |
| **guybw/LuxPython_DEV** (the original "LuxPower HA integration", `luxpower` domain) — https://github.com/guybw/LUXPower (public pointer) | Python HA integration | Dongle :8000 | Yes | Yes (EG4 6000XP users) | **Private repo**; access by emailing the author | Active-ish; not inspectable. |
| guybw/LuxPythonCard — https://github.com/guybw/LuxPythonCard | Lovelace power-flow card | — | — | — | — | Companion card |
| **paulsteigel/luxpower_sna** — https://github.com/paulsteigel/luxpower_sna | ESPHome external component (ESP32 talks to dongle :8000) | Dongle :8000 | One hub per inverter | **Explicitly SNA / SNA-G2** | MIT (per README; no LICENSE file in repo) [U] | Active, last commit 2026-09-27, about 970 commits, 7 stars |
| andrew867/LuxPower-Advanced — https://github.com/andrew867/LuxPower-Advanced | Python HA integration (fork of LuxPython lineage) | Dongle :8000 | Claims "parallel systems" | Lists SNA 3000-6000 (CBAA), SNA-US 6000, SNA 12K, SNA-US 12K | Not stated [U] | README partly templated (placeholder repo URL); treat as low-maturity |
| totaldebug/lumen + totaldebug/luxmodbus — https://github.com/totaldebug/lumen | Python HA integration + standalone protocol lib | Dongle, client or server mode | — | Not stated | MIT | New (10 commits, 0 stars); luxmodbus not yet on PyPI |
| **f-garofalo/openlux** — https://github.com/f-garofalo/openlux | ESP32 firmware: RS485 to "dongle protocol" on WiFi/Ethernet | RS485 (replaces dongle) | One per inverter | Not stated | Not checked [U] | 2025-12+; works with ant0nkr integration |
| nicolaERTT/ESP32-luxpower — https://github.com/nicolaERTT/ESP32-luxpower | ESP32 RS485 reader | RS485 @ 19200 | — | — | [U] | Referenced in ant0nkr #41 |
| poldim/EG4-Inverter-Modbus — https://github.com/poldim/EG4-Inverter-Modbus | HA integration for standard Modbus TCP via RS485 gateway | RS485 via Waveshare | Yes (one IP each) | EG4 only; some Lux registers blank [S] | [U] | — |
| OwlBawl/Luxpower-Modbus-RTU — https://github.com/OwlBawl/Luxpower-Modbus-RTU | Markdown transcription of the official LuxPower Modbus RTU protocol (V16-V23) | Docs | — | — | [U] | 2025 |
| SolarAssistant (commercial, not OSS) — https://solar-assistant.io/help/inverters/luxpower/SNA/dongle | Pi/Orange Pi image | Dongle (needs logger serial) or RS485 | Yes | **Explicit SNA 3000-6000** | Paid licence | Active |

**Node-RED:** no maintained public flow found. People pair lxp-bridge (MQTT) with
Node-RED (powerforum, 2 × SNA5000) or post ad-hoc flows on Facebook. [S]

**ESPHome:** besides paulsteigel's component (dongle client), ESPHome's generic
`modbus_controller` works over RS485, but only via plain Modbus RTU; see section 5. [S]

**Not found / does not exist under that name:** "lxp-packet" as a standalone library.
The packet code lives inside lxp-bridge (`src/lxp/packet.rs`) and each integration.
"luxpower-modbus" as a PyPI library was also not found; ant0nkr's HA domain is
`lxp_modbus`, and the nearest equivalent is `luxmodbus` (totaldebug, unpublished). [U]

---

## 5. RS485 (Modbus RTU) alternative

Use this if the dongles are ENC-locked, Ethernet-only, or unreliable.

- **Serial settings:** the protocol doc header says **19200 bps, 8N1**. diysolarforum users
  on LXP-LB-EU-12K and an ESP32 project confirm 19200. LuxPower support once told a user
  9600, and a 2026 offgrid4less thread claims 9600 for SNA-NB-6000. **That thread reads
  as low-quality or AI-generated**, so treat 9600 as unverified. Try 19200 first. [V 19200 / U 9600]
- **Slave address:** hold register 15 ("Com Addr", 0-150). It is not always 1, so scan if needed. [S]
- **Port / pinout (SNA):** SolarAssistant says SNA 3-6K use the RS485 RJ45 inside the
  inverter, **pin 7 = RS485-B, pin 8 = RS485-A**. The port is labelled "CT" on newer units
  and "MPP485" on older ones. Other Lux models use pins 1/2 on INV485. **On many units this
  port is shared with the dongle, so unplug the dongle** or you get bus collisions.
  [S: SolarAssistant / U for each SNA revision; check the manual's comms-port table]
- **Parallel:** **one cable or channel per inverter.** SolarAssistant states this explicitly
  for Lux parallel installs. Options are three USB-RS485 adapters on the Pi, or a
  multi-channel Waveshare RS485-to-Ethernet gateway with one IP per channel.
- **Protocol flavour:**
  - Plain Modbus RTU function 0x04/0x03 reads reportedly work through a "Modbus TCP to RTU"
    gateway with `pymodbus` (diysolarforum example reads input regs 0-199 in 2 × 100).
  - f-garofalo (OpenLux) states LuxPower's RTU variant includes the inverter serial and
    allows up to 127 registers per read; in that case plain one-register-at-a-time polling
    is the fallback.
  - pylxpweb has a ready RS485 transport (pymodbus backend).
  - Register numbers and scaling are identical to section 3, but note RTU on-wire values
    are **big-endian** (standard Modbus) whereas the TCP dongle payload is little-endian. [V for 0x04 working via gateway / U for serial-in-frame requirement on SNA]
- **Electrical:** use an isolated adapter (FTDI or Waveshare industrial). Bond the comm
  ground and use twisted pair. Never wire with the inverter energised.

---

## 6. Practical recommendations for the Pi display

1. In the router, give each of the 3 dongles a DHCP reservation. Record each
   dongle serial (on the dongle label or LuxPower portal) and inverter serial.
2. Check the portal dongle type is **E-WIFI**, not **E-WIFI ENC**. If any is ENC, open a
   ticket with LuxPower support before writing code.
3. If the dongle has a web UI (old MiCO firmware), confirm Network Connection 2 = TCP Server :8000.
4. First smoke test from the Pi: send the 38-byte read-input frame from section 2.2 with
   a tiny Python script. **Do not** `nmap`/`modpoll` the dongle first; it can lock up.
5. Poll every 10-30 s per inverter, sequentially, with one persistent socket each.
   Ignore frames whose function, start register or serial does not match. Reconnect on
   reset or after 60-120 s of silence.
6. Make sure nothing else on the LAN (HA integration, SolarAssistant, lxp-bridge) is a
   second local client of the same dongles. Otherwise consume their output (MQTT) instead.
7. Keep the display strictly read-only (functions 0x03/0x04 only).

---

## 7. Contradictions and open questions

| Item | Conflict / uncertainty |
|---|---|
| Request protocol version | ant0nkr and pylxpweb send `01 00`; paulsteigel and lxp-bridge use `02 00`. Both are reported working. |
| Reg 9 / 30 / 44-45 meaning | Official doc: *total* PV. lxp-bridge/ant0nkr: PV3. On 2-MPPT SNA the difference is visible. Verify on site. |
| Reg 81/82 scale | 0.01 A per doc; some models 0.1 A (paulsteigel note). |
| Load power on SNA | Peps (24) vs Pload (170) vs computed (Ptouser − Prec + Pinv − Ptogrid, paulsteigel's "home_live"). Verify on site. |
| RS485 baud | 19200 (protocol doc, multiple users) vs 9600 (LuxPower support anecdote, low-quality forum). |
| Dongle firmware boundaries | "3.x blocks local" and "v2 has no web UI" are forum claims; ENC vs non-ENC type is the better-attested factor. |
| Dongle web UI availability | Older MiCO dongles have the admin/admin UI; newer E-WIFI v2 reportedly do not, with port 8000 on by default. |
| SNA-US / SNA 12K | Split-phase; grid and EPS split into L1N/L2N regs 127-138 and 193-204. Not relevant if the user's units are 230 V WPV. |
| OwlBawl doc | Third-party transcription of LuxPower's PDF. One known index overlap at regs 115-119 is flagged in the doc itself. |

---

## Sources

Protocol / registers
- lxp-bridge wiki, TCP Packet Spec: https://github.com/celsworth/lxp-bridge/wiki/TCP-Packet-Spec
- lxp-bridge wiki, Inputs: https://github.com/celsworth/lxp-bridge/wiki/Inputs
- lxp-bridge wiki, Inverter Setup (dongle Network Setting): https://github.com/celsworth/lxp-bridge/wiki/Inverter-Setup
- lxp-bridge source (`src/lxp/packet.rs`, `src/coordinator/mod.rs`, `doc/inputs.md`, `doc/lux_network_setting.png`, `config.yaml.example`, `CHANGELOG.md`): https://github.com/celsworth/lxp-bridge
- LuxPower Modbus RTU protocol (V16-V23) transcription: https://raw.githubusercontent.com/OwlBawl/Luxpower-Modbus-RTU/main/modbus_protocol_updated_on_2025.06.14.md
- ant0nkr integration source (`constants/input_registers.py`, `classes/lxp_request_builder.py`, `classes/lxp_response.py`, `classes/lxp_packet_utils.py`, `entity_descriptions/sensor_types.py`, README): https://github.com/ant0nkr/luxpower-ha-integration
- pylxpweb source (`transports/dongle.py`, `constants/registers.py`, README): https://github.com/joyfulhouse/pylxpweb
- paulsteigel SNA ESPHome component (`components/luxpower_sna/luxpower_sna.cpp`, README): https://github.com/paulsteigel/luxpower_sna

Dongle behaviour / firmware
- ant0nkr issue #69, "E-WiFi v2.07 – Port 8000 open but no Modbus communication": https://github.com/ant0nkr/luxpower-ha-integration/issues/69
- ant0nkr issue #41, "MPPT485/CT1 modbus support" (RS485, timing, OpenLux): https://github.com/ant0nkr/luxpower-ha-integration/issues/41
- HA community, "Luxpower Inverter Integration" (ENC to E-WIFI, local port 4346): https://community.home-assistant.io/t/luxpower-inverter-integration/911796?page=2
- LuxPower "Dongle Local Connect Guideline" (PDF): https://luxpowertek.com/wp-content/uploads/2024/07/02-01-01-04-DL-Dongle-Local-Connet-Guideline.pdf
- LuxPower E-WiFi dongle product page: https://luxpowertek.com/product-ewifi-dongle/

SNA models / parallel / community
- SNA5000WPV user manual (parallel up to 10): https://luxpowertek.com/wp-content/uploads/2022/02/SNA5000WPV-UM-210604.pdf
- SNA 3-6K user manual (2024-10): https://luxpowertek.com/wp-content/uploads/2024/11/SNA-3-6K-User-Manual-24.10.30.pdf
- SNA-US 12/15K manual: https://luxpowertek.com/wp-content/uploads/2025/08/SNA-US-12-15K-User-Manual-2025.3.10-1.pdf
- SNA PRO manual (2026, up to 16 parallel): https://luxpowertek.com/wp-content/uploads/2026/04/SNA-PRO-User-Manual-26.03.05.pdf
- Powerforum, "Luxpower SNA 5000 raspberrypi/mqtt": https://powerforum.co.za/topic/12303-luxpower-sna-5000-raspberrypimqtt/
- Powerforum, "Luxpower SNA 5000 Parallel set up": https://powerforum.co.za/topic/25799-luxpower-sna-5000-parallel-set-up/
- SolarAssistant, Luxpower SNA WiFi dongle: https://solar-assistant.io/help/inverters/luxpower/SNA/dongle
- SolarAssistant, Luxpower SNA RS485: https://solar-assistant.io/help/inverters/luxpower/SNA/rs485
- diysolarforum, HA with Modbus for LuxPower via Waveshare: https://diysolarforum.com/threads/homeassistant-with-modbus-for-luxpower-also-eg4-using-waveshare-2-ch-rs485-to-poe-eth.118939/
- offgrid4less, SNA-NB-6000 RS485 thread (low reliability): https://offgrid4less.com/thread/luxpower-tek-6000-watt-inverter-model-sna-nb-6000-rs485-modbus-rtu-not-working-need-help.5086

Other projects
- jaredmauch/eg4-bridge: https://github.com/jaredmauch/eg4-bridge
- joyfulhouse/eg4_web_monitor: https://github.com/joyfulhouse/eg4_web_monitor
- guybw/LUXPower (pointer to the private LuxPython_DEV): https://github.com/guybw/LUXPower
- guybw/LuxPythonCard: https://github.com/guybw/LuxPythonCard
- andrew867/LuxPower-Advanced: https://github.com/andrew867/LuxPower-Advanced
- totaldebug/lumen: https://github.com/totaldebug/lumen
- f-garofalo/openlux: https://github.com/f-garofalo/openlux
- nicolaERTT/ESP32-luxpower: https://github.com/nicolaERTT/ESP32-luxpower
- poldim/EG4-Inverter-Modbus: https://github.com/poldim/EG4-Inverter-Modbus
- totaldebug blog, "Integrating a Lux Power Inverter with Home Assistant": https://totaldebug.uk/posts/integrate-lux-inverter-with-home-assistant

Repository metadata (last commit dates, licences, versions) comes from shallow git clones
made on 2026-11-17. Some luxpowertek.com and powerforum pages were read through a
secondary fetcher because the session's primary fetch tool could not resolve those hosts.
