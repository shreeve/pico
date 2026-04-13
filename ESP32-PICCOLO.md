# ESP32-Piccolo — MQuickJS IoT Gateway on ESP32-S3

A production IoT gateway built on ESP-IDF for the Seeed Studio XIAO
ESP32-S3, running MQuickJS for scriptable device behavior. Connects
to MQTT brokers over TLS, speaks ASTM E1394 to the Piccolo Xpress
medical analyzer via USB Host, and provides an SSH shell with a JS
REPL for interactive development and file management.

## Target Hardware

| | Spec |
|--|------|
| Board | Seeed Studio XIAO ESP32-S3 |
| MCU | ESP32-S3 (Xtensa LX7 dual-core @ 240 MHz) |
| Flash | 8 MB |
| PSRAM | 8 MB |
| WiFi | 802.11 b/g/n (built-in) |
| Bluetooth | BLE 5.0 (built-in) |
| USB | Native USB-OTG (Host + Device) |
| Power | USB-C + LiPo charging circuit |
| Size | 21 x 17.5 mm |

## What This Builds

```
┌──────────────────────────────────────────┐
│           User Scripts (JS)              │
│  REPL · MQTT handlers · data transforms  │
├──────────────────────────────────────────┤
│         MQuickJS Runtime (C)             │
│  18K lines · ~80 KB flash · 1-2 MB heap  │
├──────────────────────────────────────────┤
│       Native Services (C / ESP-IDF)      │
│  MQTT · WiFi · TLS · OTA · LED · Storage │
├──────────────────────────────────────────┤
│      ASTM E1394 Protocol (C)             │
│  ENQ/ACK/EOT framing · record parser     │
├──────────────────────────────────────────┤
│      USB Host + FTDI Driver (C)          │
│  Piccolo Xpress @ 9600 8N1               │
├──────────────────────────────────────────┤
│        ESP-IDF / FreeRTOS                │
│  WiFi · lwIP · mbedTLS · NVS · OTA      │
├──────────────────────────────────────────┤
│           ESP32-S3 Hardware              │
│  240 MHz dual-core · 8 MB PSRAM · radio  │
└──────────────────────────────────────────┘
```

## Core Features

### 1. SSH Shell with JS REPL

SSH directly into the device (no telnet, encrypted from day one):

```bash
ssh piccolo@10.0.0.39
```

Interactive session:

```
piccolo v0.1.0 — type 'help' for commands
> 2 + 2
4
> led.blink(200)
true
> mqtt.publish("piccolo/status", "online")
true
> ls /scripts
  main.js       1.2 KB  2026-04-13 14:30
  astm_handler.js  820 B  2026-04-13 14:25
> run main.js
[js] running main.js...
ok
> cat /scripts/main.js
mqtt.on("message", function(topic, payload) {
    console.log("Got: " + topic + " = " + payload);
});
console.log("main.js loaded");
```

**Implementation:** Lightweight SSH server (Dropbear or libssh2-embedded)
running over ESP-IDF's TCP/mbedTLS stack. The SSH channel feeds a
readline-equipped REPL that evals JS via MQuickJS. File commands
(ls, cat, put, rm) operate on a LittleFS partition for script storage.

### 2. MQTT over TLS

Connect to any MQTT broker with certificate-based TLS:

```c
// ESP-IDF esp-mqtt handles everything
esp_mqtt_client_config_t mqtt_cfg = {
    .broker.address.uri = "mqtts://broker.example.com:8883",
    .broker.verification.certificate = ca_cert_pem,
};
```

**Topic namespace:**

| Topic | Handler | Description |
|-------|---------|-------------|
| `piccolo/<id>/js` | JS eval | Execute payload as JavaScript |
| `piccolo/<id>/led` | C native | on, off, toggle, blink |
| `piccolo/<id>/cmd` | JS dispatch | Application messages → `mqtt.on("message", fn)` |
| `piccolo/<id>/ota` | C native | Trigger firmware update |
| `piccolo/<id>/config` | C native | Update device configuration |
| `piccolo/<id>/result` | C publish | Parsed ASTM results (outbound) |
| `piccolo/<id>/status` | C publish | Heartbeat, connectivity, errors |

