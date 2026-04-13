# Session Handoff — Pico Firmware

This document captures the full context so a new AI or developer can pick
up exactly where we left off.

## Current State (April 13, 2026)

### Branch: `main` — proven on hardware

Everything is on `main`. No feature branches.

**Validated on real Pico W hardware:**
- CYW43 WiFi: PIO SPI → firmware upload → scan → WPA2-PSK join → DHCP
- ICMP echo reply (device responds to `ping`)
- TCP: full handshake, bidirectional data, MSS negotiation, clean teardown
- Telnet shell on port 23 with readline-lite (cursor, history, Ctrl keys)
- JavaScript eval over WiFi: `eval 2 + 2` returns `4` via telnet
- MQTT plaintext (port 1883): bidirectional pub/sub with Mosquitto broker
- MQTT over TLS 1.2 (port 8883): BearSSL handshake + encrypted pub/sub
- IPv4 layer with generic demux (ICMP/UDP/TCP), checksum validation, routing
- UDP listener dispatch: DHCP registers on port 68, stack routes by port
- ARP client/cache with outbound resolution and gratuitous ARP
- MQuickJS running JavaScript (`console.log("pico is alive!")`)
- USB Host with FTDI driver + ASTM protocol for Piccolo Xpress analyzer
- UART `reboot` and `wifi` commands for probe-free dev workflow
- Watchdog (8s) with crash counter and safe-mode detection
- 10ms periodic timer interrupt enabling `wfe` idle

**Not yet validated on hardware:**
- Script push over TCP port 9001 (listener registered, untested)
- OTA firmware update
- Flash KV write (read works via XIP, write needs RAM flash driver)

**Known limitation:**
- WPA3/mixed-mode APs cause consistent DEAUTH during WPA2 4-way handshake.
  Router must be set to WPA2-PSK only. Simple APs (iPhone hotspot) work fine.

### Recent Changes (this session)

BearSSL TLS + MQTT end-to-end + readline shell:

1. **BearSSL vendored** — `ext/bearssl/` (293 C source files, MIT license).
   Compiled for Cortex-M0+ with `BR_LOMUL=1`. Adds ~68KB flash when TLS active.
2. **TLS 1.2 validated on hardware** — full ECDHE_RSA_WITH_AES_128_GCM_SHA256
   handshake on Cortex-M0+ at 125 MHz, no hardware crypto. Entropy from
   ROSC jitter + SHA-256 conditioning → HMAC-DRBG.
3. **MQTT plaintext validated** — connect, publish, subscribe, receive via
   Mosquitto broker. Auto-subscribes to `pico/cmd` on CONNACK.
4. **MQTT over TLS validated** — bidirectional encrypted pub/sub on port 8883.
   Known-key trust (pin broker RSA public key).
5. **Readline-lite for telnet shell** — cursor movement (arrows, Home/End),
   4-entry command history (up/down with scratch-line preservation),
   Ctrl-A/E/K/U/C, proper backspace/delete. Telnet character-mode negotiation
   (WILL ECHO, SUPPRESS-GO-AHEAD).
6. **Shell commands** — `mqtt <ip>`, `mqtts <ip>`, `pub <topic> <msg>`,
   `sub <topic>`, `mqtt?`. UART `wifi` command for post-boot retry.
7. **Firmware size**: 464KB payload with all features active (fits 768KB).

### Previous Session Changes

Major refactoring and hardening pass across the network stack:

1. **Shared helpers** — `lib/byteutil.zig` (BE byte-order, checksum, ipv4Eq)
   and `lib/fmt.zig` (UART debug output) centralize duplicated code from 5 files
2. **Stack-owned IPv4 config** — `NetStack` holds `local_ip`/`subnet_mask`/
   `gateway_ip`; DHCP publishes via `setIpv4()` on lease acquisition; ARP,
   IPv4, TCP all read from stack, not DHCP globals
3. **TCP checksum decoupled** — `tcpChecksum()`/`tcpChecksumValid()` take
   explicit src/dst IP parameters; no cross-layer DHCP dependency
4. **TIME-WAIT is time-based** — configurable `tcp_timewait_ms` (default 30s),
   driven by wall-clock `elapsed_ms`, clamped to avoid timer drain on stalls
5. **Retransmission timers are ms-based** — `rto_ms` (initial 250ms, max 5s
   with exponential backoff), `retx_deadline_ms` compared via wrapping
   subtraction against `last_tick_ms`
6. **ISN hardened** — 4-tuple + boot-secret + monotonic counter + lowbias32 mixer
7. **MSS option** — SYN/SYN-ACK include 4-byte MSS option advertising 1460
8. **ARP-pending deferred retry** — `emitSegment()` returns `EmitResult`;
   `retryArpPending()` with per-connection cooldown prevents first-segment loss
9. **Superloop clarified** — poll.zig handles timers and deferred callbacks only; device
   polling is explicit in main loop; documented cooperative scheduling contract
10. **34 host-side unit tests** — sequence arithmetic, checksums, byte-order,
    MSS encoding, mix32 avalanche; run with `zig build test`

