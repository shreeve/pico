/// I2C service (stub).
const hal = @import("../platform/hal.zig");

pub const Bus = enum { i2c0, i2c1 };

pub fn init(bus: Bus, freq_hz: u32) void {
    _ = bus;
    _ = freq_hz;
    // TODO: configure I2C peripheral
}

pub fn writeRead(bus: Bus, addr: u7, tx: []const u8, rx: []u8) bool {
    _ = bus;
    _ = addr;
    _ = tx;
    _ = rx;
    // TODO: I2C write-then-read transaction
    return false;
}

pub fn write(bus: Bus, addr: u7, data: []const u8) bool {
    _ = bus;
    _ = addr;
    _ = data;
    return false;
}

pub fn read(bus: Bus, addr: u7, buf: []u8) bool {
    _ = bus;
    _ = addr;
    _ = buf;
    return false;
}
