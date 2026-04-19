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
// ════════════════════════════════════════════════════════════════════

const nanoruby = @import("nanoruby.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;
const watchdog = @import("../runtime/watchdog.zig");
const led = @import("../bindings/led.zig");
const console = @import("../bindings/console.zig");
const bindings_adapter = @import("bindings_adapter.zig");

pub const InitOptions = struct {
    /// VM heap size in KB. Currently honored only indirectly — the
    /// VM uses `DEFAULT_ARENA_SIZE` (32 KB per nanoruby). A future
    /// revision will accept the buffer from this module instead of
    /// the VM's file-scope static.
    heap_kb: u32 = 32,
};

var vm_state: nanoruby.VM = undefined;
var initialized: bool = false;

pub fn init(opts: InitOptions) !void {
    _ = opts;
    if (initialized) return;

    vm_state = nanoruby.VM.initDefault();
    nanoruby.installCoreNatives(&vm_state);
    nanoruby.installPlatformNatives(&vm_state, &bindings_adapter.pico_platform_natives);

    // Core dispatch atoms that the VM uses for implicit method lookup.
    vm_state.setSymNew(nanoruby.ATOM_NEW);
    vm_state.setSymInitialize(nanoruby.ATOM_INITIALIZE);

    initialized = true;
}

/// Reference to the live VM — used by adapters that need to raise or
/// allocate (none currently — adapters receive `*VM` via the NativeFn
/// signature). Kept available for Phase B callback-dispatch paths.
pub fn vm() *nanoruby.VM {
    return &vm_state;
}

/// Run the embedded boot script. Stub at A3; fleshed out in A5 (the
/// `@embedFile`'d `.nrb` bytecode is deserialized via
/// `nanoruby.Loader` and executed on the initialized VM).
pub fn runBootScript() void {
    // A5 populates this.
}

/// Shared cooperative-pump. Every iteration of the main superloop AND
/// every iteration of `sleepMsCooperative` (A4) calls this exactly
/// once. Keep it tight and bounded — no blocking calls.
///
/// Phase A set: watchdog feed + LED blink poll. WiFi/MQTT/netif/USB
/// pollers land when their bindings are actually invoked from Ruby
/// (Phase B). Phase A blinky.rb only needs the LED + watchdog, and
/// keeping the pump minimal reduces the "what could wake from wfe?"
/// surface area.
pub fn superloopTickOnce() void {
    watchdog.feed();
    led.poll();
}

/// Hard clamp on a single `sleep_ms` call. Longer Ruby sleeps must
/// be a Ruby-side loop of `sleep_ms` calls. Rationale: keeps the
/// cooperative pump cadence tight.
pub const MAX_SLEEP_MS: u32 = 60_000;

/// Re-entrancy guard. `sleep_ms` is not re-entrant (invariant #5 in
/// the file header). If a Phase B callback is ever dispatched from
/// inside `sleep_ms`, this flag traps the caller rather than
/// allowing an undetected nested pump.
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
