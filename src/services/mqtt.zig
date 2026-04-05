// MQTT client service (stub).
const c = @import("../vm/c.zig");
const console = @import("console.zig");

pub const MqttState = enum { disconnected, connecting, connected, error_state };
var state: MqttState = .disconnected;

pub fn init() void { state = .disconnected; }
pub fn poll() void {}
pub fn isConnected() bool { return state == .connected; }

pub export fn js_mqtt_connect(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_UNDEFINED;
    console.puts("[mqtt] connect: ");
    console.puts(ptr[0..len]);
    console.puts("\n");
    state = .connecting;
    return c.JS_NewBool(1);
}

pub export fn js_mqtt_publish(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var tb: c.JSCStringBuf = undefined;
    var mb: c.JSCStringBuf = undefined;
    var tlen: usize = 0;
    var mlen: usize = 0;
    const topic = c.JS_ToCStringLen(cx, &tlen, args[0], &tb) orelse return c.JS_UNDEFINED;
    const msg = c.JS_ToCStringLen(cx, &mlen, args[1], &mb) orelse return c.JS_UNDEFINED;
    console.puts("[mqtt] pub ");
    console.puts(topic[0..tlen]);
    console.puts(": ");
    console.puts(msg[0..mlen]);
    console.puts("\n");
    return c.JS_UNDEFINED;
}

pub export fn js_mqtt_subscribe(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const topic = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_UNDEFINED;
    console.puts("[mqtt] sub ");
    console.puts(topic[0..len]);
    console.puts("\n");
    return c.JS_UNDEFINED;
}

pub export fn js_mqtt_disconnect(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    state = .disconnected;
    console.puts("[mqtt] disconnected\n");
    return c.JS_UNDEFINED;
}
