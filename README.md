# pico

**Zig-based embedded runtime for Raspberry Pi Pico W / Pico 2 W**

Flash once, script forever.

## What is this?

pico is a firmware platform for Raspberry Pi Pico W / Pico 2 W that
boots a bare-metal Zig runtime, brings up MQuickJS, and now proves the
full CYW43439 path through Wi-Fi join and DHCP on real hardware.

## Current status

The CYW43439 stack is now proven on real Pico W hardware through DHCP:

- PIO SPI / gSPI transport at 31 MHz
- firmware + NVRAM upload, HT clock boot
- SDPCM/CDC IOCTL control plane
- CLM upload and onboard LED control
- Wi-Fi scan with hidden-network support
- WPA2-PSK join with retry logic
- raw Ethernet TX/RX (BDC v2)
- DHCP client bound on the LAN without lwIP
- ARP responder and DHCP lease-renewal logic present in the stack

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
zig build

# Build for Pico 2 W
zig build -Dboard=pico2_w

# Generate UF2 for flashing
zig build uf2

# Generate stdlib headers (dev)
zig build gen
```

### Flash the firmware

**Via SWD (recommended for development):**
```bash
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; program zig-out/bin/pico verify reset exit"
picocom -b 115200 /dev/cu.usbmodem201302
```

**Via UF2 (no debug probe needed):**
1. Hold BOOTSEL on the Pico, plug in USB
2. Copy `zig-out/firmware/pico.uf2` to the RPI-RP2 drive
3. The device reboots and starts the runtime

### Current limitation

Remote script upload over TCP is **not wired up yet**. The command parser
exists in `src/net/script_push.zig` and uses the `AppVTable` interface
on the TCP/IP stack in `src/net/tcpip.zig`.

## Architecture

```
┌──────────────────────────────────────┐
│         User Scripts (JS)            │
├──────────────────────────────────────┤
│       MQuickJS Runtime (C)           │
├──────────────────────────────────────┤
│     pico Runtime (Zig)           │
│  event loop · timers · scheduler     │
├──────────────────────────────────────┤
│       Services (Zig → JS)            │
│  wifi · mqtt · gpio · timer · uart   │
│  spi · i2c · usb_host · storage      │
├──────────────────────────────────────┤
│     HAL / Platform (Zig)             │
│  RP2040 / RP2350 · CYW43 · net      │
├──────────────────────────────────────┤
│           Hardware                   │
└──────────────────────────────────────┘
```

## Current JS API

```js
// Console
console.log("hello");
console.warn("caution");
console.error("problem");

// GPIO
gpio.mode(25, 1);       // pin 25 = output
gpio.write(25, 1);      // high
gpio.write(25, 0);      // low
gpio.toggle(25);
var val = gpio.read(0); // read pin 0

// Timers
var id = setTimeout(fn, 1000);
clearTimeout(id);
var id2 = setInterval(fn, 500);
clearInterval(id2);
var ms = timer.millis();

// Planned WiFi API (surface exists, behavior not fully implemented yet)
wifi.connect("ssid", "password");
wifi.disconnect();
wifi.status();  // "connected" | "connecting" | "disconnected"
wifi.ip();      // "192.168.1.42" or null

// Planned MQTT API (stubbed today)
mqtt.connect("mqtt://broker:1883");
mqtt.publish("topic", "message");
mqtt.subscribe("topic", function(msg) { });
mqtt.disconnect();

// Storage (flash KV)
storage.set("key", "value");
var v = storage.get("key");
storage.del("key");

