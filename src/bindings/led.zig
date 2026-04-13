// Onboard LED service (Pico W — CYW43 GPIO, not RP2040 GPIO).
//
// JS API:
//   led.on()         Turn on (cancels blink)
//   led.off()        Turn off (cancels blink)
//   led.toggle()     Toggle (cancels blink)
//   led.blink(ms)    Blink at interval (managed Zig timer)
//   led.isOn()       Returns current state
//
// Any explicit on/off/toggle cancels an active blink.
// All LED writes go through apply() — single place for hardware access.
//
// Also used by: telnet shell (led on/off/toggle/blink), MQTT (pico/led).

const hal = @import("../platform/hal.zig");
const c = @import("../js/quickjs_api.zig");
const cyw43 = @import("../cyw43/cyw43.zig");

const MIN_BLINK_MS: u32 = 50;

var led_state: bool = false;
var blink_interval_ms: u32 = 0;
var blink_next_ms: u64 = 0;

fn apply(state: bool) void {
    cyw43.ledSet(state) catch return;
    led_state = state;
}

pub fn on() void {
    blink_interval_ms = 0;
    apply(true);
}

pub fn off() void {
    blink_interval_ms = 0;
    apply(false);
}

pub fn set(state: bool) void {
    blink_interval_ms = 0;
    apply(state);
}

pub fn toggle() void {
    blink_interval_ms = 0;
    apply(!led_state);
}

pub fn isOn() bool {
    return led_state;
}

pub fn blink(interval_ms: u32) void {
    blink_interval_ms = if (interval_ms < MIN_BLINK_MS) MIN_BLINK_MS else interval_ms;
    apply(!led_state);
    blink_next_ms = hal.millis() + blink_interval_ms;
}

/// Called from the superloop.
pub fn poll() void {
    if (blink_interval_ms == 0) return;
    const now = hal.millis();
    if (now >= blink_next_ms) {
        apply(!led_state);
        blink_next_ms += blink_interval_ms;
        if (now >= blink_next_ms) blink_next_ms = now + blink_interval_ms;
    }
}

// ── JS exports ───────────────────────────────────────────────────────

pub export fn js_led_on(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    on();
    return c.JS_TRUE;
}

pub export fn js_led_off(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    off();
    return c.JS_TRUE;
}

pub export fn js_led_toggle(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    toggle();
    return c.JS_NewBool(@intFromBool(led_state));
}

pub export fn js_led_blink(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    var ms: i32 = 500;
    if (argc >= 1) {
        const cx = ctx orelse return c.JS_UNDEFINED;
        const args = argv orelse return c.JS_UNDEFINED;
        _ = c.JS_ToInt32(cx, &ms, args[0]);
    }
    blink(if (ms > 0) @intCast(ms) else 500);
    return c.JS_TRUE;
}

pub export fn js_led_isOn(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_NewBool(@intFromBool(led_state));
}
