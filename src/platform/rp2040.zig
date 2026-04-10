/// RP2040 (ARM Cortex-M0+) platform driver
/// - 264 KB SRAM (0x2000_0000 .. 0x2004_1FFF)
/// - 2 MB Flash  (0x1000_0000, XIP)
/// - 125 MHz default system clock
const hal = @import("hal.zig");

// ── Base addresses ─────────────────────────────────────────────────────

pub const SRAM_BASE: u32 = 0x2000_0000;
pub const SRAM_SIZE: u32 = 264 * 1024;
pub const FLASH_BASE: u32 = 0x1000_0000;
pub const FLASH_SIZE: u32 = 2 * 1024 * 1024;
pub const XIP_BASE: u32 = FLASH_BASE;

// Peripherals
pub const RESETS_BASE: u32 = 0x4000_C000;
pub const CLOCKS_BASE: u32 = 0x4000_8000;
pub const XOSC_BASE: u32 = 0x4002_4000;
pub const PLL_SYS_BASE: u32 = 0x4002_8000;
pub const PLL_USB_BASE: u32 = 0x4002_C000;
pub const TIMER_BASE: u32 = 0x4005_4000;
pub const WATCHDOG_BASE: u32 = 0x4005_8000;

// IO
pub const IO_BANK0_BASE: u32 = 0x4001_4000;
pub const PADS_BANK0_BASE: u32 = 0x4001_C000;
pub const SIO_BASE: u32 = 0xD000_0000;

// UART
pub const UART0_BASE: u32 = 0x4003_4000;
pub const UART1_BASE: u32 = 0x4003_8000;

// SPI
pub const SPI0_BASE: u32 = 0x4003_C000;
pub const SPI1_BASE: u32 = 0x4004_0000;

// I2C
pub const I2C0_BASE: u32 = 0x4004_4000;
pub const I2C1_BASE: u32 = 0x4004_8000;

// PIO (used for CYW43 WiFi on Pico W)
pub const PIO0_BASE: u32 = 0x5020_0000;
pub const PIO1_BASE: u32 = 0x5030_0000;

// ── System clock configuration ─────────────────────────────────────────

pub const SYS_CLK_HZ: u32 = 125_000_000;
pub const XOSC_MHZ: u32 = 12;

// ── Timer registers (64-bit microsecond timer) ─────────────────────────

const TIMER_TIMELR = TIMER_BASE + 0x0C;
const TIMER_TIMEHR = TIMER_BASE + 0x08;
const TIMER_ALARM0 = TIMER_BASE + 0x10;
const TIMER_INTE = TIMER_BASE + 0x38;
const TIMER_INTF = TIMER_BASE + 0x3C;
const TIMER_INTR = TIMER_BASE + 0x34;

const TICK_INTERVAL_US: u32 = 10_000; // 10ms periodic tick

// ── Reset subsystem ────────────────────────────────────────────────────

const RESETS_RESET = RESETS_BASE + 0x00;
const RESETS_RESET_DONE = RESETS_BASE + 0x08;

const RESET_UART0: u32 = 1 << 22;
const RESET_UART1: u32 = 1 << 23;
const RESET_IO_BANK0: u32 = 1 << 5;
const RESET_PADS_BANK0: u32 = 1 << 8;
const RESET_TIMER: u32 = 1 << 21;
const RESET_SPI0: u32 = 1 << 16;
const RESET_SPI1: u32 = 1 << 17;

// ── UART registers ─────────────────────────────────────────────────────

pub const UART_DR = 0x000;
pub const UART_FR = 0x018;
pub const UART_IBRD = 0x024;
pub const UART_FBRD = 0x028;
pub const UART_LCR_H = 0x02C;
pub const UART_CR = 0x030;
pub const UART_FR_TXFF: u32 = 1 << 5;
pub const UART_FR_RXFE: u32 = 1 << 4;

// ── Initialization ─────────────────────────────────────────────────────

pub fn init() void {
    initClocks();
    initPeripherals();
}

