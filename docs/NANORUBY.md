# Nanoruby on pico — integration plan

## Handoff preflight (run before touching code)

This doc is a self-contained execution plan. Before starting A1, verify every item below passes. If any fails, stop and resolve before proceeding.

- [ ] `zig version` prints `0.16.0` (stock upstream release).
- [ ] `git log --oneline -3` shows commits `1dfbff9` (this plan), `eb7452c` (test-hal/test-main fixes), and `c297361` (0.16.0 migration).
- [ ] `ls ~/Data/Code/nanoruby/src/vm/vm.zig` returns a real file. **If nanoruby lives elsewhere on your machine, update every `~/Data/Code/nanoruby` reference in this doc before executing A1.**
- [ ] `git status` shows the expected pre-existing dirty state:
      `M src/main.zig`, `?? src/ruby/`. That is *not* uncommitted migration work — it is the user's pre-migration nanoruby demo that this plan absorbs (toy stub deleted in A2).
- [ ] From a clean rebuild (`rm -rf .zig-cache zig-out`), all six targets are green: `zig build`, `zig build uf2`, `zig build test`, `zig build test-uart`, `zig build test-hal`, `zig build test-main`. Baseline before any Ruby work.
- [ ] Pico W connected via USB; `picotool` and `picocom` are known-working. See `AGENTS.md` § "Build & Flash Workflow" and § "Hardware Setup".
- [ ] You have read `AGENTS.md` § "RP2040 Gotchas", § "CYW43 Gotchas", and § "Code Style". The plan references platform conventions documented there and will not restate them.
- [ ] You have read `ZIG-0.16.0-QUICKSTART.md` at repo root if you are not already fluent in Zig 0.16 stdlib (`std.Io`, Juicy Main, `.empty` decl literals, `captureStdOut(.{})`, etc.).
- [ ] You have `~/Data/Code/pico/docs/NANORUBY.md` open alongside a terminal in `~/Data/Code/pico`. Every path in this plan is relative to that directory unless explicitly prefixed with `~/`.

Execution guidance:

- Follow the checklist at the end of the doc in order. Do not batch A-phases. Each step either leaves the tree green or fails a measurable gate.
- If anything in §"Freestanding compile constraint" or §"GC and native-binding rooting" feels unclear, re-read it before coding. Those two sections capture the non-obvious risks.
- Use the `user-ai` MCP's `discuss` tool with `conversation_id: pico-nanoruby-integration-review-2026` to reach the peer AI review history if you need to revisit tradeoffs.

---

> **Status box**
> - **State**: plan refined; ready to execute in a dedicated session.
> - **Prerequisite**: Zig 0.15.2 → 0.16.0 migration of pico. **DONE** (commits `c297361` and `eb7452c` on `origin/main`; all six build targets green on 0.16.0).
> - **Goal**: run embedded `blinky.rb` on Pico W hardware behind `-Dengine=ruby`.
> - **Non-goals (this milestone)**: source eval on target, runtime dual-engine interop, WiFi/MQTT parity (deferred to Phase B).
> - **Success criteria**: onboard LED toggles under Ruby control; UART console shows expected output; watchdog remains stable across ≥10 minutes of repeated loop (exercising GC); existing `-Dengine=js` MQuickJS build is **byte-identical** to pre-integration `pico.uf2`; firmware `.text` contains **zero hosted-std symbols** from nanoruby (`std.debug.print`, `std.Io.File.stderr`, etc.).
> - **Effort**: 10–16h for Phase A, likely across two sessions (one to execute the vendored fork + build integration, a second for hardware iteration).
> - **Revision**: plan was redlined after ground-truth verification against `~/Data/Code/nanoruby` and peer review with GPT-5.4 (conversation `pico-nanoruby-integration-review-2026`). Original plan underestimated freestanding-compile pull-in; see §"What changed from the original plan".

**Direction:** pico absorbs nanoruby, not the other way.
**First milestone:** `blinky.rb` running on real Pico W hardware behind `-Dengine=ruby`.
**Second (stretch) milestone:** WiFi/MQTT parity with `scripts/wifi_blink.js`.

---

## TL;DR

The pico project is a mature firmware platform — custom CYW43439 WiFi, bare-metal TCP/IP, MQTT over TLS, USB Host, 28 documented RP2040 / CYW43 / BearSSL / telnet gotchas, two boards supported via `hal.zig` chip detection. Its `src/bindings/*.zig` files already split **engine-agnostic internal Zig APIs** from MQuickJS-specific `js_*` export wrappers. A second engine is the pattern the codebase was built for — `src/ruby/` even exists today as a placeholder with a 111-line toy VM.

Nanoruby (`~/Data/Code/nanoruby`) is a register-VM Ruby runtime: **317/317 tests passing**, 88% of Ruby's syntax surface (per `COVERAGE.md`), compacting GC, float support, cross-compiles clean for `thumb-cortex_m0plus` **when only the VM core is built** (`zig build arm` targets `demo.zig`, not the full engine). The engine itself is ~14,200 lines total, with `class.zig` (1,799 lines, 81 KB) being the critical file for integration — see §"Freestanding compile constraint" for why.

The integration is straightforward in shape but has **three** preconditions (the plan previously claimed two):

