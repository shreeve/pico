// HAL integration test — validates the full clock init path on real hardware.
// Uses boot.zig (proper vector table + BSS/data init), rp2040.zig HAL
// (XOSC -> PLL -> 125 MHz), and UART at 115200 baud through the HAL API.
//
// Build:  zig build test-hal
// Flash:  openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
//           -c "adapter speed 1000; program zig-out/bin/test-hal verify reset exit"
// Serial: picocom -b 115200 /dev/cu.usbmodem201302

const deps = @import("support");

comptime {
    _ = deps.boot;
}

const hal = deps.hal;
const rp2040 = hal.platform;

fn putc(ch: u8) void {
    rp2040.uartWrite(rp2040.UART0_BASE, ch);
}

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') putc('\r');
        putc(ch);
    }
}

fn printU32(val: u32) void {
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) { putc('0'); return; }
    while (n > 0) { i -= 1; buf[i] = @intCast(n % 10 + '0'); n /= 10; }
    puts(buf[i..]);
}

fn printU64(val: u64) void {
    var buf: [20]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) { putc('0'); return; }
    while (n > 0) { i -= 1; buf[i] = @intCast(n % 10 + '0'); n /= 10; }
    puts(buf[i..]);
}

pub fn main() noreturn {
    // Full HAL init: XOSC -> PLL (125 MHz) -> clk_sys -> clk_peri -> peripherals
    hal.init();

    // UART0 at 115200 via the HAL (uses 125 MHz clock)
    rp2040.uartInit(rp2040.UART0_BASE, 115_200);

    puts("\n\n");
    puts("================================\n");
    puts("  pico HAL test\n");
    puts("  XOSC + PLL @ 125 MHz\n");
    puts("  UART @ 115200 baud\n");
    puts("================================\n");
    puts("\n");

    puts("timer now: ");
    printU64(hal.millis());
    puts(" ms\n\n");

    var count: u32 = 0;
    var next = hal.millis() + 1000;
    while (true) {
        puts("tick ");
        printU32(count);
        puts(" (");
        printU64(hal.millis());
        puts(" ms)\n");
        count +%= 1;
        while (hal.millis() < next) {}
        next += 1000;
    }
}

pub const panic = struct {
    pub fn call(msg: []const u8, _: ?usize) noreturn {
        puts("PANIC: ");
        puts(msg);
        puts("\n");
        while (true) asm volatile ("nop");
    }
}.call;
