/// Cooperative event loop — timers, deferred callbacks, and task scheduler.
///
/// Scheduling contract:
///   - single-core, non-preemptive (RP2040 core 0 only)
///   - every poll callback must be short and non-blocking
///   - device polling (WiFi, UART, MQTT, net) is handled explicitly
///     in the main loop, not through this module
///   - timer accuracy is best-effort based on main loop cadence
const std = @import("std");
const hal = @import("../platform/hal.zig");
const timer_mod = @import("timer.zig");
const scheduler = @import("scheduler.zig");

var tick_count: u64 = 0;

const IoCallback = *const fn () void;

const MAX_IO_SOURCES = 8;
var io_sources: [MAX_IO_SOURCES]?IoCallback = [_]?IoCallback{null} ** MAX_IO_SOURCES;
var io_source_count: usize = 0;

/// Process pending timers, deferred I/O callbacks, and scheduled tasks.
/// Called once per main loop iteration. Returns true if work was done.
pub fn step() bool {
    tick_count +%= 1;
    timer_mod.processPending();
    processIO();
    const had_work = scheduler.hasWork();
    scheduler.runReady();
    return had_work;
}

/// Register an I/O poll callback (used by USB host when enabled).
pub fn registerIO(cb: IoCallback) !void {
    if (io_source_count >= MAX_IO_SOURCES) return error.TooManyIOSources;
    io_sources[io_source_count] = cb;
    io_source_count += 1;
}

fn processIO() void {
    for (io_sources[0..io_source_count]) |maybe_cb| {
        if (maybe_cb) |cb| cb();
    }
}

pub fn ticks() u64 {
    return tick_count;
}
