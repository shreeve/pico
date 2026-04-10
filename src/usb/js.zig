// JS bindings for USB Host.
//
// Exposes the USB host driver to MQuickJS scripts:
//
//   usb.status()    → string
//   usb.init()      → void
//
// More bindings will be added as enumeration and transfer support matures.

const std = @import("std");
const c = @import("../js/quickjs_api.zig");
const host = @import("host.zig");
const desc = @import("descriptors.zig");
const engine = @import("../js/runtime.zig");
const console = @import("../bindings/console.zig");

// ── Init ───────────────────────────────────────────────────────────────

pub fn initCallbacks() void {
    // Callbacks will be wired up as enumeration and transfer support matures
}

// ── JS exports ─────────────────────────────────────────────────────────

// usb.status() → string
pub export fn js_usb_status(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const label: []const u8 = if (host.isReady()) "ready" else "not_initialized";
    return c.JS_NewStringLen(cx, label.ptr, label.len);
}

// usb.init() — initialize USB host
pub export fn js_usb_init(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    host.init();
    initCallbacks();
    return c.JS_UNDEFINED;
}

// Stubs for C function table (will be implemented as USB host matures)
pub export fn js_usb_control_in(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_UNDEFINED;
}
pub export fn js_usb_control_out(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_UNDEFINED;
}
pub export fn js_usb_next_address(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_UNDEFINED;
}
pub export fn js_usb_alloc_ep0(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_UNDEFINED;
}
pub export fn js_usb_on(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    return c.JS_UNDEFINED;
}
