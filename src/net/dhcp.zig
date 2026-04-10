// Minimal DHCP client — just enough to obtain an IP address after WPA2 join.
//
// Implements the 4-step exchange: DISCOVER → OFFER → REQUEST → ACK.
// Builds raw Ethernet/IPv4/UDP frames and sends them through the CYW43 data channel.
//
// Reference: RFC 2131 (DHCP), RFC 791 (IPv4), RFC 768 (UDP)

const core = @import("../cyw43/core.zig");
const regs = @import("../cyw43/regs.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;

pub const DhcpState = enum {
    idle,
    discovering,
    requesting,
    bound,
    failed,
};

pub var dhcp_state: DhcpState = .idle;
pub var ip_addr: [4]u8 = [_]u8{0} ** 4;
pub var subnet_mask: [4]u8 = [_]u8{0} ** 4;
pub var gateway: [4]u8 = [_]u8{0} ** 4;
pub var dns_server: [4]u8 = [_]u8{0} ** 4;
pub var lease_time: u32 = 0;

var server_ip: [4]u8 = [_]u8{0} ** 4;
var xid: u32 = 0x52495021; // "RIP!" base, incremented per transaction
var lease_start_ms: u64 = 0;
var renew_sent: bool = false;

// ── UART helpers (TODO: deduplicate with core.zig into shared module) ─

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') rp2040.uartWrite(rp2040.UART0_BASE, '\r');
        rp2040.uartWrite(rp2040.UART0_BASE, ch);
    }
}

fn putDec(val: u32) void {
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) {
        puts("0");
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    puts(buf[i..]);
}

pub fn putIp(addr: [4]u8) void {
    for (addr, 0..) |b, i| {
        if (i > 0) puts(".");
        putDec(b);
    }
}

// ── Public API ────────────────────────────────────────────────────────

pub fn start() void {
    xid +%= 1;
    dhcp_state = .discovering;
    sendDiscover();
}

pub fn retransmit() void {
    sendDiscover();
}

/// Called from service() to check lease timers. Renews at T1 (lease_time / 2).
pub fn tick() void {
    if (dhcp_state != .bound) return;
    if (lease_time == 0) return;

    const elapsed_s = @as(u32, @intCast((hal.millis() - lease_start_ms) / 1000));
    const t1 = lease_time / 2;

    if (elapsed_s >= lease_time) {
        puts("[dhcp] lease expired\n");
        dhcp_state = .idle;
        start();
    } else if (elapsed_s >= t1 and !renew_sent) {
        puts("[dhcp] renewing lease...\n");
        renew_sent = true;
        dhcp_state = .requesting;
        xid +%= 1;
        sendRenew();
    }
}

/// Called from ipv4.handlePacket — receives UDP payload (IP header already stripped).
pub fn handleUdp(udp_data: []const u8) void {
    if (dhcp_state == .idle or dhcp_state == .bound) return;
    if (udp_data.len < 8) return;

    const src_port = (@as(u16, udp_data[0]) << 8) | udp_data[1];
    const dst_port = (@as(u16, udp_data[2]) << 8) | udp_data[3];

    if (src_port != 67 or dst_port != 68) return;
    if (udp_data.len < 8 + 236 + 4) return;

    const bootp = udp_data[8..];
    handleDhcp(bootp);
}

// ── DHCP message handling ─────────────────────────────────────────────

