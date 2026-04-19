# Vendored nanoruby — upstream provenance and local modifications

This directory is a **vendored fork** of nanoruby. It is not a pristine mirror
and is not kept in sync via `git pull` / submodule. Re-vendoring is a deliberate
re-patch operation: produce a new clean snapshot, then re-apply the enumerated
local modifications. See the "How to re-vendor" section at the bottom.

## Upstream source

- Repository: `git@github.com:shreeve/nanoruby.git`
- Upstream HEAD at snapshot time: `d54129e8181f7f638f642f3fac83aff1cb287d2f`
- `git describe`: `d54129e-dirty`
- Commit subject: `` `rescue => e` binds exception; symbol-based error values``
- Author: Steve Shreeve <steve.shreeve@gmail.com>
- Commit date: Sat Apr 18 02:09:30 2026 -0600
- **Working-tree state at snapshot**: dirty (see "Working-tree deltas" below).
  Snapshot was taken from the **working tree**, not `HEAD`. This is intentional:
  the pico integration plan treats the working tree as authoritative because
  upstream's current feature work (317/317 test pass, per `COVERAGE.md`) lives
  there, not in the last committed state.
- Snapshot date: 2026-04-19 (pico integration session, `docs/NANORUBY.md` A1.1)
- Local file count: 18 source files, 736 KB on disk.

## Working-tree deltas vs. HEAD at snapshot time

From `git -C ~/Data/Code/nanoruby diff --stat src/`:

```
 src/compiler/codegen.zig  |  361 ++++++++++-
 src/compiler/pipeline.zig |  528 ++++++++++++++++
 src/parser.zig            | 1529 +++++++++++++++++++++++----------------------
 src/ruby.zig              |  165 ++++-
 src/vm/atom.zig           |    5 +-
 src/vm/class.zig          |  322 +++++++++-
 src/vm/heap.zig           |   29 +
 src/vm/mod.zig            |   16 -
 src/vm/opcode.zig         |    3 +-
 src/vm/vm.zig             |  374 +++++++++--
 10 files changed, 2503 insertions(+), 829 deletions(-)
```

For content verification, sha1 (`git hash-object`) of key vendored files at
snapshot time:

| file | sha1 |
|---|---|
| `vm/class.zig` | `cb9ee24efb3e6b83f28cc43a026f0d132fcd5439` |
| `vm/vm.zig` | `cd932fa1524e4336a3c877e8749520d9936b1a0a` |
| `vm/nrb.zig` | `5dbcb0f6f6fcb334dcb74150fa1bda85ad159e95` |
| `parser.zig` | `6dd9ccb080ea3de54a41617a24d55438bc81818d` |

Note that `src/vm/mod.zig` exists in upstream `HEAD` but was deleted in the
working tree — the snapshot reflects its deleted state (file not present here).

## Layout policy

The vendored tree contains **both firmware-usable and host-tool source**. The
firmware module never imports host-only paths; the boundary is enforced by
`pico/src/ruby/nanoruby.zig` (the narrow public face used by firmware code),
not by deletion of files from this directory.

| Subdir / file | Firmware-usable | Host-only | Notes |
|---|---|---|---|
| `vm/vm.zig`, `vm/value.zig`, `vm/heap.zig`, `vm/opcode.zig`, `vm/atom.zig`, `vm/symbol.zig`, `vm/assembler.zig`, `vm/nrb.zig` | yes | no | Required for firmware |
| `vm/class.zig` (core portion) | yes | no | Native table split: see "Local modifications" |
| `vm/class_debug.zig` (to be extracted) | no | yes | Hosted-std debug natives |
| `parser.zig`, `ruby.zig` | no | yes | Source-to-AST pipeline (host-only) |
| `compiler/codegen.zig`, `compiler/pipeline.zig` | no | yes | Codegen (host-only) |
| `nrbc.zig` | no | yes | Host CLI for compiling `.rb` → `.nrb` |
| `parse_dump.zig` | no | yes | Diagnostic |
| `test_all.zig` | no | yes | Host test harness |
| `ruby/` | no | yes (pipeline helpers) | |