### 3. MQuickJS Runtime

Same engine as the Pico W project. Runs full ES2023 JavaScript.

**JS API surface:**

```javascript
// LED
led.on()  led.off()  led.toggle()  led.blink(ms)  led.isOn()

// MQTT
mqtt.publish(topic, payload)
mqtt.subscribe(topic)
mqtt.on("message", function(topic, payload) { ... })
mqtt.status()  // "connected" | "disconnected"

// Console
console.log(msg)

// Storage (LittleFS)
storage.get(key)
storage.set(key, value)
storage.list()

// Device info
device.id()         // unique device identifier
device.uptime()     // milliseconds since boot
device.freeHeap()   // bytes available
device.version()    // firmware version string

// Timers
timer.setTimeout(fn, ms)
timer.setInterval(fn, ms)
timer.clearTimeout(id)
timer.clearInterval(id)
```

**Memory budget:**

| Allocation | Size | Location |
|------------|------|----------|
| JS heap | 1-2 MB | PSRAM |
| Script storage | 512 KB | Flash (LittleFS) |
| Max script size | 64 KB | Enforced limit |
| Max execution time | 5 seconds | Watchdog-enforced |

### 4. USB Host — Piccolo Xpress

Connect the Piccolo Xpress medical analyzer via USB:

| | Detail |
|--|--------|
| Interface | USB Host (ESP32-S3 OTG) |
| Analyzer chip | FTDI (VID=0x0403, PID=0xCD18) |
| Serial config | 9600 baud, 8N1 |
| Protocol | ASTM E1394 |
| Data | Patient records, lab results |

**ASTM protocol flow:**

```
Piccolo → ENQ
Gateway → ACK
Piccolo → STX [frame data] ETX [checksum] CR LF
Gateway → ACK (or NAK for retry)
  ... repeat for each frame ...
Piccolo → EOT
```

**Data path:**

```
USB bulk IN → FTDI decode → ASTM framing (C) → record parser (C)
  → structured result → JS transform (optional) → MQTT publish
  → audit log (flash)
```

### 5. OTA Firmware Updates

ESP-IDF dual-partition OTA with rollback:

```
Flash layout:
  factory     (fallback firmware)
  ota_0       (active app, slot A)
  ota_1       (staging, slot B)
  nvs         (config/credentials, encrypted)
  littlefs    (scripts, audit logs)
  otadata     (boot selection)
```

Triggered via MQTT command or SSH:

```bash
> ota https://releases.example.com/piccolo-v0.2.0.bin
[ota] downloading... 456 KB
[ota] verifying signature...
[ota] writing to ota_1...
[ota] rebooting...
```

Post-boot health check validates connectivity before marking the
new image as good. Automatic rollback if health check fails.

---

## Project Structure

```
esp32-piccolo/
├── CMakeLists.txt
├── sdkconfig.defaults
├── partitions.csv
├── main/
│   ├── CMakeLists.txt
│   └── app_main.c                 Boot + task creation
├── components/
│   ├── wifi_mgr/                  WiFi connect/reconnect state machine
│   │   ├── include/wifi_mgr.h
│   │   └── wifi_mgr.c
│   ├── mqtt_mgr/                  MQTT client wrapper + topic dispatch
│   │   ├── include/mqtt_mgr.h
│   │   └── mqtt_mgr.c
│   ├── ssh_server/                SSH shell + REPL + file commands
│   │   ├── include/ssh_server.h
│   │   ├── ssh_server.c
│   │   └── repl.c
│   ├── js_runtime/                MQuickJS integration + bindings
│   │   ├── include/js_runtime.h
│   │   ├── js_runtime.c
│   │   ├── js_bindings.c          led, mqtt, storage, device, timer
│   │   └── js_eval.c
│   ├── usb_ftdi/                  USB Host FTDI driver
│   │   ├── include/usb_ftdi.h
│   │   └── usb_ftdi.c
│   ├── astm/                      ASTM E1394 protocol
│   │   ├── include/astm.h
│   │   ├── astm_framing.c         ENQ/ACK/EOT state machine
│   │   ├── astm_parser.c          Record parser (pipe-delimited)
│   │   └── astm_types.h           Patient/result/header structs
│   ├── led/                       LED control + blink timer
│   │   ├── include/led.h
│   │   └── led.c
│   ├── storage/                   NVS config + LittleFS scripts/logs
│   │   ├── include/storage.h
│   │   ├── nvs_config.c
│   │   └── script_fs.c
│   ├── audit/                     Medical data audit trail
│   │   ├── include/audit.h
│   │   └── audit_log.c
│   ├── ota/                       OTA update manager
│   │   ├── include/ota.h
│   │   └── ota_mgr.c
│   └── time_sync/                 SNTP time synchronization
│       ├── include/time_sync.h
│       └── time_sync.c
└── ext/
    └── mquickjs/                  MQuickJS engine (vendored, same as pico)
```

