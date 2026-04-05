// PIO-based half-duplex SPI transport for CYW43 on Pico W.
//
// Uses a single PIO program matching the Pico SDK's spi_gap01_sample0:
//   TX: out pins, 1 (side 0) / jmp x-- (side 1)  — X+1 bits
//   Gap: set pindirs=0 (side 0) / nop (side 1)    — 1 turnaround clock
//   RX: in pins, 1 (side 0) / jmp y-- (side 1)    — Y+1 bits
//
// Host pre-loads X (TX bits - 1) and Y (RX bits - 1) before each transaction.
// Uses autopull/autopush at 32-bit threshold. DMA not used (FIFO polling).
// Clock: ~1 MHz for bring-up (div=64).
//
// See CYW43.md for protocol details.

const hal = @import("../../platform/hal.zig");
const rp2040 = hal.platform;

const PIO0_BASE = rp2040.PIO0_BASE;

// ── PIO register offsets ───────────────────────────────────────────────

const PIO_CTRL: u32 = 0x000;
const PIO_FSTAT: u32 = 0x004;
const PIO_FDEBUG: u32 = 0x008;
const PIO_INSTR_MEM: u32 = 0x048;
const PIO_SM0_CLKDIV: u32 = 0x0C8;
const PIO_SM0_EXECCTRL: u32 = 0x0CC;
const PIO_SM0_SHIFTCTRL: u32 = 0x0D0;
const PIO_SM0_INSTR: u32 = 0x0D8;
const PIO_SM0_PINCTRL: u32 = 0x0DC;
const PIO_TXF0: u32 = 0x010;
const PIO_RXF0: u32 = 0x020;
const PIO_INPUT_SYNC_BYPASS: u32 = 0x038;

const SM_STRIDE: u32 = 0x18;

fn smReg(sm: u5, offset: u32) u32 {
    return PIO0_BASE + offset + @as(u32, sm) * SM_STRIDE;
}

// ── PIO instruction encoding (RP2040 PIO ISA) ─────────────────────────

fn pioJmp(cond: u3, addr: u5) u16 {
    return @as(u16, cond) << 5 | addr;
}

fn pioIn(src: u3, count: u5) u16 {
    return (2 << 13) | (@as(u16, src) << 5) | count;
}

fn pioOut(dst: u3, count: u5) u16 {
    return (3 << 13) | (@as(u16, dst) << 5) | count;
}

fn pioSet(dst: u3, data: u5) u16 {
    return (7 << 13) | (@as(u16, dst) << 5) | data;
}

fn pioMov(dst: u3, op: u2, src: u3) u16 {
    return (5 << 13) | (@as(u16, dst) << 5) | (@as(u16, op) << 3) | src;
}

fn withSide(instr: u16, side: u1) u16 {
    return instr | (@as(u16, side) << 12);
}

const SRC_PINS: u3 = 0;
const DST_PINS: u3 = 0;
const DST_X: u3 = 1;
const DST_Y: u3 = 2;
const DST_PINDIRS: u3 = 4;
const JMP_X_DEC: u3 = 2;
const JMP_Y_DEC: u3 = 4;

// ── PIO program: SDK spi_gap01_sample0 ─────────────────────────────────
//
// Single combined TX/RX program. Host pre-loads:
//   X = number of TX bits - 1
//   Y = number of RX bits - 1
// Then jumps to addr 0 to start.
//
// 0: out pins, 1   side 0    ; TX: shift out bit, CLK LOW
// 1: jmp x-- 0     side 1    ; CLK HIGH, loop TX
// 2: set pindirs 0 side 0    ; switch DATA to input, CLK LOW
// 3: nop           side 1    ; 1 turnaround clock HIGH
// 4: in pins, 1    side 0    ; RX: sample bit, CLK LOW
// 5: jmp y-- 4     side 1    ; CLK HIGH, loop RX

// SDK spi_gap01_sample0: 1 gap clock, sample on CLK LOW.
// For PIO clocks >= 75 MHz (production target: ~62 MHz with div=2).
const PROGRAM = [_]u16{
    // 0: out pins, 1    side 0  ; TX bit out, CLK LOW
    withSide(pioOut(DST_PINS, 1), 0),
    // 1: jmp x--, 0     side 1  ; CLK HIGH, loop TX bits
    withSide(pioJmp(JMP_X_DEC, 0), 1),
    // 2: set pindirs, 0 side 0  ; DATA = input, CLK LOW
    withSide(pioSet(DST_PINDIRS, 0), 0),
    // 3: nop             side 1  ; 1 turnaround gap, CLK HIGH
    withSide(pioMov(DST_Y, 0, DST_Y), 1), // mov y, y = nop
    // 4: in pins, 1      side 0  ; RX sample on CLK LOW (falling edge)
    withSide(pioIn(SRC_PINS, 1), 0),
    // 5: jmp y--, 4      side 1  ; CLK HIGH, loop RX bits
    withSide(pioJmp(JMP_Y_DEC, 4), 1),
};

