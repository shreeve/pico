// Flash UART test — VECTOR TABLE at 0x10000100 (required by boot ROM).

const std = @import("std");
const CC = std.builtin.CallingConvention;

inline fn w(addr: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
}
inline fn r(addr: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn putc(ch: u8) void {
    while ((r(0x4003_4018) & (1 << 5)) != 0) {}
    w(0x4003_4000, ch);
}
fn puts(s: []const u8) void {
    for (s) |ch| putc(ch);
}
fn printU32(val: u32) void {
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) { putc('0'); return; }
    while (n > 0) { i -= 1; buf[i] = @intCast(n % 10 + '0'); n /= 10; }
    puts(buf[i..]);
}

export fn _reset_handler() callconv(CC.c) noreturn {
    // Enable XOSC — always write full CTRL (FREQ_RANGE + ENABLE)
    w(0x4002_400C, 47);                    // STARTUP delay
    w(0x4002_4000, 0xFAB_AA0);            // CTRL: ENABLE=0xFAB, FREQ_RANGE=0xAA0
    while ((r(0x4002_4004) & (1 << 31)) == 0) {}

    // Switch clk_ref to XOSC, clk_sys stays on ref = 12 MHz
    w(0x4000_8030, 0x2);
    w(0x4000_803C, 0x0);

    // Enable clk_peri = clk_sys (UART needs this to come out of reset)
    w(0x4000_8048, (1 << 11));

    // Deassert UART0(22), IO_BANK0(5), PADS_BANK0(8)
    w(0x4000_F000, (1 << 22) | (1 << 5) | (1 << 8));
    while ((r(0x4000_C008) & ((1 << 22) | (1 << 5) | (1 << 8))) != ((1 << 22) | (1 << 5) | (1 << 8))) {}

    // GP0 = UART0_TX (func 2)
    w(0x4001_4004, 2);

    // UART0 at 115200 baud (12 MHz XOSC): IBRD=6, FBRD=33
    w(0x4003_4024, 6);
    w(0x4003_4028, 33);
    w(0x4003_402C, (3 << 5) | (1 << 4));
    w(0x4003_4030, (1 << 0) | (1 << 8));

    puts("\r\n\r\n");
    puts("========================\r\n");
    puts("  pico lives!\r\n");
    puts("  Zig on RP2040!\r\n");
    puts("========================\r\n");
    puts("\r\n");

    var count: u32 = 0;
    while (true) {
        puts("tick ");
        printU32(count);
        puts("\r\n");
        count +%= 1;
        var i: u32 = 0;
        while (i < 500_000) : (i += 1) asm volatile ("nop");
    }
}

export fn _default_handler() callconv(CC.c) void {
    while (true) asm volatile ("nop");
}

// VECTOR TABLE at 0x10000100 — boot ROM reads SP and reset handler from here
comptime {
    asm (
        \\.section .vectors, "ax"
        \\.balign 4
        \\.word _stack_top
        \\.word _reset_handler
        \\.word _default_handler
        \\.word _default_handler
    );
}

extern const _stack_top: u8;
