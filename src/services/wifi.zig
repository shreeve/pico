// Wi-Fi service for Pico W / Pico 2 W (CYW43 driver).
const std = @import("std");
const c = @import("../vm/c.zig");
const console = @import("console.zig");
const cyw43 = @import("../cyw43/mod.zig");
const arp_mod = @import("../net/arp.zig");
const dhcp_mod = @import("../net/dhcp.zig");

pub const WifiState = enum { disconnected, connecting, connected, ap_mode, failed };

var state: WifiState = .disconnected;
var ssid_buf: [33]u8 = undefined;
var ssid_len: usize = 0;
var ip_buf: [16]u8 = undefined;
var ip_len: usize = 0;
var cyw43_ready: bool = false;

fn refreshState() void {
    if (!cyw43_ready) {
        ip_len = 0;
        return;
    }

    if (cyw43.hasIpAddress()) {
        const ip = cyw43.getIpAddress();
        const formatted = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{
            ip[0],
            ip[1],
            ip[2],
            ip[3],
        }) catch {
            ip_len = 0;
            return;
        };
        ip_len = formatted.len;
        state = .connected;
        return;
    }

    ip_len = 0;
    if (state == .connected) state = .disconnected;
}

pub fn init() void {
    state = .disconnected;
    ip_len = 0;
    cyw43_ready = false;
    console.puts("[wifi] init: CYW43 driver\n");

    cyw43.init(.pico_w) catch {
        console.puts("[wifi] CYW43 init failed\n");
        state = .failed;
        return;
    };

    cyw43_ready = true;
    refreshState();
    console.puts("[wifi] CYW43 ready\n");
}

pub fn connect(ssid: []const u8, password: []const u8) bool {
    if (!cyw43_ready) {
        console.puts("[wifi] connect failed: driver not ready\n");
        return false;
    }
    console.puts("[wifi] connecting to: ");
    console.puts(ssid);
    console.puts("\n");
    @memcpy(ssid_buf[0..@min(ssid.len, ssid_buf.len)], ssid[0..@min(ssid.len, ssid_buf.len)]);
    ssid_len = @min(ssid.len, ssid_buf.len);
    state = .connecting;

    cyw43.core.joinWpa2(ssid, password) catch {
        console.puts("[wifi] join failed\n");
        state = .failed;
        return false;
    };

    state = .connected;
    dhcp_mod.start();
    arp_mod.sendGratuitous();
    return true;
}

pub fn disconnect() void {
    state = .disconnected;
    ip_len = 0;
    console.puts("[wifi] disconnected\n");
}

pub fn poll() void {
    if (cyw43_ready) {
        cyw43.service();
        refreshState();
    }
}

pub fn isConnected() bool {
    return cyw43_ready and cyw43.hasIpAddress();
}

pub fn getIp() ?[]const u8 {
    refreshState();
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
    refreshState();
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