1. **~~Pico must migrate from Zig 0.15.2 to 0.16.0.~~** Done.
2. **A cooperative `sleep_ms` with precisely defined semantics must be implemented** (§"Cooperative sleep_ms semantics"). Naive busy-wait starves superloop, watchdog, LED poll, WiFi/MQTT servicing.
3. **Nanoruby's native method table must be split into core / debug / platform subsets** before it can cross-compile into firmware. The hosted-std surface in `class.zig` (used by `nativePuts`, `inspectValue`, and all `nativeGpio*` / `nativeWifi*` / `nativeMqtt*` debug stubs) compiles-in unavoidably once `installNatives()` is called — runtime override is not a fix.

Recommended engine-selection model: **`-Dengine=js` (default) or `-Dengine=ruby`** as a build-time choice, one engine per firmware image. Dual-engine-in-one-image (Mode B) is technically interesting but deferred — it roughly doubles flash/RAM cost, adds cross-VM marshaling complexity, and has no current use case that justifies the effort.

Estimated effort for the Phase A MVP (blinky.rb on real hardware): **10–16 hours** elapsed, likely spread across two sessions. The original 7–11h estimate assumed runtime-override alone would work; it doesn't.

---

## What changed from the original plan

Before execution, the plan was reviewed against the actual nanoruby source tree. Twelve items were corrected or added. Summary:

| # | Change | Why |
|---|---|---|
| 1 | Runtime "override at init" demoted from primary strategy to diagnostic-only | Referencing function pointers from a comptime table forces body analysis; hosted-std bodies don't compile on freestanding |
| 2 | "Vendor sources" → "Vendor a patched fork" | The copy must be edited, not mirrored |
| 3 | New: native table split into `installCoreNatives` / `installDebugNatives` / `installPlatformNatives` | Lets pico include only core + platform; debug set uses hosted `std.debug.print` |
| 4 | New: parser + codegen are **host-tool-only** for Phase A | Keeps ~5K lines of parsing/codegen out of firmware; `.nrb` is pre-compiled on host |
| 5 | New: explicit module boundary (what pico imports from nanoruby) | Prevents "import everything" drift; small surface makes future updates survivable |
| 6 | New: explicit `src/main.zig` migration steps | User's pre-migration work already imports the toy stub; deletion must be coordinated |
| 7 | New: memory/flash budget with measured before/after | Embedded planning without numbers invites late surprises |
| 8 | New: IRQ/async safety rules (no VM entry from ISR) | Compacting GC + ISR = latent crash |
| 9 | New: `sleep_ms` semantics defined precisely (what gets pumped, timer source, large-duration behavior) | "Cooperative" alone is ambiguous |
| 10 | New: native-binding GC rooting discipline | Compacting GC moves objects; stored `Value` across allocation is unsafe |
| 11 | Expanded hardware acceptance criteria | "LED blinks" is hello-world, not done |
| 12 | Effort re-estimated from 7–11h to 10–16h, across likely two sessions | Reflects items 3–10 |

Plus cosmetic: test count corrected to 317/317 (was 368).

---

## Why "pico absorbs nanoruby," not the reverse

Unchanged from v1. Summary:

| Consideration | Direction matters because… |
|---|---|
| **Scope alignment** | pico is a firmware platform; nanoruby is a language engine. Language engines plug into firmware platforms. |
| **Engineering capital** | pico has ~3000 lines of chip/board/driver/runtime code *plus* CYW43 driver, TCP/IP stack, TLS via BearSSL, USB Host, and 28 hard-won gotchas documented in `AGENTS.md`. Duplicating that into nanoruby would take weeks. |
| **Integration pattern** | pico's `src/bindings/*.zig` already factor engine-agnostic Zig APIs from MQuickJS export wrappers. It's structurally ready for a second engine. `src/ruby/` even exists as a stub. |
| **Build system** | pico's `build.zig` (22 KB) handles chip selection, target configuration, UF2 generation, SSID/USB build flags, boot2/linker integration, pre-translated BearSSL bindings. Nanoruby's is 82 lines and exports no module. |
| **Dev workflow** | pico has a proven `reboot` + `picotool` + `picocom` loop on real hardware. That's the most valuable artifact that isn't code. |
| **Maintenance** | Projects should do one thing. nanoruby does Ruby well; pico does firmware well. Merging pico into nanoruby would make nanoruby a firmware project. |

---

## Freestanding compile constraint (the single biggest correction from v1)

The original plan claimed nanoruby's host-side debug stubs could stay in `class.zig` and be swapped at init via `class_table.defineMethodImpl`. **This is false**, for a mechanical reason:

```zig
// nanoruby/src/vm/class.zig line 422
const native_method_table = [_]NativeEntry{
    .{ .class_id = CLASS_OBJECT, .name_atom = a("puts"),        .func = &nativePuts },
    .{ .class_id = CLASS_OBJECT, .name_atom = a("gpio_mode"),   .func = &nativeGpioMode },
    // ... 13 entries total including wifi/mqtt/gpio/led/millis/sleep_ms
};

pub fn installNatives(vm: *VM, findSym: ...) void {
    for (native_method_table) |entry| {
        vm.class_table.defineMethodImpl(entry.class_id, entry.name_atom,
            .{ .native = entry.func }) catch {};
    }
}
```

Taking `&nativeGpioMode` in a comptime-known table **forces the compiler to analyze and validate the function body** as a valid target callable. That body contains `std.debug.print(...)`, which doesn't exist on freestanding. Runtime override (calling `defineMethodImpl` again with a pico adapter) only changes which function the VM dispatches to *after* init — it doesn't unread the compile-time reference.