fn handleDhcp(bootp: []const u8) void {
    // Validate: op=2 (BOOTREPLY), xid matches
    if (bootp[0] != 2) return;
    const rx_xid = readBE32(bootp[4..8]);
    if (rx_xid != xid) return;

    // yiaddr at offset 16
    const yiaddr = bootp[16..20];

    // Parse options starting at offset 236 (after magic cookie at 236..240)
    if (bootp.len < 240) return;
    if (bootp[236] != 99 or bootp[237] != 130 or bootp[238] != 83 or bootp[239] != 99) return;

    var msg_type: u8 = 0;
    var offer_server: [4]u8 = [_]u8{0} ** 4;
    var offer_subnet: [4]u8 = [_]u8{0} ** 4;
    var offer_gateway: [4]u8 = [_]u8{0} ** 4;
    var offer_dns: [4]u8 = [_]u8{0} ** 4;
    var offer_lease: u32 = 0;

    // Walk TLV options
    var pos: usize = 240;
    while (pos < bootp.len) {
        const opt = bootp[pos];
        if (opt == 255) break; // end
        if (opt == 0) {
            pos += 1; // padding
            continue;
        }
        if (pos + 1 >= bootp.len) break;
        const opt_len: usize = bootp[pos + 1];
        const val_start = pos + 2;
        if (val_start + opt_len > bootp.len) break;
        const val = bootp[val_start..][0..opt_len];

        switch (opt) {
            53 => { // DHCP Message Type
                if (opt_len >= 1) msg_type = val[0];
            },
            54 => { // Server Identifier
                if (opt_len >= 4) @memcpy(&offer_server, val[0..4]);
            },
            1 => { // Subnet Mask
                if (opt_len >= 4) @memcpy(&offer_subnet, val[0..4]);
            },
            3 => { // Router (gateway)
                if (opt_len >= 4) @memcpy(&offer_gateway, val[0..4]);
            },
            6 => { // DNS Server
                if (opt_len >= 4) @memcpy(&offer_dns, val[0..4]);
            },
            51 => { // Lease Time
                if (opt_len >= 4) offer_lease = readBE32(val[0..4]);
            },
            else => {},
        }
        pos = val_start + opt_len;
    }

    if (msg_type == 2 and dhcp_state == .discovering) {
        // DHCPOFFER — save offered IP and server, send REQUEST
        @memcpy(&ip_addr, yiaddr);
        @memcpy(&server_ip, &offer_server);
        @memcpy(&subnet_mask, &offer_subnet);
        @memcpy(&gateway, &offer_gateway);
        @memcpy(&dns_server, &offer_dns);
        lease_time = offer_lease;

        puts("[dhcp] offer ");
        putIp(ip_addr);
        puts(" from ");
        putIp(server_ip);
        puts("\n");

        dhcp_state = .requesting;
        sendRequest();
    } else if (msg_type == 5 and dhcp_state == .requesting) {
        // DHCPACK — we have an IP!
        @memcpy(&ip_addr, yiaddr);
        if (offer_subnet[0] != 0) @memcpy(&subnet_mask, &offer_subnet);
        if (offer_gateway[0] != 0) @memcpy(&gateway, &offer_gateway);
        if (offer_dns[0] != 0) @memcpy(&dns_server, &offer_dns);
        if (offer_lease != 0) lease_time = offer_lease;

        dhcp_state = .bound;
        lease_start_ms = hal.millis();
        renew_sent = false;
        puts("[dhcp] bound ");
        putIp(ip_addr);
        puts(" gw ");
        putIp(gateway);
        puts(" mask ");
        putIp(subnet_mask);
        puts("\n");
    } else if (msg_type == 6) {
        // DHCPNAK
        puts("[dhcp] NAK\n");
        dhcp_state = .failed;
    }
}

// ── Packet builders ───────────────────────────────────────────────────

fn sendDiscover() void {
    var pkt: [600]u8 = [_]u8{0} ** 600;
    const dhcp_len = buildDhcpDiscover(pkt[42..]);
    const total = buildEthIpUdp(&pkt, dhcp_len);
    core.sendEthernet(pkt[0..total]) catch {
        puts("[dhcp] send discover failed\n");
    };
}

fn sendRequest() void {
    var pkt: [600]u8 = [_]u8{0} ** 600;
    const dhcp_len = buildDhcpRequest(pkt[42..]);
    const total = buildEthIpUdp(&pkt, dhcp_len);
    core.sendEthernet(pkt[0..total]) catch {
        puts("[dhcp] send request failed\n");
    };
}

fn buildDhcpDiscover(buf: []u8) usize {
    // BOOTP fixed header (236 bytes)
    buf[0] = 1; // op = BOOTREQUEST
    buf[1] = 1; // htype = Ethernet
    buf[2] = 6; // hlen = 6
    buf[3] = 0; // hops
    writeBE32(buf[4..8], xid);
    buf[8] = 0;
    buf[9] = 0; // secs
    buf[10] = 0x80;
    buf[11] = 0x00; // flags = broadcast
    // ciaddr, yiaddr, siaddr, giaddr = 0 (already zeroed)
    @memcpy(buf[28..34], &core.mac_addr); // chaddr

    // Options at offset 236
    var pos: usize = 236;
    // Magic cookie
    buf[pos] = 99;
    buf[pos + 1] = 130;
    buf[pos + 2] = 83;
    buf[pos + 3] = 99;
    pos += 4;

    // Option 53: DHCP Message Type = 1 (DISCOVER)
    buf[pos] = 53;
    buf[pos + 1] = 1;
    buf[pos + 2] = 1;
    pos += 3;

    // Option 55: Parameter Request List
    buf[pos] = 55;
    buf[pos + 1] = 4;
    buf[pos + 2] = 1; // subnet mask
    buf[pos + 3] = 3; // router
    buf[pos + 4] = 6; // DNS
    buf[pos + 5] = 51; // lease time
    pos += 6;

    // Option 255: End
    buf[pos] = 255;
    pos += 1;

    return pos;
}

fn sendRenew() void {
    var pkt: [600]u8 = [_]u8{0} ** 600;
    const dhcp_len = buildDhcpRenew(pkt[42..]);
    const total = buildEthIpUdp(&pkt, dhcp_len);
    core.sendEthernet(pkt[0..total]) catch {
        puts("[dhcp] send renew failed\n");
    };
}

