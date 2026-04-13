// IPv4 layer — parse, validate, route, and dispatch inbound packets;
// build and send outbound packets.
//
// Receives raw IPv4 data (no Ethernet header) from ethernet.zig.
// Dispatches to ICMP, UDP, or TCP handlers based on protocol field.
//
// Reference: RFC 791 (IPv4)

const arp_mod = @import("arp.zig");
const icmp = @import("icmp.zig");
const netif = @import("stack.zig");
const core = @import("../cyw43/device.zig");
const byteutil = @import("../lib/byteutil.zig");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub fn handlePacket(ip_data: []const u8) void {
    const s = netif.stack();
    s.stats.ip_rx += 1;

    if (ip_data.len < 20) return;

    const version = ip_data[0] >> 4;
    if (version != 4) return;

    const ihl: usize = @as(usize, ip_data[0] & 0x0F) * 4;
    if (ihl < 20 or ip_data.len < ihl) return;

    if (!validHeaderChecksum(ip_data[0..ihl])) {
        s.stats.ip_bad_checksum += 1;
        return;
    }

    const total_len = (@as(usize, ip_data[2]) << 8) | ip_data[3];
    if (total_len < ihl or total_len > ip_data.len) {
        s.stats.ip_bad_len += 1;
        return;
    }

    if (!isForUs(ip_data[16..20])) return;

    const frag_off = ((@as(u16, ip_data[6]) & 0x1F) << 8) | ip_data[7];
    const mf = (ip_data[6] & 0x20) != 0;
    if (frag_off != 0 or mf) {
        s.stats.ip_fragmented_drop += 1;
        return;
    }

    const protocol = ip_data[9];
    const payload = ip_data[ihl..total_len];
    const src_ip = ip_data[12..16];

    switch (protocol) {
        PROTO_ICMP => {
            s.stats.icmp_rx += 1;
            icmp.handlePacket(src_ip, payload);
        },
        PROTO_UDP => {
            s.stats.udp_rx += 1;
            var src_arr: [4]u8 = undefined;
            @memcpy(&src_arr, src_ip[0..4]);
            s.udpInput(src_arr, payload);
        },
        PROTO_TCP => {
            var src_arr: [4]u8 = undefined;
            @memcpy(&src_arr, src_ip[0..4]);
            s.tcpInput(src_arr, payload);
        },
        else => {},
    }
}

fn isForUs(dst: []const u8) bool {
    if (dst[0] == 255 and dst[1] == 255 and dst[2] == 255 and dst[3] == 255) return true;

    const lip = netif.stack().local_ip;
    if (lip[0] == 0 and lip[1] == 0 and lip[2] == 0 and lip[3] == 0) return true;

    if (dst[0] == lip[0] and dst[1] == lip[1] and
        dst[2] == lip[2] and dst[3] == lip[3]) return true;

    const local = ipToU32(&lip);
    const mask = ipToU32(&netif.stack().subnet_mask);
    const d = ipToU32(dst[0..4]);
    if (d == ((local & mask) | ~mask)) return true;

    return false;
}

fn validHeaderChecksum(hdr: []const u8) bool {
    return ipChecksum(hdr) == 0;
}

// ── Outbound ─────────────────────────────────────────────────────────

pub fn sendPacket(dst_ip: [4]u8, protocol: u8, payload: []const u8) !void {
    const next_hop = resolveNextHop(dst_ip) orelse return error.NoRoute;
    const dst_mac = arp_mod.resolve(next_hop) orelse return error.ArpPending;

    var frame: [1514]u8 = undefined;
    const ip_total_len: u16 = @intCast(20 + payload.len);
    const frame_len: usize = 14 + 20 + payload.len;
    if (frame_len > frame.len) return error.PacketTooLarge;

    @memcpy(frame[0..6], &dst_mac);
    @memcpy(frame[6..12], &core.mac_addr);
    frame[12] = 0x08;
    frame[13] = 0x00;

    const ip = frame[14..34];
    ip[0] = 0x45;
    ip[1] = 0x00;
    ip[2] = @intCast(ip_total_len >> 8);
    ip[3] = @intCast(ip_total_len & 0xFF);
    ip[4] = 0x00;
    ip[5] = 0x00;
    ip[6] = 0x40;
    ip[7] = 0x00;
    ip[8] = 64;
    ip[9] = protocol;
    ip[10] = 0;
    ip[11] = 0;
    @memcpy(ip[12..16], &netif.stack().local_ip);
    @memcpy(ip[16..20], &dst_ip);

    const cksum = ipChecksum(ip[0..20]);
    ip[10] = @intCast(cksum >> 8);
    ip[11] = @intCast(cksum & 0xFF);

    @memcpy(frame[34..][0..payload.len], payload);

    core.sendEthernet(frame[0..frame_len]) catch return error.SendFailed;
}

fn resolveNextHop(dst: [4]u8) ?[4]u8 {
    const lip = netif.stack().local_ip;
    const local = ipToU32(&lip);
    const mask = ipToU32(&netif.stack().subnet_mask);
    const d = ipToU32(&dst);

    if (local == 0) return null;

    if ((d & mask) == (local & mask)) return dst;

    const gw = netif.stack().gateway_ip;
    if (gw[0] == 0 and gw[1] == 0 and gw[2] == 0 and gw[3] == 0) return null;

    return gw;
}

// ── Helpers ──────────────────────────────────────────────────────────

pub const ipChecksum = byteutil.ipChecksum;

fn ipToU32(ip: *const [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}
