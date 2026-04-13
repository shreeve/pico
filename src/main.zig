// pico — main entry point and cooperative superloop.
//
// Execution model:
//   Single-core cooperative superloop on RP2040. No RTOS, no threads.
//   All forward progress occurs through explicit poll() calls in the
//   main loop below. Each subsystem does bounded work per call.
//   Interrupt handlers only set flags or enqueue data; real processing
//   happens in the superloop.
//
// Boot flow:
//   1. Platform init (clocks @ 125 MHz, peripherals)
//   2. Console init (UART @ 115200)
//   3. Memory pool init
//   4. Load config from flash
//   5. Init MQuickJS VM
//   6. Init services (wifi, storage, etc.)
//   7. Load script from flash (if present)
//   8. Enter superloop

comptime {
    _ = @import("platform/startup.zig");
}

const build_config = @import("build_config");
const hal = @import("platform/hal.zig");
const rp2040 = hal.platform;
const fmt = @import("lib/fmt.zig");
const memory = @import("runtime/memory_pool.zig");
const runtime = @import("runtime/runtime.zig");
const netif = @import("net/stack.zig");
const watchdog = @import("runtime/watchdog.zig");
const engine = @import("js/runtime.zig");
const console = @import("bindings/console.zig");
const storage = @import("bindings/storage.zig");
const config = @import("config/device_config.zig");
const wifi = @import("bindings/wifi.zig");
const mqtt = @import("bindings/mqtt.zig");
const led = @import("bindings/led.zig");
const script_push = @import("net/script_push.zig");
const shell = @import("net/shell.zig");
const usb_host = @import("usb/host.zig");
const usb_ftdi = @import("usb/ftdi.zig");
const usb_js = @import("bindings/usb.zig");

comptime {
    _ = @import("bindings/console.zig");
    _ = @import("bindings/gpio.zig");
    _ = @import("bindings/led.zig");
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

const puts = fmt.puts;

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
    fmt.putDec(@intCast(netif.Stack.memoryUsage()));
    puts(" bytes\n");

    if (watchdog.shouldEnterSafeMode()) {
        puts("[boot] SAFE MODE — too many crashes\n");
        watchdog.clearCrashCount();
    }

    // 3. Memory
    memory.init();
    puts("[boot] memory pool: ");
    fmt.putDec(@intCast(memory.totalSize()));
    puts(" bytes\n");

    // 4. Config
    storage.init();
    config.load();

    // 5. JS VM
    const heap_kb = config.get().vm_heap_kb;
    puts("[boot] JS VM heap: ");
    fmt.putDec(heap_kb);
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

    // 7. Network services (TCP listeners)
    script_push.init();
    shell.init();

    // 8. Periodic timer tick (10ms, enables wfe in main loop)
    rp2040.initPeriodicTick();

    // 9. USB Host (only when built with -DUSB_HOST)
    if (build_config.usb_host) {
        usb_host.init();
        usb_js.initCallbacks();
        puts("[boot] USB host ready\n");
    }

    // 9. Try loading a script from flash
    loadStoredScript();

    // 10. Run built-in hello script if nothing stored
    puts("[boot] running built-in hello script\n");
    _ = engine.eval(hello_script, "<boot>") catch {};

    puts("[boot] uptime: ");
    fmt.putUnsigned(u64, hal.millis());
    puts(" ms\n");
    // Start watchdog (8 second timeout)
    watchdog.init(8000);
    watchdog.clearCrashCount();
    puts("[boot] watchdog armed (8s)\n");
    puts("[boot] entering superloop\n\n");

    var heartbeat: u32 = 0;
    var next_heartbeat = hal.millis() + 5000;
    // Cooperative superloop: all forward progress happens here.
    // Subsystems are polled in a fixed order each iteration.
    while (true) {
        runtime.poll();
        pollUart();
        wifi.poll();
        mqtt.poll();
        led.poll();
        if (build_config.usb_host) {
            usb_host.poll();
            usb_ftdi.poll();
        }
        netif.poll(@truncate(hal.millis()));
        watchdog.feed();

        const now = hal.millis();
        if (now >= next_heartbeat) {
            puts("[heartbeat ");
            fmt.putDec(heartbeat);
            puts("] uptime ");
            fmt.putUnsigned(u64, now / 1000);
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
    fmt.putDec(len);
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

fn pollUart() void {
    while (rp2040.uartReadAvailable(rp2040.UART0_BASE)) {
        const ch = rp2040.uartRead(rp2040.UART0_BASE);
        if (ch == '\r' or ch == '\n') {
            const cmd = cmd_buf[0..cmd_len];
            if (cmd_len == 6 and
                cmd[0] == 'r' and cmd[1] == 'e' and
                cmd[2] == 'b' and cmd[3] == 'o' and
                cmd[4] == 'o' and cmd[5] == 't')
            {
                puts("[reboot] entering BOOTSEL mode...\n");
                rp2040.resetToUsbBoot();
            } else if (cmd_len == 4 and
                cmd[0] == 'w' and cmd[1] == 'i' and
                cmd[2] == 'f' and cmd[3] == 'i')
            {
                puts("[wifi] retrying join...\n");
                _ = wifi.connect(build_config.ssid, build_config.pass);
                if (wifi.isConnected()) {
                    puts("[wifi] IP=");
                    if (wifi.getIp()) |ip| puts(ip);
                    puts("\n");
                }
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
