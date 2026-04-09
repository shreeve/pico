// RP2040 USB controller register definitions.
// Audited line-by-line against pico-sdk hardware/regs/usb.h and
// hardware/structs/usb_dpram.h (2024-04 version).
//
// Two memory regions:
//   DPSRAM  0x5010_0000 .. 0x5010_0FFF  (4 KB, dual-port, 8/16/32-bit access)
//   REGS    0x5011_0000 .. 0x5011_009B  (156 bytes, 32-bit only)

const hal = @import("../platform/hal.zig");

// ── Base addresses ─────────────────────────────────────────────────────

pub const DPSRAM_BASE: u32 = 0x5010_0000;
pub const USB_BASE: u32 = 0x5011_0000;

// ── USB controller registers (0x5011_0000) ─────────────────────────────
// Offsets verified against USB_*_OFFSET in pico-sdk hardware/regs/usb.h

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
// Verified against usb_host_dpram_t in pico-sdk hardware/structs/usb_dpram.h

pub const SETUP_PACKET: u32 = DPSRAM_BASE + 0x000; // 8 bytes
pub const INT_EP_CTRL_BASE: u32 = DPSRAM_BASE + 0x008; // 15 × 8 bytes (ctrl + spare)
pub const EPX_BUF_CTRL: u32 = DPSRAM_BASE + 0x080;
pub const INT_EP_BUF_CTRL_BASE: u32 = DPSRAM_BASE + 0x088; // 15 × 8 bytes (ctrl + spare)
pub const EPX_CTRL: u32 = DPSRAM_BASE + 0x100;
pub const EPX_DATA: u32 = DPSRAM_BASE + 0x180; // Data buffers start here

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
// USB_MAIN_CTRL_*_BITS

pub const MAIN_CTRL_CONTROLLER_EN: u32 = 1 << 0; // 0x00000001
pub const MAIN_CTRL_HOST_NDEVICE: u32 = 1 << 1; // 0x00000002
pub const MAIN_CTRL_SIM_TIMING: u32 = 1 << 31; // 0x80000000

// ── SIE_CTRL bits ──────────────────────────────────────────────────────
// USB_SIE_CTRL_*_BITS — these were COMPLETELY wrong in the old code.
// Every value below is verified against pico-sdk hardware/regs/usb.h.

pub const SIE_CTRL_START_TRANS: u32 = 1 << 0; // 0x00000001
pub const SIE_CTRL_SEND_SETUP: u32 = 1 << 1; // 0x00000002
pub const SIE_CTRL_SEND_DATA: u32 = 1 << 2; // 0x00000004
pub const SIE_CTRL_RECEIVE_DATA: u32 = 1 << 3; // 0x00000008
pub const SIE_CTRL_STOP_TRANS: u32 = 1 << 4; // 0x00000010
pub const SIE_CTRL_PREAMBLE_EN: u32 = 1 << 6; // 0x00000040
pub const SIE_CTRL_SOF_SYNC: u32 = 1 << 8; // 0x00000100
pub const SIE_CTRL_SOF_EN: u32 = 1 << 9; // 0x00000200
pub const SIE_CTRL_KEEP_ALIVE_EN: u32 = 1 << 10; // 0x00000400
pub const SIE_CTRL_VBUS_EN: u32 = 1 << 11; // 0x00000800
pub const SIE_CTRL_RESUME: u32 = 1 << 12; // 0x00001000
pub const SIE_CTRL_RESET_BUS: u32 = 1 << 13; // 0x00002000 (SC)
pub const SIE_CTRL_PULLDOWN_EN: u32 = 1 << 15; // 0x00008000
pub const SIE_CTRL_PULLUP_EN: u32 = 1 << 16; // 0x00010000

pub const SIE_CTRL_HOST_BASE: u32 = SIE_CTRL_PULLDOWN_EN | SIE_CTRL_VBUS_EN | SIE_CTRL_KEEP_ALIVE_EN | SIE_CTRL_SOF_EN;
// = 0x8000 | 0x800 | 0x400 | 0x200 = 0x8E00

// ── SIE_STATUS bits ────────────────────────────────────────────────────
// USB_SIE_STATUS_*_BITS

pub const SIE_STATUS_VBUS_DETECTED: u32 = 1 << 0; // 0x00000001
pub const SIE_STATUS_LINE_STATE_BITS: u32 = 0x3 << 2; // 0x0000000C
pub const SIE_STATUS_SUSPENDED: u32 = 1 << 4; // 0x00000010
pub const SIE_STATUS_SPEED_BITS: u32 = 0x3 << 8; // 0x00000300
pub const SIE_STATUS_SPEED_LSB: u5 = 8;
pub const SIE_STATUS_VBUS_OVER_CURR: u32 = 1 << 10; // 0x00000400
pub const SIE_STATUS_RESUME: u32 = 1 << 11; // 0x00000800
pub const SIE_STATUS_CONNECTED: u32 = 1 << 16; // 0x00010000
pub const SIE_STATUS_SETUP_REC: u32 = 1 << 17; // 0x00020000
pub const SIE_STATUS_TRANS_COMPLETE: u32 = 1 << 18; // 0x00040000
pub const SIE_STATUS_BUS_RESET: u32 = 1 << 19; // 0x00080000
pub const SIE_STATUS_CRC_ERROR: u32 = 1 << 24; // 0x01000000
pub const SIE_STATUS_BIT_STUFF_ERROR: u32 = 1 << 25; // 0x02000000
pub const SIE_STATUS_RX_OVERFLOW: u32 = 1 << 26; // 0x04000000
pub const SIE_STATUS_RX_TIMEOUT: u32 = 1 << 27; // 0x08000000
pub const SIE_STATUS_NAK_REC: u32 = 1 << 28; // 0x10000000
pub const SIE_STATUS_STALL_REC: u32 = 1 << 29; // 0x20000000
pub const SIE_STATUS_ACK_REC: u32 = 1 << 30; // 0x40000000
pub const SIE_STATUS_DATA_SEQ_ERROR: u32 = 1 << 31; // 0x80000000

