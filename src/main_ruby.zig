// pico — Ruby engine entry point.
//
// This is the root source file for `zig build -Dengine=ruby`. The default
// `zig build -Dengine=js` uses `src/main.zig` instead and is byte-identical
// to the pre-integration firmware (see docs/NANORUBY.md A2.5 acceptance).
//
// Boot flow across A2–A5 in docs/NANORUBY.md:
//   A2 — platform + console + banner, idle superloop (stub).
//   A3 — init the nanoruby VM (32 KB heap), install core + platform natives
//        routed through `src/bindings/*.zig`, enter superloop with LED
//        blink-state pump + watchdog. Done in this file. No Ruby script
//        runs yet (that's A5).
//   A4 — cooperative `sleep_ms` with defined semantics.
//   A5 — `@embedFile`'d `.nrb` bytecode + `Loader.deserialize` + execute.
//   A6 — hardware acceptance (blinky.rb).

comptime {
    _ = @import("platform/startup.zig");
}

const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const fmt = @import("lib/fmt.zig");
const console = @import("bindings/console.zig");
const rb_runtime = @import("ruby/runtime.zig");

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
    \\  │  A3 — VM initialized    │
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
    puts("[boot] platform: RP2040 @ 125 MHz (ruby engine)\n");

    rb_runtime.init(.{ .heap_kb = 32 }) catch {
        puts("[boot] FATAL: nanoruby VM init failed\n");
        hang();
    };
    puts("[boot] nanoruby VM ready (32 KB heap)\n");

    // A5 will load a `.nrb` bytecode blob and execute it here.
    rb_runtime.runBootScript();

    rp2040.initPeriodicTick();

    puts("[boot] entering superloop (no boot script — A5 not yet wired)\n");

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
