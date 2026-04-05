/// UART service — raw serial I/O for user scripts.
/// UART0 is reserved for console/debug logging.
/// UART1 is available for user applications.
const hal = @import("../platform/hal.zig");

pub const Port = enum { uart0, uart1 };

pub fn init(port: Port, baud: u32) void {
    const base = switch (port) {
        .uart0 => hal.platform.UART0_BASE,
        .uart1 => hal.platform.UART1_BASE,
    };
    hal.platform.uartInit(base, baud);
}

pub fn write(port: Port, data: []const u8) void {
    const base = switch (port) {
        .uart0 => hal.platform.UART0_BASE,
        .uart1 => hal.platform.UART1_BASE,
    };
    for (data) |byte| {
        hal.platform.uartWrite(base, byte);
    }
}
