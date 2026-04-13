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
│  WiFi · lwIP · mbedTLS · NVS · OTA       │
├──────────────────────────────────────────┤
│           ESP32-S3 Hardware              │
│  240 MHz dual-core · 8 MB PSRAM · radio  │
└──────────────────────────────────────────┘
```

## Core Features

### 1. Remote Command Surface

**v1: MQTT + serial REPL.** All device control, JS eval, script
push, and diagnostics work through the MQTT command channel and a
serial (UART) REPL for local development. This avoids the complexity,
attack surface, and RAM pressure of an on-device SSH server.

**v2+ (optional): SSH shell.** If field operators need interactive
shell access without physical serial, add a lightweight SSH server
(Dropbear or wolfSSH). See Phase 5.

**Serial REPL (always available via UART):**

```
piccolo v0.1.0 — type 'help' for commands
> 2 + 2
4
> led.blink(200)
true
> mqtt.publish("piccolo/status", "online")
true
> run main.js
[js] running main.js...
ok
> status
WiFi: connected (10.0.0.39)
MQTT: connected (broker.example.com:8883)
USB:  Piccolo Xpress attached
Heap: 5.2 MB free
Up:   3h 22m
```

**MQTT remote commands (encrypted, from anywhere):**

```bash
# Execute JS remotely
mosquitto_pub -t "piccolo/abc123/js" -m 'led.blink(100)'

# Push a script
mosquitto_pub -t "piccolo/abc123/script/main.js" -m '$(cat main.js)'

# Control LED
mosquitto_pub -t "piccolo/abc123/led" -m "on"