## Local modifications

This section is the authoritative log of pico-local edits to the vendored
tree. Each entry records (a) what was changed, (b) why, (c) whether it is
intended for upstreaming back to nanoruby.

### M0 — Initial snapshot (commit `0aa51f3`)

- No source edits.
- Pure `cp -R` of `~/Data/Code/nanoruby/src/.` → `pico/src/ruby/nanoruby/`.
- Added this `UPSTREAM.md`.
- Upstream intent: n/a (snapshot, not a modification).

### M1 — Native-method-table split (A1.3)

Problem: nanoruby's original `vm/class.zig` installed a single
`native_method_table` whose entries included both hosted-only debug
natives (`puts`, `print`, `p` — bodies use `std.debug.print` and
`std.Io.File.stderr()`) and MCU-facing platform stubs (`gpio_*`,
`sleep_ms`, `millis`, `wifi_*`, `mqtt_*` — bodies use `std.debug.print`).
Taking `&nativePuts` (and kin) as a comptime `NativeMethodDef` entry
forces Zig to analyse those bodies for freestanding, which fails because
`std.Io.File.stderr` / `std.Io.Threaded` have no freestanding backends.

Edits:

- `vm/class.zig`:
  - Removed `writeValue`, `inspectValue`, `nativePuts`, `nativePrint`,
    `nativeP`, `nativeGpioMode`, `nativeGpioWrite`, `nativeGpioRead`,
    `nativeGpioToggle`, `nativeSleepMs`, `nativeMillis`,
    `nativeWifiConnect`, `nativeWifiStatus`, `nativeWifiIp`,
    `nativeMqttConnect`, `nativeMqttPublish`, `nativeMqttSubscribe`,
    `nativeMqttStatus` (relocated to `class_debug.zig`).
  - Renamed `native_method_table` → `core_native_table`; dropped its
    `puts`/`print`/`p` entries and all platform-stub entries.
  - Replaced `installNatives(vm, findSym)` with `installCoreNatives(vm)`
    and a generic `installPlatformNatives(vm, table)` helper.
  - Made `allocString` public so `class_debug.zig` can use it.
- `vm/class_debug.zig` (new, host-only): receives the extracted natives,
  plus `debug_native_table`, `default_platform_native_table`,
  `installDebugNatives`, `installDefaultPlatformNatives`, and a
  back-compat `installNatives` wrapper for upstream host callers.
- `nrbc.zig`, `compiler/pipeline.zig`, `compiler/codegen.zig`:
  switched the `class.installNatives` call to `class_debug.installNatives`
  (4 call sites). These files are host-only so the switch is safe.

Result: firmware build path transitively imports `vm/class.zig` through
the public face; it never touches `class_debug.zig`. `vm/class.zig` is
now freestanding-clean (verified with `zig build-obj -target
thumb-freestanding-eabi -mcpu cortex_m0plus -OReleaseSmall`).

Upstream intent: **yes — strongly recommended to upstream.** The split
is also useful to upstream even without any MCU embedder because it
surfaces the hosted-std surface explicitly and lets non-hosted embedders
reuse the core table. See peer-review conversation
`pico-nanoruby-integration-review-2026` for the design discussion.

### M2 — Public module face + engine gate (A1.4 + A2)

