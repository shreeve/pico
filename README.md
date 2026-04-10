# pico

**Zig-based embedded runtime for Raspberry Pi Pico W / Pico 2 W**

Flash once, script forever.

## What is this?

pico is a firmware platform for Raspberry Pi Pico W / Pico 2 W that
boots a bare-metal Zig runtime with a custom TCP/IP stack, brings up
MQuickJS, and connects to WiFi — all without lwIP or an OS.

## Current status

Proven on real Pico W hardware:

- Custom CYW43439 WiFi driver (PIO SPI at 31 MHz)
- WPA2-PSK join, DHCP client, ARP, IPv4, ICMP echo reply
- Device responds to `ping` from the LAN
- uIP-inspired TCP/IP stack with app-driven retransmission
- USB Host with FTDI driver + ASTM medical protocol parser
- MQuickJS JavaScript engine running on device
- Watchdog, periodic timer interrupt, `wfe` idle
- UART `reboot` command for probe-free flashing via picotool

The JS engine is [MQuickJS](https://bellard.org/mquickjs/) (Fabrice
Bellard's micro JavaScript engine), which runs full programs in as little
as 10 KB of RAM.

## Supported boards

| Board | Chip | RAM | Flash | WiFi |
|-------|------|-----|-------|------|
| Pico W | RP2040 (Cortex-M0+) | 264 KB | 2 MB | CYW43439 |
| Pico 2 W | RP2350 (Cortex-M33) | 520 KB | 4 MB | CYW43439 |

## Quick start

```bash
# Build firmware (defaults to Pico W)
zig build uf2

# Build with WiFi
zig build uf2 -DSSID='NetworkName:Password'

# Build with USB host (for Piccolo Xpress)
zig build uf2 -DUSB_HOST

# Flash (type "reboot" in picocom first):
picotool load -v -x zig-out/firmware/pico.uf2

# Serial console
picocom -b 115200 --noreset /dev/cu.usbserial-0001
```

### Flash workflow

No debug probe or BOOTSEL button needed:
1. Type `reboot` in picocom
2. `zig build uf2 && picotool load -v -x zig-out/firmware/pico.uf2`
3. Device reboots, serial output resumes

## Architecture

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

## Project structure

```
pico/
├── build.zig              Zig build system
├── build.zig.zon          Package manifest
├── src/
│   ├── main.zig           Entry point + boot flow
│   ├── platform/          HAL + chip drivers
│   │   ├── hal.zig        Chip detect + register helpers
│   │   ├── rp2040.zig     RP2040 drivers (clocks, UART, GPIO, timer, ROM)
│   │   ├── rp2350.zig     RP2350 drivers
│   │   ├── startup.zig    Vector table + BSS/data init
│   │   └── *.ld           Linker scripts
│   ├── runtime/           Core runtime
│   │   ├── event_loop.zig Cooperative event loop
│   │   ├── scheduler.zig  Task scheduler
│   │   ├── timer.zig      Software timers
│   │   ├── memory_pool.zig Fixed memory pool
│   │   ├── watchdog.zig   Watchdog with crash counter
│   │   └── panic.zig      Fault handler
│   ├── js/                MQuickJS integration
│   │   ├── runtime.zig    JS engine wrapper
│   │   ├── quickjs_api.zig Zig bindings for MQuickJS C API
│   │   └── *.c            C sources (stdlib gen, bringup)
│   ├── bindings/          JS API bindings
│   │   ├── console.zig    UART + console.log
│   │   ├── gpio.zig       GPIO control
│   │   ├── timers.zig     setTimeout/setInterval
│   │   ├── wifi.zig       WiFi management
│   │   ├── mqtt.zig       MQTT client (AppVTable)
│   │   ├── storage.zig    Flash KV store
│   │   ├── usb.zig        USB host bindings
│   │   ├── uart.zig       UART peripheral
│   │   ├── spi.zig        SPI peripheral
│   │   └── i2c.zig        I2C peripheral
│   ├── net/               Network stack
│   │   ├── tcpip.zig      Comptime NetStack(Config) — TCP state machine
│   │   ├── global_stack.zig Singleton stack instance
│   │   ├── ipv4.zig       IPv4 parse/route/send
│   │   ├── icmp.zig       Echo reply (ping)
│   │   ├── arp.zig        ARP responder + client cache
│   │   ├── dhcp_client.zig DHCP client
│   │   └── script_push.zig Script push protocol (port 9001)
│   ├── cyw43/             CYW43439 WiFi driver
│   │   ├── cyw43.zig      Public API module
│   │   ├── device.zig     Full lifecycle facade
│   │   ├── board.zig      Pin maps and reset
│   │   ├── regs.zig       gSPI register definitions
│   │   ├── types.zig      State enum + Error set
│   │   ├── control/       Boot, IOCTL, scan, join, GPIO
│   │   ├── transport/     PIO SPI + gSPI bus
│   │   ├── protocol/      WLAN event parsing
│   │   ├── netif/         Ethernet TX/RX + service loop
│   │   └── firmware/      Binary blobs
│   ├── usb/               USB host stack
│   │   ├── host.zig       Host controller
│   │   ├── regs.zig       USB register addresses
│   │   ├── descriptors.zig Descriptor types
│   │   ├── ftdi.zig       FTDI USB-to-serial driver
│   │   └── astm.zig       ASTM E1394 medical protocol
│   ├── config/            Configuration
│   │   ├── device_config.zig Device config from flash
│   │   └── flash_layout.zig Flash regions and addresses
│   ├── provisioning/
│   │   └── captive_portal.zig WiFi AP-mode provisioning (stub)
│   └── libc/              Freestanding C stubs
├── ext/
│   └── mquickjs/          MQuickJS engine (vendored)
├── tools/
│   └── uf2conv.zig        ELF → UF2 converter
└── scripts/               Example JS scripts
```

## Memory budget

| Region | RP2040 | RP2350 |
|--------|--------|--------|
| Firmware (flash) | ~768 KB | ~2 MB |
| OTA staging (flash) | ~768 KB | ~1 MB |
| Script storage (flash) | 256 KB | 512 KB |
| Config/KV (flash) | 192 KB | 256 KB |
| Net stack (SRAM) | ~15 KB | ~15 KB |
| JS VM heap (SRAM) | 96 KB | 128 KB |
| Runtime stack | 8 KB | 16 KB |

## Roadmap

- [x] Platform HAL (RP2040 + RP2350) proven on hardware
- [x] Runtime core (event loop, timers, scheduler, watchdog)
- [x] MQuickJS integration + JS execution on hardware
- [x] CYW43 WiFi driver (PIO SPI → scan → join → DHCP)
- [x] Custom IPv4/ICMP/ARP stack — device responds to ping
- [x] USB host with FTDI + ASTM for Piccolo Xpress
- [x] uIP-inspired TCP/IP stack with AppVTable retransmission
- [x] MQTT client with app-driven TCP
- [x] UF2 converter + picotool flash workflow
- [x] Probe-free development (UART `reboot` + picotool)
- [ ] TCP handshake validation on hardware
- [ ] MQTT end-to-end with Mosquitto broker
- [ ] BearSSL integration for TLS
- [ ] Flash write driver for KV and OTA
- [ ] OTA bootloader with staged updates
- [ ] Production security (signed updates, JS sandboxing)

## License

pico runtime: MIT

MQuickJS: MIT (Fabrice Bellard, Charlie Gordon)