// ── State ──────────────────────────────────────────────────────────────

const SM: u5 = 0;
var data_pin: u5 = 24;
var clk_pin: u5 = 29;

// FSTAT bit positions for SM0
const FSTAT_RXEMPTY: u32 = 1 << (SM + 8);
const FSTAT_TXFULL: u32 = 1 << (SM + 16);
const FSTAT_TXEMPTY: u32 = 1 << (SM + 24);
const FDEBUG_TXSTALL: u32 = 1 << (SM + 24);

const FIFO_TIMEOUT: u32 = 500_000;

// ── Init ───────────────────────────────────────────────────────────────

pub fn init(wl_data: u5, wl_clk: u5) void {
    data_pin = wl_data;
    clk_pin = wl_clk;

    // Deassert PIO0 reset
    const RESET_PIO0: u32 = 1 << 10;
    hal.regClr(rp2040.RESETS_BASE, RESET_PIO0);
    while ((hal.regRead(rp2040.RESETS_BASE + 0x08) & RESET_PIO0) == 0) {}

    // Bypass input synchronizer for data pin (reduces latency)
    hal.regWrite(PIO0_BASE + PIO_INPUT_SYNC_BYPASS, @as(u32, 1) << data_pin);

    // Disable SM0
    hal.regClr(PIO0_BASE + PIO_CTRL, @as(u32, 1) << SM);

    // Configure GPIO functions to PIO0 (function 6)
    hal.regWrite(rp2040.IO_BANK0_BASE + @as(u32, data_pin) * 8 + 0x004, 6);
    hal.regWrite(rp2040.IO_BANK0_BASE + @as(u32, clk_pin) * 8 + 0x004, 6);

    // CLK pad: 12mA drive + fast slew (matching SDK for high-speed SPI)
    const clk_pad = @as(u32, 0x4001_C000) + 4 + @as(u32, clk_pin) * 4;
    hal.regWrite(clk_pad, (1 << 6) | // IE
        (3 << 4) | // DRIVE = 12mA
        (1 << 1) | // SCHMITT
        (1 << 0)); // SLEWFAST

    // DATA pad: 12mA drive + fast slew + schmitt + input enabled
    const data_pad = @as(u32, 0x4001_C000) + 4 + @as(u32, data_pin) * 4;
    hal.regWrite(data_pad, (1 << 6) | // IE
        (3 << 4) | // DRIVE = 12mA
        (1 << 1) | // SCHMITT
        (1 << 0)); // SLEWFAST

    // Load program
    for (PROGRAM, 0..) |instr, i| {
        hal.regWrite(PIO0_BASE + PIO_INSTR_MEM + @as(u32, @intCast(i)) * 4, instr);
    }

    // Clock: ~31 MHz SPI (125 MHz / 2 PIO clk / 2 cycles per bit)
    hal.regWrite(smReg(SM, PIO_SM0_CLKDIV), @as(u32, 2) << 16);

    // EXECCTRL: wrap from end of program back to start
    const wrap_top: u32 = PROGRAM.len - 1;
    hal.regWrite(smReg(SM, PIO_SM0_EXECCTRL), (wrap_top << 12) | (0 << 7));

    // SHIFTCTRL: shift-left (MSB-first), autopull + autopush at 32 bits
    hal.regWrite(smReg(SM, PIO_SM0_SHIFTCTRL),
        (1 << 17) | // AUTOPULL = enabled
        (1 << 16) | // AUTOPUSH = enabled
        (0 << 19) | // OUT_SHIFTDIR = left (MSB first)
        (0 << 18)); // IN_SHIFTDIR = left (MSB first)
    // pull_thresh=0 and push_thresh=0 both mean 32 bits

    // PINCTRL
    const pinctrl = (@as(u32, 1) << 29) | // sideset_count = 1
        (@as(u32, 1) << 26) | // set_count = 1
        (@as(u32, 1) << 20) | // out_count = 1
        (@as(u32, data_pin) << 15) | // in_base
        (@as(u32, clk_pin) << 10) | // sideset_base
        (@as(u32, data_pin) << 5) | // set_base
        (@as(u32, data_pin) << 0); // out_base
    hal.regWrite(smReg(SM, PIO_SM0_PINCTRL), pinctrl);

    // Set DATA pin OE
    execImm(pioSet(DST_PINDIRS, 1));

    // Set CLK pin OE (temporarily retarget SET_BASE)
    const pinctrl_addr = smReg(SM, PIO_SM0_PINCTRL);
    const saved = hal.regRead(pinctrl_addr);
    hal.regWrite(pinctrl_addr, (saved & ~(@as(u32, 0x1F) << 5)) | (@as(u32, clk_pin) << 5));
    execImm(pioSet(DST_PINDIRS, 1));
    hal.regWrite(pinctrl_addr, saved);

    // Set DATA pin LOW initially
    execImm(pioSet(DST_PINS, 0));

    // Restart SM and clear FIFOs
    hal.regSet(PIO0_BASE + PIO_CTRL, @as(u32, 1) << (SM + 4)); // SM_RESTART
    clearFifos();

    // Enable SM (will stall on autopull waiting for TX data)
    hal.regSet(PIO0_BASE + PIO_CTRL, @as(u32, 1) << SM);
}

