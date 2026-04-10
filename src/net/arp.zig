// ARP — responder + client cache for outbound resolution.
//
// Handles inbound ARP requests (reply with our MAC) and ARP replies
// (populate cache for outbound IP routing).
// Provides resolve() for the IPv4 TX path to look up destination MACs.
//
// Reference: RFC 826 (ARP)

const core = @import("../cyw43/core.zig");
const dhcp = @import("dhcp.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;

const CACHE_SIZE = 8;
const ENTRY_TTL_MS: u64 = 300_000; // 5 minutes

const CacheEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    timestamp_ms: u64,
    valid: bool,
};

var cache: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{
    .ip = [_]u8{0} ** 4,
    .mac = [_]u8{0} ** 6,
    .timestamp_ms = 0,
    .valid = false,
}} ** CACHE_SIZE;

// ── Public API ───────────────────────────────────────────────────────

pub fn resolve(ip: [4]u8) ?[6]u8 {
    const now = hal.millis();
    for (&cache) |*entry| {
        if (entry.valid and ipEq(&entry.ip, &ip)) {
            if (now - entry.timestamp_ms < ENTRY_TTL_MS) {
                return entry.mac;
            }
            entry.valid = false;
        }
    }
    sendRequest(ip);
    return null;
}

pub fn sendGratuitous() void {
    if (dhcp.ip_addr[0] == 0 and dhcp.ip_addr[1] == 0) return;

    var frame: [42]u8 = undefined;
    @memset(frame[0..6], 0xFF);
    @memcpy(frame[6..12], &core.mac_addr);
    frame[12] = 0x08;
    frame[13] = 0x06;

    buildArpPayload(&frame, 1, &core.mac_addr, &dhcp.ip_addr, &[_]u8{0} ** 6, &dhcp.ip_addr);
    core.sendEthernet(&frame) catch {};
}

// ── Inbound handling ─────────────────────────────────────────────────

pub fn handlePacket(eth_frame: []const u8) void {
    if (eth_frame.len < 42) return;

    const a = eth_frame[14..];

    const hw_type = (@as(u16, a[0]) << 8) | a[1];
    const proto_type = (@as(u16, a[2]) << 8) | a[3];
    const hw_len = a[4];
    const proto_len = a[5];
    const operation = (@as(u16, a[6]) << 8) | a[7];

    if (hw_type != 1 or proto_type != 0x0800 or hw_len != 6 or proto_len != 4) return;

    const sender_mac = a[8..14];
    const sender_ip = a[14..18];

    updateCache(sender_ip[0..4].*, sender_mac[0..6].*);

    if (operation == 1) {
        const target_ip = a[24..28];
        if (dhcp.ip_addr[0] == 0 and dhcp.ip_addr[1] == 0) return;
        if (!ipEq(target_ip, &dhcp.ip_addr)) return;

        var reply: [42]u8 = undefined;
        @memcpy(reply[0..6], sender_mac);
        @memcpy(reply[6..12], &core.mac_addr);
        reply[12] = 0x08;
        reply[13] = 0x06;

        buildArpPayload(&reply, 2, &core.mac_addr, &dhcp.ip_addr, sender_mac, sender_ip);
        core.sendEthernet(&reply) catch {};
    }
}

// ── Outbound ARP request ─────────────────────────────────────────────

fn sendRequest(target_ip: [4]u8) void {
    if (dhcp.ip_addr[0] == 0 and dhcp.ip_addr[1] == 0) return;

    var frame: [42]u8 = undefined;
    @memset(frame[0..6], 0xFF);
    @memcpy(frame[6..12], &core.mac_addr);
    frame[12] = 0x08;
    frame[13] = 0x06;

    buildArpPayload(&frame, 1, &core.mac_addr, &dhcp.ip_addr, &[_]u8{0} ** 6, &target_ip);
    core.sendEthernet(&frame) catch {};
}

// ── Cache management ─────────────────────────────────────────────────

fn updateCache(ip: [4]u8, mac: [6]u8) void {
    const now = hal.millis();

    for (&cache) |*entry| {
        if (entry.valid and ipEq(&entry.ip, &ip)) {
            entry.mac = mac;
            entry.timestamp_ms = now;
            return;
        }
    }

    for (&cache) |*entry| {
        if (!entry.valid) {
            entry.* = .{ .ip = ip, .mac = mac, .timestamp_ms = now, .valid = true };
            return;
        }
    }

    var oldest_idx: usize = 0;
    var oldest_ts: u64 = cache[0].timestamp_ms;
    for (cache[1..], 1..) |entry, i| {
        if (entry.timestamp_ms < oldest_ts) {
            oldest_ts = entry.timestamp_ms;
            oldest_idx = i;
        }
    }
    cache[oldest_idx] = .{ .ip = ip, .mac = mac, .timestamp_ms = now, .valid = true };
}

// ── Helpers ──────────────────────────────────────────────────────────

fn buildArpPayload(frame: *[42]u8, operation: u16, sender_mac: []const u8, sender_ip: []const u8, target_mac: []const u8, target_ip: []const u8) void {
    frame[14] = 0x00;
    frame[15] = 0x01;
    frame[16] = 0x08;
    frame[17] = 0x00;
    frame[18] = 6;
    frame[19] = 4;
    frame[20] = @intCast(operation >> 8);
    frame[21] = @intCast(operation & 0xFF);
    @memcpy(frame[22..28], sender_mac[0..6]);
    @memcpy(frame[28..32], sender_ip[0..4]);
    @memcpy(frame[32..38], target_mac[0..6]);
    @memcpy(frame[38..42], target_ip[0..4]);
}

fn ipEq(a: []const u8, b: []const u8) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}
