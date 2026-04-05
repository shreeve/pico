const regs = @import("../regs.zig");
const ioctl = @import("ioctl.zig");

pub fn gpioSet(
    do_ioctl: *const fn (u32, u32, u8, []u8) anyerror!void,
    gpio_num: u8,
    value: bool,
) anyerror!void {
    var payload: [8 + 8]u8 = undefined;
    @memcpy(payload[0..8], "gpioout\x00");

    const mask = @as(u32, 1) << @as(u5, @intCast(gpio_num));
    ioctl.writeLE32(@ptrCast(payload[8..12]), mask);
    ioctl.writeLE32(@ptrCast(payload[12..16]), if (value) mask else 0);

    try do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, &payload);
}

pub fn ledSet(
    gpio_set: *const fn (u8, bool) anyerror!void,
    on: bool,
) anyerror!void {
    try gpio_set(regs.CYW43_GPIO_LED, on);
}
