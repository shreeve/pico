// Wi-Fi service for Pico W / Pico 2 W (CYW43 driver).
const c = @import("../vm/c.zig");
const console = @import("console.zig");
const cyw43 = @import("../cyw43/mod.zig");

pub const WifiState = enum { disconnected, connecting, connected, ap_mode, failed };

var state: WifiState = .disconnected;
var ssid_buf: [33]u8 = undefined;
var ssid_len: usize = 0;
var ip_buf: [16]u8 = undefined;
var ip_len: usize = 0;
var cyw43_ready: bool = false;

pub fn init() void {
    state = .disconnected;
    console.puts("[wifi] init: CYW43 driver\n");

    cyw43.init(.pico_w) catch {
        console.puts("[wifi] CYW43 init failed\n");
        state = .failed;
        return;
    };

    cyw43_ready = true;
    console.puts("[wifi] CYW43 ready\n");
}

pub fn connect(ssid: []const u8, password: []const u8) bool {
    _ = password;
    console.puts("[wifi] connecting to: ");
    console.puts(ssid);
    console.puts("\n");
    @memcpy(ssid_buf[0..ssid.len], ssid);
    ssid_len = ssid.len;
    state = .connecting;
    return true;
}

pub fn disconnect() void {
    state = .disconnected;
    console.puts("[wifi] disconnected\n");
}

pub fn poll() void {
    if (cyw43_ready) cyw43.service();
}

pub fn isConnected() bool {
    return state == .connected;
}

pub fn getIp() ?[]const u8 {
    if (ip_len == 0) return null;
    return ip_buf[0..ip_len];
}

pub export fn js_wifi_connect(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var sb: c.JSCStringBuf = undefined;
    var pb: c.JSCStringBuf = undefined;
    var slen: usize = 0;
    var plen: usize = 0;
    const sp = c.JS_ToCStringLen(cx, &slen, args[0], &sb) orelse return c.JS_UNDEFINED;
    const pp = c.JS_ToCStringLen(cx, &plen, args[1], &pb) orelse return c.JS_UNDEFINED;
    const ok = connect(sp[0..slen], pp[0..plen]);
    return c.JS_NewBool(@intFromBool(ok));
}

pub export fn js_wifi_disconnect(_: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    disconnect();
    return c.JS_UNDEFINED;
}

pub export fn js_wifi_status(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    const label: []const u8 = switch (state) {
        .disconnected => "disconnected",
        .connecting => "connecting",
        .connected => "connected",
        .ap_mode => "ap_mode",
        .failed => "failed",
    };
    return c.JS_NewStringLen(cx, label.ptr, label.len);
}

pub export fn js_wifi_ip(ctx: ?*c.JSContext, _: ?*c.JSValue, _: c_int, _: ?[*]c.JSValue) c.JSValue {
    const cx = ctx orelse return c.JS_UNDEFINED;
    if (getIp()) |ip| return c.JS_NewStringLen(cx, ip.ptr, ip.len);
    return c.JS_NULL;
}
