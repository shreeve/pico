const regs = @import("../regs.zig");
const ioctl = @import("ioctl.zig");

pub const MAX_SCAN_RESULTS = 32;

pub const ScanResult = struct {
    bssid: [6]u8,
    ssid: [32]u8,
    ssid_len: u8,
    rssi: i16,
    in_use: bool,
};

var scan_results: [MAX_SCAN_RESULTS]ScanResult = [_]ScanResult{.{
    .bssid = [_]u8{0} ** 6,
    .ssid = [_]u8{0} ** 32,
    .ssid_len = 0,
    .rssi = 0,
    .in_use = false,
}} ** MAX_SCAN_RESULTS;
var scan_count: usize = 0;

pub fn reset() void {
    scan_count = 0;
    for (&scan_results) |*r| r.in_use = false;
}

pub fn startScan(
    do_ioctl: *const fn (u32, u32, u8, []u8) anyerror!void,
    puts: *const fn ([]const u8) void,
) anyerror!void {
    var buf: [128]u8 = [_]u8{0} ** 128;
    @memcpy(buf[0..6], "escan\x00");

    const p = buf[6..];
    ioctl.writeLE32(@ptrCast(p[0..4]), 1);
    ioctl.writeLE16(@ptrCast(p[4..6]), 1);
    ioctl.writeLE16(@ptrCast(p[6..8]), 0x1234);

    const s = p[8..];
    ioctl.writeLE32(@ptrCast(s[0..4]), 0);
    @memset(s[36..42], 0xFF);
    s[42] = 2;
    s[43] = 0;
    ioctl.writeLE32(@ptrCast(s[44..48]), 0xFFFFFFFF);
    ioctl.writeLE32(@ptrCast(s[48..52]), 0xFFFFFFFF);
    ioctl.writeLE32(@ptrCast(s[52..56]), 0xFFFFFFFF);
    ioctl.writeLE32(@ptrCast(s[56..60]), 0xFFFFFFFF);
    ioctl.writeLE32(@ptrCast(s[60..64]), 0);

    try do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, buf[0..78]);
    puts("[cyw43] scan started\n");
}

pub fn handleScanEvent(rx_bytes: [*]const u8, evt_off: usize, evt_status: u32) void {
    const STATUS_PARTIAL: u32 = 8;
    if (evt_status != STATUS_PARTIAL) return;

    const pkt_size: usize = ioctl.readLE16(rx_bytes[0..2]);
    const data_off = evt_off + 48;
    const bss_off = data_off + 12;
    if (bss_off + 80 > pkt_size) return;

    var bssid: [6]u8 = undefined;
    for (&bssid, 0..) |*b, i| b.* = rx_bytes[bss_off + 8 + i];

    const ssid_len: u8 = @min(rx_bytes[bss_off + 18], 32);
    var ssid: [32]u8 = [_]u8{0} ** 32;
    for (ssid[0..ssid_len], 0..) |*b, i| b.* = rx_bytes[bss_off + 19 + i];

    const rssi: i16 = @bitCast(@as(u16, rx_bytes[bss_off + 78]) | (@as(u16, rx_bytes[bss_off + 79]) << 8));

    var found = false;
    for (&scan_results) |*r| {
        if (r.in_use and bssidMatch(&r.bssid, &bssid)) {
            if (rssi > r.rssi) r.rssi = rssi;
            found = true;
            break;
        }
    }
    if (!found and scan_count < MAX_SCAN_RESULTS) {
        scan_results[scan_count] = .{
            .bssid = bssid,
            .ssid = ssid,
            .ssid_len = ssid_len,
            .rssi = rssi,
            .in_use = true,
        };
        scan_count += 1;
    }
}

fn bssidMatch(a: *const [6]u8, b: *const [6]u8) bool {
    inline for (0..6) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub fn printScanResults(
    puts: *const fn ([]const u8) void,
    putDec: *const fn (u32) void,
    putc: *const fn (u8) void,
) void {
    puts("[scan] ");
    putDec(@intCast(scan_count));
    puts(" networks found:\n");

    const hex_chars = "0123456789abcdef";
    for (scan_results[0..scan_count]) |r| {
        if (!r.in_use) continue;

        puts("  ");
        if (r.rssi < 0) {
            puts("-");
            putDec(@intCast(-@as(i32, r.rssi)));
        } else {
            putDec(@intCast(r.rssi));
        }
        puts(" dBm  ");

        for (r.bssid, 0..) |b, i| {
            if (i > 0) putc(':');
            putc(hex_chars[b >> 4]);
            putc(hex_chars[b & 0xF]);
        }
        puts("  ");

        if (r.ssid_len == 0) {
            puts("(Hidden)");
        } else {
            for (r.ssid[0..r.ssid_len]) |ch| {
                if (ch >= 0x20 and ch < 0x7F) putc(ch) else putc('?');
            }
        }
        puts("\n");
    }
}
