const types = @import("../types.zig");
const dhcp = @import("../../net/dhcp.zig");
const tcp = @import("../../net/tcp.zig");
const ioctl = @import("../control/ioctl.zig");

pub fn service(
    state: *types.State,
    poll_device: *const fn () ioctl.PollResult,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    rx_buf: *[2048 / 4]u32,
) void {
    if (state.* == .uninitialized or state.* == .err) return;
    while (true) {
        const result = poll_device();
        if (result == .none) break;
        switch (result) {
            .event => handle_event(@as([*]const u8, @ptrCast(rx_buf))),
            .data => handle_data(),
            .control => {},
            .none => unreachable,
        }
    }
    dhcp.tick();
    tcp.tick();
}
