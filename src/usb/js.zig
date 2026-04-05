// JS bindings for USB Host.
//
// Exposes the USB host driver to MQuickJS scripts:
//
//   usb.controlIn(addr, reqType, req, value, index, len)  → Uint8Array
//   usb.controlOut(addr, reqType, req, value, index)       → bool
//   usb.controlOutData(addr, reqType, req, value, index, data) → bool
//   usb.bulkIn(addr, epAddr, len, callback)                → handle
//   usb.bulkOut(addr, epAddr, data)                        → bool
//   usb.nextAddress()                                      → int
//   usb.status()                                           → string
//   usb.on("connect", callback)                            → void
//   usb.on("disconnect", callback)                         → void
//   usb.on("data", callback)                               → void
//
// The control transfer functions are synchronous from JS's perspective:
// they block the event loop until the transfer completes.  This is fine
// for enumeration which is inherently sequential.

const std = @import("std");
const c = @import("../vm/c.zig");
const host = @import("host.zig");
const desc = @import("descriptors.zig");
const engine = @import("../vm/engine.zig");
const console = @import("../services/console.zig");

// ── Stored JS callbacks ────────────────────────────────────────────────

var js_on_connect: c.JSValue = c.JS_UNDEFINED;
var js_on_disconnect: c.JSValue = c.JS_UNDEFINED;
var js_on_data: c.JSValue = c.JS_UNDEFINED;

// ── Synchronous transfer helpers ───────────────────────────────────────
// These spin the event loop until the transfer completes.
// Safe because MQuickJS is single-threaded and non-preemptive.

var transfer_pending: bool = false;
var transfer_result_len: u16 = 0;

fn onTransferDone(_: *host.Endpoint, len: u16) void {
    transfer_result_len = len;
    transfer_pending = false;
}

fn waitForTransfer() u16 {
    transfer_pending = true;
    while (transfer_pending) {
        host.poll();
    }
    return transfer_result_len;
}

// ── Native connect/disconnect hooks ────────────────────────────────────

fn nativeOnConnect(speed: host.Speed) void {
    if (js_on_connect == c.JS_UNDEFINED) return;
    const cx = engine.context() orelse return;
    const speed_val = c.JS_NewInt32(cx, @intFromEnum(speed));
    if (c.JS_StackCheck(cx, 3) != 0) return;
    c.JS_PushArg(cx, speed_val);
    c.JS_PushArg(cx, js_on_connect);
    c.JS_PushArg(cx, c.JS_NULL);
    const result = c.JS_Call(cx, 1);
    if (c.JS_IsException(result)) engine.dumpException();
}

fn nativeOnDisconnect() void {
    if (js_on_disconnect == c.JS_UNDEFINED) return;
    const cx = engine.context() orelse return;
    if (c.JS_StackCheck(cx, 3) != 0) return;
    c.JS_PushArg(cx, js_on_disconnect);
    c.JS_PushArg(cx, c.JS_NULL);
    const result = c.JS_Call(cx, 0);
    if (c.JS_IsException(result)) engine.dumpException();
}

// ── Init ───────────────────────────────────────────────────────────────

pub fn initCallbacks() void {
    host.setConnectCallback(nativeOnConnect);
    host.setDisconnectCallback(nativeOnDisconnect);
    host.setTransferDoneCallback(onTransferDone);
}

// ── JS exports ─────────────────────────────────────────────────────────