fn initClocks() void {
    // Enable XOSC — always write full CTRL (ENABLE + FREQ_RANGE)
    hal.regWrite(XOSC_BASE + 0x0C, 47); // STARTUP: ~1ms at 12 MHz
    hal.regWrite(XOSC_BASE + 0x00, 0xFAB_AA0); // CTRL: ENABLE=0xFAB, FREQ_RANGE=0xAA0
    while ((hal.regRead(XOSC_BASE + 0x04) & (1 << 31)) == 0) {}

    // Switch clk_ref to XOSC (12 MHz)
    hal.regWrite(CLOCKS_BASE + 0x30, 0x2); // CLK_REF_CTRL: SRC = xosc

    // Configure watchdog tick for 1 µs ticks from 12 MHz XOSC
    // TICK register: bits 8:0 = CYCLES (12), bit 9 = ENABLE
    hal.regWrite(WATCHDOG_BASE + 0x2C, (1 << 9) | 12);

    // Configure PLL_SYS for 125 MHz: 12 MHz * 125 / 6 / 2 = 125 MHz
    // Register offsets: CS=0x00, PWR=0x04, FBDIV_INT=0x08, PRIM=0x0C
    hal.regClr(RESETS_RESET, 1 << 12); // deassert PLL_SYS reset
    while ((hal.regRead(RESETS_RESET_DONE) & (1 << 12)) == 0) {}

    hal.regWrite(PLL_SYS_BASE + 0x04, 0xFFFFFFFF); // PWR: power down everything
    hal.regWrite(PLL_SYS_BASE + 0x08, 125); // FBDIV_INT: VCO = 12 * 125 = 1500 MHz
    hal.regClr(PLL_SYS_BASE + 0x04, (1 << 0) | (1 << 5)); // PWR: clear PD + VCOPD
    while ((hal.regRead(PLL_SYS_BASE + 0x00) & (1 << 31)) == 0) {} // wait CS.LOCK
    hal.regWrite(PLL_SYS_BASE + 0x0C, (6 << 16) | (2 << 12)); // PRIM: postdiv1=6, postdiv2=2
    hal.regClr(PLL_SYS_BASE + 0x04, 1 << 3); // PWR: clear POSTDIVPD

    // Switch clk_sys to PLL_SYS via aux mux
    hal.regWrite(CLOCKS_BASE + 0x3C, 0); // CLK_SYS_CTRL: AUXSRC = PLL_SYS (0), SRC = ref
    hal.regWrite(CLOCKS_BASE + 0x3C, 1); // CLK_SYS_CTRL: SRC = aux (now 125 MHz)

    // Enable clk_peri = clk_sys (needed by UART, SPI, I2C)
    hal.regWrite(CLOCKS_BASE + 0x48, (1 << 11)); // CLK_PERI_CTRL: ENABLE, AUXSRC = clk_sys (0)

    // Configure PLL_USB for 48 MHz: 12 MHz * 100 / 5 / 5 = 48 MHz
    // Required for USBCTRL to come out of reset and for USB operation.
    hal.regClr(RESETS_RESET, 1 << 13); // deassert PLL_USB reset
    while ((hal.regRead(RESETS_RESET_DONE) & (1 << 13)) == 0) {}

    hal.regWrite(PLL_USB_BASE + 0x04, 0xFFFFFFFF); // PWR: power down everything
    hal.regWrite(PLL_USB_BASE + 0x08, 100); // FBDIV_INT: VCO = 12 * 100 = 1200 MHz
    hal.regClr(PLL_USB_BASE + 0x04, (1 << 0) | (1 << 5)); // PWR: clear PD + VCOPD
    while ((hal.regRead(PLL_USB_BASE + 0x00) & (1 << 31)) == 0) {} // wait CS.LOCK
    hal.regWrite(PLL_USB_BASE + 0x0C, (5 << 16) | (5 << 12)); // PRIM: postdiv1=5, postdiv2=5
    hal.regClr(PLL_USB_BASE + 0x04, 1 << 3); // PWR: clear POSTDIVPD

    // Enable clk_usb = PLL_USB at 48 MHz (required for USB controller)
    hal.regWrite(CLOCKS_BASE + 0x54, 0); // CLK_USB_CTRL: disable before switching
    hal.regWrite(CLOCKS_BASE + 0x58, 1 << 8); // CLK_USB_DIV: integer divisor = 1
    hal.regWrite(CLOCKS_BASE + 0x54, (1 << 11)); // CLK_USB_CTRL: ENABLE, AUXSRC = PLL_USB (0)
}

fn initPeripherals() void {
    // Deassert resets for peripherals we need
    const required_resets = RESET_IO_BANK0 | RESET_PADS_BANK0 | RESET_UART0 | RESET_TIMER;
    hal.regClr(RESETS_RESET, required_resets);
    while ((hal.regRead(RESETS_RESET_DONE) & required_resets) != required_resets) {}
}

// ── Microsecond timer ──────────────────────────────────────────────────

