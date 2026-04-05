// RP2040 USB controller register definitions.
// Derived from the RP2040 datasheet §4.1 and the pico-sdk hardware headers.
//
// Two memory regions:
//   DPSRAM  0x5010_0000 .. 0x5010_0FFF  (4 KB, dual-port, 8/16/32-bit access)
//   REGS    0x5011_0000 .. 0x5011_009B  (156 bytes, 32-bit only)

const hal = @import("../platform/hal.zig");

// ── Base addresses ─────────────────────────────────────────────────────

pub const DPSRAM_BASE: u32 = 0x5010_0000;
pub const USB_BASE: u32 = 0x5011_0000;

// ── USB controller registers (0x5011_0000) ─────────────────────────────

pub const ADDR_ENDP: u32 = USB_BASE + 0x00;
pub const ADDR_ENDP1: u32 = USB_BASE + 0x04;
// ADDR_ENDP2..15 at 0x08..0x3C (4-byte stride)
pub const MAIN_CTRL: u32 = USB_BASE + 0x40;
pub const SOF_WR: u32 = USB_BASE + 0x44;
pub const SOF_RD: u32 = USB_BASE + 0x48;
pub const SIE_CTRL: u32 = USB_BASE + 0x4C;
pub const SIE_STATUS: u32 = USB_BASE + 0x50;
pub const INT_EP_CTRL: u32 = USB_BASE + 0x54;
pub const BUFF_STATUS: u32 = USB_BASE + 0x58;
pub const BUFF_CPU_SHOULD_HANDLE: u32 = USB_BASE + 0x5C;
pub const EP_ABORT: u32 = USB_BASE + 0x60;
pub const EP_ABORT_DONE: u32 = USB_BASE + 0x64;
pub const EP_STALL_ARM: u32 = USB_BASE + 0x68;
pub const NAK_POLL: u32 = USB_BASE + 0x6C;
pub const EP_STATUS_STALL_NAK: u32 = USB_BASE + 0x70;
pub const USB_MUXING: u32 = USB_BASE + 0x74;
pub const USB_PWR: u32 = USB_BASE + 0x78;
pub const USBPHY_DIRECT: u32 = USB_BASE + 0x7C;
pub const USBPHY_DIRECT_OVERRIDE: u32 = USB_BASE + 0x80;
pub const USBPHY_TRIM: u32 = USB_BASE + 0x84;
pub const INTR: u32 = USB_BASE + 0x8C;
pub const INTE: u32 = USB_BASE + 0x90;
pub const INTF: u32 = USB_BASE + 0x94;
pub const INTS: u32 = USB_BASE + 0x98;

// ── DPSRAM layout (host mode, 0x5010_0000) ─────────────────────────────

pub const SETUP_PACKET: u32 = DPSRAM_BASE + 0x000; // 8 bytes
pub const INT_EP_CTRL_BASE: u32 = DPSRAM_BASE + 0x008; // 15 × 4 bytes (8-byte stride)
pub const EPX_BUF_CTRL: u32 = DPSRAM_BASE + 0x080;
pub const INT_EP_BUF_CTRL_BASE: u32 = DPSRAM_BASE + 0x088; // 15 × 4 bytes (8-byte stride)
pub const EPX_CTRL: u32 = DPSRAM_BASE + 0x100;
pub const EPX_DATA: u32 = DPSRAM_BASE + 0x180; // Data buffers start here (64 bytes each)

pub inline fn intEpCtrl(i: u4) u32 {
    return INT_EP_CTRL_BASE + @as(u32, i) * 8;
}

pub inline fn intEpBufCtrl(i: u4) u32 {
    return INT_EP_BUF_CTRL_BASE + @as(u32, i) * 8;
}

pub inline fn epxDataBuf(buf_id: u1) u32 {
    return EPX_DATA + @as(u32, buf_id) * 64;
}

// ── MAIN_CTRL bits ─────────────────────────────────────────────────────

pub const MAIN_CTRL_CONTROLLER_EN: u32 = 1 << 0;
pub const MAIN_CTRL_HOST_NDEVICE: u32 = 1 << 1;
pub const MAIN_CTRL_SIM_TIMING: u32 = 1 << 31;

// ── SIE_CTRL bits ──────────────────────────────────────────────────────

pub const SIE_CTRL_START_TRANS: u32 = 1 << 0;
pub const SIE_CTRL_RESUME: u32 = 1 << 1;
pub const SIE_CTRL_RESET_BUS: u32 = 1 << 2;
pub const SIE_CTRL_PULLDOWN_EN: u32 = 1 << 15;
pub const SIE_CTRL_PULLUP_EN: u32 = 1 << 16;
pub const SIE_CTRL_PREAMBLE_EN: u32 = 1 << 6;
pub const SIE_CTRL_SOF_EN: u32 = 1 << 3;
pub const SIE_CTRL_KEEP_ALIVE_EN: u32 = 1 << 4;
pub const SIE_CTRL_VBUS_EN: u32 = 1 << 5;
pub const SIE_CTRL_RECEIVE_DATA: u32 = 1 << 10;
pub const SIE_CTRL_SEND_DATA: u32 = 1 << 9;
pub const SIE_CTRL_SEND_SETUP: u32 = 1 << 8;
pub const SIE_CTRL_TRANSCEIVER_EN: u32 = 1 << 7;

