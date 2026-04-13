// MQTT 3.1.1 client — app-driven TCP via NetStack.
//
// Supports two transport modes:
//   1. Plaintext TCP (port 1883) — uses AppVTable.produce_tx for retransmit
//   2. TLS 1.2 (port 8883) — sends through TLS session eagerly; TLS layer
//      handles its own ciphertext retention for TCP retransmit
//
// In both modes, on_recv parses CONNACK/PUBLISH/SUBACK/PINGRESP and
// on_open triggers the MQTT CONNECT handshake.
//
// Single broker connection, QoS 0 only.
// Reference: MQTT v3.1.1 (OASIS Standard)

const c = @import("../js/quickjs_api.zig");
const console = @import("console.zig");
const netif = @import("../net/stack.zig");
const stack_mod = @import("../net/tcpip.zig");
const hal = @import("../platform/hal.zig");
const tls_mod = @import("../tls/tls.zig");
const ssl = @import("../tls/bearssl.zig");

pub const MqttState = enum { disconnected, connecting, connected, error_state };

var state: MqttState = .disconnected;
var conn_id: stack_mod.ConnId = 0;
var keepalive_s: u16 = 60;
var last_ping_ms: u64 = 0;
var tls_mode: bool = false;

const PACKET_CONNECT: u8 = 0x10;
const PACKET_CONNACK: u8 = 0x20;
const PACKET_PUBLISH: u8 = 0x30;
const PACKET_SUBSCRIBE: u8 = 0x82;
const PACKET_PINGREQ: u8 = 0xC0;
const PACKET_PINGRESP: u8 = 0xD0;
const PACKET_DISCONNECT: u8 = 0xE0;

const PendingKind = enum { none, connect_pkt, publish_pkt, subscribe_pkt, ping_pkt, disconnect_pkt };

var pending: PendingKind = .none;
var pending_token: u16 = 0;

var client_id_buf: [32]u8 = undefined;
var client_id_len: usize = 0;

var pub_topic_buf: [128]u8 = undefined;
var pub_topic_len: usize = 0;
var pub_payload_buf: [512]u8 = undefined;
var pub_payload_len: usize = 0;

var sub_topic_buf: [128]u8 = undefined;
var sub_topic_len: usize = 0;

// ── AppVTable callbacks ──────────────────────────────────────────────

fn onOpen(_: *anyopaque, _: stack_mod.ConnId) void {
    if (tls_mode) {
        console.puts("[mqtt] TLS connected, sending CONNECT\n");
        var buf: [256]u8 = undefined;
        const len = buildConnect(&buf);
        if (len > 0) {
            _ = tls_mod.getSession().send(buf[0..len]);
        }
    } else {
        console.puts("[mqtt] TCP connected, sending CONNECT\n");
        pending = .connect_pkt;
        pending_token = 1;
        netif.stack().tcpMarkSendReady(conn_id);
    }
}

fn onRecv(_: *anyopaque, _: stack_mod.ConnId, data: []const u8) void {
    if (data.len < 2) return;
    const pkt_type = data[0] & 0xF0;

    switch (pkt_type) {
        PACKET_CONNACK => {
            if (data.len >= 4 and data[3] == 0) {
                state = .connected;
                last_ping_ms = hal.millis();
                console.puts("[mqtt] CONNACK OK\n");
                _ = subscribe("pico/cmd");
            } else {
                state = .error_state;
                console.puts("[mqtt] CONNACK rejected\n");
            }
        },
        PACKET_PUBLISH => {
            parseAndLogPublish(data);
        },
        PACKET_PINGRESP => {},
        else => {},
    }
}

fn parseAndLogPublish(data: []const u8) void {
    if (data.len < 4) return;
    const remaining_start: usize = if ((data[1] & 0x80) != 0) 3 else 2;
    if (data.len < remaining_start + 2) return;

    const topic_len = (@as(u16, data[remaining_start]) << 8) | data[remaining_start + 1];
    const topic_start = remaining_start + 2;
    if (data.len < topic_start + topic_len) return;

    const topic = data[topic_start..][0..topic_len];
    const payload_start = topic_start + topic_len;
    const payload = if (payload_start < data.len) data[payload_start..] else &[_]u8{};

    console.puts("[mqtt] ");
    console.puts(topic);
    console.puts(" → ");
    if (payload.len > 0) console.puts(payload);
    console.puts("\n");
}