### Architecture

```
┌──────────────────────────────────────┐
│         User Scripts (JS)            │
├──────────────────────────────────────┤
│       MQuickJS Runtime (C)           │
├──────────────────────────────────────┤
│     pico Runtime (Zig)               │
│  superloop · timers · scheduler      │
├──────────────────────────────────────┤
│       Bindings (Zig → JS)            │
│  wifi · mqtt · gpio · timers · uart  │
│  spi · i2c · usb · storage · console │
├──────────────────────────────────────┤
│     Net Stack (Zig)                  │
│  tcpip · ipv4 · icmp · arp · dhcp   │
├──────────────────────────────────────┤
│     HAL / Drivers (Zig)              │
│  RP2040 · CYW43 · USB Host · FTDI   │
├──────────────────────────────────────┤
│           Hardware                   │
└──────────────────────────────────────┘
```

### Source Tree

```
src/
├── main.zig                  Entry point + cooperative main loop
├── lib/                      Shared pure helpers
│   ├── fmt.zig               Debug output (putc, puts, putDec, putHex32, putIp)
│   └── byteutil.zig          BE byte-order, checksum, ipv4Eq
├── bindings/                 JS API bindings
│   ├── console.zig           UART + console.log
│   ├── gpio.zig              GPIO JS bindings
│   ├── timers.zig            setTimeout/setInterval JS
│   ├── wifi.zig              WiFi management + JS
│   ├── mqtt.zig              MQTT client via AppVTable + JS
│   ├── storage.zig           Flash KV + JS
│   ├── uart.zig              UART peripheral
│   ├── usb.zig               USB host JS bindings
│   ├── spi.zig               SPI stub
│   └── i2c.zig               I2C stub
├── net/                      Network stack
│   ├── tcpip.zig             Comptime NetStack(Config) — TCP state machine
│   ├── stack.zig             Singleton stack instance (owns IPv4 config)
│   ├── ipv4.zig              IPv4 parse/route/send + stats
│   ├── icmp.zig              Echo reply (ping)
│   ├── arp.zig               ARP responder + 8-entry client cache
│   ├── dhcp.zig              DHCP client with lease renewal
│   ├── shell.zig             Telnet shell (port 23) — readline, history, MQTT cmds
│   └── script_push.zig       Script push protocol (TCP port 9001)
├── cyw43/                    CYW43439 WiFi driver
│   ├── cyw43.zig             Public API module
│   ├── device.zig            Full lifecycle facade
│   ├── board.zig             Pin maps and reset
│   ├── regs.zig              gSPI register definitions
│   ├── types.zig             State enum + Error set
│   ├── control/              Boot, IOCTL, scan, join, GPIO
│   ├── transport/            PIO SPI + gSPI bus
│   ├── protocol/             WLAN event parsing
│   ├── netif/                Ethernet TX/RX + service loop
│   └── firmware/             Binary blobs
├── platform/                 HAL + startup
│   ├── hal.zig               Chip detect + register helpers
│   ├── rp2040.zig            RP2040 drivers (clocks, UART, GPIO, timer, ROM)
│   ├── rp2350.zig            RP2350 drivers
│   ├── startup.zig           Vector table + BSS/data init
│   └── *.ld                  Linker scripts
├── runtime/                  Core runtime
│   ├── runtime.zig           JS timers, deferred callbacks, task scheduler
│   ├── scheduler.zig         Task queue
│   ├── timer.zig             Software timers
│   ├── memory_pool.zig       Fixed memory pool
│   ├── panic.zig             Fault handler
│   └── watchdog.zig          Watchdog with crash counter
├── config/                   Configuration
│   ├── device_config.zig     Device config from flash
│   └── flash_layout.zig      Flash regions and addresses
├── js/                       MQuickJS integration
│   ├── runtime.zig           JS engine wrapper
│   ├── quickjs_api.zig       Zig bindings for C API
│   └── *.c                   C sources (stdlib gen, bringup)
├── usb/                      USB host stack
│   ├── host.zig              Host controller
│   ├── regs.zig              USB register addresses
│   ├── descriptors.zig       USB descriptor types
│   ├── ftdi.zig              FTDI USB-to-serial driver
│   └── astm.zig              ASTM E1394 medical protocol parser
├── tls/                      TLS 1.2 via BearSSL
│   ├── bearssl.zig           Zig bindings to BearSSL C API
│   ├── tls.zig               TLS session adapter (TCP ↔ BearSSL)
│   └── entropy.zig           ROSC entropy for HMAC-DRBG seeding
├── provisioning/
│   └── captive_portal.zig    WiFi AP-mode provisioning (stub)
└── libc/                     Freestanding C stubs

tests/
├── test_net.zig              Host-side: sequence arithmetic, checksums, MSS, mix32
├── test_uart.zig             Hardware: minimal UART (SWD)
├── test_hal.zig              Hardware: HAL + PLL @ 125 MHz
└── test_main.zig             Hardware: MQuickJS VM bring-up
```

### TCP/IP Stack Design (uIP-inspired)

