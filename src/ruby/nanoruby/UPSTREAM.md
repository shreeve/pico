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

### M2 — (reserved for the public face `pico/src/ruby/nanoruby.zig`, A1.4)

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