fn onSent(_: *anyopaque, _: stack_mod.ConnId, _: u16) void {
    pending = .none;
}

fn onClosed(_: *anyopaque, _: stack_mod.ConnId, _: stack_mod.CloseReason) void {
    state = .disconnected;
    console.puts("[mqtt] connection closed\n");
}

fn produceTx(_: *anyopaque, _: stack_mod.ConnId, req: stack_mod.TxRequest, dst: []u8) stack_mod.TxResponse {
    _ = req;
    var len: usize = 0;

    switch (pending) {
        .connect_pkt => len = buildConnect(dst[0..@min(dst.len, 256)]),
        .publish_pkt => len = buildPublish(dst),
        .subscribe_pkt => len = buildSubscribe(dst[0..@min(dst.len, 256)]),
        .ping_pkt => {
            if (dst.len >= 2) {
                dst[0] = PACKET_PINGREQ;
                dst[1] = 0;
                len = 2;
            }
        },
        .disconnect_pkt => {
            if (dst.len >= 2) {
                dst[0] = PACKET_DISCONNECT;
                dst[1] = 0;
                len = 2;
            }
        },
        .none => {},
    }

    return .{ .len = @intCast(len), .token = pending_token };
}

const vtable = stack_mod.AppVTable{
    .ctx = @constCast(@ptrCast(&state)),
    .on_open = &onOpen,
    .on_recv = &onRecv,
    .on_sent = &onSent,
    .on_closed = &onClosed,
    .produce_tx = &produceTx,
};

// ── Public API ───────────────────────────────────────────────────────

pub fn init() void {
    state = .disconnected;
    pending = .none;
}

pub fn connectBroker(ip: [4]u8, port: u16, client_id: []const u8) bool {
    const id_len = @min(client_id.len, client_id_buf.len);
    @memcpy(client_id_buf[0..id_len], client_id[0..id_len]);
    client_id_len = id_len;
    state = .connecting;
    tls_mode = false;

    const id = netif.stack().tcpConnect(ip, port, vtable) orelse {
        console.puts("[mqtt] TCP connect failed\n");
        state = .error_state;
        return false;
    };
    conn_id = id;
    console.puts("[mqtt] connecting...\n");
    return true;
}

pub fn connectBrokerTls(
    ip: [4]u8,
    port: u16,
    client_id: []const u8,
    server_name: [*:0]const u8,
    broker_rsa_key: *const ssl.RsaPublicKey,
) bool {
    const id_len = @min(client_id.len, client_id_buf.len);
    @memcpy(client_id_buf[0..id_len], client_id[0..id_len]);
    client_id_len = id_len;
    state = .connecting;
    tls_mode = true;

    const session = tls_mod.getSession();
    session.init(broker_rsa_key);

    if (!session.connect(ip, port, server_name, vtable)) {
        console.puts("[mqtt] TLS connect failed\n");
        state = .error_state;
        return false;
    }
    console.puts("[mqtt] TLS connecting...\n");
    return true;
}

pub fn publish(topic: []const u8, payload: []const u8) bool {
    if (state != .connected) return false;

    const tl = @min(topic.len, pub_topic_buf.len);
    const pl = @min(payload.len, pub_payload_buf.len);
    @memcpy(pub_topic_buf[0..tl], topic[0..tl]);
    pub_topic_len = tl;
    @memcpy(pub_payload_buf[0..pl], payload[0..pl]);
    pub_payload_len = pl;

    if (tls_mode) {
        var buf: [700]u8 = undefined;
        const len = buildPublish(&buf);
        if (len > 0) {
            _ = tls_mod.getSession().send(buf[0..len]);
            return true;
        }
        return false;
    } else {
        if (pending != .none) return false;
        pending = .publish_pkt;
        pending_token += 1;
        netif.stack().tcpMarkSendReady(conn_id);
        return true;
    }
}

pub fn subscribe(topic: []const u8) bool {
    if (state != .connected) return false;

    const tl = @min(topic.len, sub_topic_buf.len);
    @memcpy(sub_topic_buf[0..tl], topic[0..tl]);
    sub_topic_len = tl;

    if (tls_mode) {
        var buf: [256]u8 = undefined;
        const len = buildSubscribe(&buf);
        if (len > 0) {
            _ = tls_mod.getSession().send(buf[0..len]);
            return true;
        }
        return false;
    } else {
        if (pending != .none) return false;
        pending = .subscribe_pkt;
        pending_token += 1;
        netif.stack().tcpMarkSendReady(conn_id);
        return true;
    }
}

