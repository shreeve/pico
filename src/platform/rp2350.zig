/// RP2350 (ARM Cortex-M33) platform driver
/// - 520 KB SRAM (0x2000_0000 .. 0x2008_1FFF)
/// - 4 MB Flash  (0x1000_0000, XIP)
/// - 150 MHz default system clock
/// - Optional FPU, TrustZone, dual-core
const hal = @import("hal.zig");

// ── Base addresses ─────────────────────────────────────────────────────

pub const SRAM_BASE: u32 = 0x2000_0000;
pub const SRAM_SIZE: u32 = 520 * 1024;
pub const FLASH_BASE: u32 = 0x1000_0000;
pub const FLASH_SIZE: u32 = 4 * 1024 * 1024;
pub const XIP_BASE: u32 = FLASH_BASE;

// Peripherals
pub const RESETS_BASE: u32 = 0x4002_0000;
pub const CLOCKS_BASE: u32 = 0x4001_0000;
pub const XOSC_BASE: u32 = 0x4004_8000;
pub const PLL_SYS_BASE: u32 = 0x4005_0000;
pub const PLL_USB_BASE: u32 = 0x4005_8000;
pub const TIMER0_BASE: u32 = 0x400B_0000;
pub const WATCHDOG_BASE: u32 = 0x400D_8000;

// IO
pub const IO_BANK0_BASE: u32 = 0x4002_8000;
pub const PADS_BANK0_BASE: u32 = 0x4003_8000;
pub const SIO_BASE: u32 = 0xD000_0000;

// UART
pub const UART0_BASE: u32 = 0x4007_0000;
pub const UART1_BASE: u32 = 0x4007_8000;

// SPI
pub const SPI0_BASE: u32 = 0x4008_0000;
pub const SPI1_BASE: u32 = 0x4008_8000;

// I2C
pub const I2C0_BASE: u32 = 0x4009_0000;
pub const I2C1_BASE: u32 = 0x4009_8000;

// PIO
pub const PIO0_BASE: u32 = 0x5020_0000;
pub const PIO1_BASE: u32 = 0x5030_0000;
pub const PIO2_BASE: u32 = 0x5040_0000;

// ── System clock configuration ─────────────────────────────────────────

pub const SYS_CLK_HZ: u32 = 150_000_000;
pub const XOSC_MHZ: u32 = 12;

// ── Reset subsystem ────────────────────────────────────────────────────

const RESETS_RESET = RESETS_BASE + 0x00;
const RESETS_RESET_DONE = RESETS_BASE + 0x08;

const RESET_UART0: u32 = 1 << 24;
const RESET_UART1: u32 = 1 << 25;
const RESET_IO_BANK0: u32 = 1 << 5;
const RESET_PADS_BANK0: u32 = 1 << 9;
const RESET_TIMER0: u32 = 1 << 22;

// ── UART registers (PL011 compatible, same offsets as RP2040) ──────────

pub const UART_DR = 0x000;
pub const UART_FR = 0x018;
pub const UART_IBRD = 0x024;
pub const UART_FBRD = 0x028;
pub const UART_LCR_H = 0x02C;
pub const UART_CR = 0x030;
pub const UART_FR_TXFF: u32 = 1 << 5;

// ── Initialization ─────────────────────────────────────────────────────

pub fn init() void {
    initClocks();
    initPeripherals();
}

fn initClocks() void {
    // Enable XOSC
    hal.regWrite(XOSC_BASE + 0x00, 0xAA0);
    hal.regWrite(XOSC_BASE + 0x0C, 47);
    hal.regSet(XOSC_BASE + 0x00, 0xFAB000);
    while (hal.regRead(XOSC_BASE + 0x04) & (1 << 31) == 0) {}

    // Configure PLL_SYS for 150 MHz (12 MHz * 125 / 5 / 2)
    hal.regClr(RESETS_RESET, 1 << 14);
    while (hal.regRead(RESETS_RESET_DONE) & (1 << 14) == 0) {}

    hal.regWrite(PLL_SYS_BASE + 0x08, 1);
    hal.regWrite(PLL_SYS_BASE + 0x04, 125);
    hal.regWrite(PLL_SYS_BASE + 0x08, 0);
    while (hal.regRead(PLL_SYS_BASE + 0x00) & (1 << 31) == 0) {}
    hal.regWrite(PLL_SYS_BASE + 0x0C, (5 - 1) << 16 | (2 - 1) << 12);

    // Switch system clock to PLL
    hal.regWrite(CLOCKS_BASE + 0x3C, 0);
    hal.regWrite(CLOCKS_BASE + 0x40, 1);
}

