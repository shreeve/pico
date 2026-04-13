const regs = @import("../regs.zig");
const hal = @import("../../platform/hal.zig");
const ioctl = @import("ioctl.zig");

pub const JoinState = enum { idle, joining, success, failed };
pub var join_state: JoinState = .idle;

pub fn joinWpa2(
    ssid: []const u8,
    passphrase: []const u8,
    do_ioctl: *const fn (u32, u32, u8, []u8) anyerror!void,
    set_ioctl_u32: *const fn (u32, u8, u32) anyerror!void,
    set_bsscfg_iovar_u32: *const fn ([]const u8, u32, u32) anyerror!void,
    poll_device: *const fn () ioctl.PollResult,
    service_event: *const fn () void,
    puts: *const fn ([]const u8) void,
) anyerror!void {
    if (ssid.len == 0 or ssid.len > 32) return error.IoctlTimeout;
    if (passphrase.len < 8 or passphrase.len > 63) return error.IoctlTimeout;

    join_state = .joining;

    puts("[join] configuring WPA2-PSK...\n");

    var disassoc_buf: [4]u8 = [_]u8{0} ** 4;
    do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_DISASSOC, 0, &disassoc_buf) catch {};
    hal.delayMs(100);

    // Sequence matches Pico SDK cyw43_ll_wifi_join exactly
    try set_ioctl_u32(regs.IOCTL_CMD_SET_WSEC, 0, regs.WSEC_AES);

    set_bsscfg_iovar_u32("bsscfg:sup_wpa", 0, 1) catch {};
    set_bsscfg_iovar_u32("bsscfg:sup_wpa2_eapver", 0, 0xFFFFFFFF) catch {};
    set_bsscfg_iovar_u32("bsscfg:sup_wpa_tmo", 0, 2500) catch {};

    var pmk_buf: [68]u8 = [_]u8{0} ** 68;
    ioctl.writeLE16(@ptrCast(pmk_buf[0..2]), @intCast(passphrase.len));
    ioctl.writeLE16(@ptrCast(pmk_buf[2..4]), regs.WSEC_PASSPHRASE);
    @memcpy(pmk_buf[4..][0..passphrase.len], passphrase);
    try do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_WSEC_PMK, 0, &pmk_buf);

    try set_ioctl_u32(regs.IOCTL_CMD_SET_INFRA, 0, 1);
    try set_ioctl_u32(regs.IOCTL_CMD_SET_AUTH, 0, 0);
    try set_ioctl_u32(regs.IOCTL_CMD_SET_WPA_AUTH, 0, regs.WPA2_AUTH_PSK);

    var ssid_buf: [36]u8 = [_]u8{0} ** 36;
    ioctl.writeLE32(@ptrCast(ssid_buf[0..4]), @intCast(ssid.len));
    @memcpy(ssid_buf[4..][0..ssid.len], ssid);
    try do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_SSID, 0, &ssid_buf);
    puts("[join] SSID set, waiting for association...\n");

    var timeout: u32 = 0;
    while (timeout < 15000) : (timeout += 1) {
        const result = poll_device();
        if (result == .event) {
            service_event();
        }
        if (join_state == .success) {
            puts("[join] associated!\n");
            return;
        }
        if (join_state == .failed) {
            puts("[join] failed\n");
            return error.IoctlTimeout;
        }
        hal.delayMs(1);
    }

    puts("[join] timeout\n");
    join_state = .idle;
    return error.IoctlTimeout;
}
