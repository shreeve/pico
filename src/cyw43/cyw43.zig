// CYW43 WiFi driver — top-level module.
//
// Usage:
//   const cyw43 = @import("cyw43/cyw43.zig");
//   try cyw43.init(.pico_w);     // probe + boot
//   cyw43.ledSet(true);

pub const board = @import("board.zig");
pub const types = @import("types.zig");
pub const bus = @import("transport/bus.zig");
pub const pio_spi = @import("transport/pio_spi.zig");
pub const regs = @import("regs.zig");
pub const device = @import("device.zig");
pub const dhcp = @import("../net/dhcp.zig");
pub const arp = @import("../net/arp.zig");
pub const ipv4 = @import("../net/ipv4.zig");
pub const icmp = @import("../net/icmp.zig");
const netif = @import("../net/stack.zig");

pub const State = types.State;
pub const Error = types.Error;

pub const Board = enum { pico_w, pico2_w };

fn boardOps(b: Board) *const board.BoardOps {
    return switch (b) {
        .pico_w => &board.pico_w,
        .pico2_w => &board.pico2_w,
    };
}

/// Full init: probe bus + boot firmware.
pub fn init(b: Board) Error!void {
    try device.init(boardOps(b));
}

/// Probe only: verify SPI bus, ALP clock, chip ID. No firmware needed.
pub fn probe(b: Board) Error!void {
    try device.probe(boardOps(b));
}

/// Boot firmware after successful probe.
pub fn boot() Error!void {
    try device.boot();
}

pub fn getState() State {
    return device.getState();
}

pub fn ledSet(on: bool) Error!void {
    try device.ledSet(on);
}

pub fn gpioSet(gpio: u8, value: bool) Error!void {
    try device.gpioSet(gpio, value);
}

pub fn service() void {
    device.service();
}

pub fn getIpAddress() [4]u8 {
    return netif.stack().local_ip;
}

pub fn hasIpAddress() bool {
    return dhcp.dhcp_state == .bound;
}
