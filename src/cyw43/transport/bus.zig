// CYW43 gSPI bus access layer.
//
// Two modes:
//   Pre-config (16-bit halfword mode): swap16x2 + swapEndian on cmd/data
//   Post-config (32-bit word mode):    RAW commands and data, no byte swap
//
// After WORD_LENGTH_32, the PIO sends commands raw (bit 31 first = native u32).
// 8-bit register access uses LSByte of a u32 data word; the CYW43 handles
// byte-lane positioning internally for direct backplane registers (0x1000x).
//
// See CYW43.md for protocol details.

const regs = @import("../regs.zig");
const board = @import("../board.zig");
const pio_spi = @import("pio_spi.zig");
const hal = @import("../../platform/hal.zig");

var brd: *const board.BoardOps = &board.pico_w;
var backplane_window: u32 = 0;

pub fn init(b: *const board.BoardOps) void {
    brd = b;
    backplane_window = 0;
    pio_spi.init(b.wl_data, b.wl_clk);
}

// ── Register access (32-bit word mode, after bus config) ───────────────
// RAW commands — PIO sends native u32, bit 31 first. No byte swap.

const BP_PAD: u32 = regs.BACKPLANE_READ_PAD_WORDS; // Current proven backplane read padding

pub fn readReg8(func: u32, addr: u32) u8 {
    var result: [1]u32 = undefined;
    const pad = if (func == regs.FUNC_BACKPLANE) BP_PAD else 0;
    brd.csAssert();
    pio_spi.cmdReadRaw(regs.makeCmd(false, true, func, addr, 1), pad, &result);
    brd.csDeassert();
    return @truncate(result[0]);
}

pub fn writeReg8(func: u32, addr: u32, val: u8) void {
    brd.csAssert();
    pio_spi.cmdWriteRaw(regs.makeCmd(true, true, func, addr, 1), &[_]u32{@as(u32, val)});
    brd.csDeassert();
}

pub fn readReg32(func: u32, addr: u32) u32 {
    var result: [1]u32 = undefined;
    const pad = if (func == regs.FUNC_BACKPLANE) BP_PAD else 0;
    brd.csAssert();
    pio_spi.cmdReadRaw(regs.makeCmd(false, true, func, addr, 4), pad, &result);
    brd.csDeassert();
    return result[0];
}

pub fn writeReg32(func: u32, addr: u32, val: u32) void {
    brd.csAssert();
    pio_spi.cmdWriteRaw(regs.makeCmd(true, true, func, addr, 4), &[_]u32{val});
    brd.csDeassert();
}

// ── Pre-config swap mode (before WORD_LENGTH_32) ────────────────────────

fn readReg32Swap(func: u32, addr: u32) u32 {
    var result: [1]u32 = undefined;
    brd.csAssert();
    pio_spi.cmdRead(pio_spi.swap16x2(regs.makeCmd(false, true, func, addr, 4)), &result);
    brd.csDeassert();
    return pio_spi.swap16x2(result[0]);
}

fn writeReg32Swap(func: u32, addr: u32, val: u32) void {
    brd.csAssert();
    pio_spi.cmdWrite(pio_spi.swap16x2(regs.makeCmd(true, true, func, addr, 4)), &[_]u32{pio_spi.swap16x2(val)});
    brd.csDeassert();
}

// ── Backplane (function 1) with windowing ───────────────────────────────

pub fn setBackplaneWindow(addr: u32) void {
    const target = addr & 0xFFFF_8000;
    if (target == backplane_window) return;
    // Match the known-good CYW43 driver ordering: HIGH, MID, then LOW.
    // These are byte registers; writing LOW last appears to commit the window.
    writeReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_WINDOW_ADDR + 2, @truncate(target >> 24));
    writeReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_WINDOW_ADDR + 1, @truncate(target >> 16));
    writeReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_WINDOW_ADDR, @truncate(target >> 8));
    backplane_window = target;
}

pub fn bpRead32(addr: u32) u32 {
    setBackplaneWindow(addr);
    return readReg32(regs.FUNC_BACKPLANE, (addr & 0x7FFF) | 0x8000);
}

pub fn bpWrite32(addr: u32, val: u32) void {
    setBackplaneWindow(addr);
    writeReg32(regs.FUNC_BACKPLANE, (addr & 0x7FFF) | 0x8000, val);
}

pub fn bpRead8(addr: u32) u8 {
    setBackplaneWindow(addr);
    return readReg8(regs.FUNC_BACKPLANE, (addr & 0x7FFF) | 0x8000);
}

pub fn bpWrite8(addr: u32, val: u8) void {
    setBackplaneWindow(addr);
    writeReg8(regs.FUNC_BACKPLANE, (addr & 0x7FFF) | 0x8000, val);
}

pub fn bpWriteBlock(addr: u32, data: []const u8) void {
    setBackplaneWindow(addr);
    const local = (addr & 0x7FFF) | 0x8000;
    const len: u32 = @intCast(@min(data.len, 2047));
    brd.csAssert();
    pio_spi.writeCmdAndBytesRaw(regs.makeCmd(true, true, regs.FUNC_BACKPLANE, local, len), data[0..len]);
    brd.csDeassert();
}

// ── WLAN data (function 2) ──────────────────────────────────────────────

pub fn wlanWrite(data: []const u8) void {
    brd.csAssert();
    pio_spi.writeCmdAndBytesRaw(regs.makeCmd(true, true, regs.FUNC_WLAN, 0, @intCast(data.len)), data);
    brd.csDeassert();
}

pub fn wlanRead(out_words: []u32, byte_len: u32) void {
    const aligned_len = (byte_len + 3) & ~@as(u32, 3);
    const words: u32 = aligned_len / 4;
    brd.csAssert();
    pio_spi.cmdReadRaw(regs.makeCmd(false, true, regs.FUNC_WLAN, 0, aligned_len), 0, out_words[0..words]);
    brd.csDeassert();
}

pub fn readStatus() u32 {
    return readReg32(regs.FUNC_BUS, regs.SPI_STATUS_REG_ADDR);
}

// ── Bus initialization ──────────────────────────────────────────────────

pub fn initBus() !void {
    // Phase 1: read test register in 16-bit swap mode (before WORD_LENGTH_32)
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        const val = readReg32Swap(regs.FUNC_BUS, regs.SPI_TEST_REGISTER);
        if (val == regs.SPI_TEST_MAGIC) break;
        hal.delayMs(1);
    }
    if (attempts >= 100) return error.SpiBusNotReady;

    // Phase 2: configure bus (still in 16-bit swap mode)
    // NOTE: SDK also sets ENDIAN_BIG (0x02), but the current proven working
    // path omits it and uses raw command/data words with LSByte register access.
    writeReg32Swap(regs.FUNC_BUS, regs.SPI_BUS_CONTROL,
        regs.WORD_LENGTH_32 | regs.HIGH_SPEED | regs.INTERRUPT_POLARITY_HIGH | regs.WAKE_UP);

    // Now in 32-bit mode — all subsequent access uses raw (no byte swap).
    // SDK writes SPI_RESP_DELAY_F1 = 16 here, but the current proven path keeps
    // the device default and uses 4-byte padding (BP_PAD = 1 word).
    writeReg8(regs.FUNC_BUS, regs.SPI_INTERRUPT_ENABLE, @truncate(regs.F2_PACKET_AVAILABLE));
}