# Trigger OTA
mosquitto_pub -t "piccolo/abc123/ota" -m "https://releases.example.com/v0.2.0.bin"
```

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

## Serial / MQTT Command Reference

### Serial REPL commands (UART, always available)

```
help                    Show available commands
eval <js>               Evaluate JavaScript expression
run <file>              Execute a script from /scripts
ls [path]               List files on LittleFS
cat <file>              Show file contents
status                  System status (WiFi, MQTT, USB, heap, uptime)
led on|off|toggle|blink LED control
reboot                  Restart device
wifi                    Retry WiFi connection
```

### MQTT command topics (remote, encrypted)

```
piccolo/<id>/js         Execute payload as JavaScript
piccolo/<id>/led        on, off, toggle, blink, blink 200
piccolo/<id>/cmd        Application messages → JS handler
piccolo/<id>/config     Update device configuration
piccolo/<id>/ota        Trigger firmware update (URL payload)
piccolo/<id>/script/<n> Push script file (filename in topic, JS in payload)
```

### SSH Shell (v2+, optional)

If SSH is added later, the serial REPL commands carry over directly.
Additional SSH-only capabilities:

```
put <file> <content>    Write a file via shell
upload <file>           Receive file via SCP/SFTP
rm <file>               Delete a file
```

Two viable SSH libraries:
- **Dropbear** — ~100 KB flash, MIT-like, battle-tested, ported to ESP32
- **wolfSSH** — wolfSSL ecosystem, commercial support, GPLv3 or commercial

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
| Remote access | MQTT command channel (v1); SSH optional (v2+) |
| OTA | Signed firmware images, dual-partition rollback |
| Flash | Encrypted NVS for secrets |
| Boot | Secure boot (recommended for production) |
| Scripts | Signed/authorized updates only in production mode |
| JS sandbox | See constraints below |

### JS Runtime Constraints (enforced in C, not by convention)

| Constraint | Limit | Enforcement |
|------------|-------|-------------|
| Max heap | 2 MB | Allocator hard cap |
| Max execution time | 5 seconds per eval | Watchdog timer, forced abort |
| Max script size | 64 KB | Rejected at upload |
| Max message to JS | 4 KB | Truncated before dispatch |
| API surface | Allowlist only | No raw I/O, no filesystem write, no network |
| Script deployment | Signed in production | Unsigned only in dev mode |
| Error isolation | JS crash does not crash system | Catch, log, continue |

Note: this document describes a data acquisition gateway, not a
regulated diagnostic device. The term "medical data" refers to lab
results in transit, not diagnostic conclusions. Regulatory posture
(FDA, CLIA) depends on the full system context and intended use.

## Data Integrity

Every ASTM result that flows through the device must carry:

- **Device ID** — unique per gateway
- **Analyzer ID** — from ASTM header record if available
- **Session ID** — unique per ENQ→EOT session
- **Event sequence number** — persistent monotonic counter, survives reboot
- **Monotonic timestamp** — event ordering (boot-relative)
- **Wall-clock timestamp** — from SNTP
- **Clock confidence** — `synced`, `unsynced`, `stale` (not just boolean)
- **Boot reason** — power-on, watchdog, OTA, crash, user reboot
- **Raw frame checksum** — ASTM checksum status (pass/fail)
- **Parsed record** — structured patient/result data
- **Publish timestamp** — when sent to MQTT
- **MQTT message ID** — for delivery correlation
- **JS transform flag** — whether a script modified the data
- **Firmware + script version** — at time of processing

### Fault taxonomy

Every dropped, retried, malformed, or replayed event must be classified:

| Fault | Description | Action |
|-------|-------------|--------|
| `frame_checksum_fail` | ASTM frame checksum mismatch | NAK + retry, log |
| `frame_timeout` | Expected frame not received in time | Log, session reset |
| `session_abort` | EOT without complete record set | Log partial, flag |
| `parse_error` | Valid frame but unparseable content | Log raw frame |
| `publish_failed` | MQTT publish not acknowledged | Spool for retry |
| `publish_retry` | Re-publish from offline spool | Mark as replay |
| `duplicate_suppressed` | Idempotent check caught duplicate | Log, do not publish |
| `js_transform_error` | Script threw during transform | Publish untransformed + flag |
| `js_timeout` | Script exceeded execution limit | Kill, publish raw |

### Offline spool

A **write-ahead segment spool** on LittleFS, separate from scripts
and config, holds outbound MQTT publishes when the broker is
unreachable:

- Fixed-size segments (e.g. 4 KB) with CRC32 framing
- Append-only within a segment; new segment on rollover
- Configurable retention: max segments, max age, max total size
- Explicit power-fail recovery: incomplete segment detected and
  truncated to last valid record on boot
- Published in order when connectivity resumes, with original
  timestamps and event sequence numbers
- Idempotent upstream processing prevents duplicates

### Flash wear strategy

LittleFS handles wear leveling internally, but the application must
still constrain write patterns:

- Audit log: segment rollover, bounded retention (e.g. 7 days or 1 MB)
- Spool: bounded queue depth, oldest-first eviction if full
- Config writes: NVS, infrequent (not per-event)
- Worst-case assumption: 10 results/hour × 1 KB/result × 24h × 365d
  = ~85 MB/year write volume. With 1.9 MB partition and retention
  limits, flash endurance (100K erase cycles) is not a concern.

### Boot record

At every startup, write a boot record containing:
- Event sequence number (first after reboot)
- Reset cause (from ESP-IDF `esp_reset_reason()`)
- Firmware version
- Clock sync status
- Free heap at boot
- Previous shutdown reason if known

## Implementation Phases

### v1 Core — ship this first

The v1 target is a reliable data acquisition gateway: WiFi, MQTT/TLS,
USB Host, ASTM parsing, audit logging, offline spool, OTA. The remote
command surface is MQTT + serial REPL — no SSH in v1. Scripting is
available but secondary to the transport path being rock-solid.

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
- [ ] JS REPL over serial (UART) for development
- [ ] LED control (on/off/toggle/blink)
- [ ] NVS config storage
- [ ] SNTP time sync
- [ ] Persistent event counter (survives reboot)
- [ ] Boot record logging (reset cause, version, clock status)

### Phase 2: Piccolo Integration (2-3 weeks)
- [ ] USB Host FTDI driver (custom, based on ESP-IDF USB Host API)
- [ ] ASTM framing state machine (ENQ/ACK/EOT)
- [ ] ASTM record parser (header, patient, order, result records)
- [ ] Result → MQTT publish pipeline with full metadata
- [ ] Audit logging to LittleFS (segment spool, CRC framing)
- [ ] JS bindings for result data (post-parse transform)
- [ ] Fault classification for every error path

### Phase 3: Production Hardening (3-4 weeks)
- [ ] OTA update with dual partitions + rollback + health check
- [ ] Secure boot + NVS encryption
- [ ] Signed script updates
- [ ] Watchdog coverage for all tasks
- [ ] Memory profiling under sustained load (WiFi + USB + MQTT + JS)
- [ ] USB disconnect/reconnect recovery
- [ ] MQTT offline spool + ordered replay
- [ ] Power-fail recovery: segment truncation, spool integrity check
- [ ] Flash wear analysis under worst-case write patterns
- [ ] Error reporting via MQTT status topic
- [ ] 72-hour soak test

### Phase 4: Field Deployment (2-3 weeks)
- [ ] Device provisioning workflow (WiFi creds, broker config, device ID)
- [ ] Fleet management (group config, remote script push)
- [ ] Remote monitoring and alerting
- [ ] Documentation for field installation

### Phase 5: SSH Shell (optional, v2+)
**Deferred.** SSH adds complexity, attack surface, RAM pressure, and
field support burden. The v1 remote surface (MQTT command channel +
serial REPL) is sufficient for development and operations. SSH is
only justified if field operators need interactive shell access
without physical serial connection.

- [ ] Dropbear or wolfSSH ported to ESP-IDF
- [ ] SSH shell with readline + JS REPL
- [ ] File commands (ls, cat, put, rm) on LittleFS
- [ ] SCP or SFTP for script upload
- [ ] Per-device SSH key provisioning

## Total Effort Estimate

| Phase | Duration | Risk |
|-------|----------|------|
| Phase 0: Hardware validation | 1-2 weeks | **HIGH** — go/no-go gate |
| Phase 1: Core platform | 2-3 weeks | Low (ESP-IDF does most of it) |
| Phase 2: Piccolo integration | 2-3 weeks | Medium (USB Host + ASTM) |
| Phase 3: Hardening | 3-4 weeks | Medium (edge cases, soak testing) |
| Phase 4: Deployment | 2-3 weeks | Low (operational, not technical) |
| **v1 Total** | **10-15 weeks** | |
| Phase 5: SSH (optional v2) | 2-3 weeks | Medium (SSH lib porting) |

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
| Remote shell | Telnet (port 23, unencrypted) | MQTT + serial REPL (v1); SSH optional (v2) |
| OTA | Not implemented | ESP-IDF native |
| Secure boot | Not implemented | ESP-IDF native |
| Deep sleep | Not applicable | 14 uA available |
| Flash | 2 MB | 8 MB |
| RAM | 264 KB SRAM | 512 KB + 8 MB PSRAM |
| Clock | 125 MHz single-core | 240 MHz dual-core |
| Pride factor | Immense | Practical |