Observable proof: `zig build arm` in the nanoruby repo cross-compiles successfully because it builds **only `demo.zig`** (120 lines, hand-rolled bytecode, no `installNatives` call). The full engine with natives has never been cross-compiled for freestanding.

### The fix: split the native method table by category

Split `class.zig` (or add a sibling file; same effect) into three install sets:

```zig
// Core: required for Ruby semantics to be sane. Called always.
pub fn installCoreNatives(vm: *VM) void { ... }
//   - arithmetic fallbacks (String#+ etc.)
//   - array/hash/range iterators and accessors
//   - Object#inspect machinery that routes through a writer parameter
//     (not through std.Io.File.stderr directly)
//   - anything the VM implicitly dispatches to without the user naming it

// Debug: hosted-only. Provides std.debug.print-based puts/p/inspect.
// Used by tests, demo, nrbc. NOT linked on freestanding.
pub fn installDebugNatives(vm: *VM) void { ... }

// Platform: target-specific HAL bindings (gpio, led, wifi, mqtt, millis,
// sleep_ms). Nanoruby provides the host-side stub set for tests; pico
// provides its own MCU set and registers that instead.
pub fn installPlatformNatives(vm: *VM, table: []const NativeEntry) void { ... }
```

On pico (freestanding):

```zig
vm.installCoreNatives();
// skip installDebugNatives — std.debug.print is not available
vm.installPlatformNatives(&pico_natives);   // gpio/led/millis/sleep_ms → pico adapters
```

On nanoruby's own test/demo/nrbc builds (hosted):

```zig
vm.installCoreNatives();
vm.installDebugNatives();                     // uses std.debug.print, fine here
vm.installPlatformNatives(&host_stub_natives); // existing debug-print stubs
```

**Core natives must not touch `std.debug.print`, `std.Io.File.stderr()`, `std.Io.Threaded.init_single_threaded`, or any hosted API.** If the current `class.zig` has such usage in core paths (e.g., `inspectValue` uses `std.Io.File.stderr()` at line 475–479), those must be rewritten to take a `writer: *std.Io.Writer` parameter from the caller. Pico passes a UART-backed writer; host tests pass stderr.

This is a real but bounded refactor. A careful pass over `class.zig` should identify all hosted-std usage; each occurrence goes into either `_debug.zig` or gets parameterized on a writer.

### Upstreamability

The split layout is friendlier to upstreaming back into nanoruby than a target-gated hack (`if (builtin.os.tag == .freestanding) ...`). Upstream maintainers reject "core contamination"; they accept "clean backend split." If the plan is to eventually send this back, the split is the right first edit regardless.

---

## Vendor a patched fork (not a mirror)

### What "vendor" means in this plan

`cp -r ~/Data/Code/nanoruby/src pico/src/ruby/nanoruby/` **plus** targeted edits to:
- Split `class.zig` as described above (or add `class_natives_host.zig` + `class_natives_mcu.zig` siblings).
- Parameterize any core path using `std.Io.File.stderr()` on a writer.
- Export a narrow module surface (§"Module boundary").
- Exclude parser + codegen from the firmware build path (§"Host-only vs firmware components").

The vendored tree stays under `pico/src/ruby/nanoruby/` until either (a) the split and writer-parameterization are upstreamed, at which point we can switch to `b.dependency` against a tagged release, or (b) nanoruby proves not interested, and we keep the fork indefinitely. Neither is a disaster.

### Why not a git submodule or `b.dependency` path now

- The edits needed (native-table split, writer parameterization) must land before the firmware builds. That's source changes in nanoruby's tree, which a read-only dependency can't absorb. A submodule could, but then the firmware fork diverges from upstream on day one — vendoring makes that divergence explicit.
- While the integration is experimental, coupling two repos' CI/tagging to each other is friction for no benefit.
- Once the fork stabilizes and (if) the split upstreams, we can convert to `b.dependency("nanoruby", .{ .target = fw_target, ... })` trivially.

---

## Module boundary: what pico imports from nanoruby

Pico does **not** import "all of nanoruby". It imports a narrow firmware-facing surface:

```zig
// pico/src/ruby/nanoruby.zig — the public face exposed to pico code
pub const VM       = @import("nanoruby/vm/vm.zig").VM;
pub const Value    = @import("nanoruby/vm/value.zig").Value;
pub const IrFunc   = @import("nanoruby/vm/vm.zig").IrFunc;
pub const Loader   = @import("nanoruby/vm/nrb.zig");   // deserialize only
pub const NativeFn = @import("nanoruby/vm/class.zig").NativeFn;
pub const NativeEntry = @import("nanoruby/vm/class.zig").NativeEntry;
pub const installCoreNatives = @import("nanoruby/vm/class.zig").installCoreNatives;
pub const installPlatformNatives = @import("nanoruby/vm/class.zig").installPlatformNatives;
pub const atom = @import("nanoruby/vm/atom.zig").atom;
```

What pico does **not** import:
- `parser.zig` (2,008 lines)
- `ruby.zig` (1,145 lines, lexer/rewriter)
- `compiler/codegen.zig` (2,764 lines)
- `compiler/pipeline.zig` (1,252 lines)
- `nrbc.zig` (host CLI entry)
- `parse_dump.zig` (diagnostic)
- `installDebugNatives` (hosted-only)

