# Session Handoff — USB Host Bring-Up

This document captures the full context from the USB host bring-up session so a
new AI or developer can pick up exactly where we left off.

## Current State

### Branch: `main`
- clean, proven on hardware
- Wi-Fi/DHCP works via build-time credentials:
  ```bash
  zig build -DSSID='Shreeve:innovation'
  ```
- MQuickJS VM running
- CYW43 firmware loaded, LED blink proven
- PLL_USB (48 MHz) and clk_usb now configured in `src/platform/rp2040.zig`
- USB host code is **not** present on `main`

### Branch: `usb-host-zig-core-v1` (archived)
- first USB host attempt, based on the **older** `misc/pico-usb` reference
- contains proven hardware fixes but outdated software architecture
- do NOT use this as a software architecture base going forward
- DO mine it for hardware-level register knowledge

### Reference code: `misc/picousb` (the CORRECT one)
- newer, more complete USB host library in C
- has pipes abstraction, driver model, FTDI setup, ASTM protocol, callbacks
- **this** is the code that should guide the next Zig USB host implementation
- the older `misc/pico-usb` was an earlier version and should not be used

## Hardware Setup

### Boards
- **Debug probe**: Pico running debugprobe firmware (top board in 3D-printed tray)
- **Target**: Pico W (bottom board)
- Connected via SWD + UART
- Debug probe powers the Pico W

### USB Host Testing
- Cable Creation micro-USB to USB-A female adapter: **confirmed passes data**
- Piccolo Xpress (Abaxis): VID=0x0403, PID=0xCD18, FTDI-based, 9600 8N1
- Piccolo has its own power supply; provides 5V on its USB-B port
- Best test setup: Piccolo's USB-A power cable provides VBUS, data cable
  connects through OTG adapter to Pico W micro-USB

### Build and Flash Commands
```bash
# Build (with Wi-Fi credentials for full boot)
zig build -DSSID='Shreeve:innovation'

# Build (without Wi-Fi, for USB-only work)
zig build

# Flash
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; program zig-out/bin/pico verify reset exit"

# Reset only (when flash is already current)
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; reset_config none; init; reset run; shutdown"

# Serial
picocom -b 115200 --noreset /dev/cu.usbmodem201202
```

### Recovery from wedged SWD/serial
1. close picocom
2. replug the debug probe
3. if needed, hold BOOTSEL on the Pico W during reconnect
4. reopen picocom
5. reflash or reset

## Proven Hardware Facts (carry these forward)

### RP2040 USB Clock Requirement
- `PLL_USB` must be configured at 48 MHz before USBCTRL can come out of reset
- `clk_usb` must be enabled and sourced from PLL_USB
- without this, `RESET_DONE` for USBCTRL will never assert
- **this fix is now on `main`** in `src/platform/rp2040.zig`

### USB Host Register Configuration
- `USB_MUXING` = `TO_PHY | SOFTCON` (0x00000009)
- `USB_PWR` needs `VBUS_DETECT_OVERRIDE_VALUE` set, not just `VBUS_DETECT` and
  `VBUS_DETECT_OVERRIDE_EN`. Without the override value, the controller thinks
  VBUS is absent and never detects device attachment.
- Recommended host-mode USB_PWR:
  ```
  VBUS_DETECT | VBUS_DETECT_OVERRIDE_EN | VBUS_DETECT_OVERRIDE_VALUE |
  OVERCURR_DETECT | OVERCURR_DETECT_EN
  ```
- `MAIN_CTRL` = `CONTROLLER_EN | HOST_NDEVICE` (0x00000003)
- `SIE_CTRL` host base = `PULLDOWN_EN | VBUS_EN | KEEP_ALIVE_EN | SOF_EN`
  - readback may show only PULLDOWN_EN | SOF_EN (bits 4,5 are non-latching)
  - this is expected RP2040 behavior, not a bug

### SIE_STATUS Speed Bits Are W1C
- the ISR must capture speed from `SIE_STATUS` **before** clearing
- after clearing, speed reads as zero
- pass the captured speed through the event queue to the main loop
- do NOT re-read SIE_STATUS for speed after the ISR has cleared it

### Bus Reset Behavior
- bus reset (SE0 for 50ms) causes spurious connect/disconnect at electrical level
- must mask `HOST_CONN_DIS` interrupt during bus reset
- must disable NVIC USB IRQ during bus reset to prevent ISR from firing
- after bus reset, clear all SIE_STATUS, flush event queue, then re-enable
- device connect was proven on hardware with this approach