// usb.controlIn(addr, reqType, req, value, index, len) → data bytes in ctrl_buf
pub export fn js_usb_control_in(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 6) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;

    var addr: i32 = 0;
    var req_type: i32 = 0;
    var req: i32 = 0;
    var value: i32 = 0;
    var index: i32 = 0;
    var len: i32 = 0;
    if (c.JS_ToInt32(cx, &addr, args[0]) != 0) return c.JS_UNDEFINED;
    if (c.JS_ToInt32(cx, &req_type, args[1]) != 0) return c.JS_UNDEFINED;
    if (c.JS_ToInt32(cx, &req, args[2]) != 0) return c.JS_UNDEFINED;
    if (c.JS_ToInt32(cx, &value, args[3]) != 0) return c.JS_UNDEFINED;
    if (c.JS_ToInt32(cx, &index, args[4]) != 0) return c.JS_UNDEFINED;
    if (c.JS_ToInt32(cx, &len, args[5]) != 0) return c.JS_UNDEFINED;

    // Find or use EP0
    const ep = host.findEndpoint(@intCast(addr), 0) orelse host.getEpx();
    ep.user_buf = host.getCtrlBuf().ptr;

    host.controlTransfer(ep, &.{
        .bmRequestType = @intCast(req_type),
        .bRequest = @intCast(req),
        .wValue = @intCast(value),
        .wIndex = @intCast(index),
        .wLength = @intCast(len),
    });

    const actual_len = waitForTransfer();

    // ZLP status stage
    host.transferZlp(ep);
    _ = waitForTransfer();

    // Return data as a JS string (TODO: return Uint8Array when available)
    const buf = host.getCtrlBuf();
    return c.JS_NewStringLen(cx, buf.ptr, actual_len);
}

// usb.controlOut(addr, reqType, req, value, index) → bool
pub export fn js_usb_control_out(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 5) return c.JS_FALSE;
    const cx = ctx orelse return c.JS_FALSE;
    const args = argv orelse return c.JS_FALSE;

    var addr: i32 = 0;
    var req_type: i32 = 0;
    var req: i32 = 0;
    var value: i32 = 0;
    var index: i32 = 0;
    if (c.JS_ToInt32(cx, &addr, args[0]) != 0) return c.JS_FALSE;
    if (c.JS_ToInt32(cx, &req_type, args[1]) != 0) return c.JS_FALSE;
    if (c.JS_ToInt32(cx, &req, args[2]) != 0) return c.JS_FALSE;
    if (c.JS_ToInt32(cx, &value, args[3]) != 0) return c.JS_FALSE;
    if (c.JS_ToInt32(cx, &index, args[4]) != 0) return c.JS_FALSE;

    const ep = host.findEndpoint(@intCast(addr), 0) orelse host.getEpx();
    ep.user_buf = host.getCtrlBuf().ptr;

    host.controlTransfer(ep, &.{
        .bmRequestType = @intCast(req_type),
        .bRequest = @intCast(req),
        .wValue = @intCast(value),
        .wIndex = @intCast(index),
        .wLength = 0,
    });

    _ = waitForTransfer();

    // ZLP status stage
    host.transferZlp(ep);
    _ = waitForTransfer();

    return c.JS_TRUE;
}

// usb.nextAddress() → int
pub export fn js_usb_next_address(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const addr = host.nextDevAddr() orelse return c.JS_UNDEFINED;
    return c.JS_NewInt32(cx, addr);
}

// usb.allocEp0(addr, maxsize) → bool
pub export fn js_usb_alloc_ep0(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_FALSE;
    const cx = ctx orelse return c.JS_FALSE;
    const args = argv orelse return c.JS_FALSE;

    var addr: i32 = 0;
    var maxsize: i32 = 0;
    if (c.JS_ToInt32(cx, &addr, args[0]) != 0) return c.JS_FALSE;
    if (c.JS_ToInt32(cx, &maxsize, args[1]) != 0) return c.JS_FALSE;

    const ep = host.allocEp0(@intCast(addr), @intCast(maxsize));
    return c.JS_NewBool(if (ep != null) 1 else 0);
}

// usb.status() → string
pub export fn js_usb_status(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const label: []const u8 = if (host.isReady()) "ready" else "not_initialized";
    return c.JS_NewStringLen(cx, label.ptr, label.len);
}

// usb.on(event, callback) — register event handlers
pub export fn js_usb_on(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;

    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const name_ptr = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_UNDEFINED;
    const name = name_ptr[0..len];

    if (std.mem.eql(u8, name, "connect")) {
        js_on_connect = args[1];
    } else if (std.mem.eql(u8, name, "disconnect")) {
        js_on_disconnect = args[1];
    } else if (std.mem.eql(u8, name, "data")) {
        js_on_data = args[1];
    }

    return c.JS_UNDEFINED;
}

// usb.init() — initialize USB host
pub export fn js_usb_init(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    host.init();
    initCallbacks();
    return c.JS_UNDEFINED;
}
