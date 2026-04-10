# Session Handoff — Pico Firmware

This document captures the full context so a new AI or developer can pick
up exactly where we left off.

## Current State (April 10, 2026)

### Branch: `main` — proven on hardware

Everything is on `main`. No feature branches. Clean working tree.

**Validated on real Pico W hardware:**
- CYW43 WiFi: PIO SPI → firmware upload → scan → WPA2-PSK join → DHCP
- ICMP echo reply (device responds to `ping`)
- IPv4 layer with generic demux (ICMP/UDP/TCP), checksum validation, routing
- ARP client/cache with outbound resolution and gratuitous ARP
- MQuickJS running JavaScript (`console.log("pico is alive!")`)
- USB Host with FTDI driver + ASTM protocol for Piccolo Xpress analyzer
- UART `reboot` command triggers ROM `reset_usb_boot()` for probe-free flashing
- Watchdog (8s) with crash counter and safe-mode detection
- 10ms periodic timer interrupt enabling `wfe` idle

**Not yet validated:**
- TCP handshake (stack is written, not tested on hardware)
- MQTT broker connection
- Script push over TCP port 9001
- OTA firmware update
- Flash KV write (read works via XIP, write needs RAM flash driver)

### Architecture

```
┌──────────────────────────────────────┐
│         User Scripts (JS)            │
├──────────────────────────────────────┤
│       MQuickJS Runtime (C)           │
├──────────────────────────────────────┤
│     pico Runtime (Zig)               │
│  event loop · timers · scheduler     │
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
├── main.zig                  Entry point + boot flow
├── test_support.zig          Test harness re-exports
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
│   ├── global_stack.zig      Singleton stack instance bridge
│   ├── ipv4.zig              IPv4 parse/route/send + stats
│   ├── icmp.zig              Echo reply (ping)
│   ├── arp.zig               ARP responder + 8-entry client cache
│   ├── dhcp_client.zig       DHCP client with lease renewal
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
│   ├── event_loop.zig        Cooperative event loop
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
├── provisioning/
│   └── captive_portal.zig    WiFi AP-mode provisioning (stub)
└── libc/                     Freestanding C stubs
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
- **19 observability counters**: ip_rx, ip_bad_checksum, arp_hits/misses, tcp_retx, etc.
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
```

### Hardware Setup

Two USB cables to Mac:
1. **CP2102** (USB-to-serial) → Pico W GP0/GP1 (UART TX/RX/GND)
2. **USB-C** → Pico W (power + UF2 flashing)

Optional: Raspberry Pi Debug Probe for SWD (not needed for normal dev).

### Flash Workflow

1. Type `reboot` in picocom → device enters BOOTSEL mode
2. `zig build uf2 && picotool load -v -x zig-out/firmware/pico.uf2`
3. Device reboots, picocom shows boot banner

No debug probe, no BOOTSEL button, no OpenOCD.

## What Is Next

1. **Test TCP handshake** on hardware — connect to a server or accept connection
2. **Test MQTT** end-to-end with Mosquitto broker
3. **Integrate BearSSL** for TLS (MQTT over port 8883, HTTPS for OTA)
4. **Implement flash write driver** (RAM-resident, for KV storage.set() and OTA)
5. **Build OTA bootloader** (immutable, SHA-256 verification, staged update)
6. **Production security**: signed updates, authenticated script upload, JS sandboxing

## Piccolo Xpress Details

- Manufacturer: Abaxis Inc.
- Product: piccolo xpress
- VID: 0x0403 (FTDI), PID: 0xCD18
- Communication: 9600 8N1 over FTDI USB serial
- Protocol: ASTM E1394 (laboratory data, ENQ/ACK/EOT framing)
- Has its own power supply

## Key Documentation

- `AGENTS.md` — AI agent instructions and RP2040 gotchas
- `NETWORKING.md` — WiFi/networking status and architecture
- `CYW43.md` — CYW43 bring-up reference
- `PICO.md` — Host-side CLI tool vision
- `ZIG-0.15.2.md` — Zig language reference
