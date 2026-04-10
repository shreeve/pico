// console.log / console.warn / console.error → UART output.
// Also serves as the MQuickJS log function sink.
const std = @import("std");
const hal = @import("../platform/hal.zig");
const engine = @import("../js/runtime.zig");
const c = @import("../js/quickjs_api.zig");
const CC = std.builtin.CallingConvention;

const UART_BASE = hal.platform.UART0_BASE;

pub fn init() void {
    hal.platform.uartInit(UART_BASE, 115200);
}

pub fn putc(ch: u8) void {
    hal.platform.uartWrite(UART_BASE, ch);
}

pub fn puts(s: []const u8) void {
    hal.platform.uartPuts(UART_BASE, s);
}

pub fn logFunc(_: ?*anyopaque, buf: ?[*]const u8, len: usize) callconv(CC.c) void {
    if (buf) |b| {
        hal.platform.uartPuts(UART_BASE, b[0..len]);
    }
}

fn printValue(ctx: *c.JSContext, val: c.JSValue) void {
    if (c.JS_IsString(ctx, val) != 0) {
        var buf: c.JSCStringBuf = undefined;
        var len: usize = 0;
        if (c.JS_ToCStringLen(ctx, &len, val, &buf)) |ptr| {
            hal.platform.uartPuts(UART_BASE, ptr[0..len]);
        }
    } else {
        c.JS_PrintValueF(ctx, val, c.JS_DUMP_LONG);
    }
}

fn printArgs(ctx: *c.JSContext, argc: c_int, argv: ?[*]c.JSValue) void {
    const args = argv orelse return;
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i != 0) hal.platform.uartWrite(UART_BASE, ' ');
        printValue(ctx, args[@intCast(i)]);
    }
    hal.platform.uartWrite(UART_BASE, '\n');
}

pub export fn js_console_log(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (ctx) |cx| printArgs(cx, argc, argv);
    return c.JS_UNDEFINED;
}

pub export fn js_console_warn(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    puts("[WARN] ");
    if (ctx) |cx| printArgs(cx, argc, argv);
    return c.JS_UNDEFINED;
}

pub export fn js_console_error(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    puts("[ERR]  ");
    if (ctx) |cx| printArgs(cx, argc, argv);
    return c.JS_UNDEFINED;
}
