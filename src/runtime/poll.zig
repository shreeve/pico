/// Cooperative polling runtime — timers, deferred callbacks, and tasks.
///
/// This module handles JS timers (setTimeout/setInterval), deferred
/// callbacks, and the task scheduler. It does NOT own subsystem polling;
/// all forward progress happens through explicit poll() calls from main.
const std = @import("std");
const hal = @import("../platform/hal.zig");
const timer_mod = @import("timer.zig");
const scheduler = @import("scheduler.zig");

var tick_count: u64 = 0;

/// Process pending timers, deferred callbacks, and scheduled tasks.
/// Called once per main loop iteration. Returns true if work was done.
pub fn step() bool {
    tick_count +%= 1;
    timer_mod.processPending();
    const had_work = scheduler.hasWork();
    scheduler.runReady();
    return had_work;
}

pub fn ticks() u64 {
    return tick_count;
}