Combined into a single commit to keep the tree green. The plan's A1.4
("create `pico/src/ruby/nanoruby.zig`") and A2.4 ("delete `pico/src/
ruby/nanoruby.zig` toy stub in the same commit that adds the engine
gate") describe the same file write — overwriting the pre-integration
toy stub with the narrow public face. Splitting those into two commits
either breaks `zig build` transiently or requires back-compat scaffolding.

Pico-local files added (outside the vendored tree):

- `pico/src/ruby/nanoruby.zig` — the public module face. Re-exports a
  narrow surface: `VM`, `IrFunc`, `Value`, `Loader` (nrb deserializer),
  `NativeFn`, `NativeMethodDef`, `installCoreNatives`,
  `installPlatformNatives`, `CLASS_OBJECT`, `atom`. Nothing else from
  the vendored tree is reachable from firmware code.
- `pico/src/main_ruby.zig` — Ruby-engine root source file. At A2 it is
  a stub (platform + console + banner + idle superloop). It will be
  progressively wired at A3 (bindings adapter + runtime), A4
  (cooperative sleep_ms), A5 (`@embedFile`'d `.nrb` bytecode).

Pico-local files edited:

- `pico/build.zig` — adds `Engine` enum + `-Dengine={js,ruby}` build
  option + root-source-file selection. The `.js` arm keeps
  `b.path("src/main.zig")` (untouched), so the default build path
  compiles and produces the byte-identical pre-integration firmware.
  Engine selection is done at the root-source-file level rather than
  by branching in `main.zig`, on GPT-5.4's advice (review thread
  `pico-nanoruby-integration-review-2026`): dead-branch imports in
  `main.zig` would still pull the unselected engine's module graph
  into the compile unit, defeating byte-identity.

Acceptance (A2.5 / A6.7 gates, all hard requirements per
docs/NANORUBY.md):

- `-Dengine=js` UF2 byte-identical to pre-integration baseline:
  PASSED. sha256 `6265c96b...` (plain), `82aad4c6...` (SSID),
  `4cb28108...` (USB_HOST).
- `-Dengine=ruby` compiles and produces a valid UF2:
  PASSED. 494 blocks / 126364 bytes payload, `.text`=119544.
- Hosted-std leak check (`strings $ELF | grep std.debug.print |
  std.Io.File.stderr | std.Io.Threaded`): 0 matches on both engines.
- All six existing build targets (`zig build`, `zig build uf2`,
  `zig build test`, `zig build test-uart`, `zig build test-hal`,
  `zig build test-main`) remain green.

Upstream intent: n/a for these files (pico-local; vendored tree
unchanged in this commit). The vendored `src/ruby/nanoruby/` is not
touched by A2.

### M3 — LED well-known atoms for pico platform natives (A3)

Problem: nanoruby's `vm/atom.zig` pre-interns all native-method names as
well-known atoms (comptime-resolved via `atom("name")` in the platform-
native table), but the upstream list stops at `ATOM_TO_F = 80`. It
includes `gpio_*`, `wifi_*`, `mqtt_*`, `sleep_ms`, `millis` but not
`led_on` / `led_off` / `led_toggle` / `led_blink`. The pico adapter
table needs those names (Pico W's onboard LED is on the CYW43 chip,
not a raw GPIO pin — it routes through `bindings/led.zig` which owns
the blink-state machine).

Edits in `vm/atom.zig`:

- Add `ATOM_LED_ON = 81`, `ATOM_LED_OFF = 82`, `ATOM_LED_TOGGLE = 83`,
  `ATOM_LED_BLINK = 84`.
- Bump `WELL_KNOWN_COUNT` from `81` to `85`.
- Add sorted entries to `well_known_by_name[]` between `last` and
  `length`.
- Append four entries to `atom_names[]` (index 81-84).

Upstream intent: **yes — strongly recommended to upstream.** Nanoruby
already pre-interned the `gpio_*` / `wifi_*` / `mqtt_*` platform native
names speculatively; LED is the same kind of convenience atom.

Pico-local files also added in this commit (A3):

- `pico/src/ruby/runtime.zig` — firmware-facing VM lifecycle
  (`init`, `runBootScript`, `sleepMsCooperative` stub [A4 upgrades],
  `superloopTickOnce`). File header documents the 5 IRQ/async/GC
  invariants from `docs/NANORUBY.md`.
- `pico/src/ruby/bindings_adapter.zig` — the 11-entry platform-native
  table for Phase A (`gpio_*`, `led_*`, `millis`, `sleep_ms`, `puts`).
  Each adapter routes to `bindings/*.zig` internal Zig APIs (for LED +
  console) or directly to `hal.platform.*` (for stateless GPIO and
  read-only clock) per `docs/NANORUBY.md` A3.
- `pico/src/ruby/nanoruby.zig` — small additions (`VmError`,
  `ExecResult`, `ATOM_NEW`, `ATOM_INITIALIZE` re-exports).
- `pico/src/main_ruby.zig` — upgraded from A2 stub to call
  `rb_runtime.init(.{ .heap_kb = 32 })` and enter the superloop with
  `rb_runtime.superloopTickOnce()` + `wfe`. Ruby VM is now live; no
  script is loaded yet (that's A5).

Acceptance (A3 gates):

- `-Dengine=js` UF2 still byte-identical (plain/SSID/USB_HOST all
  match pre-integration baselines).
- `-Dengine=ruby` compiles to 207416-byte payload UF2
  (`.text`=200596, `.data`=6820, `.bss`=157336). Below the
  `docs/NANORUBY.md` memory budget (≤550 KB flash target).
- `strings $ELF | grep 'std\\.debug\\.print|std\\.Io\\.File\\.stderr|std\\.Io\\.Threaded'`
  returns 0 on both engines.
- All six build targets green (js + test + test-uart + test-hal +
  test-main + ruby).

### M4 — Cooperative sleep_ms hardened (A4, pico-local only)

No vendored-tree edits. All changes are in pico-local files.

`pico/src/ruby/runtime.zig`:

- `sleepMsCooperative(ms)` upgraded from A3's busy-loop to the full
  production contract from `docs/NANORUBY.md` §A4:
  * Per-call clamp of 60 000 ms (`MAX_SLEEP_MS` constant).
  * `wfe` between cooperative pumps — CPU idles until the next IRQ
    (10 ms periodic timer, UART RX, GPIO edges). No hot-loop.
  * Re-entrancy guard (`in_sleep` flag) — if a future Phase B
    callback dispatches from inside `sleep_ms`, the nested call
    returns immediately rather than silently nesting the pump
    (invariant #5 in the file header).
  * Monotonic-wrap-safe deadline comparison: u32 subtraction +
    signed bitcast produces correct ordering across the 32-bit
    wrap.

Acceptance:

- `.js` byte-identical (plain): 6265c96b...
- `.ruby` UF2: 207456 bytes payload (+40 vs A3), `.text`=200636,
  hosted-std strings = 0.
- All six build targets green.

### M5 — Host nrbc build + bytecode embed (A5, pico-local only)

No vendored-tree edits. All changes are in pico-local files
(`build.zig`, `pico/src/ruby/runtime.zig`, `scripts/blinky*.rb`).

Edits:

- `build.zig` inside `if (engine == .ruby)` — build `nrbc` from the
  vendored `src/ruby/nanoruby/nrbc.zig` as a host-native executable,
  run it on the `-Druby_script` path (default `scripts/blinky.rb`),
  pipe the resulting `.nrb` into `fw_module.addAnonymousImport
  ("script_bytecode", ...)`. The `.js` arm is completely untouched.
- `pico/src/ruby/runtime.zig` — replace the A4 `runBootScript` stub
  with a real implementation: declare a stack-local `IrFunc` with
  explicit defaults for the 5 no-default fields (issue #16), call
  `Loader.deserialize(script_bytecode, &func)`, then
  `vm_state.execute(&func)`. Reports deserialize + execution errors
  to the UART console via `console.puts` + `@errorName`.
- `scripts/blinky.rb`, `scripts/blinky_2.rb`, `scripts/blinky_3.rb`
  — Phase A graduation scripts, all using `while true` (not
  `loop { }` — the current `.nrb` format drops child funcs; see
  ISSUES.md #15).

Acceptance (all A5 gates green):

- `.js` byte-identical (plain/SSID/USB_HOST all match baselines).
- `.ruby` UF2 with embedded blinky.rb: 813 blocks, 208120-byte
  payload, `.text`=201300. Bytecode blob 46 bytes (blinky.rb) /
  53 bytes (blinky_2.rb) / 64 bytes (blinky_3.rb).
- Hosted-std strings check: 0 matches.
- All six build targets green.

### M6 — `.nrb` format v2: serialize syms + string_literals (A6 fix)

Problem caught on hardware: blinky.rb embedded with `.nrb` v1
deserialized to an `IrFunc` whose `syms` and `string_literals` slices
were left at their struct defaults (`&.{}`). Any SEND / LOAD_SYM /
LOAD_GVAR / LOAD_STRING opcode then over-indexed into the empty
slice and the VM raised `ConstOutOfBounds`. On-device picocom output:

    [nanoruby] executing boot script
    [nanoruby] boot script error: ConstOutOfBounds

The v1 format was only ever exercised (upstream) by the LOAD_CONST /
ADD / RETURN tests in `vm/nrb.zig` — programs without method calls
or string literals. Any realistic script hits this.

Edits to `vm/nrb.zig`:

- Bump `VERSION` from 1 to 2. Firmware rejects v1 blobs with
  `NrbError.BadVersion`.
- Function header grows from 5 bytes to 7 bytes: add `sym_count` (u8)
  and `string_count` (u8) after the existing `const_count`.
- Serialize the syms array (u16 atom IDs, LE) after the constants.
- Serialize string literals after the syms: each string prefixed with
  its u16 LE length, then raw bytes.
- Add `sym_storage: [256]u16` and `string_storage: [256][]const u8`
  file-scope BSS statics for the deserialized slice backings. String
  byte-slice pointers alias into the blob (.rodata on firmware);
  LOAD_STRING copies into the heap on materialisation, so the alias
  is safe.
- Reject `.nrb` blobs with const/sym/string counts >255 on the wire;
  Phase B can widen if needed.

Explicitly NOT yet serialized (still in ISSUES.md #15):

- `child_funcs` — blocks (`loop do … end`, `5.times { }`, `each { }`)
  remain unsupported at Phase A. Scripts use `while true` instead.
- `float_pool` — no float-literal use in Phase A scripts.

Upstream intent: **yes — strongly recommended to upstream.** The v1
format is buggy for any realistic program; v2 (plus eventual v3 with
child_funcs + floats) is the correct shape.

Acceptance:

- `.js` still byte-identical (6265c96b...).
- `.ruby` UF2: 814 blocks / 208152 bytes payload (+32 bytes .text for
  the new serialize logic, +2560 bytes .bss for the two new storage
  arrays).
- blinky.rb now serializes to 52 bytes (was 46 under v1 — additional
  2 bytes of count fields + 2 × 2 bytes of syms for `led_toggle` and
  `sleep_ms`).

### M7 — `allocHeapObj` GC tombstone-reclamation fix

Problem caught on pico hardware soak: blinky_3.rb (`puts "blink " +
count.to_s; sleep_ms 500`) ran for ~84 iterations then died with
`[nanoruby] boot script error: TypeError`. Root cause traced to
`vm/vm.zig::allocHeapObj`:

```zig
// pre-M7
pub fn allocHeapObj(...) ?HeapAlloc {
    if (self.obj_registry_count >= self.obj_registry.len) return null;
    const raw = self.heap.allocObj(obj_type, payload_bytes) orelse {
        self.gc();
        const retry = self.heap.allocObj(obj_type, payload_bytes) orelse return null;
        return self.registerObj(obj_type, retry);
    };
    return self.registerObj(obj_type, raw);
}
```

`obj_registry_count` is a high-water mark — `gc()` never decrements
it. `gc()` tombstones dead slots (sets `raw_ptr = null`); the
separate `registerObj` function already knew how to walk for
tombstones and reuse them. But the up-front HWM check short-circuited
before `registerObj` ever got called on the HWM-saturated path. Once
any program reached MAX_OBJ_REGISTRY (256) simultaneously live
objects, every subsequent allocation returned null without a GC
attempt. `Integer#to_s`'s `orelse Value.nil` then propagated nil
into `String#+`, producing TypeError.

Edit in `vm/vm.zig`:

```zig
// post-M7
pub fn allocHeapObj(...) ?HeapAlloc {
    if (self.tryAllocHeapObj(obj_type, payload_bytes)) |r| return r;
    self.gc();
    return self.tryAllocHeapObj(obj_type, payload_bytes);
}

fn tryAllocHeapObj(...) ?HeapAlloc {
    const raw = self.heap.allocObj(obj_type, payload_bytes) orelse return null;
    return self.registerObj(obj_type, raw);
}
```

Both failure modes (heap-bytes-full OR registry-full) now trigger
`gc()` once and retry via the same path that walks for tombstones.
If after GC both conditions are STILL unrecoverable (genuinely 256
live objects with no garbage OR a payload larger than the remaining
compacted heap), the retry returns null and the caller's
`orelse Value.nil` path kicks in as before — but that's now a true
limit, not an artefact of the HWM check.

No `.nrb` format change. No API change. The fix is source-visible
only to contributors reading the vendored tree.

Upstream intent: **yes — strongly recommended to upstream.** This is
a straightforward bug, the kind that evades host-side tests because
they tend to allocate <256 objects per test case. Pico's sustained-
loop soak was the natural exercise.

Acceptance (post-M7, verified locally):

- `.js` UF2 still byte-identical (6265c96b...).
- `.ruby` UF2 rebuilt (new hash; format unchanged so size is stable
  modulo a few bytes for the refactored helper).
- The blinky_3.rb TypeError should no longer appear; the script
  should now run indefinitely or until some other resource saturates.
  Hardware verification required to confirm.

ISSUES.md #20 updated to mark this as resolved-pending-hardware-
verification.

### M8 — nrbc success message → stdout

Cosmetic. `nrbc.zig`'s final "nrbc: wrote N bytes to …" diagnostic
was routed to stderr via `eprint`. Zig 0.16's build system flags any
step with stderr output and echoes the command prefixed with
"failed command:" — misleading. Switching this one `eprint` to
`print` (stdout) silences the spurious noise in `zig build` output
without losing the diagnostic. Error paths (`die`, `parse error`,
etc.) still use stderr correctly.

Upstream intent: **yes**, though low priority. Standard Unix
convention puts "I successfully did X" on stdout and "error:" on
stderr.

### M9 — (reserved for further hardware iteration)

Subsequent modifications enumerated here as they are committed.

## How to re-vendor

1. Identify the target upstream SHA (ideally a tagged release).
2. Capture the desired upstream working-tree or `HEAD` state.
3. Record the new SHA, date, and dirty state in this file (new "Snapshot"
   section above; keep the old one for history).
4. `rm -rf pico/src/ruby/nanoruby/` (preserves `UPSTREAM.md` in the commit
   message only — copy it aside first if you want to keep the mod log).
5. `cp -R <upstream>/src/. pico/src/ruby/nanoruby/`
6. **Re-apply each entry in "Local modifications" in order.** Do not
   re-derive them from scratch — use `git log` of this directory in the
   pico repo for the canonical change set.
7. Update this `UPSTREAM.md` with the new SHA and snapshot date.
8. Rebuild and re-run firmware acceptance gates.

The cost of re-vendoring is proportional to the number of entries in "Local
modifications". Keep that section tight.
