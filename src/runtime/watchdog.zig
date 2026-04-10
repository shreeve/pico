// Watchdog timer — resets the device if the main loop stalls.
//
// Uses the RP2040's built-in watchdog peripheral. The main event loop
// must call feed() periodically. If it doesn't (hung JS, network flood,
// hardware fault), the watchdog resets the MCU.
//
// Also tracks crash count via the watchdog scratch registers so the
// bootloader/app can detect repeated crashes and enter safe mode.

const hal = @import("../platform/hal.zig");

const WATCHDOG_BASE: u32 = 0x4005_8000;
const WATCHDOG_CTRL = WATCHDOG_BASE + 0x00;
const WATCHDOG_LOAD = WATCHDOG_BASE + 0x04;
const WATCHDOG_REASON = WATCHDOG_BASE + 0x08;
const WATCHDOG_SCRATCH0 = WATCHDOG_BASE + 0x0C;
const WATCHDOG_SCRATCH4 = WATCHDOG_BASE + 0x1C;

const MAGIC: u32 = 0x57444F47; // "WDOG"
const MAX_CRASHES_BEFORE_SAFE_MODE = 3;

var enabled = false;
var reload_val: u32 = 0;

pub fn init(timeout_ms: u32) void {
    reload_val = timeout_ms * 1000;
    hal.regWrite(WATCHDOG_LOAD, reload_val);
    hal.regWrite(WATCHDOG_CTRL, (1 << 30) | reload_val);
    enabled = true;
}

pub fn feed() void {
    if (!enabled) return;
    hal.regWrite(WATCHDOG_LOAD, reload_val);
}

pub fn wasWatchdogReset() bool {
    return (hal.regRead(WATCHDOG_REASON) & 0x01) != 0;
}

pub fn getCrashCount() u32 {
    if (hal.regRead(WATCHDOG_SCRATCH4) != MAGIC) return 0;
    return hal.regRead(WATCHDOG_SCRATCH0);
}

pub fn incrementCrashCount() void {
    var count = getCrashCount();
    count += 1;
    hal.regWrite(WATCHDOG_SCRATCH0, count);
    hal.regWrite(WATCHDOG_SCRATCH4, MAGIC);
}

pub fn clearCrashCount() void {
    hal.regWrite(WATCHDOG_SCRATCH0, 0);
    hal.regWrite(WATCHDOG_SCRATCH4, MAGIC);
}

pub fn shouldEnterSafeMode() bool {
    return getCrashCount() >= MAX_CRASHES_BEFORE_SAFE_MODE;
}