fn buildDhcpRenew(buf: []u8) usize {
    buf[0] = 1; // op = BOOTREQUEST
    buf[1] = 1; // htype = Ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops
    writeBE32(buf[4..8], xid);
    // ciaddr = our current IP (renewal)
    @memcpy(buf[12..16], &ip_addr);
    @memcpy(buf[28..34], &core.mac_addr);

    var pos: usize = 236;
    buf[pos] = 99;
    buf[pos + 1] = 130;
    buf[pos + 2] = 83;
    buf[pos + 3] = 99;
    pos += 4;

    // Option 53: DHCP Message Type = 3 (REQUEST)
    buf[pos] = 53;
    buf[pos + 1] = 1;
    buf[pos + 2] = 3;
    pos += 3;

    // Option 54: Server Identifier
    buf[pos] = 54;
    buf[pos + 1] = 4;
    @memcpy(buf[pos + 2 ..][0..4], &server_ip);
    pos += 6;

    // Option 255: End
    buf[pos] = 255;
    pos += 1;

    return pos;
}

fn buildDhcpRequest(buf: []u8) usize {
    buf[0] = 1; // op = BOOTREQUEST
    buf[1] = 1; // htype = Ethernet
    buf[2] = 6; // hlen
    buf[3] = 0; // hops
    writeBE32(buf[4..8], xid);
    buf[10] = 0x80;
    buf[11] = 0x00; // flags = broadcast
    @memcpy(buf[28..34], &core.mac_addr);

    var pos: usize = 236;
    // Magic cookie
    buf[pos] = 99;
    buf[pos + 1] = 130;
    buf[pos + 2] = 83;
    buf[pos + 3] = 99;
    pos += 4;

    // Option 53: DHCP Message Type = 3 (REQUEST)
    buf[pos] = 53;
    buf[pos + 1] = 1;
    buf[pos + 2] = 3;
    pos += 3;

    // Option 50: Requested IP Address
    buf[pos] = 50;
    buf[pos + 1] = 4;
    @memcpy(buf[pos + 2 ..][0..4], &ip_addr);
    pos += 6;

    // Option 54: Server Identifier
    buf[pos] = 54;
    buf[pos + 1] = 4;
    @memcpy(buf[pos + 2 ..][0..4], &server_ip);
    pos += 6;

    // Option 55: Parameter Request List
    buf[pos] = 55;
    buf[pos + 1] = 4;
    buf[pos + 2] = 1;
    buf[pos + 3] = 3;
    buf[pos + 4] = 6;
    buf[pos + 5] = 51;
    pos += 6;

    // Option 255: End
    buf[pos] = 255;
    pos += 1;

    return pos;
}

/// Build Ethernet + IPv4 + UDP headers around a DHCP payload already at buf[42..].
/// Returns total frame length.
fn buildEthIpUdp(buf: *[600]u8, dhcp_len: usize) usize {
    const udp_len = 8 + dhcp_len;
    const ip_total_len: u16 = @intCast(20 + udp_len);
    const frame_len = 14 + 20 + udp_len;

    // Ethernet header (14 bytes)
    @memset(buf[0..6], 0xFF); // dst = broadcast
    @memcpy(buf[6..12], &core.mac_addr); // src
    buf[12] = 0x08;
    buf[13] = 0x00; // ethertype = IPv4

    // IPv4 header (20 bytes, at offset 14)
    const ip = buf[14..34];
    ip[0] = 0x45; // version=4, IHL=5
    ip[1] = 0x00; // DSCP/ECN
    ip[2] = @intCast(ip_total_len >> 8);
    ip[3] = @intCast(ip_total_len & 0xFF);
    ip[4] = 0x00;
    ip[5] = 0x01; // identification
    ip[6] = 0x00;
    ip[7] = 0x00; // flags + fragment offset
    ip[8] = 64; // TTL
    ip[9] = 17; // protocol = UDP
    ip[10] = 0;
    ip[11] = 0; // checksum (fill after)
    @memset(ip[12..16], 0x00); // src = 0.0.0.0
    @memset(ip[16..20], 0xFF); // dst = 255.255.255.255

    // Compute IPv4 header checksum
    const cksum = ipChecksum(ip[0..20]);
    ip[10] = @intCast(cksum >> 8);
    ip[11] = @intCast(cksum & 0xFF);

    // UDP header (8 bytes, at offset 34)
    const udp = buf[34..42];
    udp[0] = 0x00;
    udp[1] = 68; // src port = 68 (DHCP client)
    udp[2] = 0x00;
    udp[3] = 67; // dst port = 67 (DHCP server)
    udp[4] = @intCast(@as(u16, @intCast(udp_len)) >> 8);
    udp[5] = @intCast(@as(u16, @intCast(udp_len)) & 0xFF);
    udp[6] = 0x00;
    udp[7] = 0x00; // UDP checksum = 0 (optional for IPv4)

    return frame_len;
}

// ── Helpers ───────────────────────────────────────────────────────────

fn readBE32(p: []const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

fn writeBE32(p: []u8, val: u32) void {
    p[0] = @intCast((val >> 24) & 0xFF);
    p[1] = @intCast((val >> 16) & 0xFF);
    p[2] = @intCast((val >> 8) & 0xFF);
    p[3] = @intCast(val & 0xFF);
}

fn ipChecksum(hdr: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < hdr.len) : (i += 2) {
        sum += (@as(u32, hdr[i]) << 8) | hdr[i + 1];
    }
    if (i < hdr.len) sum += @as(u32, hdr[i]) << 8;
    // Fold carries
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}