fn initPeripherals() void {
    const required = RESET_IO_BANK0 | RESET_PADS_BANK0 | RESET_UART0 | RESET_TIMER0;
    hal.regClr(RESETS_RESET, required);
    while (hal.regRead(RESETS_RESET_DONE) & required != required) {}
}

// ── Timer (64-bit microsecond) ─────────────────────────────────────────

const TIMER_TIMELR = TIMER0_BASE + 0x0C;
const TIMER_TIMEHR = TIMER0_BASE + 0x08;

pub fn timerReadUs() u64 {
    const lo: u64 = hal.regRead(TIMER_TIMELR);
    const hi: u64 = hal.regRead(TIMER_TIMEHR);
    return (hi << 32) | lo;
}

pub fn millis() u64 {
    return timerReadUs() / 1000;
}

// ── UART ───────────────────────────────────────────────────────────────

pub fn uartInit(base: u32, baud: u32) void {
    const baud_div = (SYS_CLK_HZ * 4) / baud;
    const ibrd = baud_div >> 6;
    const fbrd = baud_div & 0x3F;

    hal.regWrite(base + UART_IBRD, ibrd);
    hal.regWrite(base + UART_FBRD, fbrd);
    hal.regWrite(base + UART_LCR_H, (0b11 << 5) | (1 << 4));
    hal.regWrite(base + UART_CR, (1 << 0) | (1 << 8) | (1 << 9));

    if (base == UART0_BASE) {
        hal.regWrite(IO_BANK0_BASE + 0x004, 2);
        hal.regWrite(IO_BANK0_BASE + 0x00C, 2);
    }
}

pub fn uartWrite(base: u32, byte: u8) void {
    while (hal.regRead(base + UART_FR) & UART_FR_TXFF != 0) {}
    hal.regWrite(base + UART_DR, byte);
}

pub fn uartPuts(base: u32, s: []const u8) void {
    for (s) |c| {
        if (c == '\n') uartWrite(base, '\r');
        uartWrite(base, c);
    }
}

// ── GPIO ───────────────────────────────────────────────────────────────

const SIO_GPIO_OUT_SET: u32 = SIO_BASE + 0x018;
const SIO_GPIO_OUT_CLR: u32 = SIO_BASE + 0x020;
const SIO_GPIO_OUT_XOR: u32 = SIO_BASE + 0x028;
const SIO_GPIO_OE_SET: u32 = SIO_BASE + 0x038;
const SIO_GPIO_OE_CLR: u32 = SIO_BASE + 0x040;
const SIO_GPIO_IN: u32 = SIO_BASE + 0x008;

pub fn gpioInit(pin: u5, output: bool) void {
    const ctrl_addr = IO_BANK0_BASE + @as(u32, pin) * 8 + 0x004;
    hal.regWrite(ctrl_addr, 5);

    if (output) {
        hal.regWrite(SIO_GPIO_OE_SET, @as(u32, 1) << pin);
    } else {
        hal.regWrite(SIO_GPIO_OE_CLR, @as(u32, 1) << pin);
    }
}

pub fn gpioSet(pin: u5, high: bool) void {
    const mask = @as(u32, 1) << pin;
    if (high) {
        hal.regWrite(SIO_GPIO_OUT_SET, mask);
    } else {
        hal.regWrite(SIO_GPIO_OUT_CLR, mask);
    }
}

pub fn gpioToggle(pin: u5) void {
    hal.regWrite(SIO_GPIO_OUT_XOR, @as(u32, 1) << pin);
}

pub fn gpioRead(pin: u5) bool {
    return (hal.regRead(SIO_GPIO_IN) >> pin) & 1 != 0;
}
