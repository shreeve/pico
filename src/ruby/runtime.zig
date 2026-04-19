// pico/src/ruby/runtime.zig — firmware-facing nanoruby runtime.
//
// ════════════════════════════════════════════════════════════════════
// IRQ and async safety invariants (docs/NANORUBY.md §"IRQ and async safety")
//
//   (1) No VM entry from IRQ context.
//       Timer ISR, UART RX ISR, USB CDC, network RX — none of them call
//       into the nanoruby VM directly.
//
//   (2) Async sources enqueue events to non-VM-owned buffers.
//       UART RX → raw byte ring buffer. Timer tick → atomic counter / flag.
//       MQTT message (Phase B) → a pico-owned queue of {topic, payload}
//       byte pairs.
//
//   (3) Main loop drains.
//       Every iteration of pico's superloop AND every iteration of
//       `superloopTickOnce` during cooperative sleep inspects the event
//       queues and, if the VM is idle, dispatches Ruby-level handlers.
//
//   (4) Compacting GC ⇒ no raw pointers across calls.
//       Native adapters that return heap objects (strings, arrays) return
//       them inline; the VM's calling frame roots them. Adapters do NOT
//       cache `*Value` or string-data pointers between calls. See
//       `bindings_adapter.zig` for the adapter-level rules.
//
//   (5) Re-entrancy into `sleep_ms` is forbidden.
//       If a binding callback path is added in Phase B (e.g., MQTT
//       on-message), those callbacks run from the superloop, never from
//       inside `sleep_ms`.
//
// Violating any of these produces intermittent crashes that are painful
// to debug. New contributors must read this header before editing.
//
// ════════════════════════════════════════════════════════════════════
// COOPERATIVE-YIELD CONTRACT (docs/NANORUBY.md §Cooperative sleep_ms)
//
// During Ruby VM execution, the ONLY firmware progress guarantees come
// from `sleep_ms` (or any future explicit yield primitive) calling
// `superloopTickOnce()` — plus IRQ-driven subsystems that do not enter
// the VM. A tight Ruby loop without `sleep_ms` is a starvation test:
//   - `reboot` UART shell stops responding.
//   - `watchdog.feed()` stops firing; 8 s later the MCU resets.
//   - `led.poll()` stops advancing the blink-state machine.
//   - Phase B WiFi/MQTT/netif pumps (when added) will stall.
//
// Script authors must therefore yield cooperatively. For the Phase A
// graduation set (`while true; led_toggle; sleep_ms(ms); end`) this
// is trivially satisfied. For Phase B scripts the policy should be
// documented in a user-facing guide, not just a file header.
// ════════════════════════════════════════════════════════════════════

