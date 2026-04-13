// Shared debug output helpers.
//
// Centralized UART printing for boot diagnostics, driver messages, and
// protocol logging. All output goes through the platform UART via
// console.putc / console.puts.

const console = @import("../bindings/console.zig");

pub const putc = console.putc;
pub const puts = console.puts;

pub fn putDec(val: u32) void {
    putUnsigned(u32, val);
}

pub fn putHex32(val: u32) void {
    const hex = "0123456789abcdef";
    var buf: [10]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    inline for (0..8) |idx| {
        const shift: u5 = @intCast(28 - idx * 4);
        buf[2 + idx] = hex[@as(usize, (val >> shift) & 0xF)];
    }
    puts(&buf);
}

pub fn putIp(addr: [4]u8) void {
    for (addr, 0..) |b, i| {
        if (i > 0) putc('.');
        putDec(b);
    }
}

pub fn putUnsigned(comptime T: type, val: T) void {
    comptime {
        const info = @typeInfo(T);
        if (info != .int or info.int.signedness != .unsigned)
            @compileError("putUnsigned requires an unsigned integer type");
    }
    const buf_len = switch (@bitSizeOf(T)) {
        8 => 3,
        16 => 5,
        32 => 10,
        64 => 20,
        else => 20,
    };
    var buf: [buf_len]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) {
        putc('0');
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    puts(buf[i..]);
}