## FreeRTOS Task Model

```
┌─────────────────────────────────────────────────────────┐
│                    FreeRTOS Tasks                        │
├──────────────┬──────────────┬───────────────────────────┤
│  Core 0      │  Core 1      │  Notes                    │
├──────────────┼──────────────┼───────────────────────────┤
│  WiFi (IDF)  │  JS Runtime  │  JS pinned to Core 1      │
│  MQTT (IDF)  │              │  WiFi internals on Core 0  │
│  TCP/IP (IDF)│              │                            │
├──────────────┼──────────────┼───────────────────────────┤
│  USB Host    │              │  High priority             │
│  ASTM Parser │              │  Timing-sensitive          │
├──────────────┼──────────────┼───────────────────────────┤
│  SSH Server  │              │  Spawns per-connection     │
│  Audit Log   │              │  Low priority background   │
│  OTA Manager │              │  On-demand                 │
└──────────────┴──────────────┴───────────────────────────┘
```

**Inter-task communication:**
- FreeRTOS queues for USB → ASTM → JS/MQTT
- Event groups for WiFi/MQTT state changes
- Ring buffers for USB bulk data
- Mutex-protected audit log writes

## C vs JS Responsibility Split

| Concern | Language | Rationale |
|---------|----------|-----------|
| WiFi connect/reconnect | C | ESP-IDF native, timing-sensitive |
| TLS/MQTT transport | C | ESP-IDF esp-mqtt, mature and tested |
| USB Host + FTDI driver | C | Hardware-specific, timing-sensitive |
| ASTM framing + checksum | C | Protocol correctness, medical compliance |
| ASTM record parser | C | Deterministic, testable, auditable |
| LED control + blink | C | Simple, shared across interfaces |
| OTA update flow | C | Security-critical, must not be scriptable |
| SSH server | C | Security-critical |
| Audit logging | C | Integrity-critical |
| Topic dispatch + validation | C | Security boundary before JS |
| Data transformation | **JS** | Field-updatable business logic |
| Result routing/filtering | **JS** | Site-specific rules |
| Custom MQTT handlers | **JS** | Application-specific behavior |
| Automation/orchestration | **JS** | Flexible, push-updateable |
| Interactive REPL | **JS** | Development and debugging |

**Golden rule:** JS never touches the wire directly. C handles all
protocol framing, transport, and security. JS processes structured
data and makes decisions.

## SSH Server Options

Two viable embedded SSH libraries:

### Option A: Dropbear (recommended)
- ~100 KB flash, battle-tested, widely used in embedded Linux
- Supports password auth + public key
- Single-process model fits FreeRTOS well
- Has been ported to ESP32 before (community examples)
- License: MIT-like

### Option B: libssh (wolfSSH)
- wolfSSL ecosystem, designed for embedded
- Commercial support available
- Good ESP32 integration
- License: GPLv3 or commercial

### SSH Shell Commands

```
help                    Show available commands
eval <js>               Evaluate JavaScript expression
run <file>              Execute a script from /scripts
ls [path]               List files
cat <file>              Show file contents
put <file> <content>    Write a file (small files via shell)
upload <file>           Receive file via SSH SCP/SFTP
rm <file>               Delete a file
mqtt <ip>               Connect to MQTT broker (plaintext)
mqtts <ip>              Connect to MQTT broker (TLS)
pub <topic> <msg>       Publish MQTT message
sub <topic>             Subscribe to topic
led on|off|toggle|blink LED control
status                  System status (WiFi, MQTT, USB, heap)
reboot                  Restart device
ota <url>               Trigger firmware update
```

