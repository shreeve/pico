const regs = @import("../regs.zig");
const bus = @import("../transport/bus.zig");
const hal = @import("../../platform/hal.zig");
const ioctl = @import("../control/ioctl.zig");
const ipv4 = @import("../../net/ipv4.zig");
const arp = @import("../../net/arp.zig");

pub fn sendEthernet(ctx: *ioctl.Context, frame: []const u8) ioctl.Error!void {
    var tx_buf: [2048]u8 = undefined;
    const total_len = regs.SDPCM_HEADER_LEN + regs.BDC_HEADER_LEN + frame.len;

    var credit_wait: u32 = 0;
    while (!ioctl.hasCredit(ctx) and credit_wait < 1000) : (credit_wait += 1) {
        _ = ioctl.pollDevice(ctx);
        hal.delayMs(1);
    }
    if (!ioctl.hasCredit(ctx)) return ioctl.Error.IoctlTimeout;

    ioctl.writeLE16(@ptrCast(tx_buf[0..2]), @intCast(total_len));
    ioctl.writeLE16(@ptrCast(tx_buf[2..4]), @intCast(total_len ^ 0xFFFF));
    tx_buf[4] = ctx.sdpcm_tx_seq.*;
    ctx.sdpcm_tx_seq.* +%= 1;
    tx_buf[5] = regs.CHANNEL_DATA;
    tx_buf[6] = 0;
    tx_buf[7] = @intCast(regs.SDPCM_HEADER_LEN);
    tx_buf[8] = 0;
    tx_buf[9] = 0;
    tx_buf[10] = 0;
    tx_buf[11] = 0;

    tx_buf[12] = regs.BDC_VERSION_2;
    tx_buf[13] = 0;
    tx_buf[14] = 0;
    tx_buf[15] = 0;

    const payload_off = regs.SDPCM_HEADER_LEN + regs.BDC_HEADER_LEN;
    @memcpy(tx_buf[payload_off..][0..frame.len], frame);

    const padded = (total_len + 63) & ~@as(usize, 63);
    @memset(tx_buf[total_len..padded], 0);

    bus.wlanWrite(tx_buf[0..padded]);
}

pub fn handleDataPacket(ctx: *ioctl.Context) void {
    const rx_bytes = @as([*]const u8, @ptrCast(ctx.rx_buf));
    const pkt_size: usize = ioctl.readLE16(rx_bytes[0..2]);
    if (pkt_size < 20) return;

    const hdr_len: usize = rx_bytes[7];
    if (hdr_len + regs.BDC_HEADER_LEN > pkt_size) return;
    const bdc_off: usize = hdr_len;
    const bdc_data_offset: usize = @as(usize, rx_bytes[bdc_off + 3]) * 4;
    const eth_off = bdc_off + regs.BDC_HEADER_LEN + bdc_data_offset;
    if (eth_off + 14 > pkt_size) return;

    const ethertype = (@as(u16, rx_bytes[eth_off + 12]) << 8) | rx_bytes[eth_off + 13];
    const eth_payload = pkt_size - eth_off;

    if (ethertype == 0x0800) {
        const ip_off = eth_off + 14;
        if (pkt_size <= ip_off or pkt_size - ip_off < 20) return;
        ipv4.handlePacket(rx_bytes[ip_off..][0 .. pkt_size - ip_off]);
    } else if (ethertype == 0x0806) {
        if (eth_payload < 42) return;
        arp.handlePacket(rx_bytes[eth_off..][0..eth_payload]);
    }
}