fn execImm(instr: u16) void {
    hal.regWrite(smReg(SM, PIO_SM0_INSTR), instr);
}

fn clearFifos() void {
    const addr = smReg(SM, PIO_SM0_SHIFTCTRL);
    const val = hal.regRead(addr);
    hal.regWrite(addr, val | (1 << 31));
    hal.regWrite(addr, val);
}

// ── FIFO access ────────────────────────────────────────────────────────

fn txPut(word: u32) void {
    var t: u32 = FIFO_TIMEOUT;
    while (t > 0) : (t -= 1) {
        if ((hal.regRead(PIO0_BASE + PIO_FSTAT) & FSTAT_TXFULL) == 0) {
            hal.regWrite(PIO0_BASE + PIO_TXF0 + @as(u32, SM) * 4, word);
            return;
        }
    }
}

fn rxGet() u32 {
    var t: u32 = FIFO_TIMEOUT;
    while (t > 0) : (t -= 1) {
        if ((hal.regRead(PIO0_BASE + PIO_FSTAT) & FSTAT_RXEMPTY) == 0) {
            return hal.regRead(PIO0_BASE + PIO_RXF0 + @as(u32, SM) * 4);
        }
    }
    return 0xDEAD_BEEF;
}

fn waitTxEmpty() void {
    var t: u32 = FIFO_TIMEOUT;
    while (t > 0) : (t -= 1) {
        if ((hal.regRead(PIO0_BASE + PIO_FSTAT) & FSTAT_TXEMPTY) != 0) return;
    }
}

fn waitTxDone() void {
    waitTxEmpty();
    // The SDK waits for TXSTALL before ending write-only transfers. TX FIFO empty
    // is not sufficient: the final word may still be shifting out on the wire.
    var t: u32 = FIFO_TIMEOUT;
    while (t > 0) : (t -= 1) {
        if ((hal.regRead(PIO0_BASE + PIO_FDEBUG) & FDEBUG_TXSTALL) != 0) break;
    }
    // After TX, SM enters RX phase (Y+1 bits). We set Y=31 for write-only
    // so autopush produces exactly 1 word. Drain it.
    _ = rxGet();
}

// ── Transaction interface ──────────────────────────────────────────────

/// Perform a write-only SPI transaction.
pub fn write(words: []const u32) void {
    const tx_bits: u32 = @intCast(words.len * 32);

    setupTransaction(tx_bits, 0);

    for (words) |w| txPut(swapEndian(w));

    waitTxDone();
}

/// Perform a read transaction: send cmd, read response words.
pub fn cmdRead(cmd: u32, out: []u32) void {
    cmdReadPadded(cmd, 0, out);
}

/// Raw read (no byte swap) — for 32-bit word mode after bus config.
pub fn cmdReadRaw(cmd: u32, pad_words: u32, out: []u32) void {
    const tx_bits: u32 = 32;
    const rx_bits: u32 = @intCast((pad_words + out.len) * 32);
    setupTransaction(tx_bits, rx_bits);
    txPut(cmd);
    for (0..pad_words) |_| _ = rxGet();
    for (out) |*slot| slot.* = rxGet();
}

/// Raw write (no byte swap) — for 32-bit word mode after bus config.
pub fn cmdWriteRaw(cmd: u32, data: []const u32) void {
    const total_words = 1 + data.len;
    const tx_bits: u32 = @intCast(total_words * 32);
    setupTransaction(tx_bits, 0);
    txPut(cmd);
    for (data) |w| txPut(w);
    waitTxDone();
}

