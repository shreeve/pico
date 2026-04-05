/// Software timer management.
/// Provides setTimeout / setInterval semantics backed by the hardware
/// microsecond counter.  Timer callbacks are invoked from the event loop,
/// never from interrupt context.
const hal = @import("../platform/hal.zig");

pub const TimerCallback = *const fn (?*anyopaque) void;

const TimerEntry = struct {
    callback: TimerCallback,
    ctx: ?*anyopaque,
    expire_ms: u64,
    interval_ms: u32,
    repeating: bool,
    active: bool,
};

pub const TimerHandle = u8;
pub const INVALID_HANDLE: TimerHandle = 0xFF;

const MAX_TIMERS = 32;
var timers: [MAX_TIMERS]TimerEntry = [_]TimerEntry{.{
    .callback = undefined,
    .ctx = null,
    .expire_ms = 0,
    .interval_ms = 0,
    .repeating = false,
    .active = false,
}} ** MAX_TIMERS;

/// Schedule a one-shot timer.
pub fn setTimeout(cb: TimerCallback, ctx: ?*anyopaque, delay_ms: u32) TimerHandle {
    return allocTimer(cb, ctx, delay_ms, false);
}

/// Schedule a repeating timer.
pub fn setInterval(cb: TimerCallback, ctx: ?*anyopaque, interval_ms: u32) TimerHandle {
    return allocTimer(cb, ctx, interval_ms, true);
}

/// Cancel a timer.
pub fn clearTimer(handle: TimerHandle) void {
    if (handle < MAX_TIMERS) {
        timers[handle].active = false;
    }
}

/// Called from the event loop each iteration.
pub fn processPending() void {
    const now = hal.millis();
    for (&timers) |*t| {
        if (!t.active) continue;
        if (now >= t.expire_ms) {
            const cb = t.callback;
            const ctx = t.ctx;
            if (t.repeating) {
                t.expire_ms = now + t.interval_ms;
            } else {
                t.active = false;
            }
            cb(ctx);
        }
    }
}

pub fn hasPending() bool {
    for (&timers) |*t| {
        if (t.active) return true;
    }
    return false;
}

/// Returns ms until the next timer fires, or null if no timers.
pub fn nextDeadline() ?u64 {
    var earliest: ?u64 = null;
    for (&timers) |*t| {
        if (!t.active) continue;
        if (earliest == null or t.expire_ms < earliest.?) {
            earliest = t.expire_ms;
        }
    }
    return earliest;
}

fn allocTimer(cb: TimerCallback, ctx: ?*anyopaque, ms: u32, repeating: bool) TimerHandle {
    for (&timers, 0..) |*t, i| {
        if (!t.active) {
            t.* = .{
                .callback = cb,
                .ctx = ctx,
                .expire_ms = hal.millis() + ms,
                .interval_ms = ms,
                .repeating = repeating,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return INVALID_HANDLE;
}
