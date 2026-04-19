// test_main.zig — Staged MQuickJS bring-up test for real hardware.
//
// Validates the full critical path to JS execution:
//   Stage 1: HAL init (clocks, PLL @ 125 MHz)        — proven
//   Stage 2: Console init (UART @ 115200)             — proven pattern
//   Stage 3: Memory pool init + bounds check          — new
//   Stage 4: setjmp/longjmp smoke test                — new
//   Stage 5: MQuickJS JS_NewContext                   — new
//   Stage 6a: JS_Eval("1+1") — pure VM, no callbacks — new
//   Stage 6b: JS_Eval("console.log(...)") — callback  — THE MILESTONE
//
// Build:  zig build test-main
// Flash:  openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
//           -c "adapter speed 1000; program zig-out/bin/test-main verify reset exit"
// Serial: picocom -b 115200 /dev/cu.usbmodem201302

const deps = @import("support");

comptime {
    _ = deps.boot;
}

// Force-include exported C functions so the linker doesn't drop them.
// These are required by the generated js_stdlib (pico_stdlib_data.c).
comptime {
    _ = deps.console;
    _ = deps.gpio;
    _ = deps.led;
    _ = deps.timer;
    _ = deps.wifi;
    _ = deps.mqtt;
    _ = deps.storage;
    _ = deps.usb_js;
}

const std = @import("std");
const CC = std.builtin.CallingConvention;
const hal = deps.hal;
const rp2040 = hal.platform;
const memory = deps.memory;

// ── UART helpers (self-contained, no allocator dependency) ──────────────

fn putc(ch: u8) void {
    rp2040.uartWrite(rp2040.UART0_BASE, ch);
}

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') putc('\r');
        putc(ch);
    }
}

fn printHex32(val: u32) void {
    const hex = "0123456789ABCDEF";
    puts("0x");
    var i: u5 = 28;
    while (true) {
        putc(hex[@intCast((val >> i) & 0xF)]);
        if (i == 0) break;
        i -= 4;
    }
}

