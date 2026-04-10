// Minimal ICMP handler — echo reply (ping) support.
//
// Receives ICMP payloads (no IP header) from ipv4.zig.
// Sends echo replies so the device can be pinged from the LAN.
//
// Reference: RFC 792 (ICMP)

const ipv4 = @import("ipv4.zig");

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

pub fn handlePacket(src_ip: []const u8, icmp_data: []const u8) void {
    if (icmp_data.len < 8) return;

    const msg_type = icmp_data[0];
    if (msg_type != ICMP_ECHO_REQUEST) return;

    if (!validChecksum(icmp_data)) return;

    var reply: [1480]u8 = undefined;
    if (icmp_data.len > reply.len) return;

    reply[0] = ICMP_ECHO_REPLY;
    reply[1] = 0;
    reply[2] = 0;
    reply[3] = 0;
    @memcpy(reply[4..][0 .. icmp_data.len - 4], icmp_data[4..]);

    const cksum = ipv4.ipChecksum(reply[0..icmp_data.len]);
    reply[2] = @intCast(cksum >> 8);
    reply[3] = @intCast(cksum & 0xFF);

    var dst_ip: [4]u8 = undefined;
    @memcpy(&dst_ip, src_ip[0..4]);
    ipv4.sendPacket(dst_ip, ipv4.PROTO_ICMP, reply[0..icmp_data.len]) catch {};
}

fn validChecksum(data: []const u8) bool {
    return ipv4.ipChecksum(data) == 0;
}