That's ~**7,200 lines excluded** from the firmware compile path — the entire compile pipeline. Firmware embeds `.nrb`; `.nrb` is produced on the host at build time.

---

## Host-only vs firmware components

| Component | Built for | Notes |
|---|---|---|
| VM core (`vm.zig`, `value.zig`, `heap.zig`, `opcode.zig`, `atom.zig`, `symbol.zig`, `assembler.zig`, core parts of `class.zig`) | **Both host and firmware** | Must not reference hosted-std in paths reachable from core |
| `nrb.zig` deserializer | **Firmware only** (load from ROM/RAM) | Serializer stays host-only via codepath |
| Parser (`parser.zig`, `ruby.zig`) | **Host only** | For host compile step |
| Codegen (`compiler/*.zig`) | **Host only** | For host compile step |
| `nrbc` CLI | **Host only** | Invoked as build step |
| Debug natives (`class_debug.zig` after split) | **Host only** | Uses `std.debug.print` |
| Platform natives | **Firmware only (pico-provided)** | Pico supplies its own table; nanoruby's host-stub table is ignored on firmware |

---

## Phase A — blinky.rb on real Pico W

**Goal:** type `zig build uf2 -Dengine=ruby`, flash, watch the onboard LED blink driven by Ruby bytecode. `-Dengine=js` (default) produces the same firmware as today, byte-for-byte.

### A1. Fork nanoruby into `pico/src/ruby/nanoruby/` (2–3h)

- `cp -r ~/Data/Code/nanoruby/src pico/src/ruby/nanoruby/`
- Delete `pico/src/ruby/nanoruby.zig` (toy stub, 111 lines). Coordinated with A2 so the default build still compiles.
- Apply the native-table split as in §"Freestanding compile constraint":
  - Extract the debug stubs and hosted-only paths from `class.zig` into `class_debug.zig`.
  - Split `native_method_table` into `core_native_table`, `debug_native_table`, and remove platform entries entirely (pico provides its own).
  - Rewrite any core `inspectValue`-style paths to take a `writer: *std.Io.Writer` parameter.
- Delete the vendored `parser.zig`, `ruby.zig`, `compiler/`, `nrbc.zig`, `parse_dump.zig`, `test_all.zig` **only after** A5 confirms they're not pulled in via `@import` from retained files. (Likely: `vm.zig` is self-contained; parser/codegen are above it.)
- Create `pico/src/ruby/nanoruby.zig` (the public face, see §"Module boundary").

**Regeneration rule**: the vendored tree is a fork. If upstream nanoruby changes and we want to pull it in, it's a re-patch operation, not a `git pull`. Document the current upstream SHA in a `UPSTREAM.md` inside `pico/src/ruby/nanoruby/` so the divergence is discoverable.

### A2. Build-flag engine selection + main.zig surgery (1–2h)

Add to `build.zig`:

```zig
const Engine = enum { js, ruby };
const engine = b.option(Engine, "engine", "Script engine: js or ruby") orelse .js;

switch (engine) {
    .js => {
        // existing MQuickJS setup stays exactly as-is
        // (pico_stdlib_gen, bearssl flags, mquickjs.c compile, …)
    },
    .ruby => {
        // nanoruby core VM module
        const nanoruby_mod = b.createModule(.{
            .root_source_file = b.path("src/ruby/nanoruby.zig"),
            .target = fw_target,
            .optimize = fw_optimize,
            .link_libc = false,
        });
        fw_mod.addImport("nanoruby", nanoruby_mod);

        // host-side nrbc build step (see A5)
        // firmware embed of produced .nrb (see A5)
    },
}

// build-time constant the Zig code can switch on
const build_options = b.addOptions();
build_options.addOption(Engine, "engine", engine);
fw_mod.addImport("build_config", build_options.createModule());
```

