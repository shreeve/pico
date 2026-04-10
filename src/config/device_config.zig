/// Device configuration — loaded from flash at boot.
const storage = @import("../bindings/storage.zig");
const console = @import("../bindings/console.zig");

pub const Config = struct {
    wifi_ssid: [33]u8 = [_]u8{0} ** 33,
    wifi_ssid_len: u8 = 0,
    wifi_pass: [64]u8 = [_]u8{0} ** 64,
    wifi_pass_len: u8 = 0,
    device_name: [32]u8 = [_]u8{0} ** 32,
    device_name_len: u8 = 0,
    tcp_port: u16 = 9001,
    vm_heap_kb: u16 = 96,
    configured: bool = false,
};

var current: Config = .{};

pub fn load() void {
    console.puts("[config] loading from flash\n");

    if (storage.get("wifi_ssid")) |ssid| {
        const len = @min(ssid.len, current.wifi_ssid.len);
        @memcpy(current.wifi_ssid[0..len], ssid[0..len]);
        current.wifi_ssid_len = @intCast(len);
        current.configured = true;
    }

    if (storage.get("wifi_pass")) |pass| {
        const len = @min(pass.len, current.wifi_pass.len);
        @memcpy(current.wifi_pass[0..len], pass[0..len]);
        current.wifi_pass_len = @intCast(len);
    }

    if (storage.get("device_name")) |name| {
        const len = @min(name.len, current.device_name.len);
        @memcpy(current.device_name[0..len], name[0..len]);
        current.device_name_len = @intCast(len);
    }
}

pub fn save() void {
    if (current.wifi_ssid_len > 0) {
        _ = storage.set("wifi_ssid", current.wifi_ssid[0..current.wifi_ssid_len]);
    }
    if (current.wifi_pass_len > 0) {
        _ = storage.set("wifi_pass", current.wifi_pass[0..current.wifi_pass_len]);
    }
}

pub fn get() *const Config {
    return &current;
}

pub fn getMut() *Config {
    return &current;
}

pub fn isConfigured() bool {
    return current.configured;
}

pub fn wifiSsid() ?[]const u8 {
    if (current.wifi_ssid_len == 0) return null;
    return current.wifi_ssid[0..current.wifi_ssid_len];
}

pub fn wifiPass() ?[]const u8 {
    if (current.wifi_pass_len == 0) return null;
    return current.wifi_pass[0..current.wifi_pass_len];
}