/// Raw write command + raw bytes — for 32-bit word mode block writes.
pub fn writeCmdAndBytesRaw(cmd: u32, data: []const u8) void {
    const data_bits = ((data.len + 3) / 4) * 32;
    const tx_bits: u32 = 32 + @as(u32, @intCast(data_bits));
    setupTransaction(tx_bits, 0);
    txPut(cmd);
    var i: usize = 0;
    while (i < data.len) {
        var word: u32 = 0;
        var shift: u5 = 0;
        for (0..4) |_| {
            if (i < data.len) {
                word |= @as(u32, data[i]) << shift;
                i += 1;
            }
            if (shift < 24) shift += 8 else break;
        }
        txPut(word);
    }
    waitTxDone();
}

/// Read with padding: discard `pad_words` before reading `out` words.
/// Used for backplane (function 1) reads which have 4-byte response padding.
pub fn cmdReadPadded(cmd: u32, pad_words: u32, out: []u32) void {
    const tx_bits: u32 = 32;
    const rx_bits: u32 = @intCast((pad_words + out.len) * 32);

    setupTransaction(tx_bits, rx_bits);

    txPut(swapEndian(cmd));

    for (0..pad_words) |_| _ = rxGet();
    for (out) |*slot| {
        slot.* = swapEndian(rxGet());
    }
}

/// Write command + data words (no response).
pub fn cmdWrite(cmd: u32, data: []const u32) void {
    const total_words = 1 + data.len;
    const tx_bits: u32 = @intCast(total_words * 32);

    setupTransaction(tx_bits, 0);

    txPut(swapEndian(cmd));
    for (data) |w| txPut(swapEndian(w));

    waitTxDone();
}

/// Write command + raw bytes (for firmware upload).
pub fn writeCmdAndBytes(cmd: u32, data: []const u8) void {
    const data_bits = ((data.len + 3) / 4) * 32;
    const tx_bits: u32 = 32 + @as(u32, @intCast(data_bits));

    setupTransaction(tx_bits, 0);

    txPut(swapEndian(cmd));

    var i: usize = 0;
    while (i < data.len) {
        var word: u32 = 0;
        var shift: u5 = 24;
        for (0..4) |_| {
            if (i < data.len) {
                word |= @as(u32, data[i]) << shift;
                i += 1;
            }
            if (shift > 0) shift -= 8 else break;
        }
        txPut(word);
    }

    waitTxDone();
}

// ── Internal helpers ───────────────────────────────────────────────────

fn setupTransaction(tx_bits: u32, rx_bits: u32) void {
    hal.regClr(PIO0_BASE + PIO_CTRL, @as(u32, 1) << SM);
    clearFifos();
    // Clear sticky TXSTALL from any previous transaction before restarting.
    hal.regWrite(PIO0_BASE + PIO_FDEBUG, FDEBUG_TXSTALL);
    execImm(withSide(pioSet(DST_PINDIRS, 1), 0)); // DATA = output
    hal.regSet(PIO0_BASE + PIO_CTRL, @as(u32, 1) << (SM + 4)); // SM_RESTART

    // Load X = TX bits - 1, Y = RX bits - 1
    // For write-only (rx_bits=0), use Y=31 so autopush produces 1 drainable word.
    hal.regWrite(PIO0_BASE + PIO_TXF0 + @as(u32, SM) * 4, tx_bits - 1);
    execImm(pioOut(DST_X, 0));
    const y_val = if (rx_bits > 0) rx_bits - 1 else 31;
    hal.regWrite(PIO0_BASE + PIO_TXF0 + @as(u32, SM) * 4, y_val);
    execImm(pioOut(DST_Y, 0));

    execImm(pioJmp(0, 0)); // jmp always to addr 0
    hal.regSet(PIO0_BASE + PIO_CTRL, @as(u32, 1) << SM);
}

fn swapEndian(v: u32) u32 {
    return ((v & 0xFF) << 24) |
        ((v & 0xFF00) << 8) |
        ((v & 0xFF0000) >> 8) |
        ((v & 0xFF000000) >> 24);
}

/// Swap bytes within each 16-bit halfword (ARM rev16).
/// Used for initial gSPI transactions before WORD_LENGTH_32 is configured.
pub fn swap16x2(v: u32) u32 {
    return ((v & 0xFF00FF00) >> 8) | ((v & 0x00FF00FF) << 8);
}
