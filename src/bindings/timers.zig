// setTimeout / setInterval / clearTimeout / clearInterval / gc / Date.now
const c = @import("../js/quickjs_api.zig");
const timer = @import("../runtime/timer.zig");
const engine = @import("../js/runtime.zig");

const TimerSlot = struct {
    handle: timer.TimerHandle,
    js_func: c.JSValue,
    active: bool,
};

const MAX_JS_TIMERS = 16;
var slots: [MAX_JS_TIMERS]TimerSlot = [_]TimerSlot{.{
    .handle = timer.INVALID_HANDLE,
    .js_func = 0,
    .active = false,
}} ** MAX_JS_TIMERS;

fn allocSlot() ?usize {
    for (&slots, 0..) |*s, i| {
        if (!s.active) return i;
    }
    return null;
}

fn timerFired(ctx_ptr: ?*anyopaque) void {
    const idx: usize = @intFromPtr(ctx_ptr);
    if (idx >= MAX_JS_TIMERS) return;
    const slot = &slots[idx];
    if (!slot.active) return;

    const cx = engine.context() orelse return;
    if (c.JS_StackCheck(cx, 3) != 0) return;
    c.JS_PushArg(cx, slot.js_func);
    c.JS_PushArg(cx, c.JS_NULL);
    const result = c.JS_Call(cx, 0);
    if (c.JS_IsException(result)) {
        engine.dumpException();
    }
}

fn createTimer(ctx: ?*c.JSContext, argc: c_int, argv: ?[*]c.JSValue, repeating: bool) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;

    var delay_ms: i32 = 0;
    if (c.JS_ToInt32(cx, &delay_ms, args[1]) != 0) return c.JS_UNDEFINED;
    if (delay_ms < 0) delay_ms = 0;

    const slot_idx = allocSlot() orelse return c.JS_UNDEFINED;
    const ms: u32 = @intCast(delay_ms);

    const handle = if (repeating)
        timer.setInterval(timerFired, @ptrFromInt(slot_idx), ms)
    else
        timer.setTimeout(timerFired, @ptrFromInt(slot_idx), ms);

    if (handle == timer.INVALID_HANDLE) return c.JS_UNDEFINED;

    slots[slot_idx] = .{
        .handle = handle,
        .js_func = args[0],
        .active = true,
    };

    return c.JS_NewInt32(cx, @intCast(slot_idx));
}

fn cancelTimer(ctx: ?*c.JSContext, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var id: i32 = 0;
    if (c.JS_ToInt32(cx, &id, args[0]) != 0) return c.JS_UNDEFINED;
    if (id < 0 or id >= MAX_JS_TIMERS) return c.JS_UNDEFINED;

    const idx: usize = @intCast(id);
    if (slots[idx].active) {
        timer.clearTimer(slots[idx].handle);
        slots[idx].active = false;
    }
    return c.JS_UNDEFINED;
}

pub export fn js_setTimeout(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    return createTimer(ctx, argc, argv, false);
}

pub export fn js_clearTimeout(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    return cancelTimer(ctx, argc, argv);
}

pub export fn js_setInterval(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    return createTimer(ctx, argc, argv, true);
}

pub export fn js_clearInterval(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    return cancelTimer(ctx, argc, argv);
}

pub export fn js_timer_millis(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const ms = @import("../platform/hal.zig").millis();
    return c.JS_NewInt64(cx, @intCast(ms));
}

pub export fn js_gc(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    engine.gc();
    return c.JS_UNDEFINED;
}

pub export fn js_date_now(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const ms = @import("../platform/hal.zig").millis();
    return c.JS_NewInt64(cx, @intCast(ms));
}

// js_date_constructor is provided by mquickjs.c internally
