const regs = @import("../regs.zig");
const scan = @import("../control/scan.zig");
const join = @import("../control/join.zig");
const ioctl = @import("../control/ioctl.zig");

fn readBE32(p: [*]const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

pub fn handleEvent(
    rx_bytes: [*]const u8,
    puts: *const fn ([]const u8) void,
    putDec: *const fn (u32) void,
    putHex32: *const fn (u32) void,
) void {
    const pkt_size: usize = ioctl.readLE16(rx_bytes[0..2]);
    if (pkt_size < 20) return;

    const hdr_len: usize = rx_bytes[7];
    if (hdr_len + 4 > pkt_size) return;
    const bdc_off = hdr_len;
    const bdc_data_offset: usize = @as(usize, rx_bytes[bdc_off + 3]) * 4;
    const eth_off = bdc_off + 4 + bdc_data_offset;

    if (eth_off + 14 > pkt_size) return;
    const ethertype = (@as(u16, rx_bytes[eth_off + 12]) << 8) | rx_bytes[eth_off + 13];
    if (ethertype != 0x886C) return;

    const evt_off = eth_off + 14 + 10;
    if (evt_off + 12 > pkt_size) return;

    const event_type = readBE32(rx_bytes[evt_off + 4 ..]);
    const evt_status = readBE32(rx_bytes[evt_off + 8 ..]);

    switch (event_type) {
        regs.EVENT_ESCAN_RESULT => scan.handleScanEvent(rx_bytes, evt_off, evt_status),
        regs.EVENT_SET_SSID => {
            puts("[evt] SET_SSID status=");
            putDec(evt_status);
            puts("\n");
            if (evt_status == 0) join.join_state = .success else join.join_state = .failed;
        },
        regs.EVENT_AUTH => {
            puts("[evt] AUTH status=");
            putDec(evt_status);
            puts("\n");
        },
        regs.EVENT_LINK => {
            if (evt_off + 16 > pkt_size) return;
            const flags = readBE32(rx_bytes[evt_off + 12 ..]);
            puts("[evt] LINK status=");
            putDec(evt_status);
            puts(" flags=");
            putHex32(flags);
            puts("\n");
        },
        regs.EVENT_PSK_SUP => {
            puts("[evt] PSK_SUP status=");
            putDec(evt_status);
            puts("\n");
        },
        regs.EVENT_DEAUTH_IND, regs.EVENT_DISASSOC_IND => {
            puts("[evt] DEAUTH/DISASSOC type=");
            putDec(event_type);
            puts("\n");
            if (join.join_state == .joining) join.join_state = .failed;
        },
        else => {},
    }
}