In `src/main.zig` (currently has unconditional `nanoruby.runDemo();` from user's pre-migration work):

```zig
const build_config = @import("build_config");
// ...
switch (build_config.engine) {
    .js => {
        // existing MQuickJS initialization (memory.init, engine.init, etc.)
    },
    .ruby => {
        const rb = @import("ruby/runtime.zig");
        rb.init(.{ .heap_kb = 32 }) catch hang();
        rb.installBindings();
        rb.runBootScript();
    },
}
```

**Defaults**: `-Dengine=js` produces **the same `pico.uf2` artifact as before this integration** (byte-identical check is part of A6 acceptance). `-Dengine=ruby` opts into the experimental path.

Delete the toy `pico/src/ruby/nanoruby.zig` in the same commit that adds the engine gate — otherwise the default build breaks mid-edit.

### A3. Bindings adapter (2–3h)

`pico/src/ruby/runtime.zig` (firmware-facing init + boot-script runner).

`pico/src/ruby/bindings_adapter.zig` (defines the platform-native table pico passes to `installPlatformNatives`).

**Critical architectural point**: Ruby native bindings target existing `src/bindings/*.zig` internal Zig APIs, **not** `hal.*` directly. That preserves the LED blink-state machine (`bindings/led.zig` owns `blink_interval_ms` + `poll()`), the timer-cursor bookkeeping (`bindings/timers.zig`), and the WiFi state shadow (`bindings/wifi.zig`). The stack looks like:

```
nanoruby native fn  →  bindings/<x>.zig internal fn  →  HAL/runtime
```

**Not**:

```
nanoruby native fn  →  HAL directly   (WRONG — bypasses binding state)
```

**Binding surface for Phase A** (minimum to run `blinky.rb`):

| Ruby name | Binding internal called |
|---|---|
| `gpio_mode(pin, mode)` | `bindings.gpio.mode(pin, mode != 0)` |
| `gpio_write(pin, val)` | `bindings.gpio.write(pin, val != 0)` |
| `gpio_read(pin)` | `bindings.gpio.read(pin)` |
| `gpio_toggle(pin)` | `bindings.gpio.toggle(pin)` |
| `led_on`, `led_off`, `led_toggle`, `led_blink(ms)` | `bindings.led.on/off/toggle/blink` |
| `millis` | `hal.millis()` (no binding wrapper — read-only clock) |
| `sleep_ms(ms)` | cooperative sleep (§A4) |
| `puts(str)` | writes to UART console via `bindings.console.puts` |

**GC-rooting discipline** for the adapter (§"GC and native-binding rooting" for rationale):

- Native adapters **do not cache `Value` instances across calls that may allocate**. Read args, compute, return — and return before the next call into the VM.
- If an adapter needs to hand a heap object back (e.g., a newly-allocated String), it's returned directly in the function result; the caller's frame roots it.
- No adapter stores a `Value` in a module-level `var` or in a ring buffer. If we need async event delivery to Ruby (Phase B: MQTT subscribe callback), that's a separately-designed mechanism (not a raw `Value` cache).

### A4. Cooperative `sleep_ms` with defined semantics (1h)

**What it does:**
- Blocks Ruby execution until at least `ms` milliseconds have elapsed from call start (wall-clock, `hal.millis()`-based).
- During the wait, pumps: `scheduler.poll()`, `led.poll()`, `watchdog.feed()`, and the superloop's net/mqtt/wifi service calls (a shared `superloop_tick_once()` helper should exist in `runtime/` so `sleep_ms` and the main superloop pump the same set of services by definition).
- **Not cancellable** from Ruby (there's no signal mechanism). A `break` inside a Ruby block around `sleep_ms` will take effect *after* the current `sleep_ms` returns.
- Large durations are clamped in a single Ruby call (e.g., 60000 ms max per call); longer Ruby sleeps should be a Ruby-side loop. Rationale: keeps the cooperative-pump tight.
- Timer source: `hal.millis()` — 1 ms tick on the Cortex-M0+ SysTick / RP2040 watchdog TICK, already set up on boot.
- Re-entrancy: not allowed. If a binding that could itself call back into Ruby is ever added (Phase B — MQTT on-message), those callbacks must run from the superloop, not from inside a `sleep_ms` pump.

**Implementation sketch:**

```zig
// pico/src/ruby/runtime.zig
pub fn sleepMsCooperative(ms: u32) void {
    const clamped = @min(ms, 60_000);
    const start = hal.millis();
    const deadline = start +% clamped;
    while (true) {
        const now = hal.millis();
        if ((@as(i32, @bitCast(now -% deadline))) >= 0) break;
        superloopTickOnce();
        asm volatile ("wfe");  // sleep until next interrupt
    }
}

fn superloopTickOnce() void {
    watchdog.feed();
    scheduler.poll();
    led.poll();
    netif.poll(@truncate(hal.millis()));
    wifi.poll();
    mqtt.poll();
    // USB host / console if enabled
}
```

**Why `wfe` not `nop`**: the periodic timer tick + UART RX IRQ are already wake sources; `wfe` saves power and avoids hot-looping the CPU.

### A5. Host compile step for bytecode + embed (1–2h)

Nanoruby already ships `nrbc.zig` (a `zig build nrbc -- input.rb -o output.nrb` CLI) and `src/vm/nrb.zig` (magic `NRBY` + u16 version + CRC32, 32 KB max). Both are compatible with being invoked from pico's `build.zig`.

Build recipe:

```zig
// In build.zig, inside switch (.ruby => { ... })
const ruby_script = b.option([]const u8, "ruby_script",
    "Path to .rb file") orelse "scripts/blinky.rb";

// Host-native build of nrbc (so we run it on the dev machine, not the MCU)
const nrbc_mod = b.createModule(.{
    .root_source_file = b.path("src/ruby/nanoruby/nrbc.zig"),
    .target = host_target,
    .optimize = .ReleaseFast,
});
const nrbc = b.addExecutable(.{ .name = "nrbc", .root_module = nrbc_mod });

// Run nrbc at build time on the chosen .rb
const compile_rb = b.addRunArtifact(nrbc);
compile_rb.addFileArg(b.path(ruby_script));
compile_rb.addArg("-o");
const nrb_path = compile_rb.addOutputFileArg("script.nrb");

// Embed the bytecode into firmware
fw_mod.addAnonymousImport("script_bytecode", .{
    .root_source_file = nrb_path,
});
```

Runtime:

```zig
// pico/src/ruby/runtime.zig
const script_bytecode = @embedFile("script_bytecode");

pub fn runBootScript() void {
    const func = nanoruby.Loader.deserialize(script_bytecode) catch |err| {
        console.puts("[nanoruby] bytecode load failed: ");
        console.puts(@errorName(err));
        console.puts("\n");
        return;
    };
    _ = vm.execute(&func);
}
```

**Version lock**: `nrb.zig` already includes a magic and u16 version. Any change to the serialized format in nanoruby bumps the version; the firmware loader rejects mismatched versions with a clear error (not a silent wrong-interpretation crash).

**First blinky.rb** (minimum moving parts):

```ruby
loop do
  led_toggle
  sleep_ms(500)
end
```

Graduation sequence (increasingly exercises GC + allocations):
1. `loop { led_toggle; sleep_ms(500) }` — engine → binding → hardware
2. Add `puts "blink"` (no interpolation) — console path
3. Add `millis` + a counter — fixnum-from-native return
4. Add `"blink! #{millis}ms"` — formatting + string allocation (exercises GC)
5. Add `5.times { |i| ... }` — iterator / block / GC-under-loop

### A6. Flash + verify on real Pico W (2–4h)

**Build + flash** (existing workflow works unchanged):

```bash
# In picocom:
>>> reboot

# On host:
zig build uf2 -Dengine=ruby -Dboard=pico_w
picotool load -v -x zig-out/firmware/pico.uf2

# Back in picocom:
[nanoruby] VM starting (32 KB heap)
[nanoruby] loading 142-byte bytecode
[nanoruby] executing
# LED blinks
```

**Acceptance (all must pass before Phase A is "done"):**

- [ ] LED toggles at 500 ms ±10% (eyeball or phone stopwatch)
- [ ] `millis` returns monotonically increasing values
- [ ] `puts` output appears on UART at 115200 baud
- [ ] **Runs continuously for ≥10 minutes without reset or wedge** (exercises GC cycles under a real loop; watchdog must stay fed)
- [ ] WiFi association still works when built with `-DSSID=...` on the `-Dengine=js` default build (proves platform still intact)
- [ ] `reboot` UART command still functions
- [ ] `-Dengine=js` `pico.uf2` is **byte-identical** to the pre-integration build (proves zero collateral impact on the default path). `diff zig-out-before.uf2 zig-out-after.uf2` must be empty.
- [ ] **No hosted-std symbols in firmware `.text`**:  
      `nm zig-out/bin/pico | grep -E 'std\.debug\.print|std\.Io\.File\.stderr|std\.Io\.Threaded'` returns zero lines.
- [ ] Flash delta measured and recorded: `size zig-out/bin/pico` before/after; target `.text` delta < 100 KB for Ruby engine vs. default.
- [ ] Peak RAM measured: Ruby engine under running blinky.rb should fit within budget (§"Memory and flash budget").

**If any step fails**: the reason MQuickJS stays as default is precisely so you can `zig build uf2` (no `-Dengine=ruby`) and confirm the platform itself is fine. That isolates engine bugs from hardware/platform regressions.

### Phase A total

| Step | Est |
|---|---|
| A1 Fork nanoruby + native-table split | 2–3h |
| A2 Engine flag + main.zig surgery | 1–2h |
| A3 Bindings adapter (+ GC rooting) | 2–3h |
| A4 Cooperative sleep with defined semantics | 1h |
| A5 Host nrbc build step + @embedFile | 1–2h |
| A6 Flash + acceptance verification on hardware | 2–4h |
| **Total** | **9–15h** |

Likely split: one session does A1–A5 (engine compiles, produces a `.uf2`); second session does A6 (hardware iteration).

---

## Memory and flash budget

**Budget targets for Phase A** (must measure, not guess):

| Resource | Current (MQuickJS) | Ruby target | Ruby acceptance |
|---|---|---|---|
| `.text + .rodata` flash | ~465 KB (from `pico.uf2` = 1819 × 256-byte payload) | ≤ 550 KB | fits within 2 MB flash comfortably |
| VM heap (RAM) | 96 KB (from `config.vm_heap_kb` × 1024) | 32 KB (nanoruby default) | blinky.rb + core natives must fit |
| Bytecode blob (ROM, `@embedFile`) | n/a | ≤ 2 KB for blinky.rb | nrb.zig `MAX_NRB_SIZE = 32768` is hard cap |
| Stack | existing | unchanged | no stack growth from Ruby |

**Measurement plan** (all three taken before hardware flash):

```bash
# After build:
ls -la zig-out/bin/pico                                    # ELF size
arm-none-eabi-size zig-out/bin/pico                        # section breakdown
nm zig-out/bin/pico | grep -E 'std\..*print|std\.Io\.File' # hosted-std leakage
stat -f%z zig-out/firmware/pico.uf2                        # flash footprint
```

If any number exceeds its target: stop and investigate before flashing. A factor-of-two flash delta is a signal that parser/codegen accidentally came in, or debug natives didn't get split out.

---

## IRQ and async safety rules

**Rules for Phase A** (violating any of these creates intermittent crashes that are painful to debug):

1. **No VM entry from IRQ context.** Ever. Timer ISR, UART RX ISR, USB CDC, network RX — none of them call into the nanoruby VM directly.
2. **Async sources enqueue events to non-VM-owned buffers.** UART RX → raw byte ring buffer. Timer tick → atomic counter / flag. MQTT message → (Phase B) a pico-owned queue of `{topic, payload}` byte pairs.
3. **Main loop drains.** Every iteration of pico's superloop (and every iteration of `superloopTickOnce` during cooperative sleep) inspects the event queues and, if the VM is idle, dispatches Ruby-level handlers.
4. **Compacting GC ⇒ no raw pointers across calls.** Native adapters that return heap objects (strings, arrays) must return them inline; the VM's calling frame roots them. Adapters do not cache `*Value` or string data pointers between calls. This is already a nanoruby invariant; the Phase A adapter code must honor it.
5. **Re-entrancy into `sleep_ms` is forbidden.** If a binding callback path is ever added in Phase B, it runs from superloop context, never from inside `sleep_ms`.

These rules should be stated in `pico/src/ruby/runtime.zig` as a file header so they don't get quietly violated by a future contributor.

---

## GC and native-binding rooting

Nanoruby uses a compacting mark-sweep GC over a single arena (README). That means heap object addresses **change** across GC cycles. Rules for native bindings (these are stricter than the nanoruby test-suite currently enforces, because firmware can't afford the classes of bugs caching permits):

- An adapter receives `args: []const Value`. Use each `Value` locally (read fixnum, read string bytes via VM accessor, etc.) before doing anything that could allocate.
- If an adapter needs to allocate (e.g., returning a newly-made string), do it at the end and return the result. Don't allocate in the middle and then re-use an earlier `Value`'s internal pointer.
- **Strings returned to Zig are not stable.** If a Ruby-passed string is consumed by a binding (e.g. `mqtt_publish(topic, payload)` in Phase B), copy the bytes into a pico-owned buffer synchronously; do not retain a slice pointing into the Ruby heap.
- No binding caches a `Value` in a module-level `var`, thread-local, or any storage that outlives the current frame. Phase B callback registration (MQTT subscribe) will need an explicit pinning mechanism — design it deliberately, don't improvise.

---

## Cooperative sleep_ms semantics (formalized)

Covered inline in §A4. Summary:

- **What it blocks**: Ruby execution.
- **What it pumps**: watchdog, scheduler, LED poll, netif, wifi, mqtt, USB host (when enabled), console — the same set as the superloop's main iteration.
- **Not cancellable** from within Ruby. `break` / `return` from an enclosing block takes effect after current `sleep_ms` returns.
- **Clamped per call** to 60 s. Longer Ruby sleeps = Ruby-side loop of `sleep_ms` calls.
- **Timer source**: `hal.millis()` (1 ms resolution, already configured on boot).
- **Re-entrancy**: forbidden. Callbacks never originate from inside `sleep_ms` pump.
- **Power**: use `wfe` inside the pump loop, not `nop`.

These are firm contracts. If Phase B needs different semantics (e.g., a "wake on event" variant), add a new builtin; don't change `sleep_ms`.

---

## Phase B — WiFi/MQTT parity (stretch, separate session)

After blinky.rb works, the obvious next milestone is a ruby-flavored equivalent of `scripts/wifi_blink.js` — connect to WiFi, report status over MQTT, blink LED while doing so.

**What this requires** (much more deliberate than Phase A):

1. More adapter entries: `wifi_connect`, `wifi_status`, `wifi_ip`, `mqtt_connect`, `mqtt_publish`, `mqtt_subscribe`, `mqtt_status`. All already have Zig internal APIs in `src/bindings/{wifi,mqtt}.zig`.
2. Some form of `set_interval` — or a cooperative `loop` pattern. Preferred: `set_interval`, because it doesn't need `sleep_ms` and doesn't block the superloop.
3. MQTT subscribe callback — **this is where the GC rooting story gets real**. A Ruby block passed to `mqtt_subscribe(...)` must survive across superloop iterations, which means it must be pinned in nanoruby's root set. Design this deliberately before coding.

**Estimate**: +5–10h, depending on how polished the callback story needs to be. **Do not start Phase B before Phase A is fully green** (all A6 acceptance items).

---

## Dual-engine models

Unchanged from v1. Summary:

- **Mode A** — one engine per build, `-Dengine=js|ruby`. **This is Phase A.**
- **Mode A'** — both linked, runtime flag selects. Deferred; possible later if A/B comparison matters.
- **Mode B** — both engines live with cross-engine interop. Explicitly not planned. Doubles flash + RAM, two GCs on one arena, marshaling layer between different `Value` tag schemes, doubled test matrix, no concrete use case.

GPT-5.4 concurred explicitly on Mode A for Phase A. Revisit after Phase B ships if there's a real need.

---

## RP2040 gotchas that intersect with Ruby specifically

From `AGENTS.md`, the ones that intersect with nanoruby's runtime (others are platform concerns already solved):

1. **Watchdog starvation from blocking interpreter loops** (gotcha pattern behind #13 SWD lockup) — addressed by cooperative `sleep_ms` (§A4). Still a risk: any `while true ... end` in Ruby without calling a cooperative primitive is a hang. Script review catches this.
2. **`src/libc/stubs.c` memset recursion** (gotcha #10) — if nanoruby's build ever pulls in C code (it currently does not), same rule: no `__builtin_memset/memcpy/memmove` in freestanding stubs.
3. **Console output formatting** — nanoruby's `puts` with interpolation allocates transient strings and routes through the console. First script stays on literal strings (§A5 graduation).
4. **GC interaction with native bindings** — §"GC and native-binding rooting" above. Nanoruby's `ObjRef` registry handles most cases automatically; custom storage is where bugs hide.

The other 24 documented gotchas (CYW43, BearSSL, boot2, PLL, clocks, linker, telnet, etc.) don't re-emerge unless we modify startup or linker scripts — which we won't.

---

## Open questions — resolved before start (these WERE open; now pinned)

The original doc left six questions open. After the review:

1. **Serialized IrFunc format.** `nanoruby/src/vm/nrb.zig` already implements magic + version + CRC32, 32 KB cap. Load-from-bytes exists. **Resolved: use it as-is.**
2. **`nrbc` as a buildable artifact.** Already an executable target in nanoruby's `build.zig`. Pico invokes it as `b.addRunArtifact(nrbc)`. **Resolved.**
3. **Nanoruby as a Zig module.** Doesn't currently export one. We don't need it to — after vendoring, pico creates its own module boundary via `pico/src/ruby/nanoruby.zig` (§"Module boundary"). **Resolved without upstream change.**
4. **Should nanoruby's `class.zig` HAL stubs move to a separate file?** YES. Required, not optional. §"Freestanding compile constraint". **Resolved.**
5. **Zig 0.16 migration scope.** **DONE.** Separate commits, separate session.
6. **Bytecode / compiler ↔ VM version lock.** `nrb.zig` already has magic + u16 version. Pico's `runBootScript` rejects on mismatch. Vendoring pins the format to the vendored SHA. **Resolved.**
7. **Native binding error policy.** Decision: **raise Ruby exceptions** on bad arguments (`ArgumentError` / `TypeError`), not silent `nil`. Nanoruby's native-exception channel already exists (per `DEFERRED.md` F2). Silent-nil is a hardware-debugging trap. **Resolved.**

---

## Execution checklist (locked; use this in the execution session)

```
□ -1. Prerequisite: Zig 0.16.0 migration of pico  — DONE (commits c297361, eb7452c)

□ A1. Fork nanoruby into pico/src/ruby/nanoruby/
    □ A1.1 cp -r ~/Data/Code/nanoruby/src pico/src/ruby/nanoruby/
    □ A1.2 Pin upstream SHA in pico/src/ruby/nanoruby/UPSTREAM.md
    □ A1.3 Split class.zig native table into core / debug / platform
    □ A1.4 Parameterize core inspectValue-style paths on writer
    □ A1.5 Delete vendored parser/codegen/nrbc/parse_dump (if reachable via @import audit)
    □ A1.6 Create pico/src/ruby/nanoruby.zig (public module face)
    □ A1.7 Confirm: zig build -Dengine=ruby compiles (no nm hosted-std hits)

□ A2. Engine selection + main.zig surgery
    □ A2.1 Add Engine enum + -Dengine option to build.zig
    □ A2.2 Conditional source routing (js vs ruby branch)
    □ A2.3 Gate nanoruby.runDemo() in src/main.zig behind build_config.engine == .ruby
    □ A2.4 Delete pico/src/ruby/nanoruby.zig (toy stub) same commit
    □ A2.5 Confirm: -Dengine=js build is byte-identical to pre-integration pico.uf2
    □ A2.6 Update build.zig.zon .paths to include src/ruby/nanoruby/ tree

□ A3. Bindings adapter
    □ A3.1 pico/src/ruby/runtime.zig (init, boot script runner, superloop pump)
    □ A3.2 pico/src/ruby/bindings_adapter.zig (native table, targets bindings/*.zig)
    □ A3.3 Register via installPlatformNatives (not by editing class.zig at runtime)
    □ A3.4 Apply GC rooting discipline; no Value caching in adapters

□ A4. Cooperative sleep_ms
    □ A4.1 Implement sleepMsCooperative per §A4 (wfe, 60s clamp, superloopTickOnce)
    □ A4.2 Wire into rbSleepMs native
    □ A4.3 File header in runtime.zig documents IRQ/async/GC rules

□ A5. Bytecode embedding
    □ A5.1 Host-native build of nrbc.zig in pico's build.zig
    □ A5.2 addRunArtifact step: nrbc scripts/blinky.rb → script.nrb
    □ A5.3 addAnonymousImport("script_bytecode", nrb_path)
    □ A5.4 runBootScript in pico/src/ruby/runtime.zig

□ A6. Flash + acceptance on real Pico W
    □ A6.1 Script 1: loop { led_toggle; sleep_ms(500) }
    □ A6.2 Script 2: add puts "blink"
    □ A6.3 Script 3: add millis counter
    □ A6.4 Script 4: add "blink! #{millis}ms" interpolation (exercises GC)
    □ A6.5 Script 5: 5.times { |i| puts i } (iterator + block)
    □ A6.6 Run continuously ≥10 min; watchdog stable
    □ A6.7 Confirm -Dengine=js UF2 byte-identical to pre-integration
    □ A6.8 Confirm no hosted-std symbols in firmware via nm
    □ A6.9 Record flash delta + peak RAM
    □ A6.10 Commit: src/ruby/nanoruby/ fork + pico integration + script.nrb inputs
```

---

## References

- Nanoruby source: `~/Data/Code/nanoruby/`
- Nanoruby Ruby surface coverage: `~/Data/Code/nanoruby/COVERAGE.md`
- Nanoruby float analysis: `~/Data/Code/nanoruby/docs/softfp-analysis.md`
- Pico HANDOFF: `~/Data/Code/pico/HANDOFF.md`
- Pico gotchas: `~/Data/Code/pico/AGENTS.md` §"RP2040 Gotchas", §"CYW43 Gotchas", §"BearSSL/TLS Gotchas"
- Pico Zig 0.16.0 reference: `~/Data/Code/pico/ZIG-0.16.0-REFERENCE.md`
- Peer review conversation: `pico-nanoruby-integration-review-2026` (via `user-ai` MCP)