## Memory Budget (ESP32-S3, 8 MB PSRAM + 8 MB Flash)

### PSRAM (8 MB)

| Allocation | Size | Notes |
|------------|------|-------|
| MQuickJS heap | 2 MB | Configurable, watchdog-capped |
| WiFi/TLS buffers | ~200 KB | ESP-IDF managed |
| MQTT buffers | ~64 KB | Configurable |
| USB Host buffers | ~16 KB | Transfer descriptors + data |
| ASTM parsing buffers | ~8 KB | Frame + record staging |
| Audit spool (RAM) | ~256 KB | Before flush to flash |
| General heap headroom | ~5.4 MB | Available for growth |

### Flash (8 MB)

| Partition | Size | Purpose |
|-----------|------|---------|
| bootloader | 32 KB | ESP-IDF second stage |
| otadata | 8 KB | Boot selection |
| nvs | 24 KB | Config, credentials (encrypted) |
| factory | 2 MB | Fallback firmware |
| ota_0 | 2 MB | Active app slot |
| ota_1 | 2 MB | Staging slot |
| littlefs | 1.9 MB | Scripts, audit logs, data spool |

## Security Model

| Layer | Mechanism |
|-------|-----------|
| WiFi | WPA2/WPA3 (ESP-IDF native) |
| MQTT | TLS 1.2+ with server cert verification |
| SSH | Public key + password auth |
| OTA | Signed firmware images |
| Flash | Encrypted NVS for secrets |
| Boot | Secure boot (optional, recommended for production) |
| Scripts | Signed/authorized updates only in production mode |
| JS sandbox | Bounded heap, execution timeout, no raw I/O access |

## Medical Data Integrity

Every ASTM result that flows through the device must have:

- **Device ID** — unique per gateway
- **Analyzer ID** — from ASTM header record if available
- **Session ID** — unique per ENQ→EOT session
- **Monotonic timestamp** — event ordering (boot-relative)
- **Wall-clock timestamp** — from SNTP (marked if not yet synced)
- **Raw frame checksum** — ASTM checksum status (pass/fail)
- **Parsed record** — structured patient/result data
- **Publish timestamp** — when sent to MQTT
- **MQTT message ID** — for delivery correlation
- **JS transform flag** — whether a script modified the data
- **Firmware + script version** — at time of processing

**Offline behavior:** If MQTT is unavailable, results are spooled to
LittleFS with full metadata. Published in order when connectivity
resumes, with original receive timestamps and unique IDs. Idempotent
upstream processing prevents duplicates.

## Implementation Phases

### Phase 0: Hardware Validation (1-2 weeks)
**MUST DO FIRST — this is the go/no-go gate.**

- [ ] ESP-IDF project builds and flashes to XIAO ESP32-S3
- [ ] WiFi connects to WPA2 and WPA3-Transition APs
- [ ] USB Host mode works on the board (VBUS power, OTG routing)
- [ ] FTDI device (0403:CD18) enumerates reliably
- [ ] 9600 8N1 send/receive works over FTDI
- [ ] Repeated plug/unplug survives without crashes
- [ ] WiFi + USB Host run concurrently without instability

**If USB Host fails on this board, stop and pick different hardware.**

### Phase 1: Core Platform (2-3 weeks)
- [ ] WiFi manager with reconnect state machine
- [ ] MQTT over TLS with esp-mqtt
- [ ] Topic dispatch (piccolo/js, piccolo/led, piccolo/cmd)
- [ ] MQuickJS compiles and runs on ESP32-S3
- [ ] JS REPL over serial (UART) for early testing
- [ ] LED control (on/off/toggle/blink)
- [ ] NVS config storage
- [ ] SNTP time sync

### Phase 2: Piccolo Integration (2-3 weeks)
- [ ] USB Host FTDI driver (custom, based on ESP-IDF USB Host API)
- [ ] ASTM framing state machine (ENQ/ACK/EOT)
- [ ] ASTM record parser (header, patient, order, result records)
- [ ] Result → MQTT publish pipeline
- [ ] Audit logging to LittleFS
- [ ] JS bindings for result data

