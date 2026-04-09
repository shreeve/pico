# AI Agent Instructions for pico firmware

## Start Here

Read these files in order:
1. **This file** — priorities, workflow, tools
2. **NETWORKING.md** — current networking state, milestones, and next steps
3. **CYW43.md** — low-level CYW43 bring-up and protocol findings
4. **ZIG-0.15.2.md** — Zig language reference (API changes from older versions)

## What We're Building

**pico** is the firmware/runtime in this repository: a Zig-based embedded OS for Raspberry Pi Pico W that hosts MQuickJS (Fabrice Bellard's micro JavaScript engine). The stack:

- **Bottom**: Zig HAL — bare metal RP2040 at 125 MHz. USB host, GPIO, UART, SPI, WiFi (CYW43), flash storage. Must be tight and fast.
- **Middle**: MQuickJS — 18K-line C engine compiled alongside Zig. Manual bindings in `vm/c.zig`. Freestanding C support in `libc/`.
- **Top**: User JavaScript scripts — pushed over WiFi, stored in flash, run instantly. No firmware rebuild.

There is also a secondary objective: a host-side CLI/debug tool described in `PICO.md`. It is lower priority than the firmware/runtime in this repository.

## Current Milestone

**ACHIEVED: DHCP working on real Pico W hardware.**

The full path from bare metal to IP is now proven on hardware: PIO SPI at 31 MHz → firmware upload → IOCTL control plane → CLM upload → LED blink → Wi-Fi scan → WPA2-PSK join → Ethernet TX/RX → DHCP bound at `10.0.0.27`.

**Next milestone: ARP validation + TCP/IP, then TLS and MQTT.**

## Known-Good Wi-Fi Recovery

If you need to get back to the last known-good "boot → join Wi-Fi → DHCP" flow,
use the `main` branch at commit `f0f0ac3`.

Important facts about the current tree:

- `src/services/storage.zig` is still a stub, so runtime flash-backed Wi-Fi
  config does NOT work yet
- `src/services/wifi.zig.connect()` is still a facade and does NOT drive the
  real CYW43 join path yet
- the currently proven path is the older build-time credential flow inside
  `src/cyw43/control/boot.zig`

That means: if you want to reproduce the known-good Wi-Fi path, do NOT rely on
runtime config loading from flash. Instead, build with credentials:

```bash
zig build -DSSID='Shreeve:innovation'
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; program zig-out/bin/pico verify reset exit"
```

Expected UART log shape on success:

- `[cyw43] scan started`
- `[join] configuring WPA2-PSK...`
- `[join] associated!`
- `[dhcp] starting...`
- `[dhcp] offer 10.0.0.27 from 10.0.0.1`
- `[dhcp] bound 10.0.0.27 gw 10.0.0.1 mask 255.255.255.0`
- `[wifi] IP=10.0.0.27`

If the log shows:

- scan results
- then immediately `[boot] no active Wi-Fi link — provisioning mode`

that means the firmware was built without `-DSSID=...`, or the runtime config
path was expected to provide credentials (it currently cannot).

The USB host rewrite work was split out to branch `usb-host-zig-core` so that
`main` can still be used as the Wi-Fi/DHCP recovery branch.

## AI Peer Review (MCP) — USE THIS

You have access to **GPT-5.4** as a peer reviewer via the `user-ai` MCP server. **Use it proactively** — it was critical to achieving the MQuickJS milestone. In that session, GPT-5.4:

- Identified the `this_val` ABI risk in native callbacks (turned out correct for MQuickJS)
- Recommended C wrappers for fragile Zig↔C boundary APIs — this avoided hours of debugging
- Pushed for staged bring-up with UART breadcrumbs at every step — essential for finding the memset crash
- Suggested splitting eval into "1+1" then "console.log" to isolate VM core from callback ABI

**Tools** (call via `user-ai` MCP server):
- **`review`** — send code for structured review. Include `language: "zig"` and describe context.
- **`chat`** — quick questions, second opinions on architecture decisions, debugging hypotheses.
- **`discuss`** — multi-turn conversations for complex design. Pick a `conversation_id` and reuse it.

**Important**: GPT-5.4 doesn't see your Cursor context. Always include relevant code snippets and explain what the code does. Attribute feedback: "GPT-5.4 suggests..."

## Build & Test Workflow

```bash
# Build
zig build              # Full firmware with MQuickJS (193KB ELF)
zig build test-main    # MQuickJS staged bring-up (PROVEN — milestone achieved)
zig build test-hal     # HAL integration test (proven working)
zig build test-uart    # Minimal UART test (proven working)

# Flash via OpenOCD (the ONLY reliable method — probe-rs is broken)
# Use full erase for clean flash, especially after crashes:
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; init; halt; flash erase_address 0x10000000 0x200000; \
      program zig-out/bin/test-main verify; reset run; exit"

# Flash via UF2 (BOOTSEL mode — no debug probe needed)
# Hold BOOTSEL while plugging in Pico W USB, then:
cp /tmp/firmware.uf2 /Volumes/RPI-RP2/

# ┌───────────────────────────────────────────────────────────┐
# │  SERIAL: MUST use picocom. NEVER use stty+cat or screen.  │
# │  stty+cat CORRUPTS the CDC serial state on macOS.         │
# │  This is not a suggestion — it breaks the hardware link.  │
# └───────────────────────────────────────────────────────────┘
picocom -b 115200 /dev/cu.usbmodem201202

# Reset target while picocom is open (separate terminal)
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; init; reset run; exit"

# Debug: read hardware registers via SWD
openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "adapter speed 1000; init; targets rp2040.core0; halt; \
      mem2array r 32 <ADDR> <COUNT>; echo \"\$r(0) \$r(1)\"; \
      resume; exit"
```

## Hardware Debug Setup

- Debug probe: original Pico running Picoprobe/debugprobe firmware
- Target UART: debug probe `GP4 -> target GP1`, `GP5 <- target GP0`
- Serial: `115200` baud on `/dev/cu.usbmodem201202` (may vary by USB port)

## RP2040 Gotchas (hard-won knowledge)

These are real bugs we hit and fixed. Do NOT reintroduce them:

1. **XOSC**: Always write full CTRL register (`0xFAB_AA0`), never use SET alias alone. SET alias corrupts FREQ_RANGE.

2. **clk_peri**: Must be explicitly enabled (`CLK_PERI_CTRL bit 11`). UART and SPI cannot come out of reset without it.

3. **Operator precedence**: In Zig, `==` binds tighter than `&`. Every `regRead(addr) & mask == value` MUST have parentheses: `(regRead(addr) & mask) == value`. Without them, the comparison is always false.

4. **Vector table thumb bit**: The Zig linker sets bit 0 on Thumb function symbols. Do NOT add `+ 1` in the vector table assembly.

5. **PLL registers**: PWR is at offset 0x04, FBDIV_INT is at 0x08. These are commonly swapped in documentation/examples.

6. **PRIM post-dividers**: Use actual divider values (6 and 2), not value-1.

7. **boot2 must be included**: The main firmware and any flash-based test must compile and link `boot2.c` and have a BOOT2 region in the linker script at 0x10000000.

8. **Pico W has no reset button**: Only BOOTSEL (USB boot mode). Use OpenOCD `reset run` for firmware reset during development.

9. **probe-rs is broken for RP2040**: Silently fails to program flash, crashes with double faults. Use OpenOCD exclusively.

10. **`src/libc/stubs.c` must NOT use `__builtin_memset/memcpy/memmove`**: LLVM on freestanding ARM compiles these as calls to `memset`/`memcpy`/`memmove`, causing infinite recursion. Use manual byte loops.

11. **NEVER use `stty` + `cat` for serial on macOS**: This CORRUPTS the CDC serial state and BREAKS the USB serial link — not just garbled output, it makes the port unusable until power-cycle. **Always use `picocom -b 115200 --noreset`.** Do not use `screen` either. picocom is the ONLY safe serial tool for this project.

12. **Watchdog TICK must be configured for XOSC**: After switching clk_ref to 12 MHz XOSC, the watchdog TICK register (0x4005802C) must be set to `(1 << 9) | 12` for correct 1 µs timer ticks. Without this, the microsecond timer runs ~42x too slow. **Fixed** in `initClocks()`.

15. **USB host init hangs CPU**: `usb_host.init()` enables USB INTE register. If any status bit is pending, the IRQ fires into `_default_handler` (infinite nop loop). Fix: add proper USBCTRL_IRQ handler to vector table. Currently disabled in main.zig.

16. **PLL clock switch fails in tiny binaries**: Firmware under ~2KB can't switch CLK_SYS from ref to PLL. The glitchless mux needs time to settle. Not an issue for production builds (MQuickJS makes the binary ~130KB).

13. **RP2040 SWD locks up when firmware is running**: OpenOCD often can't reconnect after firmware starts. Power cycle (unplug/replug debug probe) is the reliable recovery. Full chip erase before programming prevents stale flash conflicts.

14. **Replug debug probe after every OpenOCD flash**: OpenOCD's halt/program cycle corrupts the debug probe's UART-to-CDC serial bridge. picocom shows "Terminal ready" but receives no data. Fix: close picocom → unplug/replug debug probe → reopen picocom. If SWD is locked (can't flash), hold BOOTSEL on the Pico W during the replug to prevent firmware from running, then flash.

17. **CYW43 CHIPCOMMON_CHIPID low 16 bits are the decimal chip number, not the marketing shorthand**: For CYW43439, `bpRead32(0x18000000)` returns raw word `0x1545A9AF`. Bits [15:0] = `0xA9AF` (chip ID = 43439 decimal), bits [19:16] = `0x5` (chip revision), bits [31:20] = package/other info. This is standard across Broadcom Silicon Backplane architecture (BCM4329 stores `0x4329`, BCM43438 stores `0xA99E`, etc.). Do NOT expect `0x4373` — that is the marketing shorthand, not the register value. The TXSTALL wait for write-only SPI transactions is also critical: the gSPI protocol requires the host to wait for PIO shift completion before releasing CS, otherwise the backplane write may not complete. The high byte of the window address is particularly susceptible since it is the last byte written.

18. **CYW43 SPI backplane block writes MUST use 64-byte chunks and SRAM staging**: The SDK defines `CYW43_BUS_MAX_BLOCK_SIZE = 64` for SPI (in `cyw43_ll.h`) and enforces it with `assert(fn != BACKPLANE_FUNCTION || (len <= CYW43_BUS_MAX_BLOCK_SIZE))`. The 64-byte limit is a real hardware constraint of the CYW43's SPI-to-backplane bridge FIFO. Writing 512-byte blocks causes the FIFO to overflow — writes are silently dropped or go to wrong addresses, producing a characteristic `0xc51b0000` readback pattern (default/uninitialized SRAM). Each chunk must also be copied from flash to a SRAM buffer before the SPI transfer: on RP2040, XIP flash cannot reliably be used as a source for PIO SPI in all configurations, and the SDK's `memcpy` to `spid_buf` handles both the FIFO limit and the XIP concern.

19. **CYW43 bulk firmware payload words must be packed LITTLE-endian**: The final firmware boot blocker was that `writeCmdAndBytesRaw()` packed bytes big-endian within each 32-bit word. Full-image verification caught this at offset `0x1000`: expected `0x00801BD4`, got `0xD41B8000` — exactly the byte-swapped form. Changing the bulk payload packer to little-endian made `verify OK` pass and allowed `HT clock OK — firmware running`.

20. **CYW43 backplane window registers are WRITE-ONLY from SPI**: You cannot read back the window registers at `0x1000A/B/C` to verify their contents. The SDK tracks the current window in `self->cur_backplane_window` and only writes bytes that changed. If window state gets out of sync (e.g., after an error recovery), force-write all three bytes. The SDK resets to `CHIPCOMMON_BASE_ADDRESS` after each backplane access as a safety measure.

21. **SDK documents 16-byte SPI backplane read padding, but the current proven path uses 4 bytes**: `CYW43_BACKPLANE_READ_PAD_LEN_BYTES = 16` is an SDK fact, but in this Zig path the `SPI_RESP_DELAY_F1` write was not yet proven effective. The current working implementation uses 4-byte backplane padding; treat 16-byte padding as a reference behavior to revisit only if backplane read issues reappear.

## Zig 0.15.2 Key Points

- `callconv(.C)` → `callconv(std.builtin.CallingConvention.c)` — use `const CC = std.builtin.CallingConvention;` then `callconv(CC.c)`
- `addExecutable` requires `.root_module` from `b.createModule(...)`
- `@setCold` removed, `usingnamespace` removed, `opaque` is a keyword
- `@import("root")` refers to the build system's root source file — used by boot.zig
- For freestanding ARM: no libc, no stack unwinding, `@memset`/`@memcpy` are compiler builtins
- See `ZIG-0.15.2.md` for the comprehensive reference

17. **SDPCM credit check before every IOCTL send**: The CYW43 firmware flow-controls the host via SDPCM credits. Before sending any IOCTL frame, check `(sdpcm_last_credit -% sdpcm_tx_seq) & 0xFF != 0`. If no credits, poll with `pollDevice()` until one arrives. Without this, rapid IOCTL sequences (like the WPA2 join setup) silently drop packets and the host times out waiting for a response that was never delivered.

18. **`bsscfg:` iovars encode an extra u32 interface index**: Unlike regular iovars (`name\0` + payload), `bsscfg:` iovars encode as `name\0` + `u32 bsscfg_index` + `u32 value`. For STA mode, index = 0. Omitting the index corrupts the value the firmware sees.

19. **pollDevice must drain ALL pending packets, not just one**: The CYW43 SPI interrupt fires once when data is available. If multiple packets queue (e.g., an event + a control response), reading one and clearing the interrupt loses the second. The doIoctl response wait MUST loop `while (pollDevice() != .none)` to drain everything before sleeping. Use the status register (not interrupt register) to check for pending packets.

20. **BDC TX header must use version 2 (0x20)**: Data frames sent to CYW43 need BDC version 2 in byte 0 of the 4-byte BDC header. Version 0 (all zeros) causes the firmware to silently drop the frame — no error, just never transmitted over the air. Both Pico SDK and Embassy use `0x20`.

## Code Style

- Register addresses use `0x4002_4000` underscore notation for readability
- HAL functions: `hal.regWrite(addr, val)`, `hal.regRead(addr)`, `hal.regSet(addr, mask)`, `hal.regClr(addr, mask)`
- Inline volatile access: `@as(*volatile u32, @ptrFromInt(addr)).* = val`
- Test files are standalone: `test_uart.zig` and `test_hal.zig` can boot independently
- Comments explain hardware behavior and register semantics, not obvious code flow
