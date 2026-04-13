// Shared network byte-order and checksum helpers.
//
// Pure functions with no hardware dependencies. Used by the network
// stack (TCP/IP, DHCP, ARP) and CYW43 protocol parsing.
//
// These are big-endian (network byte order) helpers only. Little-endian
// helpers for the CYW43 SDPCM protocol live in cyw43/control/ioctl.zig.

pub inline fn readBE16(p: *const [2]u8) u16 {
    return (@as(u16, p[0]) << 8) | p[1];
}

pub inline fn writeBE16(p: *[2]u8, v: u16) void {
    p[0] = @intCast(v >> 8);
    p[1] = @intCast(v & 0xFF);
}

pub inline fn readBE32(p: *const [4]u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

pub inline fn writeBE32(p: *[4]u8, v: u32) void {
    p[0] = @intCast((v >> 24) & 0xFF);
    p[1] = @intCast((v >> 16) & 0xFF);
    p[2] = @intCast((v >> 8) & 0xFF);
    p[3] = @intCast(v & 0xFF);
}

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

pub inline fn ipv4Eq(a: [4]u8, b: [4]u8) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}