pub fn disconnect() void {
    if (state == .connected) {
        if (tls_mode) {
            const disc = [2]u8{ PACKET_DISCONNECT, 0 };
            _ = tls_mod.getSession().send(&disc);
            tls_mod.getSession().close();
        } else {
            pending = .disconnect_pkt;
            pending_token += 1;
            netif.stack().tcpMarkSendReady(conn_id);
        }
    }
    state = .disconnected;
}

pub fn poll() void {
    if (state != .connected) return;

    if (tls_mode) {
        tls_mod.getSession().pump();
    }

    const now = hal.millis();
    if (now - last_ping_ms >= @as(u64, keepalive_s) * 1000) {
        if (tls_mode) {
            const ping = [2]u8{ PACKET_PINGREQ, 0 };
            _ = tls_mod.getSession().send(&ping);
            last_ping_ms = now;
        } else if (pending == .none) {
            pending = .ping_pkt;
            pending_token += 1;
            netif.stack().tcpMarkSendReady(conn_id);
            last_ping_ms = now;
        }
    }
}

pub fn isConnected() bool {
    return state == .connected;
}

// ── Packet builders ──────────────────────────────────────────────────

fn buildConnect(buf: []u8) usize {
    if (buf.len < 14 + client_id_len) return 0;
    var pos: usize = 0;

    const var_hdr_len = 10 + 2 + client_id_len;
    buf[pos] = PACKET_CONNECT;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_hdr_len);

    buf[pos] = 0;
    buf[pos + 1] = 4;
    buf[pos + 2] = 'M';
    buf[pos + 3] = 'Q';
    buf[pos + 4] = 'T';
    buf[pos + 5] = 'T';
    pos += 6;

    buf[pos] = 4;
    pos += 1;
    buf[pos] = 0x02;
    pos += 1;
    buf[pos] = @intCast(keepalive_s >> 8);
    buf[pos + 1] = @intCast(keepalive_s & 0xFF);
    pos += 2;

    buf[pos] = @intCast(client_id_len >> 8);
    buf[pos + 1] = @intCast(client_id_len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..client_id_len], client_id_buf[0..client_id_len]);
    pos += client_id_len;

    return pos;
}

fn buildPublish(buf: []u8) usize {
    const var_len = 2 + pub_topic_len + pub_payload_len;
    if (var_len + 5 > buf.len) return 0;

    var pos: usize = 0;
    buf[pos] = PACKET_PUBLISH;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_len);

    buf[pos] = @intCast(pub_topic_len >> 8);
    buf[pos + 1] = @intCast(pub_topic_len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..pub_topic_len], pub_topic_buf[0..pub_topic_len]);
    pos += pub_topic_len;

    @memcpy(buf[pos..][0..pub_payload_len], pub_payload_buf[0..pub_payload_len]);
    pos += pub_payload_len;

    return pos;
}

fn buildSubscribe(buf: []u8) usize {
    const var_len = 2 + 2 + sub_topic_len + 1;
    if (var_len + 3 > buf.len) return 0;
    var pos: usize = 0;

    buf[pos] = PACKET_SUBSCRIBE;
    pos += 1;
    pos += encodeRemainingLength(buf[pos..], var_len);

    buf[pos] = 0;
    buf[pos + 1] = 1;
    pos += 2;

    buf[pos] = @intCast(sub_topic_len >> 8);
    buf[pos + 1] = @intCast(sub_topic_len & 0xFF);
    pos += 2;
    @memcpy(buf[pos..][0..sub_topic_len], sub_topic_buf[0..sub_topic_len]);
    pos += sub_topic_len;

    buf[pos] = 0;
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

pub export fn js_mqtt_connect(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
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
    return c.JS_NewBool(@intFromBool(publish(topic[0..tl], msg[0..ml])));
}

pub export fn js_mqtt_subscribe(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var tb: c.JSCStringBuf = undefined;
    var tl: usize = 0;
    const topic = c.JS_ToCStringLen(cx, &tl, args[0], &tb) orelse return c.JS_UNDEFINED;
    return c.JS_NewBool(@intFromBool(subscribe(topic[0..tl])));
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