fn printU32(val: u32) void {
    var buf: [10]u8 = undefined;
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

fn printI32(val: i32) void {
    if (val < 0) {
        putc('-');
        printU32(@intCast(-val));
    } else {
        printU32(@intCast(val));
    }
}

fn printU64(val: u64) void {
    var buf: [20]u8 = undefined;
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

// ── Stage tracker for fault diagnosis ───────────────────────────────────

var current_stage: u32 = 0;

fn stage(num: u32, label: []const u8) void {
    current_stage = num;
    puts("\n--- Stage ");
    printU32(num);
    puts(": ");
    puts(label);
    puts(" ---\n");
}

fn ok() void {
    puts("  OK\n");
}

fn fail(code: i32) void {
    puts("  FAIL (code ");
    printI32(code);
    puts(")\n");
}

// ── C helpers (defined in pico_bringup.c) ────────────────────────────────

extern fn pico_test_setjmp() callconv(CC.c) c_int;
extern fn pico_js_init(heap: ?*anyopaque, size: usize) callconv(CC.c) c_int;
extern fn pico_js_set_log(wf: *const fn (?*anyopaque, ?*const anyopaque, usize) callconv(CC.c) void) callconv(CC.c) c_int;
extern fn pico_js_eval(source: [*]const u8, len: usize) callconv(CC.c) c_int;
extern fn pico_js_sizeof_jsvalue() callconv(CC.c) usize;
extern fn pico_js_sizeof_context_ptr() callconv(CC.c) usize;

// ── Log function for MQuickJS (matches JSWriteFunc signature) ───────────

fn logFunc(_: ?*anyopaque, buf: ?*const anyopaque, len: usize) callconv(CC.c) void {
    if (buf) |b| {
        const bytes: [*]const u8 = @ptrCast(b);
        rp2040.uartPuts(rp2040.UART0_BASE, bytes[0..len]);
    }
}

// ── Linker symbols ─────────────────────────────────────────────────────

extern const _heap_start: u8;
extern const _heap_end: u8;
extern const _stack_bottom: u8;
extern const _stack_top: u8;

// ── Main ───────────────────────────────────────────────────────────────

pub fn main() noreturn {
    // ── Stage 1: HAL init ───────────────────────────────────────────
    hal.init();

    // ── Stage 2: Console init ───────────────────────────────────────
    rp2040.uartInit(rp2040.UART0_BASE, 115_200);

    puts("\n\n");
    puts("========================================\n");
    puts("  pico MQuickJS bring-up test\n");
    puts("  XOSC + PLL @ 125 MHz, UART @ 115200\n");
    puts("========================================\n");

    puts("\ntimer: ");
    printU64(hal.millis());
    puts(" ms\n");

    stage(1, "HAL init");
    ok();

    stage(2, "Console + UART");
    ok();

    // ── Stage 3: Memory pool ────────────────────────────────────────
    stage(3, "Memory pool");

    puts("  heap_start: ");
    printHex32(@intFromPtr(&_heap_start));
    puts("\n  heap_end:   ");
    printHex32(@intFromPtr(&_heap_end));
    puts("\n  heap_size:  ");
    printU32(@intFromPtr(&_heap_end) - @intFromPtr(&_heap_start));
    puts(" bytes\n");
    puts("  stack_bot:  ");
    printHex32(@intFromPtr(&_stack_bottom));
    puts("\n  stack_top:  ");
    printHex32(@intFromPtr(&_stack_top));
    puts("\n");

    memory.init();

    puts("  pool total: ");
    printU32(@intCast(memory.totalSize()));
    puts(" bytes\n");
    puts("  pool used:  ");
    printU32(@intCast(memory.used()));
    puts(" bytes\n");
    puts("  pool free:  ");
    printU32(@intCast(memory.remaining()));
    puts(" bytes\n");

    // Alignment check
    const heap_base = @intFromPtr(&_heap_start);
    if (heap_base & 7 != 0) {
        puts("  WARNING: heap not 8-byte aligned!\n");
    }

    ok();

    // ── Stage 4: setjmp/longjmp ─────────────────────────────────────
    stage(4, "setjmp/longjmp");

    puts("  JSValue size: ");
    printU32(@intCast(pico_js_sizeof_jsvalue()));
    puts(" bytes\n");
    puts("  JSContext* size: ");
    printU32(@intCast(pico_js_sizeof_context_ptr()));
    puts(" bytes\n");

    const sjr = pico_test_setjmp();
    if (sjr == 1) {
        ok();
    } else {
        fail(sjr);
        puts("  setjmp/longjmp broken — cannot proceed\n");
        hang();
    }

    // ── Stage 5: JS_NewContext ───────────────────────────────────────
    stage(5, "JS_NewContext");

    const vm_heap_size: usize = 96 * 1024; // 96 KB — generous for bring-up
    const vm_heap = memory.allocVmHeap(vm_heap_size);
    if (vm_heap == null) {
        puts("  FAIL: could not allocate ");
        printU32(@intCast(vm_heap_size));
        puts(" bytes from pool\n");
        puts("  pool remaining: ");
        printU32(@intCast(memory.remaining()));
        puts(" bytes\n");
        hang();
    }
    const heap_region = vm_heap.?;

    puts("  vm heap base: ");
    printHex32(@intFromPtr(heap_region.base));
    puts("\n  vm heap size: ");
    printU32(@intCast(heap_region.size));
    puts(" bytes\n");
    puts("  pool used after alloc: ");
    printU32(@intCast(memory.used()));
    puts(" bytes\n");

    const init_result = pico_js_init(heap_region.base, heap_region.size);
    if (init_result == 1) {
        ok();
    } else {
        fail(init_result);
        puts("  JS_NewContext failed — cannot proceed\n");
        hang();
    }

    // Set log function
    _ = pico_js_set_log(&logFunc);

    // ── Stage 6a: JS_Eval("1+1") — pure VM, no callbacks ───────────
    stage(6, "JS_Eval pure (no callbacks)");

    const simple_src = "1+1;\x00";
    const eval_simple = pico_js_eval(simple_src.ptr, simple_src.len - 1);
    if (eval_simple == 1) {
        ok();
    } else {
        fail(eval_simple);
        puts("  basic eval failed — VM core broken\n");
        hang();
    }

    // ── Stage 6b: console.log — THE MILESTONE ───────────────────────
    stage(7, "console.log('pico is alive!')");

    const hello_src = "console.log('pico is alive!');\x00";
    const eval_hello = pico_js_eval(hello_src.ptr, hello_src.len - 1);
    if (eval_hello == 1) {
        ok();
    } else {
        fail(eval_hello);
        puts("  console.log eval failed\n");
    }

    // ── Done ────────────────────────────────────────────────────────
    puts("\n========================================\n");
    if (eval_hello == 1) {
        puts("  ALL STAGES PASSED\n");
        puts("  pico milestone ACHIEVED!\n");
    } else {
        puts("  MILESTONE NOT YET REACHED\n");
    }
    puts("========================================\n\n");

    // Heartbeat loop — repeat status so it's visible whenever picocom connects
    var count: u32 = 0;
    var next = hal.millis() + 3000;
    while (true) {
        puts("\n========================================\n");
        if (eval_hello == 1) {
            puts("  ALL STAGES PASSED\n");
            puts("  pico milestone ACHIEVED!\n");
        } else {
            puts("  MILESTONE NOT YET REACHED\n");
            puts("  Stage 6 (1+1): ");
            printI32(eval_simple);
            puts("  Stage 7 (console.log): ");
            printI32(eval_hello);
            puts("\n");
        }
        puts("  heartbeat ");
        printU32(count);
        puts(" uptime ");
        printU64(hal.millis());
        puts(" ms\n");
        puts("========================================\n");
        count +%= 1;
        while (hal.millis() < next) {}
        next += 3000;
    }
}

// ── Panic / fault handlers ──────────────────────────────────────────────

pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        puts("\n!!! PANIC at stage ");
        printU32(current_stage);
        puts(": ");
        puts(msg);
        puts(" !!!\n");
        hang();
    }
}.call;

pub fn hardFault() void {
    puts("\n!!! HARD FAULT at stage ");
    printU32(current_stage);
    puts(" !!!\n");
    hang();
}

fn hang() noreturn {
    var n: u32 = 0;
    while (true) {
        puts("HUNG at stage ");
        printU32(current_stage);
        puts(" (");
        printU32(n);
        puts(")\n");
        n +%= 1;
        hal.delayMs(2000);
    }
}
