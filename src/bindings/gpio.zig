// GPIO service — exposes gpio.mode / gpio.write / gpio.read / gpio.toggle to JS.
//
// For RP2040 pins 0-29 only. The Pico W onboard LED is on the CYW43
// chip and is handled by bindings/led.zig, not this module.

const hal = @import("../platform/hal.zig");
const c = @import("../js/quickjs_api.zig");

fn pinFromArg(ctx: *c.JSContext, val: c.JSValue) ?u5 {
    var pin: i32 = 0;
    if (c.JS_ToInt32(ctx, &pin, val) != 0) return null;
    if (pin < 0 or pin > 29) return null;
    return @intCast(pin);
}

pub export fn js_gpio_mode(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    const pin = pinFromArg(cx, args[0]) orelse return c.JS_UNDEFINED;
    var mode: i32 = 0;
    if (c.JS_ToInt32(cx, &mode, args[1]) != 0) return c.JS_UNDEFINED;
    hal.platform.gpioInit(pin, mode != 0);
    return c.JS_UNDEFINED;
}

pub export fn js_gpio_write(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    const pin = pinFromArg(cx, args[0]) orelse return c.JS_UNDEFINED;
    var val: i32 = 0;
    if (c.JS_ToInt32(cx, &val, args[1]) != 0) return c.JS_UNDEFINED;
    hal.platform.gpioSet(pin, val != 0);
    return c.JS_UNDEFINED;
}

pub export fn js_gpio_read(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    const pin = pinFromArg(cx, args[0]) orelse return c.JS_UNDEFINED;
    const val = hal.platform.gpioRead(pin);
    return c.JS_NewBool(@intFromBool(val));
}

pub export fn js_gpio_toggle(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    const pin = pinFromArg(cx, args[0]) orelse return c.JS_UNDEFINED;
    hal.platform.gpioToggle(pin);
    return c.JS_UNDEFINED;
}