// GC
gc();
```

The Wi-Fi and MQTT JS service surface is present in the tree, but it is
not yet a complete remote-control/network application API. The snippets
above are the intended user-facing shape, not a claim that the full
implementation is available today.

## Project structure

```
pico/
├── build.zig              Zig build system
├── build.zig.zon          Package manifest
├── src/
│   ├── main.zig           Entry point + boot flow
│   ├── platform/          HAL + chip drivers
│   │   ├── hal.zig        Hardware abstraction interface
│   │   ├── rp2040.zig     RP2040 registers + drivers
│   │   ├── rp2350.zig     RP2350 registers + drivers
│   │   ├── boot.zig       Vector table + startup
│   │   ├── rp2040.ld      Linker script (RP2040)
│   │   └── rp2350.ld      Linker script (RP2350)
│   ├── runtime/           Core runtime
│   │   ├── event_loop.zig Cooperative event loop
│   │   ├── scheduler.zig  Task scheduler
│   │   ├── timer.zig      Software timers
│   │   ├── memory.zig     Memory pool manager
│   │   └── panic.zig      Fault handler
│   ├── js/                MQuickJS integration
│   │   ├── engine.zig     JS engine wrapper
│   │   ├── c.zig          Zig declarations for the MQuickJS C API
│   │   ├── pico_stdlib_gen.c   JS stdlib definition source for codegen
│   │   ├── pico_stdlib_data.c
│   │   └── pico_bringup.c      bring-up helpers used by test_main
│   ├── bindings/          JS API bindings
│   │   ├── console.zig    UART output
│   │   ├── gpio.zig       GPIO control
│   │   ├── timer.zig      setTimeout/setInterval
│   │   ├── wifi.zig       Wi-Fi management
│   │   ├── mqtt.zig       MQTT client
│   │   ├── storage.zig    Flash KV store
│   │   ├── uart.zig       UART peripheral
│   │   ├── spi.zig        SPI peripheral
│   │   ├── i2c.zig        I2C peripheral
│   │   └── usb_host.zig   USB host
│   ├── cyw43/             CYW43439 Wi-Fi driver
│   │   ├── mod.zig        Top-level public API
│   │   ├── board.zig      Board abstraction (pins, reset, CS)
│   │   ├── regs.zig       Register definitions and constants
│   │   ├── types.zig      Shared state/error types
│   │   ├── core.zig       Compatibility shim + shared helpers
│   │   ├── transport/     PIO SPI + gSPI bus access
│   │   ├── control/       Boot, ioctl, scan, join, gpio
│   │   ├── protocol/      Event parsing
│   │   ├── netif/         Ethernet TX/RX + service loop
│   │   └── firmware/      Combined firmware + NVRAM blobs
│   ├── net/               Networking
│   │   ├── arp.zig        ARP responder
│   │   ├── dhcp.zig       DHCP client
│   │   ├── tcp.zig        TCP server
│   │   └── protocol.zig   pico control protocol
│   ├── provisioning/      WiFi setup
│   │   └── wifi.zig       AP-mode provisioning
│   └── config/            Configuration
│       ├── config.zig     Device config
│       └── flash.zig      Flash regions
├── ext/
│   └── mquickjs/          MQuickJS engine (vendored)
├── tools/
│   └── uf2conv.zig        ELF → UF2 converter
└── scripts/               Example JS scripts
    ├── blink.js
    ├── hello.js
    └── wifi_blink.js
```

## Build system

The build has two phases:

1. **Host phase**: compiles the MQuickJS stdlib generator tool natively,
   runs it to produce `mquickjs_atom.h` and `pico_stdlib.h` (ROM-resident
   JS standard library data structures).

2. **Cross phase**: compiles the MQuickJS C engine + Zig runtime for the
   target ARM chip, producing an ELF binary that can be converted to UF2.

## Memory budget

| Region | RP2040 | RP2350 |
|--------|--------|--------|
| Firmware code (flash) | ~1 MB | ~2 MB |
| Script storage (flash) | 896 KB | 1.75 MB |
| Config/KV (flash) | 124 KB | 252 KB |
| JS VM heap (SRAM) | 64 KB | 128 KB |
| Runtime stack | 8 KB | 16 KB |

## Roadmap

- [x] Project scaffold + build system
- [x] Platform HAL (RP2040 + RP2350)
- [x] HAL proven on hardware (XOSC, PLL @ 125 MHz, UART, timer)
- [x] Runtime core (event loop, timers, scheduler)
- [x] MQuickJS integration + JS stdlib
- [x] Service stubs (gpio, wifi, mqtt, storage)
- [ ] TCP control protocol transport
- [x] UF2 converter
- [x] MQuickJS JS execution on hardware (`console.log('pico is alive!')`)
- [x] Full `main.zig` runtime boot on hardware (event loop + heartbeat proven)
- [ ] USB host IRQ handler (currently disabled — Bug 15)
- [ ] Flash read/write for config/script storage
- [x] CYW43 WiFi driver (PIO SPI → firmware upload → scan → join → DHCP)
- [x] Raw Ethernet TX/RX and DHCP client
- [x] ARP responder and network service loop
- [ ] Minimal TCP/IP stack
- [ ] MQTT client implementation
- [ ] OTA firmware updates
- [ ] `pico` CLI tool (see PICO.md)
- [ ] BLE provisioning
- [ ] Web dashboard

## License

pico runtime: MIT

MQuickJS: MIT (Fabrice Bellard, Charlie Gordon)
