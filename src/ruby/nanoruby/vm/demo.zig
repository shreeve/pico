const std = @import("std");
const VM = @import("vm.zig").VM;
const IrFunc = @import("vm.zig").IrFunc;
const Value = @import("value.zig").Value;
const Assembler = @import("assembler.zig").Assembler;

/// Build the demo program: 40 + 2 = 42
/// Equivalent Ruby: a = 40; b = 2; a + b
fn buildDemo(a: *Assembler) IrFunc {
    const k40 = a.addConst(Value.fromFixnum(40).?);
    const k2 = a.addConst(Value.fromFixnum(2).?);

    a.emitAB(.LOAD_CONST, 0, k40); // r0 = 40
    a.emitAB(.LOAD_CONST, 1, k2); // r1 = 2
    a.emitA(.ADD, 0); // r0 = r0 + r1
    a.emitA(.RETURN, 0); // return r0

    return a.build(2);
}

/// Write function for firmware console output.
/// On host: writes to stderr. On firmware: replace with HAL putc.
/// Under `zig test` the test binary speaks a binary protocol on its
/// stdout/stderr; plain text writes disrupt the build-runner's progress
/// renderer, so we silence console output during tests.
fn writeConsole(bytes: []const u8) void {
    const builtin = @import("builtin");
    if (builtin.is_test) return;
    if (builtin.os.tag == .freestanding) {
        // Firmware: would call hal.puts() here — stub for now
        @trap();
    } else {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
    }
}

fn putChar(c: u8) void {
    writeConsole(&[_]u8{c});
}

fn putDecimal(n: i32) void {
    var buf: [12]u8 = undefined;
    var val: u32 = if (n < 0) blk: {
        putChar('-');
        break :blk @intCast(-@as(i64, n));
    } else @intCast(n);

    var len: usize = 0;
    if (val == 0) {
        putChar('0');
        return;
    }
    while (val > 0) : (len += 1) {
        buf[len] = @truncate(val % 10 + '0');
        val /= 10;
    }
    while (len > 0) {
        len -= 1;
        putChar(buf[len]);
    }
}

/// Run the nanoruby demo.
/// Returns the result value (for testing) and prints to console.
pub fn run() Value {
    writeConsole("[nanoruby] VM demo starting\n");

    var a = Assembler.init();
    const func = buildDemo(&a);
    var vm = VM.initDefault();

    writeConsole("[nanoruby] executing: 40 + 2\n");
    const result = vm.execute(&func);

    switch (result) {
        .ok => |val| {
            writeConsole("[nanoruby] result = ");
            if (val.asFixnum()) |n| {
                putDecimal(n);
            } else if (val.isNil()) {
                writeConsole("nil");
            } else if (val.isTrue()) {
                writeConsole("true");
            } else if (val.isFalse()) {
                writeConsole("false");
            } else {
                writeConsole("???");
            }
            writeConsole("\n");
            return val;
        },
        .err => |e| {
            writeConsole("[nanoruby] ERROR: ");
            writeConsole(@errorName(e));
            writeConsole("\n");
            return Value.nil;
        },
    }
}

/// Host entry point for testing the demo standalone.
pub fn main() void {
    const result = run();
    if (result.asFixnum()) |n| {
        if (n == 42) {
            writeConsole("[nanoruby] PASS: got 42\n");
        } else {
            writeConsole("[nanoruby] FAIL: expected 42\n");
        }
    } else {
        writeConsole("[nanoruby] FAIL: not a fixnum\n");
    }
}

test "demo produces 42" {
    const result = run();
    try std.testing.expectEqual(@as(i32, 42), result.asFixnum().?);
}
