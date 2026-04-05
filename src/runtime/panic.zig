// Panic / fault handler for the firmware.
const hal = @import("../platform/hal.zig");

const UART_BASE = hal.platform.UART0_BASE;

fn uartEmergencyWrite(s: []const u8) void {
    for (s) |byte| {
        if (byte == '\n') hal.platform.uartWrite(UART_BASE, '\r');
        hal.platform.uartWrite(UART_BASE, byte);
    }
}

pub fn hardFault() void {
    uartEmergencyWrite("\n!!! HARD FAULT !!!\n");
    hang();
}

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    uartEmergencyWrite("\n!!! PANIC: ");
    uartEmergencyWrite(msg);
    uartEmergencyWrite(" !!!\n");
    hang();
}

fn hang() noreturn {
    asm volatile ("cpsid i");
    while (true) {
        asm volatile ("wfi");
    }
}