pub const SIE_CTRL_HOST_BASE: u32 = SIE_CTRL_PULLDOWN_EN | SIE_CTRL_VBUS_EN | SIE_CTRL_KEEP_ALIVE_EN | SIE_CTRL_SOF_EN;

// ── SIE_STATUS bits ────────────────────────────────────────────────────

pub const SIE_STATUS_SPEED_BITS: u32 = 0x3 << 8;
pub const SIE_STATUS_SPEED_LSB: u5 = 8;
pub const SIE_STATUS_TRANS_COMPLETE: u32 = 1 << 18;
pub const SIE_STATUS_STALL_REC: u32 = 1 << 29;
pub const SIE_STATUS_RX_TIMEOUT: u32 = 1 << 27;
pub const SIE_STATUS_DATA_SEQ_ERROR: u32 = 1 << 31;
pub const SIE_STATUS_RESUME: u32 = 1 << 11;
pub const SIE_STATUS_NAK_REC: u32 = 1 << 28;

// ── INTE / INTS bits ───────────────────────────────────────────────────

pub const INT_HOST_CONN_DIS: u32 = 1 << 0;
pub const INT_HOST_RESUME: u32 = 1 << 1;
pub const INT_STALL: u32 = 1 << 4;
pub const INT_BUFF_STATUS: u32 = 1 << 2;
pub const INT_TRANS_COMPLETE: u32 = 1 << 3;
pub const INT_ERROR_DATA_SEQ: u32 = 1 << 11;
pub const INT_ERROR_RX_TIMEOUT: u32 = 1 << 9;

// ── Endpoint control register (ECR) bits ───────────────────────────────

pub const EP_CTRL_ENABLE: u32 = 1 << 31;
pub const EP_CTRL_DOUBLE_BUFFERED: u32 = 1 << 30;
pub const EP_CTRL_INT_PER_BUFFER: u32 = 1 << 29;
pub const EP_CTRL_INT_PER_DOUBLE_BUFFER: u32 = 1 << 28;
pub const EP_CTRL_BUFFER_TYPE_LSB: u5 = 26;
pub const EP_CTRL_HOST_INT_INTERVAL_LSB: u5 = 18;

// ── Buffer control register (BCR) bits ─────────────────────────────────

pub const BUF_CTRL_FULL: u32 = 1 << 15;
pub const BUF_CTRL_LAST: u32 = 1 << 14;
pub const BUF_CTRL_DATA1_PID: u32 = 1 << 13;
pub const BUF_CTRL_DATA0_PID: u32 = 0;
pub const BUF_CTRL_STALL: u32 = 1 << 11;
pub const BUF_CTRL_AVAIL: u32 = 1 << 10;
pub const BUF_CTRL_LEN_MASK: u32 = 0x3FF;

// High half (buffer 1) uses same layout shifted by 16
pub const BUF_CTRL_AVAIL_HI: u32 = BUF_CTRL_AVAIL << 16;
pub const UNAVAILABLE_MASK: u32 = ~(BUF_CTRL_AVAIL_HI | BUF_CTRL_AVAIL);

// ── USB_MUXING bits ────────────────────────────────────────────────────

pub const MUXING_TO_PHY: u32 = 1 << 0;
pub const MUXING_SOFTCON: u32 = 1 << 3;

// ── USB_PWR bits ───────────────────────────────────────────────────────

pub const PWR_VBUS_DETECT: u32 = 1 << 0;
pub const PWR_VBUS_DETECT_OVERRIDE_EN: u32 = 1 << 3;

// ── ADDR_ENDP bits ─────────────────────────────────────────────────────

pub const ADDR_ENDP_ADDRESS_MASK: u32 = 0x7F;
pub const ADDR_ENDP_ENDPOINT_LSB: u5 = 16;
pub const ADDR_ENDP_ENDPOINT_MASK: u32 = 0xF << 16;

// ── Register access helpers ────────────────────────────────────────────

pub inline fn read(addr: u32) u32 {
    return hal.regRead(addr);
}

pub inline fn write(addr: u32, val: u32) void {
    hal.regWrite(addr, val);
}

// Atomic set/clear aliases for USB controller registers (NOT for DPSRAM)
pub inline fn set(addr: u32, mask: u32) void {
    hal.regWrite(addr + 0x2000, mask);
}

pub inline fn clr(addr: u32, mask: u32) void {
    hal.regWrite(addr + 0x3000, mask);
}

// DPSRAM read/write (these are direct, no atomic aliases)
pub inline fn dpRead(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn dpWrite(addr: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

pub inline fn dpRead8(addr: u32) u8 {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn dpWrite8(addr: u32, offset: u32, val: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(addr + offset);
    ptr.* = val;
}

pub inline fn dpMemcpy(dst: u32, src: [*]const u8, len: usize) void {
    const d: [*]volatile u8 = @ptrFromInt(dst);
    for (0..len) |i| d[i] = src[i];
}

pub inline fn dpMemcpyFrom(dst: [*]u8, src: u32, len: usize) void {
    const s: [*]volatile u8 = @ptrFromInt(src);
    for (0..len) |i| dst[i] = s[i];
}

pub fn dpMemset(addr: u32, val: u8, len: usize) void {
    const d: [*]volatile u8 = @ptrFromInt(addr);
    for (0..len) |i| d[i] = val;
}
