// MQTT 3.1.1 client — minimal implementation over TCP.
//
// Supports: CONNECT, PUBLISH, SUBSCRIBE, PINGREQ, DISCONNECT.
// Single broker connection, QoS 0 only.
//
// Reference: MQTT v3.1.1 (OASIS Standard)

const c = @import("../vm/c.zig");
const console = @import("console.zig");
const tcp = @import("../net/tcp.zig");
const hal = @import("../platform/hal.zig");

pub const MqttState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

var state: MqttState = .disconnected;
var keepalive_s: u16 = 60;
var last_ping_ms: u64 = 0;
var broker_ip: [4]u8 = [_]u8{0} ** 4;
var broker_port: u16 = 1883;

const PACKET_CONNECT: u8 = 0x10;
const PACKET_CONNACK: u8 = 0x20;
const PACKET_PUBLISH: u8 = 0x30;
const PACKET_SUBSCRIBE: u8 = 0x82;
const PACKET_SUBACK: u8 = 0x90;
const PACKET_PINGREQ: u8 = 0xC0;
const PACKET_PINGRESP: u8 = 0xD0;
const PACKET_DISCONNECT: u8 = 0xE0;

pub fn init() void {
    state = .disconnected;
}

pub fn connectBroker(ip: [4]u8, port: u16, client_id: []const u8) bool {
    broker_ip = ip;
    broker_port = port;
    state = .connecting;

    tcp.connect(ip, port) catch {
        console.puts("[mqtt] TCP connect failed\n");
        state = .error_state;
        return false;
    };

    var buf: [256]u8 = undefined;
    const len = buildConnect(&buf, client_id);
    tcp.send(buf[0..len]) catch {
        console.puts("[mqtt] send CONNECT failed\n");
        state = .error_state;
        return false;
    };

    state = .connected;
    last_ping_ms = hal.millis();
    console.puts("[mqtt] CONNECT sent\n");
    return true;
}

pub fn publish(topic: []const u8, payload: []const u8) bool {
    if (state != .connected) return false;

    var buf: [1024]u8 = undefined;
    const len = buildPublish(&buf, topic, payload);
    if (len == 0) return false;

    tcp.send(buf[0..len]) catch return false;
    return true;
}

pub fn subscribe(topic: []const u8) bool {
    if (state != .connected) return false;

    var buf: [256]u8 = undefined;
    const len = buildSubscribe(&buf, topic);
    tcp.send(buf[0..len]) catch return false;
    return true;
}

pub fn disconnect() void {
    if (state == .connected) {
        var buf: [2]u8 = undefined;
        buf[0] = PACKET_DISCONNECT;
        buf[1] = 0;
        tcp.send(&buf) catch {};
    }
    tcp.close();
    state = .disconnected;
}

pub fn poll() void {
    if (state != .connected) return;

    const now = hal.millis();
    if (now - last_ping_ms >= @as(u64, keepalive_s) * 1000) {
        var ping: [2]u8 = .{ PACKET_PINGREQ, 0 };
        tcp.send(&ping) catch {
            state = .error_state;
            return;
        };
        last_ping_ms = now;
    }
}

pub fn isConnected() bool {
    return state == .connected;
}

// ── Packet builders ──────────────────────────────────────────────────

fn buildConnect(buf: *[256]u8, client_id: []const u8) usize {
    var pos: usize = 0;

    const var_hdr_len = 10 + 2 + client_id.len;
    buf[pos] = PACKET_CONNECT;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_hdr_len);

    // Protocol Name "MQTT"
    buf[pos] = 0;
    buf[pos + 1] = 4;
    buf[pos + 2] = 'M';
    buf[pos + 3] = 'Q';
    buf[pos + 4] = 'T';
    buf[pos + 5] = 'T';
    pos += 6;

    buf[pos] = 4; // Protocol Level (3.1.1)
    pos += 1;
    buf[pos] = 0x02; // Connect Flags: Clean Session
    pos += 1;
    buf[pos] = @intCast(keepalive_s >> 8);
    buf[pos + 1] = @intCast(keepalive_s & 0xFF);
    pos += 2;

    // Client ID
    buf[pos] = @intCast(client_id.len >> 8);
    buf[pos + 1] = @intCast(client_id.len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..client_id.len], client_id);
    pos += client_id.len;

    return pos;
}

fn buildPublish(buf: *[1024]u8, topic: []const u8, payload: []const u8) usize {
    const var_len = 2 + topic.len + payload.len;
    if (var_len + 5 > buf.len) return 0;

    var pos: usize = 0;
    buf[pos] = PACKET_PUBLISH;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_len);

    buf[pos] = @intCast(topic.len >> 8);
    buf[pos + 1] = @intCast(topic.len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..topic.len], topic);
    pos += topic.len;

    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;

    return pos;
}

fn buildSubscribe(buf: *[256]u8, topic: []const u8) usize {
    const var_len = 2 + 2 + topic.len + 1;
    var pos: usize = 0;

    buf[pos] = PACKET_SUBSCRIBE;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_len);

    // Packet Identifier
    buf[pos] = 0;
    buf[pos + 1] = 1;
    pos += 2;

    // Topic Filter
    buf[pos] = @intCast(topic.len >> 8);
    buf[pos + 1] = @intCast(topic.len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..topic.len], topic);
    pos += topic.len;

    buf[pos] = 0; // QoS 0
    pos += 1;

    return pos;
}

fn encodeRemainingLength(buf: []u8, length: usize) usize {
    var len = length;
    var pos: usize = 0;
    while (true) {
        var byte: u8 = @intCast(len & 0x7F);
        len >>= 7;
        if (len > 0) byte |= 0x80;
        buf[pos] = byte;
        pos += 1;
        if (len == 0) break;
    }
    return pos;
}

// ── JS exports ───────────────────────────────────────────────────────

pub export fn js_mqtt_connect(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    _ = ctx;
    if (argc < 1) return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    _ = args;
    console.puts("[mqtt] JS connect (use mqtt.connectBroker from native)\n");
    return c.JS_UNDEFINED;
}

pub export fn js_mqtt_publish(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var tb: c.JSCStringBuf = undefined;
    var mb: c.JSCStringBuf = undefined;
    var tl: usize = 0;
    var ml: usize = 0;
    const topic = c.JS_ToCStringLen(cx, &tl, args[0], &tb) orelse return c.JS_UNDEFINED;
    const msg = c.JS_ToCStringLen(cx, &ml, args[1], &mb) orelse return c.JS_UNDEFINED;
    const ok = publish(topic[0..tl], msg[0..ml]);
    return c.JS_NewBool(@intFromBool(ok));
}

pub export fn js_mqtt_subscribe(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var tb: c.JSCStringBuf = undefined;
    var tl: usize = 0;
    const topic = c.JS_ToCStringLen(cx, &tl, args[0], &tb) orelse return c.JS_UNDEFINED;
    const ok = subscribe(topic[0..tl]);
    return c.JS_NewBool(@intFromBool(ok));
}

pub export fn js_mqtt_disconnect(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    disconnect();
    return c.JS_UNDEFINED;
}

pub export fn js_mqtt_status(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const label: []const u8 = switch (state) {
        .disconnected => "disconnected",
        .connecting => "connecting",
        .connected => "connected",
        .error_state => "error",
    };
    return c.JS_NewStringLen(cx, label.ptr, label.len);
}
