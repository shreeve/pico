// IPv4 layer — parse, validate, route, and dispatch inbound packets;
// build and send outbound packets.
//
// Receives raw IPv4 data (no Ethernet header) from ethernet.zig.
// Dispatches to ICMP, UDP, or TCP handlers based on protocol field.
//
// Reference: RFC 791 (IPv4)

const dhcp = @import("dhcp.zig");
const arp_mod = @import("arp.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const netif = @import("netif.zig");
const core = @import("../cyw43/core.zig");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub fn handlePacket(ip_data: []const u8) void {
    const s = netif.get();
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
            dhcp.handleUdp(payload);
        },
        PROTO_TCP => {
            var src_arr: [4]u8 = undefined;
            @memcpy(&src_arr, src_ip[0..4]);
            s.tcpInput(src_arr, payload);
            tcp.handleSegment(src_ip, payload);
        },
        else => {},
    }
}

fn isForUs(dst: []const u8) bool {
    if (dst[0] == 255 and dst[1] == 255 and dst[2] == 255 and dst[3] == 255) return true;

    if (dhcp.ip_addr[0] == 0 and dhcp.ip_addr[1] == 0 and
        dhcp.ip_addr[2] == 0 and dhcp.ip_addr[3] == 0) return true;

    if (dst[0] == dhcp.ip_addr[0] and dst[1] == dhcp.ip_addr[1] and
        dst[2] == dhcp.ip_addr[2] and dst[3] == dhcp.ip_addr[3]) return true;

    const local = ipToU32(&dhcp.ip_addr);
    const mask = ipToU32(&dhcp.subnet_mask);
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
    @memcpy(ip[12..16], &dhcp.ip_addr);
    @memcpy(ip[16..20], &dst_ip);

    const cksum = ipChecksum(ip[0..20]);
    ip[10] = @intCast(cksum >> 8);
    ip[11] = @intCast(cksum & 0xFF);

    @memcpy(frame[34..][0..payload.len], payload);

    core.sendEthernet(frame[0..frame_len]) catch return error.SendFailed;
}

fn resolveNextHop(dst: [4]u8) ?[4]u8 {
    const local = ipToU32(&dhcp.ip_addr);
    const mask = ipToU32(&dhcp.subnet_mask);
    const d = ipToU32(&dst);

    if (local == 0) return null;

    if ((d & mask) == (local & mask)) return dst;

    if (dhcp.gateway[0] == 0 and dhcp.gateway[1] == 0 and
        dhcp.gateway[2] == 0 and dhcp.gateway[3] == 0) return null;

    return dhcp.gateway;
}

// ── Helpers ──────────────────────────────────────────────────────────

pub fn ipChecksum(hdr: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < hdr.len) : (i += 2) {
        sum += (@as(u32, hdr[i]) << 8) | hdr[i + 1];
    }
    if (i < hdr.len) sum += @as(u32, hdr[i]) << 8;
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

fn ipToU32(ip: *const [4]u8) u32 {
    return (@as(u32, ip[0]) << 24) | (@as(u32, ip[1]) << 16) | (@as(u32, ip[2]) << 8) | ip[3];
}
