// pico — Ruby engine entry point.
//
// This is the root source file for `zig build -Dengine=ruby`. The default
// `zig build -Dengine=js` uses `src/main.zig` instead and is byte-identical
// to the pre-integration firmware (see docs/NANORUBY.md A2.5 acceptance).
//
// Boot flow (progressively wired across A2–A5 in docs/NANORUBY.md):
//   A2 (this file) — platform + console + banner, then idle superloop.
//                    Proves the Ruby-engine build path compiles to a valid
//                    UF2; no Ruby VM is actually invoked yet.
//   A3 — init the nanoruby VM (32 KB heap), install core + platform natives
//        routed through `src/bindings/*.zig`, run boot superloop.
//   A4 — cooperative sleep_ms with defined semantics.
//   A5 — @embedFile'd .nrb bytecode + `Loader.deserialize` + execute.
//   A6 — hardware acceptance (blinky.rb).

comptime {
    _ = @import("platform/startup.zig");
}

const build_config = @import("build_config");
const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const fmt = @import("lib/fmt.zig");
const console = @import("bindings/console.zig");
const watchdog = @import("runtime/watchdog.zig");

comptime {
    // Preserve the binding exports that the C function table expects.
    // The Ruby path doesn't yet call into these from user code, but
    // dropping them would change the firmware's `extern` surface.
    _ = @import("bindings/console.zig");
    _ = @import("bindings/gpio.zig");
    _ = @import("bindings/led.zig");
    _ = @import("bindings/timers.zig");
}

const BANNER =
    \\
    \\  ┌─────────────────────────┐
    \\  │  pico v0.1.0 [ruby]     │
    \\  │  A2 stub build          │
    \\  └─────────────────────────┘
    \\
;

const puts = fmt.puts;

pub fn main() noreturn {
    hal.init();
    console.init();

    // Same 5 s picocom-connect window as the JS build.
    hal.delayMs(5000);

    puts(BANNER);
    puts("[boot] platform: RP2040 @ 125 MHz (ruby engine, A2 stub)\n");
    puts("[boot] Ruby runtime integration lands in A3-A5 per docs/NANORUBY.md\n");

    rp2040.initPeriodicTick();

    // A3 will replace this with the cooperative superloop from
    // `src/ruby/runtime.zig` (watchdog.feed / scheduler.poll / led.poll /
    // netif.poll / wifi.poll / mqtt.poll + VM tick).
    while (true) {
        asm volatile ("wfe");
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