The network stack in `net/tcpip.zig` uses a comptime-parameterized design:

```zig
const Stack = NetStack(.{ .tcp_conn_count = 4, .enable_icmp = true });
```

Key design principles:
- **App-driven retransmission**: stack stores no payload. Apps implement
  `AppVTable` with a `produce_tx()` callback that regenerates data on retransmit.
- **Stop-and-wait**: one unacked segment per connection, no sliding window.
- **Multi-connection**: fixed array of N connections (default 4) + listener table.
- **Work flags**: per-connection `ack_due`, `tx_ready`, `retx_due`, `close_due`
  processed deterministically in `tcpPollOutput()`.
- **Fixed receive window**: comptime `rcv_wnd` (default 2048); no per-connection
  receive buffer — app consumes data via `on_recv` callback.
- **MSS advertisement**: SYN/SYN-ACK include 4-byte MSS option (1460 for Ethernet).
- **Time-based timers**: all TCP timers (retransmit RTO, TIME-WAIT) use
  wall-clock milliseconds via `last_tick_ms`. RTO starts at 250ms, doubles to 5s max.
- **21 observability counters**: ip_rx, ip_bad_checksum, arp_hits/misses,
  tcp_retx, tcp_bad_checksum, tcp_rst_tx, etc.
- **RX checksum verification**: incoming TCP segments validated before processing.
- **RST generation**: unmatched segments receive RST per RFC 793.
- **Stack-owned IPv4 config**: `local_ip`/`subnet_mask`/`gateway_ip` live in the
  stack instance, set by DHCP (or future static config).
- **Zero dynamic allocation**: all buffers are static, compile-time sized.

### Flash Layout (RP2040, 2 MB)

```
0x10000000  BOOT2          256 bytes
0x10000100  Firmware       ~768 KB
0x100C0000  OTA Staging    ~768 KB
0x10180000  Scripts        256 KB
0x101C0000  Config/KV      192 KB
0x101F0000  OTA Metadata   64 KB
```

## Build and Flash

```bash
# Development build (no WiFi, USB as device for flashing)
zig build uf2

# WiFi build
zig build uf2 -DSSID='NetworkName:Password'

# USB host build (for Piccolo Xpress)
zig build uf2 -DUSB_HOST

# Combined WiFi + USB host
zig build uf2 -DSSID='NetworkName:Password' -DUSB_HOST

# Flash (type "reboot" in picocom first, then):
picotool load -v -x zig-out/firmware/pico.uf2

# Serial console
picocom -b 115200 --noreset /dev/cu.usbserial-0001

# Run host-side unit tests
zig build test
```

### Flash Workflow

1. Type `reboot` in picocom → device enters BOOTSEL mode
2. `zig build uf2 && picotool load -v -x zig-out/firmware/pico.uf2`
3. Device reboots, picocom shows boot banner

No debug probe, no BOOTSEL button, no OpenOCD.

## What Is Next

### Achieved (this + previous sessions)

1. TCP validated — telnet shell on port 23, full lifecycle proven
2. Telnet shell with readline-lite — line editing, history, character mode
3. JavaScript eval over WiFi — `eval 2+2` returns `4` via telnet
4. MQTT plaintext validated — bidirectional pub/sub with Mosquitto
5. MQTT over TLS 1.2 validated — BearSSL handshake + encrypted pub/sub
6. BearSSL integrated — 293 C sources, ECDHE_RSA_WITH_AES_128_GCM_SHA256

### Immediate next

7. **Hook MQTT into JS runtime** — `mqtt.on("message", fn)` callback so
   scripts can react to incoming MQTT messages.

8. **Implement flash write driver** (RAM-resident, for KV storage.set() and OTA)

9. **Build OTA bootloader** (immutable, SHA-256 verification, staged update)

### Near-term

10. **Peripheral bindings** (ADC, PWM, I2C, SPI) to enable real hardware JS projects
11. **Audit `bindings/` for consistency** — naming, lifecycle, error reporting
12. **Investigate WPA3 support** — CYW43 may support SAE; current driver only does WPA2

### Deferred

13. **Production security**: signed updates, authenticated script upload,
    JS sandboxing. Required before internet-facing deployment.

## Piccolo Xpress Details

- Manufacturer: Abaxis Inc.
- Product: piccolo xpress
- VID: 0x0403 (FTDI), PID: 0xCD18
- Communication: 9600 8N1 over FTDI USB serial
- Protocol: ASTM E1394 (laboratory data, ENQ/ACK/EOT framing)
- Has its own power supply

## Key Documentation

- `AGENTS.md` — AI agent instructions and RP2040 gotchas
- `docs/JAVASCRIPT.md` — JS engine, API reference, MQuickJS details
- `docs/NETWORKING.md` — WiFi/networking status and architecture
- `docs/CYW43.md` — CYW43 bring-up reference
- `ISSUES.md` — Current issue tracker (resolved + open)
- `PICO.md` — Host-side CLI tool vision
- `docs/ZIG-0.15.2.md` — Zig language reference
