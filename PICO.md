# pico — Unified Runtime, Debugger, and Deploy System for Microcontrollers

> Working name: **pico**. See naming notes at bottom.

## What is pico?

`pico` is not "probe-rs in Zig." It's a **unified host-side control plane** for microcontrollers — one binary that replaces the entire fragmented mess of embedded development tooling. Debug, flash, deploy, observe, script, orchestrate. No dependencies. No sudo. No Python. No cmake. Nothing.

```
Host (pico)
   ↓ USB / TCP / TLS
Debug Probe (CMSIS-DAP, J-Link, ST-Link, FTDI)
   ↓ SWD / JTAG
Target MCU (ARM Cortex-M, RISC-V)
```

```bash
pico flash firmware.elf        # Program flash via SWD
pico run firmware.elf          # Flash + serial output (the daily workflow)
pico attach                    # Inspect without reset
pico reset                     # Clean chip reset
pico serial                    # Built-in serial terminal
pico push blink.js             # Upload JS script over WiFi
pico repl                      # Live JavaScript REPL
pico logs                      # Stream device output
pico trace                     # Interrupt timeline, memory heatmaps
pico info                      # Chip ID, flash size, firmware version
pico erase                     # Full chip erase
pico read 0x10000000 256       # Read memory
pico write 0x20000000 0xFF     # Write memory
pico session ls                # List active debug sessions
pico remote connect            # Remote debugging over TLS
```

## Why This Tool Must Exist

### The Current State of Embedded Tooling is Broken

To develop for a Raspberry Pi Pico today, you need some combination of:

