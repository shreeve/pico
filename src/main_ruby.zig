// pico — Ruby engine entry point.
//
// Root source file for `zig build -Dengine=ruby`. The default
// `zig build -Dengine=js` uses `src/main.zig` instead, which is
// byte-identical to the pre-integration firmware (see
// docs/NANORUBY.md A2.5 acceptance gate, hash 6265c96b…).
//
// Integration phases (history in git log a31909c..27ced7a):
//   A1–A2 — vendor fork, native-table split, engine gate.
//   A3    — nanoruby VM + core + platform natives via bindings_adapter.
//   A4    — cooperative sleep_ms (wfe + 60 s clamp + re-entrancy guard).
//   A5    — `@embedFile`'d `.nrb` bytecode + Loader.deserialize + execute.
//   A6    — hardware acceptance (LED blink, `puts`, fixnum arithmetic,
//           String alloc + GC under load, cooperative UART reboot).
//
// Phase B (deferred): WiFi/MQTT parity, Ruby blocks (see ISSUES.md
// #15), `pending_native_error` exercise on hardware (ISSUES.md #17).

comptime {
    _ = @import("platform/startup.zig");
}

const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const fmt = @import("lib/fmt.zig");
const console = @import("bindings/console.zig");
const wifi = @import("bindings/wifi.zig");
const rb_runtime = @import("ruby/runtime.zig");

// These `comptime` imports exist for their side effect: each binding
// module declares `pub export fn js_*(…) …` symbols that the C
// function table in `src/js/pico_stdlib_data.c` expects at link time.
// The Ruby path does NOT call into the `js_*` exports, but the C
// table still references them, so the symbols must be present or
// the link fails. Do not delete these imports during a cleanup pass
// unless `pico_stdlib_data.c` is also taught that the Ruby engine
// does not need them. See also: `src/main.zig`'s matching block.
comptime {
    _ = @import("bindings/console.zig");
    _ = @import("bindings/gpio.zig");
    _ = @import("bindings/led.zig");
    _ = @import("bindings/timers.zig");
    _ = @import("bindings/wifi.zig");
}

const BANNER =
    \\
    \\  ┌─────────────────────────┐
    \\  │  pico v0.1.0 [ruby]     │
    \\  │  nanoruby on metal      │
    \\  └─────────────────────────┘
    \\
;

const puts = fmt.puts;

// REQUIRED BOOT ORDER (mirrors src/main.zig and documented to prevent
// future A6-style regressions — bug history in git log for ef031c1):
//
//   1. hal.init()                    — clocks @ 125 MHz, peripherals
//   2. console.init()                — UART @ 115200
//   3. wifi.init()                   — CYW43 bring-up; required for
//                                      the onboard LED (not a raw GPIO)
//   4. rb_runtime.init(...)          — nanoruby VM + core + platform
//                                      native tables; installs the
//                                      adapter table from
//                                      `bindings_adapter.zig`
//   5. rp2040.initPeriodicTick()     — **must** be before step 6.
//                                      The boot script's sleep_ms uses
//                                      `wfe`, and without a periodic
//                                      tick IRQ as a wake source,
//                                      sleep_ms(ms) returns in µs.
//   6. rb_runtime.runBootScript()    — `@embedFile`'d .nrb; normally
//                                      never returns (scripts use
//                                      `while true`).
//
// If step 6 ever does return, the trailing `while (true)` below kicks
// in as a fallback. For Phase A all scripts loop forever, so that
// path is unreached in practice.

pub fn main() noreturn {
    hal.init();
    console.init();

    // 5 s delay before the first banner write so the UART serial
    // console host (picocom over CP2102 or debug-probe CDC) has time
    // to attach after a `picotool load` reboot. Matches the JS path
    // (`src/main.zig`). Not a CDC-reset quirk — just a human-timing
    // buffer.
    hal.delayMs(5000);

    puts(BANNER);
    puts("[boot] platform: RP2040 @ 125 MHz (ruby engine)\n");

    // CYW43 bring-up. Required even when WiFi join is not attempted —
    // the Pico W's onboard LED is wired to a CYW43 GPIO (not a raw
    // RP2040 pin), so `bindings/led.zig` needs the driver alive to
    // succeed. This takes several seconds (SPI backplane + firmware
    // upload + SDPCM handshake). Any configured -DSSID credential is
    // loaded into `build_config.ssid/pass` but we do NOT call
    // `wifi.connect()` here; association is Phase B territory.
    //
    // Policy consequence: Ruby mode pays CYW43 bring-up cost on every
    // boot even if the script never toggles the LED or touches WiFi.
    // Acceptable for Phase A; revisit if iteration time becomes an
    // annoyance.
    wifi.init();

    rb_runtime.init(.{ .heap_kb = 32 }) catch {
        puts("[boot] FATAL: nanoruby VM init failed\n");
        hang();
    };
    // Log the actual arena size, not the ignored `heap_kb` argument.
    // nanoruby's VM.initDefault() uses DEFAULT_ARENA_SIZE (32 KB); the
    // InitOptions.heap_kb field is reserved for Phase B (see
    // src/ruby/runtime.zig::InitOptions).
    puts("[boot] nanoruby VM ready (32 KB arena, nanoruby default)\n");

    // Periodic tick BEFORE runBootScript — see boot-order comment above.
    rp2040.initPeriodicTick();

    rb_runtime.runBootScript();

    puts("[boot] entering superloop (script returned — unusual)\n");

    while (true) {
        rb_runtime.superloopTickOnce();
        asm volatile ("wfe");
    }
}

fn hang() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

// Startup-referenced hooks (see src/platform/startup.zig).
pub fn timerIrq0() void {
    rp2040.timerIrq0Handler();
}

pub fn usbIrq() void {
    // USB host is .js-path only for now; stub on the Ruby path.
}

pub const panic = @import("runtime/panic.zig").panic;
pub const hardFault = @import("runtime/panic.zig").hardFault;
