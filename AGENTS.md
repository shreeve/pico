# AI Agent Instructions for pico firmware

## Start Here

Read these files in order:
1. **This file** — priorities, workflow, tools
2. **HANDOFF.md** — current state, source tree, what's proven, what's next
3. **docs/NETWORKING.md** — networking stack status and architecture
4. **docs/CYW43.md** — low-level CYW43 bring-up and protocol findings
5. **docs/ZIG-0.15.2.md** — Zig language reference (API changes from older versions)

## What We're Building

**pico** is the firmware/runtime in this repository: a Zig-based embedded OS for Raspberry Pi Pico W that hosts MQuickJS (Fabrice Bellard's micro JavaScript engine). The stack:

- **Bottom**: Zig HAL — bare metal RP2040 at 125 MHz. USB host, GPIO, UART, SPI, WiFi (CYW43), flash storage. Must be tight and fast.
- **Middle**: MQuickJS — 18K-line C engine compiled alongside Zig. Manual bindings in `js/quickjs_api.zig`. Freestanding C support in `libc/`.
- **Top**: User JavaScript scripts — pushed over WiFi, stored in flash, run instantly. No firmware rebuild.

There is also a secondary objective: a host-side CLI/debug tool described in `PICO.md`. It is lower priority than the firmware/runtime in this repository.

## Current Milestone

**ACHIEVED: Custom TCP/IP stack with ICMP ping validated on hardware.**

The full path from bare metal to pingable device: PIO SPI → CYW43 firmware → IOCTL → Wi-Fi scan → WPA2-PSK join → Ethernet TX/RX → DHCP → IPv4 → ICMP echo reply. Device responds to `ping` from the LAN.

**Next milestone: TCP handshake validation, then MQTT broker connection.**

## Build & Flash Workflow

```bash
# Development build (no WiFi)
zig build uf2

# WiFi build
zig build uf2 -DSSID='NetworkName:Password'

# USB host build (for Piccolo Xpress)
zig build uf2 -DUSB_HOST

# Flash (type "reboot" in picocom first):
picotool load -v -x zig-out/firmware/pico.uf2

# Serial console (CP2102 adapter)
picocom -b 115200 --noreset /dev/cu.usbserial-0001

# Serial console (debug probe UART)
picocom -b 115200 --noreset /dev/cu.usbmodem201202
```

The primary dev workflow requires NO debug probe and NO BOOTSEL button:
1. Type `reboot` in picocom → device enters BOOTSEL via ROM `reset_usb_boot()`
2. `zig build uf2 && picotool load -v -x zig-out/firmware/pico.uf2`
3. Device reboots, picocom shows boot banner

## Hardware Setup

Two USB cables to Mac:
1. **CP2102** (USB-to-serial) → Pico W GP0/GP1 (TX/RX/GND)
2. **USB-C** → Pico W (power + UF2 flashing)

Optional: Raspberry Pi Debug Probe for SWD debugging.

## AI Peer Review (MCP) — USE THIS

You have access to **GPT-5.4** as a peer reviewer via the `user-ai` MCP server. **Use it proactively.**

**Tools** (call via `user-ai` MCP server):
- **`review`** — send code for structured review. Include `language: "zig"` and describe context.
- **`chat`** — quick questions, second opinions on architecture decisions, debugging hypotheses.
- **`discuss`** — multi-turn conversations for complex design. Pick a `conversation_id` and reuse it.

**Important**: GPT-5.4 doesn't see your Cursor context. Always include relevant code snippets and explain what the code does. Attribute feedback: "GPT-5.4 suggests..."

## RP2040 Gotchas (hard-won knowledge)

These are real bugs we hit and fixed. Do NOT reintroduce them:

1. **XOSC**: Always write full CTRL register (`0xFAB_AA0`), never use SET alias alone. SET alias corrupts FREQ_RANGE.

2. **clk_peri**: Must be explicitly enabled (`CLK_PERI_CTRL bit 11`). UART and SPI cannot come out of reset without it.

3. **Operator precedence**: In Zig, `==` binds tighter than `&` and `|`. Every bitwise comparison MUST have parentheses: `(regRead(addr) & mask) == value`, `d == ((local & mask) | ~mask)`. Without them, the comparison is always wrong.

4. **Vector table thumb bit**: The Zig linker sets bit 0 on Thumb function symbols. Do NOT add `+ 1` in the vector table assembly.

5. **PLL registers**: PWR is at offset 0x04, FBDIV_INT is at 0x08. These are commonly swapped in documentation/examples.

6. **PRIM post-dividers**: Use actual divider values (6 and 2), not value-1.

7. **boot2 must be included**: The main firmware and any flash-based test must compile and link `boot2.c` and have a BOOT2 region in the linker script at 0x10000000.

8. **Pico W has no reset button**: Only BOOTSEL. Use `reboot` UART command + picotool for development.

9. **probe-rs is broken for RP2040**: Silently fails to program flash, crashes with double faults. Use OpenOCD or picotool.

10. **`src/libc/stubs.c` must NOT use `__builtin_memset/memcpy/memmove`**: LLVM on freestanding ARM compiles these as calls to `memset`/`memcpy`/`memmove`, causing infinite recursion. Use manual byte loops.

11. **NEVER use `stty` + `cat` for serial on macOS**: Corrupts the CDC serial state. Always use picocom.

12. **Watchdog TICK must be configured for XOSC**: After switching clk_ref to 12 MHz XOSC, set watchdog TICK to `(1 << 9) | 12` for correct 1 µs timer ticks.

13. **RP2040 SWD locks up when firmware busy-loops**: The `wfe` instruction in the main loop (with periodic timer interrupt) gives SWD a window to connect. Without it, OpenOCD can't halt the core.

14. **USB host init hangs CPU**: `usb_host.init()` enables USB INTE register. If any status bit is pending, the IRQ fires into `_default_handler`. Fix: proper USBCTRL_IRQ handler in vector table. Gated behind `-DUSB_HOST` build flag.

## CYW43 Gotchas

15. **SPI backplane block writes MUST use 64-byte chunks**: Hardware constraint of the CYW43's SPI-to-backplane bridge FIFO. Writing larger blocks silently corrupts firmware uploads.

16. **Bulk firmware payload words must be packed LITTLE-endian**: Big-endian packing was the final firmware boot blocker.

17. **Backplane window registers are WRITE-ONLY from SPI**: Track window state in software. Force-write all three bytes after error recovery.

18. **SDPCM credit check before every IOCTL send**: Without this, rapid IOCTL sequences silently drop packets.

19. **`bsscfg:` iovars encode an extra u32 interface index**: Omitting the index corrupts the value.

20. **pollDevice must drain ALL pending packets**: Reading one and clearing the interrupt loses subsequent packets.

21. **BDC TX header must use version 2 (0x20)**: Version 0 silently drops data frames.

## BearSSL/TLS Gotchas

22. **`BR_ARMEL_CORTEXM_GCC` uses Thumb-2 assembly**: Despite documentation saying "Cortex M0, M0+", the inline asm uses Thumb-2 instructions (`eor Rd, Rn`, three-operand `sub`). Set `BR_ARMEL_CORTEXM_GCC=0` for Cortex-M0+. Use `BR_LOMUL=1` instead for the important optimization (prefer 32×32→32 multiply).

23. **TLS records cannot be regenerated for TCP retransmit**: The TCP stack's `produce_tx()` pattern assumes payload can be re-created on demand. TLS sequence numbers advance per record, making re-encryption produce different ciphertext. The TLS adapter must maintain a ciphertext retention buffer between BearSSL sendrec output and TCP ACK.

24. **BearSSL `resume` is a Zig keyword**: Parameter names from the C API that clash with Zig keywords must be renamed in bindings (e.g. `resume` → `resume_session`).

## Zig 0.15.2 Key Points

- `callconv(.C)` → `callconv(std.builtin.CallingConvention.c)` — use `const CC = std.builtin.CallingConvention;` then `callconv(CC.c)`
- `addExecutable` requires `.root_module` from `b.createModule(...)`
- `@setCold` removed, `usingnamespace` removed, `opaque` is a keyword
- `@import("root")` refers to the build system's root source file — used by startup.zig
- For freestanding ARM: no libc, no stack unwinding, `@memset`/`@memcpy` are compiler builtins
- See `docs/ZIG-0.15.2.md` for the comprehensive reference

## Code Style

- Register addresses use `0x4002_4000` underscore notation for readability
- HAL functions: `hal.regWrite(addr, val)`, `hal.regRead(addr)`, `hal.regSet(addr, mask)`, `hal.regClr(addr, mask)`
- Inline volatile access: `@as(*volatile u32, @ptrFromInt(addr)).* = val`
- Test files are standalone: `test_uart.zig` and `test_hal.zig` can boot independently
- Comments explain hardware behavior and register semantics, not obvious code flow
- File names are self-documenting: `bindings/mqtt.zig`, `net/tcpip.zig`, `js/quickjs_api.zig`
- JS bindings live in `bindings/`, drivers in their subsystem dirs, protocols in `net/`