**For flashing firmware:**
- **OpenOCD** (C, 900+ files, autotools build, requires specific config files for every probe/target combination, version mismatches constantly, cryptic error messages)
- **probe-rs** (Rust, `cargo install` or homebrew, requires sudo on macOS, silently fails to program flash, crashes with "double fault" on RP2040, shows "Erasing" without "Programming" and claims success)
- **picotool** (C++, cmake build, Pico SDK dependency, only works via USB BOOTSEL)
- **UF2 drag-and-drop** (requires physical access to BOOTSEL button, doesn't work when USB port is used for other purposes)

**For serial console:**
- **picocom** (C, separate install, `Ctrl-A Ctrl-X` to exit which conflicts with everything)
- **minicom** (C, separate install, byzantine configuration, AT-modem heritage from 1986)
- **screen** (terminal multiplexer pretending to be a serial tool, `Ctrl-A K Y` to exit)
- **cu** (literally "call unix", from the UUCP era)

**For debugging:**
- **GDB** (separate install, requires GDB server, 40-year-old interface)
- **probe-rs** (see above — broken)
- **OpenOCD + GDB** (two processes, two terminals, two configs, hope the versions match)

### What Actually Happened To Us

In a single development session, we hit every one of these failure modes:

1. **probe-rs `download`** showed "Erasing ✔" and "Finished" but silently skipped Programming. Flash was blank. No error.
2. **probe-rs `run`** crashed with "double fault" at garbage address `0x42824002`.
3. **probe-rs `reset`** booted stale firmware because `download` hadn't written anything.
4. **probe-rs required `sudo`** on macOS. OpenOCD didn't.
5. **picocom** works but is a separate tool with no integration with the flash workflow.
6. **OpenOCD** works but requires memorizing incantations. Can't do serial.
7. **screen** hijacks your terminal. Can't do flashing.

The result: what should be a 2-second "flash and see output" cycle becomes a multi-minute ordeal juggling 3 tools and 2 terminals.

### The Real Cost

This isn't about convenience. It's about **iteration speed**. The edit-compile-flash-test loop is everything.

Current:
```
edit → zig build → close picocom → openocd flash → replug probe → open picocom → read output → repeat
```

With pico:
```
edit → zig build → pico run → output appears
```

Or with watch mode:
```
pico watch    # auto-rebuild, auto-flash, serial output streams live
```

## Architecture

### The Mental Model

probe-rs feels painful because of leaky layering, Rust abstraction overhead in critical paths, CMSIS-Pack dependency hell, and "almost great" UX. We don't want to replicate those mistakes.

pico is built around **clean separation of concerns**:

```
┌───────────────────────────────────────────────────┐
│                   Frontends                       │
│   CLI · DAP Server · GDB Server · Scripting API   │
├───────────────────────────────────────────────────┤
│                    Services                       │
│  Flash · RunControl · Memory · Trace · Channel ·  │
│  Symbol · Terminal · Remote · Orchestration       │
├───────────────────────────────────────────────────┤
│                    Session                        │
│  probe + target + cores + symbols + events +      │
│  caches + capabilities + persistence              │
├───────────────────────────────────────────────────┤
│              Target Execution Model               │
│  halt/resume/step · breakpoints · registers ·     │
│  memory map · flash regions · core enumeration ·  │
│  reset modes · quirks                             │
├───────────────────────────────────────────────────┤
│               Artifact / Program                  │
│  ELF · DWARF/symbols · BIN/IHEX/UF2 · relocation ·│
│  patch planning · semihosting                     │
├───────────────────────────────────────────────────┤
│                Wire Protocols                     │
│          SWD · JTAG · (cJTAG future)              │
├───────────────────────────────────────────────────┤
│                 Probe Drivers                     │
│  CMSIS-DAP · J-Link · ST-Link · FTDI · Remote     │
├───────────────────────────────────────────────────┤
│                   Transports                      │
│     USB HID · USB Bulk · TCP/TLS · Serial · Pipe  │
└───────────────────────────────────────────────────┘
```

### Core Abstractions

**`Probe`** — physical or remote debug adapter. Connect/disconnect, voltage/speed, protocol selection, low-level wire ops.

**`Target`** — discovered chip or core complex. Memory map, flash regions, reset modes, attach/unlock sequences, quirks database.

**`Session`** — the central runtime object. Selected probe + target + attached cores + symbol state + event streams + caches + capability set + persistence metadata. Foundation for remote sessions, reconnect, multi-client attach, IDE + CLI simultaneously.

**`Service`** — stateless operations over a session. FlashService, RunControlService, MemoryService, TraceService, ChannelService, SymbolService.

**`FrontendAdapter`** — CLI, GDB, DAP, scripting. Thin translation over the service layer.

### Module Layout

```
pico/
  transport/          USB HID, USB bulk, TCP/TLS, serial, pipes
  probe/              CMSIS-DAP, J-Link, ST-Link, FTDI drivers
  wire/               SWD engine, JTAG engine
  target/             Chip model, memory map, quirks, auto-introspection
  artifact/           ELF, DWARF, BIN/IHEX/UF2 parsing, symbol lookup
  session/            State machine, caches, capability negotiation
  service/
    flash.zig         Sector erase, program, verify, differential
    run_control.zig   Halt, resume, step, breakpoint/watchpoint manager
    memory.zig        Read/write, memory map awareness
    trace.zig         Interrupt timeline, DMA, peripheral diffing
    channel.zig       Multiplexed log/data/event streams (RTT replacement)
    symbol.zig        Symbolication, DWARF, source correlation
    terminal.zig      Serial console with auto-detect
    remote.zig        TLS sessions, multi-device, persistence
  frontend/
    cli.zig           Command-line interface
    dap.zig           Debug Adapter Protocol server
    gdb.zig           GDB remote serial protocol
    script.zig        JS/Pico scripting API
  pico/               pico-specific: WiFi push, REPL, device logs
```

## Capability Tiers

### Tier 1 — Foundation (non-negotiable)

These are irreducible primitives. Without them, the tool is dead.

#### 1. Probe Abstraction

Plug-in, zero-cost abstraction:

```zig
pub const Probe = union(enum) {
    cmsis_dap: CmsisDap,
    jlink: JLink,
    stlink: STLink,
    ftdi: Ftdi,
    remote: RemoteProbe,
};
```

Table stakes. probe-rs supports all of these. Our opportunity: make it cleanly extensible.

#### 2. SWD / JTAG Transport

The hardest engineering part. Bit-level correctness, retry logic, timing, fault recovery.

Our opportunity: make it **deterministic and observable**. Expose cycle-level tracing hooks for debugging transport issues themselves.

#### 3. Target Control

- halt / run / step / reset
- hardware + software breakpoints (with a resource planner — HW resources are constrained)
- register read/write
- memory read/write
- multi-core aware from day one (RP2040 already has 2 cores)

Core selection explicit everywhere: `session.targets[]`, `core_id`, per-core stop reasons, synchronized halt policy.

#### 4. Flash Programming

Not one thing — treat these separately:
- Generic memory programming
- Flash algorithm execution (Zig-native, no CMSIS-Pack dependency)
- Vendor ROM bootloader use (RP2040 ROM flash helpers)
- External flash / QSPI / XiP handling
- Verify strategy
- **Differential programming** (only flash changed sectors)
- Recovery/unbrick flows

```bash
pico flash firmware.elf            # Flash ELF
pico flash firmware.uf2            # Flash UF2
pico flash firmware.bin 0x10000000 # Flash raw binary at address
pico erase                         # Full chip erase
pico erase 0x10000000 4096         # Erase specific sectors
```

#### 5. Target Database

probe-rs ships hundreds of targets via CMSIS-Pack import. We go further:

- Auto-introspect chip layout on connect
- Memory map, flash layout, core topology, debug AP topology
- Reset semantics, register descriptions, peripheral descriptions
- Flash algorithms / loaders (Zig-native DSL, not CMSIS-Pack XML)
- Errata / quirks system (not just static YAML)
- Attach sequences, security/unlock procedures

### Tier 2 — Required for Real Usage

#### 6. CLI Workflow

What developers actually use daily:

```bash
pico run firmware.elf              # Flash + serial (the default workflow)
pico flash firmware.elf            # Program flash
pico attach                        # Inspect without reset
pico reset                         # System reset
pico reset halt                    # Reset and halt
pico read 0x40034030 4             # Read peripheral register
pico write 0x20000000 0xDEADBEEF   # Write to SRAM
pico reg                           # Dump all CPU registers
pico info                          # Chip ID, flash, ROM version
```

#### 7. Built-in Serial Terminal

No more picocom. No more screen. No more minicom.

- Auto-detection of debug probe's CDC serial port
- Configurable baud rate (default: 115200)
- Clean exit with `Ctrl-C`
- Timestamps, log to file, hex dump mode
- No conflicts with SWD (separate USB endpoints)
- Integrated with flash workflow: `pico run` = flash + serial, no gap

```bash
pico serial                       # Auto-detect, 115200
pico serial -b 9600               # Custom baud
pico serial -t                    # Timestamps
pico serial -l output.log         # Log to file
```

#### 8. Logging / Stream Channels (RTT Replacement)

probe-rs supports RTT and defmt. We replace RTT entirely with a formal channel model:

- Multiplexed named channels (not just "up buffer 0")
- Channel types: text logs, binary frames, metrics, trace events, REPL I/O, file transfer, app-defined topics
- WebSocket streaming
- Structured binary logs with time-series tagging
- Backpressure policy per channel
- Persistence behavior (ring buffer, flush-to-disk, drop)
- Timestamp and clock domain awareness

#### 9. Debug Adapter Protocol (DAP)

Build a richer internal event/state model, then degrade into DAP:

- DAP server for VSCode integration (minimum viable)
- Internal model is richer than DAP — DAP is a thin compatibility shim
- Don't shape internals around DAP protocol assumptions

#### 10. GDB Compatibility

GDB remote serial protocol server. People expect it. Build it as an adapter over the service layer, not a core abstraction.

### Tier 3 — Strategic Differentiators (Where We Crush probe-rs)

#### 11. Remote Debugging (First-Class)

probe-rs has a weak WebSocket server. We make remote first-class:

- TLS built-in (not "add your own")
- Multi-device orchestration
- Persistent sessions with reconnect
- Multi-client attach (IDE + CLI simultaneously)
- Device identity, host identity, credential provisioning
- Audit logging

Design the session/service RPC boundary early — even if first implementation is in-process. Bolting on remote later means rewriting the service boundary.

#### 12. Live Reload / Partial Patching

probe-rs: `cargo run` → flash + run. We go much further:

**Staged ambition:**
1. Differential flash programming (only changed sectors)
2. Section-level hot patch with halt
3. Function patch + resume if safe (needs symbol-level diffing, stack frame analysis)
4. State-preserving live update (ISR patch safety, peripheral state preservation, global re-init strategy)

```bash
pico run firmware.elf              # Full flash
pico reload                        # Differential patch, preserve state
```

#### 13. Introspection / Observability

probe-rs barely touches this. The biggest gap in embedded debugging:

- Memory heatmaps (sampled read patterns)
- Stack evolution over time
- Interrupt timeline
- DMA tracing
- Peripheral register diffing (before/after snapshots)
- Consistent event capture semantics: sampled vs traced vs instrumented
- Source correlation via DWARF
- Composable data model (not isolated features)

```bash
pico trace interrupts              # Interrupt timeline
pico trace memory 0x20000000       # Memory access heatmap
pico diff peripherals              # Register diff snapshot
```

#### 14. Multi-Core / Multi-Device Orchestration

- Orchestrate multiple boards
- Synchronized execution across cores/devices
- Distributed testing
- Fleet management / CI integration

```bash
pico session ls                    # List active sessions
pico attach --device pico-kitchen  # Named device
pico sync halt                     # Halt all cores simultaneously
```

#### 15. Simulation / Hybrid Mode

Not in probe-rs. We could do:

- QEMU + hardware hybrid debugging
- Record/replay execution
- Deterministic stepping

#### 16. Extensible Scripting

probe-rs = Rust API. We embed JS (or future Rip) on the host side:

```js
on("breakpoint", "HardFault", function() {
  dump(0x20000000, 0x1000);
  restart();
});
```

Automation, custom debug flows, CI/CD scripted testing — all via the same JS engine (MQuickJS) that runs on the device.

## Watch Mode

File system watcher that auto-rebuilds and auto-flashes:

```bash
pico watch --build "zig build" --elf zig-out/bin/pico
```

Edit, save, output appears. Hot reload for embedded.

## WiFi Integration (pico Specific)

For pico firmware, pico speaks the pico control protocol over TCP:

```bash
pico push blink.js                 # Upload and run a JS script
pico repl                          # Interactive JavaScript REPL
pico logs                          # Stream device logs over WiFi
pico restart                       # Restart the pico runtime
```

Works over WiFi — no physical connection needed after initial firmware flash. mDNS discovery of pico devices on the network.

## UF2 Conversion

Built-in ELF to UF2 (we already have this in Zig):

```bash
pico uf2 firmware.elf              # Convert to UF2
pico uf2 firmware.elf -o out.uf2   # Custom output path
```

## What pico Replaces

| Current Tool | What It Does | Problems | pico Equivalent |
|---|---|---|---|
| OpenOCD | SWD flash/debug | 900 files of C, config file hell, no serial | `pico flash` |
| probe-rs | SWD flash/debug | Silently fails, requires sudo, crashes on RP2040 | `pico flash` |
| picotool | USB flash | Only works with BOOTSEL, C++ + cmake | `pico flash` via SWD |
| picocom | Serial terminal | Separate install, weird keybindings | `pico serial` |
| minicom | Serial terminal | 1986 modem heritage, byzantine config | `pico serial` |
| screen | Serial terminal | It's a terminal multiplexer, not a serial tool | `pico serial` |
| GDB + server | Debugging | Two processes, 40-year-old interface | `pico attach`, `pico reg` |
| Custom scripts | WiFi upload | Fragile, Python dependency | `pico push` |
| RTT viewer | Device logging | Tied to probe-rs/SEGGER, single channel | `pico logs` |

**Total tools replaced: 9 → 1**

## Why Zig?

- **Single binary, zero dependencies.** Copy it anywhere, it works.
- **Cross-platform from day one.** macOS, Linux, Windows from any host.
- **USB access.** Call C libraries (libusb, hidapi) or platform-native APIs (IOKit, usbfs).
- **Speed.** Native performance for SWD bitbanging, flash programming, serial I/O.
- **Already in the toolchain.** pico developers already have Zig. Same `zig build` workflow.
- **Comptime + generics.** Zero-cost probe abstraction, compile-time protocol dispatch.

## Implementation Plan

### Phase 1: Core SWD + Serial (MVP)

- Transport layer (USB HID via hidapi or platform-native)
- CMSIS-DAP probe driver
- SWD protocol engine (DP/AP register access, retry, fault recovery)
- RP2040 target model (memory map, flash regions, ROM flash helpers)
- Flash service (erase, program, verify via debug trampoline)
- Serial terminal with auto-detect
- Session lifecycle (connect, attach, disconnect)
- CLI: `pico flash`, `pico serial`, `pico run`, `pico reset`, `pico info`

### Phase 2: Debug + Quality of Life

- Run control service (halt, resume, step, breakpoints)
- Memory/register inspection (`pico reg`, `pico read`, `pico write`)
- ELF/DWARF symbol loading
- Watch mode with filesystem watcher
- Log to file, timestamps, hex mode
- Differential flash programming
- Config file for per-project defaults

### Phase 3: WiFi + Channels

- TCP client for pico control protocol
- `pico push`, `pico repl`, `pico logs`
- mDNS device discovery
- Channel multiplexing (RTT replacement)
- WebSocket streaming

### Phase 4: Protocols + Compatibility

- GDB server (adapter over run control service)
- DAP server (adapter over service layer)
- J-Link probe driver
- ST-Link probe driver

### Phase 5: Multi-Target + Remote

- RP2350 support
- STM32, nRF target models
- Remote session protocol (TLS, persistent, multi-client)
- Multi-device orchestration
- RISC-V wire protocol support

### Phase 6: Observability + Live Patch

- Interrupt timeline tracing
- Memory heatmaps
- Peripheral register diffing
- Section-level hot patching
- Scripting API (JS on host side)

## The Killer Idea

Don't build "probe-rs in Zig."

Build: **a unified runtime + debugger + deploy system for microcontrollers.**

Tie it into:
- pico (the Zig firmware on device)
- MQuickJS (the JS engine on device AND host)
- future Rip language server

The result:

> Write code → push over WiFi → debug live → persist state → stream telemetry → orchestrate devices

One tool. One command. It just works.

```
$ pico run firmware.elf

========================
  pico lives!
  Zig on RP2040!
========================

tick 0
tick 1
tick 2
...
```

## The Pony Metaphor

Ronald Reagan once told a story about a boy who was given a room full of horse manure for his birthday. He dove in enthusiastically, shouting: "There's got to be a pony in here somewhere!"

Tonight we dove through:
- probe-rs that silently doesn't program flash
- Three stacked boot bugs (vector table, thumb bits, XOSC reinit)
- Hours of "nothing at any baud rate"

And we found the pony: `tick 42` printing from Zig on bare metal.

pico exists so that nobody else has to dig through that manure. The tooling should be invisible. The only thing that matters is the code you write and what it does on the hardware.

---

## Naming Notes

`pico` is a working name (Zig + Pico). It undersells the scope — this tool targets all ARM/RISC-V MCUs, not just Pico.

The current working name is `pico`. The architecture and capabilities are name-independent.
