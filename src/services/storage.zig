// Flash-backed key-value storage (stub).
const c = @import("../vm/c.zig");
const console = @import("console.zig");

pub fn init() void { console.puts("[storage] init\n"); }

pub fn get(_: []const u8) ?[]const u8 { return null; }
pub fn set(_: []const u8, _: []const u8) bool { return false; }
pub fn del(_: []const u8) bool { return false; }

pub export fn js_storage_get(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_NULL;
    const cx = ctx orelse return c.JS_NULL;
    const args = argv orelse return c.JS_NULL;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const key = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_NULL;
    if (get(key[0..len])) |val| return c.JS_NewStringLen(cx, val.ptr, val.len);
    return c.JS_NULL;
}

pub export fn js_storage_set(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var kb: c.JSCStringBuf = undefined;
    var vb: c.JSCStringBuf = undefined;
    var kl: usize = 0;
    var vl: usize = 0;
    const key = c.JS_ToCStringLen(cx, &kl, args[0], &kb) orelse return c.JS_UNDEFINED;
    const val = c.JS_ToCStringLen(cx, &vl, args[1], &vb) orelse return c.JS_UNDEFINED;
    const ok = set(key[0..kl], val[0..vl]);
    return c.JS_NewBool(@intFromBool(ok));
}

pub export fn js_storage_del(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const key = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_UNDEFINED;
    const ok = del(key[0..len]);
    return c.JS_NewBool(@intFromBool(ok));
}