### Phase 3: SSH + REPL (2-3 weeks)
- [ ] Dropbear or wolfSSH ported to ESP-IDF
- [ ] SSH shell with readline
- [ ] JS REPL over SSH
- [ ] File commands (ls, cat, put, rm) on LittleFS
- [ ] Script execution (run main.js)
- [ ] SCP or SFTP for file transfer

### Phase 4: Production Hardening (3-4 weeks)
- [ ] OTA update with dual partitions + rollback
- [ ] Secure boot + NVS encryption
- [ ] Signed script updates
- [ ] Watchdog coverage for all tasks
- [ ] Memory profiling under sustained load
- [ ] USB disconnect/reconnect recovery
- [ ] MQTT offline spool + replay
- [ ] Error reporting via MQTT status topic
- [ ] 72-hour soak test (WiFi + USB + MQTT + JS)

### Phase 5: Field Deployment (2-3 weeks)
- [ ] Device provisioning workflow (WiFi creds, broker config)
- [ ] Fleet management (device ID, group config)
- [ ] Remote monitoring dashboard
- [ ] Alerting (device offline, analyzer disconnect, parse errors)
- [ ] Documentation for field installation

## Total Effort Estimate

| Phase | Duration | Risk |
|-------|----------|------|
| Phase 0: Hardware validation | 1-2 weeks | **HIGH** — go/no-go gate |
| Phase 1: Core platform | 2-3 weeks | Low (ESP-IDF does most of it) |
| Phase 2: Piccolo integration | 2-3 weeks | Medium (USB Host + ASTM) |
| Phase 3: SSH + REPL | 2-3 weeks | Medium (SSH lib porting) |
| Phase 4: Hardening | 3-4 weeks | Medium (edge cases, testing) |
| Phase 5: Deployment | 2-3 weeks | Low (operational, not technical) |
| **Total** | **12-18 weeks** | |

## What Carries Over from Pico W

| Component | Reuse | Notes |
|-----------|-------|-------|
| MQuickJS engine | **Direct** | Same C source, same ext/mquickjs/ |
| JS API design | **Direct** | led.on(), mqtt.publish(), etc. |
| ASTM parser logic | **Port** | Zig → C, same state machine |
| MQTT topic architecture | **Direct** | Same namespace, same dispatch |
| Audit/logging design | **Direct** | Same fields, different storage backend |
| readline/REPL UX | **Port** | Same key bindings, SSH instead of telnet |
| Custom TCP/IP stack | **Drop** | lwIP replaces it |
| BearSSL | **Drop** | mbedTLS replaces it |
| CYW43 WiFi driver | **Drop** | ESP-IDF WiFi replaces it |
| Zig HAL/platform | **Drop** | ESP-IDF replaces it |
| PIO SPI transport | **Drop** | Not applicable |

## Comparison: Pico W vs ESP32-S3

| | Pico W (current) | ESP32-S3 (proposed) |
|--|---|---|
| Language | Zig | C |
| OS | None (bare metal) | FreeRTOS (ESP-IDF) |
| WiFi | Custom CYW43 driver | ESP-IDF native |
| TCP/IP | Custom stack (~7 KB RAM) | lwIP (ESP-IDF) |
| TLS | BearSSL (~68 KB flash) | mbedTLS (ESP-IDF) |
| MQTT | Custom client | esp-mqtt (ESP-IDF) |
| JS engine | MQuickJS | MQuickJS (same) |
| USB Host | Custom (RP2040 peripheral) | ESP USB Host API |
| Remote shell | Telnet (port 23, unencrypted) | **SSH (encrypted)** |
| OTA | Not implemented | ESP-IDF native |
| Secure boot | Not implemented | ESP-IDF native |
| Deep sleep | Not applicable | 14 uA available |
| Flash | 2 MB | 8 MB |
| RAM | 264 KB SRAM | 512 KB + 8 MB PSRAM |
| Clock | 125 MHz single-core | 240 MHz dual-core |
| Pride factor | Immense | Practical |
