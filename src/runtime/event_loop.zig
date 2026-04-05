/// Core cooperative event loop.
/// Polls timers, I/O readiness, and the JS VM in a tight loop.
/// No threads -- everything is single-core, run-to-completion.
const std = @import("std");
const hal = @import("../platform/hal.zig");
const timer_mod = @import("timer.zig");
const scheduler = @import("scheduler.zig");

pub const EventSource = enum {
    timer,
    io,
    vm,
    net,
};

var running: bool = false;
var tick_count: u64 = 0;

const IoCallback = *const fn () void;

const MAX_IO_SOURCES = 8;
var io_sources: [MAX_IO_SOURCES]?IoCallback = [_]?IoCallback{null} ** MAX_IO_SOURCES;
var io_source_count: usize = 0;

/// Start the event loop (never returns under normal operation).
pub fn run() noreturn {
    running = true;

    while (running) {
        tick_count +%= 1;

        timer_mod.processPending();
        processIO();
        scheduler.runReady();

        // If nothing happened, briefly idle to reduce power
        if (!scheduler.hasWork() and !timer_mod.hasPending()) {
            asm volatile ("wfi");
        }
    }

    unreachable;
}

/// Execute one iteration of the loop (for testing / hosted mode).
pub fn step() void {
    tick_count +%= 1;
    timer_mod.processPending();
    processIO();
    scheduler.runReady();
}

/// Register an I/O poll callback.
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

pub fn stop() void {
    running = false;
}

pub fn ticks() u64 {
    return tick_count;
}