pub fn timerReadUs() u64 {
    // Must read TIMELR first (latches TIMEHR)
    const lo: u64 = hal.regRead(TIMER_TIMELR);
    const hi: u64 = hal.regRead(TIMER_TIMEHR);
    return (hi << 32) | lo;
}

pub fn millis() u64 {
    return timerReadUs() / 1000;
}

// ── UART ───────────────────────────────────────────────────────────────

pub fn uartInit(base: u32, baud: u32) void {
    const baud_div = (SYS_CLK_HZ * 4) / baud; // Q28.4 fixed point
    const ibrd = baud_div >> 6;
    const fbrd = baud_div & 0x3F;

    hal.regWrite(base + UART_CR, 0); // disable UART before configuring
    hal.regWrite(base + UART_IBRD, ibrd);
    hal.regWrite(base + UART_FBRD, fbrd);
    hal.regWrite(base + UART_LCR_H, (0b11 << 5) | (1 << 4)); // 8N1, FIFO enabled
    hal.regWrite(base + UART_CR, (1 << 0) | (1 << 8) | (1 << 9)); // enable UART, TX, RX

    // Set GPIO 0 & 1 to UART0 function (func 2)
    if (base == UART0_BASE) {
        hal.regWrite(IO_BANK0_BASE + 0x004, 2); // GPIO0 -> UART0_TX
        hal.regWrite(IO_BANK0_BASE + 0x00C, 2); // GPIO1 -> UART0_RX
    }
}

pub fn uartWrite(base: u32, byte: u8) void {
    while ((hal.regRead(base + UART_FR) & UART_FR_TXFF) != 0) {}
    hal.regWrite(base + UART_DR, byte);
}

pub fn uartReadAvailable(base: u32) bool {
    return (hal.regRead(base + UART_FR) & UART_FR_RXFE) == 0;
}

pub fn uartRead(base: u32) u8 {
    return @truncate(hal.regRead(base + UART_DR));
}

pub fn uartPuts(base: u32, s: []const u8) void {
    for (s) |c| {
        if (c == '\n') uartWrite(base, '\r');
        uartWrite(base, c);
    }
}

// ── Periodic timer tick (ALARM0 based, 10ms) ────────────────────────────

pub var tick_count: u32 = 0;

pub fn initPeriodicTick() void {
    hal.regWrite(TIMER_INTE, 1);
    rearmAlarm0();

    // Enable TIMER_IRQ_0 (IRQ 0) in NVIC
    const NVIC_ISER: u32 = 0xE000_E100;
    hal.regWrite(NVIC_ISER, 1 << 0);
}

fn rearmAlarm0() void {
    const lo: u32 = hal.regRead(TIMER_TIMELR);
    hal.regWrite(TIMER_ALARM0, lo +% TICK_INTERVAL_US);
}

pub fn timerIrq0Handler() void {
    hal.regWrite(TIMER_INTR, 1);
    tick_count +%= 1;
    rearmAlarm0();
}

// ── ROM functions ───────────────────────────────────────────────────────

const CC = @import("std").builtin.CallingConvention;

fn romTableLookup(code: u32) usize {
    const table_ptr: *const u16 = @ptrFromInt(0x14);
    const lookup_ptr: *const u16 = @ptrFromInt(0x18);
    const table: [*]const u16 = @ptrFromInt(@as(u32, table_ptr.*));
    const lookup: *const fn ([*]const u16, u32) callconv(CC.c) usize = @ptrFromInt(@as(u32, lookup_ptr.*));
    return lookup(table, code);
}

pub fn resetToUsbBoot() noreturn {
    const reset_fn: *const fn (u32, u32) callconv(CC.c) noreturn =
        @ptrFromInt(romTableLookup('U' | (@as(u32, 'B') << 8)));
    reset_fn(0, 0);
}

// ── GPIO (via SIO for fast single-cycle access) ────────────────────────

const SIO_GPIO_OUT_SET: u32 = SIO_BASE + 0x014;
const SIO_GPIO_OUT_CLR: u32 = SIO_BASE + 0x018;
const SIO_GPIO_OUT_XOR: u32 = SIO_BASE + 0x01C;
const SIO_GPIO_OE_SET: u32 = SIO_BASE + 0x024;
const SIO_GPIO_OE_CLR: u32 = SIO_BASE + 0x028;
const SIO_GPIO_IN: u32 = SIO_BASE + 0x004;

pub fn gpioInit(pin: u5, output: bool) void {
    // Set function to SIO (func 5)
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