// ── INTE / INTS bits ───────────────────────────────────────────────────
// USB_INTE_*_BITS — several were WRONG in old code.

pub const INT_HOST_CONN_DIS: u32 = 1 << 0; // 0x00000001
pub const INT_HOST_RESUME: u32 = 1 << 1; // 0x00000002
pub const INT_HOST_SOF: u32 = 1 << 2; // 0x00000004
pub const INT_TRANS_COMPLETE: u32 = 1 << 3; // 0x00000008
pub const INT_BUFF_STATUS: u32 = 1 << 4; // 0x00000010
pub const INT_ERROR_DATA_SEQ: u32 = 1 << 5; // 0x00000020
pub const INT_ERROR_RX_TIMEOUT: u32 = 1 << 6; // 0x00000040
pub const INT_ERROR_RX_OVERFLOW: u32 = 1 << 7; // 0x00000080
pub const INT_ERROR_BIT_STUFF: u32 = 1 << 8; // 0x00000100
pub const INT_ERROR_CRC: u32 = 1 << 9; // 0x00000200
pub const INT_STALL: u32 = 1 << 10; // 0x00000400
pub const INT_VBUS_DETECT: u32 = 1 << 11; // 0x00000800
pub const INT_BUS_RESET: u32 = 1 << 12; // 0x00001000

// ── Endpoint control register bits (from usb_dpram.h) ──────────────────

pub const EP_CTRL_ENABLE: u32 = 1 << 31;
pub const EP_CTRL_DOUBLE_BUFFERED: u32 = 1 << 30;
pub const EP_CTRL_INT_PER_BUFFER: u32 = 1 << 29;
pub const EP_CTRL_INT_PER_DOUBLE_BUFFER: u32 = 1 << 28;
pub const EP_CTRL_INT_ON_STALL: u32 = 1 << 17;
pub const EP_CTRL_INT_ON_NAK: u32 = 1 << 16;
pub const EP_CTRL_BUFFER_TYPE_LSB: u5 = 26;
pub const EP_CTRL_HOST_INT_INTERVAL_LSB: u5 = 16; // was 18 — WRONG

// ── Buffer control register bits (from usb_dpram.h) ────────────────────

pub const BUF_CTRL_FULL: u32 = 1 << 15; // 0x00008000
pub const BUF_CTRL_LAST: u32 = 1 << 14; // 0x00004000
pub const BUF_CTRL_DATA1_PID: u32 = 1 << 13; // 0x00002000
pub const BUF_CTRL_DATA0_PID: u32 = 0; // 0x00000000
pub const BUF_CTRL_SEL: u32 = 1 << 12; // 0x00001000
pub const BUF_CTRL_STALL: u32 = 1 << 11; // 0x00000800
pub const BUF_CTRL_AVAIL: u32 = 1 << 10; // 0x00000400
pub const BUF_CTRL_LEN_MASK: u32 = 0x3FF; // 0x000003FF

// High half (buffer 1) uses same layout shifted by 16
pub const BUF_CTRL_AVAIL_HI: u32 = BUF_CTRL_AVAIL << 16;
pub const UNAVAILABLE_MASK: u32 = ~(BUF_CTRL_AVAIL_HI | BUF_CTRL_AVAIL);

// ── USB_MUXING bits ────────────────────────────────────────────────────
// USB_USB_MUXING_*_BITS

pub const MUXING_TO_PHY: u32 = 1 << 0; // 0x00000001
pub const MUXING_TO_EXTPHY: u32 = 1 << 1; // 0x00000002
pub const MUXING_TO_DIGITAL_PAD: u32 = 1 << 2; // 0x00000004
pub const MUXING_SOFTCON: u32 = 1 << 3; // 0x00000008

// ── USB_PWR bits ───────────────────────────────────────────────────────
// USB_USB_PWR_*_BITS

pub const PWR_VBUS_EN: u32 = 1 << 0; // 0x00000001
pub const PWR_VBUS_EN_OVERRIDE_EN: u32 = 1 << 1; // 0x00000002
pub const PWR_VBUS_DETECT: u32 = 1 << 2; // 0x00000004
pub const PWR_VBUS_DETECT_OVERRIDE_EN: u32 = 1 << 3; // 0x00000008
pub const PWR_OVERCURR_DETECT: u32 = 1 << 4; // 0x00000010
pub const PWR_OVERCURR_DETECT_EN: u32 = 1 << 5; // 0x00000020

pub const PWR_HOST_MODE: u32 = PWR_VBUS_DETECT | PWR_VBUS_DETECT_OVERRIDE_EN | PWR_OVERCURR_DETECT | PWR_OVERCURR_DETECT_EN;

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
