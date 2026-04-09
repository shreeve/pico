// pico main entry point.
//
// Boot flow:
//   1. Platform init (clocks @ 125 MHz, peripherals)
//   2. Console init (UART @ 115200)
//   3. Memory pool init
//   4. Load config from flash
//   5. Init MQuickJS VM
//   6. Init services (wifi, storage, etc.)
//   7. Load script from flash (if present)
//   8. Start event loop

comptime {
    _ = @import("platform/boot.zig");
}

const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const memory = @import("runtime/memory.zig");
const event_loop = @import("runtime/event_loop.zig");
const engine = @import("vm/engine.zig");
const console = @import("services/console.zig");
const storage = @import("services/storage.zig");
const config = @import("config/config.zig");
const usb_host = @import("usb/host.zig");
const usb_ftdi = @import("usb/ftdi.zig");
const usb_js = @import("usb/js.zig");

comptime {
    _ = @import("services/console.zig");
    _ = @import("services/gpio.zig");
    _ = @import("services/timer.zig");
    _ = @import("services/wifi.zig"); // exports needed by C function table
    _ = @import("services/mqtt.zig"); // exports needed by C function table
    _ = @import("services/storage.zig");
    _ = @import("usb/js.zig");
}

const BANNER =
    \\
    \\  ┌─────────────────────────┐
    \\  │  pico v0.1.0        │
    \\  │  flash once, script ∞   │
    \\  └─────────────────────────┘
    \\
;

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

pub fn main() noreturn {
    // 1. Platform init (clocks @ 125 MHz)
    hal.init();

    // 2. Console (UART @ 115200)
    console.init();

    // Delay so picocom can connect after debug probe replug
    hal.delayMs(5000);

    puts(BANNER);
    puts("[boot] platform: RP2040 @ 125 MHz\n");

    // 3. Memory
    memory.init();
    puts("[boot] memory pool: ");
    printU32(@intCast(memory.totalSize()));
    puts(" bytes\n");

    // 4. Config
    storage.init();
    config.load();

    // 5. JS VM
    const heap_kb = config.get().vm_heap_kb;
    puts("[boot] JS VM heap: ");
    printU32(heap_kb);
    puts(" KB\n");

    engine.init(.{
        .heap_size = @as(usize, heap_kb) * 1024,
        .log_fn = &console.logFunc,
    }) catch {
        puts("[boot] FATAL: VM init failed\n");
        hang();
    };
    puts("[boot] MQuickJS VM ready\n");

    // 6. USB Host
    usb_host.init();
    usb_js.initCallbacks();

    // Register I/O poll callbacks
    event_loop.registerIO(usb_host.poll) catch {};
    event_loop.registerIO(usb_ftdi.pollTick) catch {};

    // 9. Try loading a script from flash
    loadStoredScript();

    // 10. Run built-in hello script if nothing stored
    puts("[boot] running built-in hello script\n");
    _ = engine.eval(hello_script, "<boot>") catch {};

    puts("[boot] uptime: ");
    printU64(hal.millis());
    puts(" ms\n");
    puts("[boot] entering event loop\n\n");

    // Event loop with periodic heartbeat
    var heartbeat: u32 = 0;
    var next_heartbeat = hal.millis() + 5000;
    while (true) {
        event_loop.step();

        const now = hal.millis();
        if (now >= next_heartbeat) {
            puts("[heartbeat ");
            printU32(heartbeat);
            puts("] uptime ");
            printU64(now / 1000);
            puts("s\n");
            heartbeat +%= 1;
            next_heartbeat = now + 5000;
        }
    }
}

fn loadStoredScript() void {
    const flash_layout = @import("config/flash.zig");
    const base = flash_layout.flashToPtr(flash_layout.SCRIPT_BASE);

    if (base[0] == 0xFF) {
        puts("[boot] no stored script\n");
        return;
    }

    const len = @as(u32, base[0]) |
        (@as(u32, base[1]) << 8) |
        (@as(u32, base[2]) << 16) |
        (@as(u32, base[3]) << 24);

    if (len == 0 or len > flash_layout.SCRIPT_SIZE - 4) {
        puts("[boot] stored script invalid\n");
        return;
    }

    const script = base[4 .. 4 + len];
    puts("[boot] loading stored script (");
    printU32(len);
    puts(" bytes)\n");
    _ = engine.eval(script, "<flash>") catch {
        puts("[boot] stored script error\n");
    };
}

const hello_script =
    \\console.log("pico is alive!");
    \\console.log("uptime: " + timer.millis() + " ms");
    \\
;

fn hang() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn usbIrq() void {
    usb_host.isr();
}

pub const panic = @import("runtime/panic.zig").panic;
pub const hardFault = @import("runtime/panic.zig").hardFault;