const std = @import("std");
const nanoruby = @import("nanoruby.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;
const watchdog = @import("../runtime/watchdog.zig");
const led = @import("../bindings/led.zig");
const console = @import("../bindings/console.zig");
const bindings_adapter = @import("bindings_adapter.zig");

pub const InitOptions = struct {
    /// VM heap size in KB. **Currently ignored.** `VM.initDefault()`
    /// uses nanoruby's `DEFAULT_ARENA_SIZE` (32 KB). Field retained in
    /// the API so Phase B can wire through a caller-supplied arena
    /// buffer without breaking `init()`'s signature.
    heap_kb: u32 = 32,
};

var vm_state: nanoruby.VM = undefined;
var initialized: bool = false;

pub fn init(opts: InitOptions) !void {
    _ = opts; // heap_kb is reserved for Phase B; see InitOptions docs
    if (initialized) return;

    vm_state = nanoruby.VM.initDefault();
    nanoruby.installCoreNatives(&vm_state);
    nanoruby.installPlatformNatives(&vm_state, &bindings_adapter.pico_platform_natives);

    // Core dispatch atoms that the VM uses for implicit method lookup.
    vm_state.setSymNew(nanoruby.ATOM_NEW);
    vm_state.setSymInitialize(nanoruby.ATOM_INITIALIZE);

    initialized = true;
}

/// Pointer to the live VM, for Phase B callback-dispatch paths.
/// **Main-loop context only — must not be used from ISR or any
/// context that violates invariant #1 in the file header.** Right
/// now no code uses this accessor; it's retained for Phase B
/// MQTT-subscribe-style machinery that needs to hand a Value back
/// into the VM from a superloop-drained event queue.
pub fn vm() *nanoruby.VM {
    return &vm_state;
}

/// The `.nrb` bytecode blob embedded at build time via
/// `fw_module.addAnonymousImport("script_bytecode", …)` in build.zig.
/// `@embedFile` places it in `.rodata` (flash).
///
/// Lifetime contract (narrowed to the M6 `.nrb` v2 format): for the
/// fields `Loader.deserialize` currently populates — `bytecode`,
/// `const_pool` backing, `syms` backing, `string_literals` byte
/// slices — the aliased pointers resolve to `.rodata` (immutable
/// flash) or `nrb.zig`'s file-scope BSS storage. Neither is relocated
/// by the VM's compacting GC, so stack-local `IrFunc` is safe across
/// `vm.execute()`. If the format grows further (child_funcs, floats —
/// see ISSUES.md #15), re-audit this contract against the new
/// backing stores before trusting it.
const script_bytecode = @embedFile("script_bytecode");

/// Run the embedded boot script. Called once from `main()` before
/// entering the superloop. The script drives the LED via `led_toggle`
/// and paces itself via `sleep_ms`, which internally pumps
/// `superloopTickOnce()` — so even long-running Ruby `while true`
/// loops keep the LED blink-state machine live and the UART reboot
/// shell responsive.
///
/// TODO(phase-A-hardening): `superloopTickOnce()` also calls
/// `watchdog.feed()`, but `watchdog.init(8000)` is NOT yet called on
/// the Ruby path (see ISSUES.md #18). Until that lands, the feed is
/// a no-op. Arm the watchdog in `main_ruby.zig` between
/// `rb_runtime.init()` and `rp2040.initPeriodicTick()` once we've
/// run a full 10-minute soak without surprises.
pub fn runBootScript() void {
    var func: nanoruby.IrFunc = .{
        .bytecode = undefined,
        .bytecode_len = 0,
        .nregs = 0,
        .nlocals = 0,
        .const_pool = &.{},
        // Remaining fields default to empty slices / zero per IrFunc's
        // struct defaults. Caller-init is explicit because
        // `Loader.deserialize` overwrites only the 5 no-default fields.
    };

    nanoruby.Loader.deserialize(script_bytecode, &func) catch |err| {
        console.puts("[nanoruby] bytecode load failed: ");
        console.puts(@errorName(err));
        console.puts("\n");
        return;
    };

    console.puts("[nanoruby] executing boot script\n");
    const result = vm_state.execute(&func);
    switch (result) {
        .ok => console.puts("[nanoruby] boot script returned\n"),
        .err => |e| {
            console.puts("[nanoruby] boot script error: ");
            console.puts(@errorName(e));
            console.puts("\n");
        },
    }
}

/// Shared cooperative-pump. Every iteration of the main superloop AND
/// every iteration of `sleepMsCooperative` (A4) calls this exactly
/// once. Keep it tight and bounded — no blocking calls.
///
/// Phase A set: watchdog feed + LED blink poll + UART shell poll
/// (for the `reboot` command, essential for the dev flash loop).
/// WiFi/MQTT/netif/USB pollers land when their bindings are actually
/// invoked from Ruby (Phase B). Phase A scripts only need these
/// three, and keeping the pump minimal reduces the "what could wake
/// from wfe?" surface area.
pub fn superloopTickOnce() void {
    watchdog.feed();
    led.poll();
    pollUart();
}

// ── UART shell ───────────────────────────────────────────────────────
//
// The JS build's `src/main.zig` owns a `pollUart` that listens for the
// `reboot` command (and a `wifi` retry). The Ruby build cannot reuse
// main.zig's version because (a) main.zig is frozen for byte-identity
// (docs/NANORUBY.md A2.5), and (b) the Ruby superloop is actually
// `sleep_ms`'s cooperative-pump, not a top-level loop. Duplicate the
// minimum here: `reboot` is the only command needed to drive the
// dev-flash iteration. If a `wifi` retry is ever needed from the Ruby
// path, extend this helper.

const reboot_cmd: []const u8 = "reboot";

// Main-loop only. Not IRQ-safe. `pollUart()` is exclusively called
// from `superloopTickOnce()` which itself is main-loop-only per
// invariant #1. If a future contributor ever wires UART polling into
// an ISR, this buffer needs either a dedicated ring-buffer feeder or
// explicit interrupt-disable around the read/accumulate.
var uart_cmd_buf: [16]u8 = undefined;
var uart_cmd_len: usize = 0;

fn pollUart() void {
    while (rp2040.uartReadAvailable(rp2040.UART0_BASE)) {
        const ch = rp2040.uartRead(rp2040.UART0_BASE);
        if (ch == '\r' or ch == '\n') {
            const cmd = uart_cmd_buf[0..uart_cmd_len];
            if (cmd.len == reboot_cmd.len and std.mem.eql(u8, cmd, reboot_cmd)) {
                console.puts("[reboot] entering BOOTSEL mode...\n");
                rp2040.resetToUsbBoot();
            }
            uart_cmd_len = 0;
        } else if (uart_cmd_len < uart_cmd_buf.len) {
            uart_cmd_buf[uart_cmd_len] = ch;
            uart_cmd_len += 1;
        } else {
            uart_cmd_len = 0;
        }
    }
}

/// Hard clamp on a single `sleep_ms` call. Longer Ruby sleeps must
/// be a Ruby-side loop of `sleep_ms` calls. Rationale: keeps the
/// cooperative pump cadence tight.
pub const MAX_SLEEP_MS: u32 = 60_000;

/// Re-entrancy guard. `sleep_ms` is not re-entrant (invariant #5 in
/// the file header). If a Phase B callback is ever dispatched from
/// inside `sleep_ms`, this flag traps the caller — nested call
/// returns immediately without pumping — rather than allowing an
/// undetected nested pump.
///
/// **Main-loop only. Not IRQ-safe.** Protected exclusively by
/// invariant #1 (no VM entry from IRQ). If that invariant is ever
/// violated, this flag races. A future revision in debug builds
/// might assert main-loop context here rather than silently skip.
var in_sleep: bool = false;

/// Cooperative sleep. Blocks Ruby execution for ≥ `ms` milliseconds
/// while pumping the superloop. Contract (docs/NANORUBY.md §A4):
///   - Wall-clock based on `hal.millis()`.
///   - Clamped per call to `MAX_SLEEP_MS` (60 s). Longer sleeps =
///     Ruby-side loop.
///   - Pumps `superloopTickOnce()` each iteration.
///   - Uses `wfe` between pumps so the CPU idles until the next
///     interrupt (periodic timer tick + UART RX + GPIO IRQs all
///     wake).
///   - Not cancellable from Ruby.
///   - Not re-entrant — re-entry returns immediately without pumping.
pub fn sleepMsCooperative(ms: u32) void {
    if (in_sleep) return; // invariant #5: refuse to nest
    in_sleep = true;
    defer in_sleep = false;

    const clamped: u32 = @min(ms, MAX_SLEEP_MS);
    if (clamped == 0) {
        superloopTickOnce();
        return;
    }

    // `hal.millis()` is u64; fold to u32 so overflow arithmetic wraps
    // cleanly at 32 bits. 2^32 ms ≈ 49.7 days — longer than any
    // single sleep_ms can span (`clamped` ≤ 60 000).
    const start: u32 = @truncate(hal.millis());
    const deadline: u32 = start +% clamped;

    while (true) {
        const now: u32 = @truncate(hal.millis());
        const delta: i32 = @bitCast(now -% deadline);
        if (delta >= 0) break;
        superloopTickOnce();
        // wfe: sleep the core until the next event. Wake sources
        // include the 10 ms periodic timer (set up in main_ruby.zig
        // via `rp2040.initPeriodicTick()`), UART RX IRQ, and GPIO
        // edge-triggered IRQs. The deadline check at loop top re-
        // evaluates `hal.millis()` post-wake and exits when due.
        asm volatile ("wfe");
    }
}
