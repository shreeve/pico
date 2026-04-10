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
    _ = @import("platform/startup.zig");
}

const build_config = @import("build_config");
const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const memory = @import("runtime/memory_pool.zig");
const event_loop = @import("runtime/event_loop.zig");
const netif = @import("net/global_stack.zig");
const watchdog = @import("runtime/watchdog.zig");
const engine = @import("js/runtime.zig");
const console = @import("bindings/console.zig");
const storage = @import("bindings/storage.zig");
const config = @import("config/device_config.zig");
const wifi = @import("bindings/wifi.zig");
const usb_host = @import("usb/host.zig");
const usb_ftdi = @import("usb/ftdi.zig");
const usb_js = @import("bindings/usb.zig");

comptime {
    _ = @import("bindings/console.zig");
    _ = @import("bindings/gpio.zig");
    _ = @import("bindings/timers.zig");
    _ = @import("bindings/wifi.zig"); // exports needed by C function table
    _ = @import("bindings/mqtt.zig"); // exports needed by C function table
    _ = @import("bindings/storage.zig");
    _ = @import("bindings/usb.zig");
}

const BANNER =
    \\
    \\  ┌─────────────────────────┐
    \\  │  pico v0.1.0            │
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

    if (watchdog.wasWatchdogReset()) {
        watchdog.incrementCrashCount();
    }

    puts(BANNER);
    puts("[boot] platform: RP2040 @ 125 MHz\n");
    puts("[boot] net stack: ");
    printU32(@intCast(netif.Stack.memoryUsage()));
    puts(" bytes\n");

    if (watchdog.shouldEnterSafeMode()) {
        puts("[boot] SAFE MODE — too many crashes\n");
        watchdog.clearCrashCount();
    }

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

    // 6. WiFi (CYW43 boot — join + DHCP handled by boot.zig if -DSSID set)
    wifi.init();
    if (wifi.isConnected()) {
        puts("[boot] WiFi IP=");
        if (wifi.getIp()) |ip| puts(ip);
        puts("\n");
    }

    // 7. Periodic timer tick (10ms, enables wfe in main loop)
    rp2040.initPeriodicTick();

    // 8. USB Host (only when built with -DUSB_HOST)
    if (build_config.usb_host) {
        usb_host.init();
        usb_js.initCallbacks();
        event_loop.registerIO(usb_host.poll) catch {};
        event_loop.registerIO(usb_ftdi.pollTick) catch {};
        puts("[boot] USB host ready\n");
    }

    // 9. Try loading a script from flash
    loadStoredScript();

    // 10. Run built-in hello script if nothing stored
    puts("[boot] running built-in hello script\n");
    _ = engine.eval(hello_script, "<boot>") catch {};

    puts("[boot] uptime: ");
    printU64(hal.millis());
    puts(" ms\n");
    // Start watchdog (8 second timeout)
    watchdog.init(8000);
    watchdog.clearCrashCount();
    puts("[boot] watchdog armed (8s)\n");
    puts("[boot] entering event loop\n\n");

    // Event loop with periodic heartbeat
    var heartbeat: u32 = 0;
    var next_heartbeat = hal.millis() + 5000;
    while (true) {
        _ = event_loop.step();
        pollUartCmd();
        wifi.poll();
        netif.tick();
        watchdog.feed();

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

        asm volatile ("wfe");
    }
}

fn loadStoredScript() void {
    const flash_layout = @import("config/flash_layout.zig");
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

// ── UART command listener ────────────────────────────────────────────

var cmd_buf: [16]u8 = undefined;
var cmd_len: usize = 0;

fn pollUartCmd() void {
    while (rp2040.uartReadAvailable(rp2040.UART0_BASE)) {
        const ch = rp2040.uartRead(rp2040.UART0_BASE);
        if (ch == '\r' or ch == '\n') {
            if (cmd_len == 6 and
                cmd_buf[0] == 'r' and cmd_buf[1] == 'e' and
                cmd_buf[2] == 'b' and cmd_buf[3] == 'o' and
                cmd_buf[4] == 'o' and cmd_buf[5] == 't')
            {
                puts("[reboot] entering BOOTSEL mode...\n");
                rp2040.resetToUsbBoot();
            }
            cmd_len = 0;
        } else if (cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = ch;
            cmd_len += 1;
        } else {
            cmd_len = 0;
        }
    }
}

fn hang() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn timerIrq0() void {
    rp2040.timerIrq0Handler();
}

pub fn usbIrq() void {
    if (build_config.usb_host) usb_host.isr();
}

pub const panic = @import("runtime/panic.zig").panic;
pub const hardFault = @import("runtime/panic.zig").hardFault;