### USBCTRL Reset State
- on warm restart, USBCTRL may already be held in reset (bit 24 of RESETS)
- if so, clearing the reset bit and waiting for RESET_DONE may hang
  without PLL_USB/clk_usb running
- the archived branch has diagnostic code for detecting and recovering
  from this condition

## What the Archived Branch (`usb-host-zig-core-v1`) Contains

### Worth mining
- `src/platform/rp2040.zig`: PLL_USB + clk_usb init (already on `main`)
- `src/usb/regs.zig`: USB register definitions and PWR_HOST_MODE constant
- `src/usb/host.zig`: ISR event queue, NVIC handling, reset diagnostics,
  bus reset with interrupt masking, device speed detection
- `src/usb/descriptors.zig`: safe descriptor parsing helpers
- `src/usb/js.zig`: MQuickJS bindings for USB host

### Do NOT reuse as architecture
- the transfer/control model was based on the older `pico-usb` reference
- the newer `picousb` has a significantly better architecture:
  - pipes instead of raw endpoints
  - driver registration model
  - per-transfer callbacks
  - FTDI device setup
  - ASTM protocol handling
  - proper command() helper for synchronous control transfers

## What Was Proven on Hardware

In chronological order:
1. USB controller init completes (all 13 breadcrumb steps pass)
2. Device connect interrupt fires when USB device is plugged in
3. Device speed is correctly detected as full-speed
4. Bus reset completes cleanly without disconnect storm
5. System remains stable in event loop after bus reset
6. Multiple connect/disconnect cycles work reliably

## What Was NOT Yet Proven
- EP0 control transfer (GET_DESCRIPTOR)
- SET_ADDRESS
- Full enumeration
- FTDI device setup
- Bulk data transfer
- Piccolo ASTM protocol communication

## Next Steps (for the new USB host branch)

1. Fork from `main` (which now has PLL_USB/clk_usb)
2. Study `misc/picousb/src/picousb.c` and `picousb.h` deeply
3. Build the Zig USB host layer following the `picousb` architecture
4. Carry forward the hardware register knowledge from above
5. Start with: init → detect → bus reset → GET_DESCRIPTOR(8) → SET_ADDRESS
6. Then: full enumeration → FTDI setup → bulk transfer → ASTM protocol

## Key Files to Read

### New reference (USE THIS)
- `misc/picousb/src/picousb.c` — the full USB host library
- `misc/picousb/src/picousb.h` — types, structs, API
- `misc/picousb/src/main.c` — Piccolo-specific application code
- `misc/picousb/src/usb_common.h` — USB 2.0 constants
- `misc/picousb/docs/enumeration.md` — enumeration log
- `misc/picousb/docs/usb-overview.md` — USB protocol reference

### Old reference (for hardware behavior only)
- `misc/pico-usb/host/host.c` — older version, less complete
- `misc/pico-usb/usb-rp2040.md` — RP2040 USB register documentation

### Project documentation
- `AGENTS.md` — AI agent instructions and RP2040 gotchas
- `NETWORKING.md` — Wi-Fi/DHCP status
- `CYW43.md` — CYW43 bring-up reference
- `ISSUES.md` — known issues

### Archived USB work (for register-level reference)
- `usb-host-zig-core-v1` branch
- `src/usb/AI-AUDIT.md` (on archived branch) — detailed audit of the first attempt
- `misc/pico-usb/AI-REVIEW.md` — review of the old C code

## Piccolo Xpress Details

- Manufacturer: Abaxis Inc.
- Product: piccolo xpress
- Serial: AVP09880
- VID: 0x0403 (FTDI)
- PID: 0xCD18
- USB class: vendor-specific (FTDI, not standard CDC ACM)
- Communication: 9600 8N1 over FTDI USB serial
- Protocol: ASTM (laboratory instrument data protocol)
- Has its own power supply (independent of USB VBUS)
- Sends structured text data including test results, hex blocks, timestamps

## Debug Probe DX Issues

The Pico Debug probe's USB-CDC serial bridge is fragile:
- OpenOCD flash/reset cycles can wedge the UART bridge
- picocom shows "Terminal ready" but no data
- fix: replug the debug probe
- the `reset_config none` variant of the reset command is more reliable
- do NOT use `stty` + `cat` for serial on macOS (corrupts CDC state)
- always use picocom

A smarter debug probe with target power control would dramatically
improve DX. The 3D-printed tray already has the right physical layout;
it just needs a load switch for target power and a GPIO for target RUN.
