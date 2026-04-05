// Minimal ARP responder — replies to who-has queries for our IP.
//
// Receives full Ethernet frames (14-byte header + ARP payload).
// Builds ARP reply and sends via core.sendEthernet().
//
// Reference: RFC 826 (ARP)

const core = @import("../cyw43/core.zig");
const dhcp = @import("dhcp.zig");

/// Handle an Ethernet frame with ethertype 0x0806 (ARP).
/// `eth_frame` starts at the Ethernet header (dst MAC at offset 0).
pub fn handlePacket(eth_frame: []const u8) void {
    if (eth_frame.len < 42) return; // 14 Ethernet + 28 ARP minimum

    const a = eth_frame[14..]; // ARP payload

    // Validate ARP header
    const hw_type = (@as(u16, a[0]) << 8) | a[1];
    const proto_type = (@as(u16, a[2]) << 8) | a[3];
    const hw_len = a[4];
    const proto_len = a[5];
    const operation = (@as(u16, a[6]) << 8) | a[7];

    if (hw_type != 1) return; // Ethernet
    if (proto_type != 0x0800) return; // IPv4
    if (hw_len != 6) return;
    if (proto_len != 4) return;
    if (operation != 1) return; // REQUEST only

    // Target IP is at ARP offset 24 (sender MAC 8, sender IP 14, target MAC 18, target IP 24)
    const target_ip = a[24..28];
    if (dhcp.ip_addr[0] == 0 and dhcp.ip_addr[1] == 0) return; // no IP yet

    if (target_ip[0] != dhcp.ip_addr[0] or target_ip[1] != dhcp.ip_addr[1] or
        target_ip[2] != dhcp.ip_addr[2] or target_ip[3] != dhcp.ip_addr[3]) return;

    // Build ARP reply: 14-byte Ethernet + 28-byte ARP = 42 bytes
    var reply: [42]u8 = undefined;

    // Ethernet header
    @memcpy(reply[0..6], a[8..14]); // dst = sender's MAC (from ARP sender hardware addr)
    @memcpy(reply[6..12], &core.mac_addr); // src = our MAC
    reply[12] = 0x08;
    reply[13] = 0x06; // ethertype = ARP

    // ARP payload
    reply[14] = 0x00;
    reply[15] = 0x01; // hardware type = Ethernet
    reply[16] = 0x08;
    reply[17] = 0x00; // protocol type = IPv4
    reply[18] = 6; // hardware addr len
    reply[19] = 4; // protocol addr len
    reply[20] = 0x00;
    reply[21] = 0x02; // operation = REPLY

    // Sender = us
    @memcpy(reply[22..28], &core.mac_addr);
    @memcpy(reply[28..32], &dhcp.ip_addr);

    // Target = requester
    @memcpy(reply[32..38], a[8..14]); // requester's MAC
    @memcpy(reply[38..42], a[14..18]); // requester's IP

    core.sendEthernet(&reply) catch {};
}
