/// SPI service (stub).
/// Used internally for CYW43 communication and available to user scripts.
const hal = @import("../platform/hal.zig");

pub const Bus = enum { spi0, spi1 };

pub fn init(bus: Bus, freq_hz: u32) void {
    _ = bus;
    _ = freq_hz;
    // TODO: configure SPI peripheral
}

pub fn transfer(bus: Bus, tx: []const u8, rx: []u8) void {
    _ = bus;
    _ = tx;
    _ = rx;
    // TODO: full-duplex SPI transfer
}

pub fn write(bus: Bus, data: []const u8) void {
    _ = bus;
    _ = data;
    // TODO: write-only SPI
}
