// CYW43 core driver — init, firmware upload, IOCTL, scan, WPA2 join, Ethernet TX/RX, DHCP.
//
// Boot sequence:
//   1. Board pin init → chip reset
//   2. PIO SPI init → bus handshake (read 0xFEEDBEAD)
//   3. ALP clock request → wait ALP available
//   4. Read chip ID (0xA9AF for CYW43439)
//   5. Upload firmware + NVRAM to CYW43 RAM via backplane
//   6. Release WLAN core → wait HT clock
//   7. Upload CLM blob via IOCTL
//   8. WLC_UP, MAC readback, LED control
//
// Reference: Pico SDK cyw43_ll.c, Embassy cyw43 runner.rs

const board = @import("board.zig");
const types = @import("types.zig");
const bus = @import("transport/bus.zig");
const pio_spi = @import("transport/pio_spi.zig");
const regs = @import("regs.zig");
const ioctl_mod = @import("control/ioctl.zig");
const boot_mod = @import("control/boot.zig");
const scan_mod = @import("control/scan.zig");
const join_mod = @import("control/join.zig");
const gpio_mod = @import("control/gpio.zig");
const events_mod = @import("protocol/events.zig");
const ethernet_mod = @import("netif/ethernet.zig");
const service_mod = @import("netif/service.zig");
const dhcp = @import("../net/dhcp.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;
const build_config = @import("build_config");

pub const State = types.State;
pub const Error = types.Error;

var state: State = .uninitialized;
var brd: *const board.BoardOps = &board.pico_w;
var chip_id: u32 = 0;
var ioctl_id: u16 = 0;

// SDPCM TX state
var sdpcm_tx_seq: u8 = 0;
var sdpcm_last_credit: u8 = 1; // SDK inits to 1 so first packet can be sent

// RX buffer — must hold the largest possible F2 packet (~2KB)
var rx_buf: [2048 / 4]u32 = undefined;

// MAC address (populated during boot)
pub var mac_addr: [6]u8 = [_]u8{0} ** 6;

// Firmware blobs embedded in flash (.rodata) at compile time.
// Combined blob = WiFi FW (padded to 512B alignment) + CLM appended.
// This matches the SDK's w43439A0_7_95_49_00_combined.h layout.
const fw_combined = @embedFile("firmware/43439A0_combined.bin");
const FW_LEN: usize = 231077; // WiFi firmware length before padding
const FW_PADDED: usize = (FW_LEN + 511) & ~@as(usize, 511); // 512-byte aligned
const fw_blob = fw_combined[0..FW_LEN];
const clm_blob = fw_combined[FW_PADDED..];
const nvram_blob = @embedFile("firmware/43439A0_nvram.bin");

// ── UART helpers (for boot-time diagnostics) ───────────────────────────

fn putc(ch: u8) void {
    rp2040.uartWrite(rp2040.UART0_BASE, ch);
}

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') putc('\r');
        putc(ch);
    }
}

fn putHex32(val: u32) void {
    const hex = "0123456789abcdef";
    var buf: [10]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    inline for (0..8) |i| {
        buf[2 + i] = hex[@as(usize, @intCast((val >> @as(u5, @intCast(28 - i * 4))) & 0xF))];
    }
    puts(&buf);
}

fn putDec(val: u32) void {
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) { puts("0"); return; }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    puts(buf[i..]);
}

// ── Public API ─────────────────────────────────────────────────────────

pub fn getState() State {
    return state;
}

/// Phase 1: probe the bus and verify chip identity.
/// Runs without firmware blobs — validates PIO SPI, gSPI protocol, and CYW43 presence.
pub fn probe(b: *const board.BoardOps) Error!void {
    brd = b;
    var ctx = bootctx();
    return boot_mod.probe(&ctx);
}

/// Phase 2: upload firmware + NVRAM, boot WLAN core.
/// Requires probe() to have succeeded first.
pub fn boot() Error!void {
    var ctx = bootctx();
    return boot_mod.boot(&ctx);
}

/// Combined init: probe + boot. Used by wifi.zig service.
pub fn init(b: *const board.BoardOps) Error!void {
    brd = b;
    var ctx = bootctx();
    return boot_mod.init(&ctx);
}

// ── Firmware upload ────────────────────────────────────────────────────

fn uploadBlob(base_addr: u32, blob: []const u8) void {
    // Use 64-byte chunks. The SDK sets CYW43_BUS_MAX_BLOCK_SIZE = 64 for SPI,
    // and 512-byte block writes silently corrupted firmware uploads on hardware.
    // Also copy each chunk to SRAM before sending (avoids XIP flash timing issues).
    const chunk_size: usize = 64;
    var sram_buf: [chunk_size]u8 = undefined;
    var offset: usize = 0;
    while (offset < blob.len) {
        const remaining = blob.len - offset;
        const addr = base_addr + @as(u32, @intCast(offset));

        // Don't cross a 32KB backplane window boundary
        const window_remaining = 0x8000 - (addr & 0x7FFF);
        const len = @min(chunk_size, remaining, window_remaining);

        @memcpy(sram_buf[0..len], blob[offset..][0..len]);
        bus.bpWriteBlock(addr, sram_buf[0..len]);
        offset += len;
    }
}

fn verifyBlob(base_addr: u32, blob: []const u8) bool {
    // Verify the uploaded firmware in 4KB pages with first-mismatch reporting.
    // This is the highest-value next diagnostic now that reset state matches SDK.
    const verify_stride: usize = 4096;
    var offset: usize = 0;
    while (offset < blob.len) : (offset += verify_stride) {
        const addr = base_addr + @as(u32, @intCast(offset));
        const expected = @as(u32, blob[offset]) |
            (@as(u32, blob[offset + 1]) << 8) |
            (@as(u32, blob[offset + 2]) << 16) |
            (@as(u32, blob[offset + 3]) << 24);
        const actual = bus.bpRead32(addr);
        if (actual != expected) {
            puts("[cyw43] verify FAIL @");
            putHex32(addr);
            puts(" got=");
            putHex32(actual);
            puts(" exp=");
            putHex32(expected);
            puts("\n");
            return false;
        }
    }
    puts("[cyw43] verify OK\n");
    return true;
}

// ── Core reset/disable helpers ─────────────────────────────────────────

fn disableCore(base: u32) void {
    const wrapper = base + regs.WRAPPER_OFFSET;

    // Match SDK disable_device_core(): read RESETCTRL twice and only proceed
    // if the core is already in reset. The SDK's implementation does NOT
    // actively force reset here; reset_device_core() handles the bring-up.
    _ = bus.bpRead32(wrapper + regs.AI_RESETCTRL_OFFSET);
    const r = bus.bpRead32(wrapper + regs.AI_RESETCTRL_OFFSET);
    if ((r & regs.AIRC_RESET) != 0) return;
}

fn resetCore(base: u32) void {
    const wrapper = base + regs.WRAPPER_OFFSET;

    disableCore(base);

    bus.bpWrite32(wrapper + regs.AI_IOCTRL_OFFSET, regs.SICF_FGC | regs.SICF_CLOCK_EN);
    _ = bus.bpRead32(wrapper + regs.AI_IOCTRL_OFFSET);

    bus.bpWrite32(wrapper + regs.AI_RESETCTRL_OFFSET, 0);
    hal.delayMs(1);

    bus.bpWrite32(wrapper + regs.AI_IOCTRL_OFFSET, regs.SICF_CLOCK_EN);
    _ = bus.bpRead32(wrapper + regs.AI_IOCTRL_OFFSET);
    hal.delayMs(1);
}

// ── IOCTL / SDPCM control plane ────────────────────────────────────────

const PollResult = ioctl_mod.PollResult;

fn ioctx() ioctl_mod.Context {
    return .{
        .ioctl_id = &ioctl_id,
        .sdpcm_tx_seq = &sdpcm_tx_seq,
        .sdpcm_last_credit = &sdpcm_last_credit,
        .rx_buf = &rx_buf,
    };
}

fn bootctx() boot_mod.Context {
    return .{
        .state = &state,
        .brd = brd,
        .chip_id = &chip_id,
        .mac_addr = &mac_addr,
        .fw_blob = fw_blob,
        .nvram_blob = nvram_blob,
        .clm_blob = clm_blob,
        .puts = &puts,
        .putDec = &putDec,
        .putHex32 = &putHex32,
        .do_ioctl = &doIoctl,
        .led_set = &ledSet,
        .start_scan = &startScan,
        .print_scan_results = &printScanResults,
        .join_wpa2 = &joinWpa2,
        .poll_device = &pollDevice,
        .handle_event = &handleEvent,
        .handle_data = &handleDataPacket,
        .upload_blob = &uploadBlob,
        .verify_blob = &verifyBlob,
        .disable_core = &disableCore,
        .reset_core = &resetCore,
        .clm_load = &clmLoad,
        .rx_buf = &rx_buf,
        .wifi_ssid = build_config.ssid,
        .wifi_pass = build_config.pass,
    };
}

fn readLE16(src: []const u8) u16 {
    return ioctl_mod.readLE16(src);
}

fn readLE32(src: []const u8) u32 {
    return ioctl_mod.readLE32(src);
}

fn writeLE16(dst: *[2]u8, val: u16) void {
    ioctl_mod.writeLE16(dst, val);
}

fn writeLE32(dst: *[4]u8, val: u32) void {
    ioctl_mod.writeLE32(dst, val);
}

fn pollDevice() PollResult {
    var ctx = ioctx();
    return ioctl_mod.pollDevice(&ctx);
}

fn hasCredit() bool {
    var ctx = ioctx();
    return ioctl_mod.hasCredit(&ctx);
}

fn doIoctl(kind: u32, cmd: u32, iface: u8, payload: []u8) Error!void {
    var ctx = ioctx();
    return ioctl_mod.doIoctl(&ctx, &handleEvent, &handleDataPacket, kind, cmd, iface, payload);
}

// ── Ethernet TX/RX (data channel) ──────────────────────────────────────

pub fn sendEthernet(frame: []const u8) Error!void {
    var ctx = ioctx();
    return ethernet_mod.sendEthernet(&ctx, frame);
}

fn handleDataPacket() void {
    var ctx = ioctx();
    ethernet_mod.handleDataPacket(&ctx);
}

fn serviceEvent() void {
    handleEvent(@as([*]const u8, @ptrCast(&rx_buf)));
}

// ── CLM upload ─────────────────────────────────────────────────────────

fn clmLoad() Error!void {
    const chunk_len: usize = 1024;
    var iobuf: [8 + 20 + chunk_len]u8 = undefined;
    var offset: usize = 0;

    while (offset < clm_blob.len) {
        var len = chunk_len;
        var flag: u16 = 1 << 12; // DLOAD_HANDLER_VER
        if (offset == 0) flag |= 2; // DL_BEGIN
        if (offset + len >= clm_blob.len) {
            flag |= 4; // DL_END
            len = clm_blob.len - offset;
        }

        @memcpy(iobuf[0..8], "clmload\x00");
        writeLE16(iobuf[8..10], flag);
        writeLE16(iobuf[10..12], 2); // dload type
        writeLE32(iobuf[12..16], @intCast(len));
        writeLE32(iobuf[16..20], 0); // CRC
        @memcpy(iobuf[20..][0..len], clm_blob[offset..][0..len]);

        const total = (20 + len + 7) & ~@as(usize, 7); // 8-byte align
        try doIoctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, iobuf[0..total]);

        offset += len;
    }

    // Verify CLM upload succeeded
    var status_buf: [20]u8 = [_]u8{0} ** 20;
    @memcpy(status_buf[0..15], "clmload_status\x00");
    doIoctl(regs.SDPCM_GET, regs.IOCTL_CMD_GET_VAR, 0, status_buf[0..20]) catch {
        puts("[cyw43] CLM status query failed\n");
        return;
    };
    const clm_status = readLE32(status_buf[0..4]);
    if (clm_status != 0) {
        puts("[cyw43] CLM status=");
        putHex32(clm_status);
        puts("\n");
    }
}

// ── GPIO control (LED) ────────────────────────────────────────────────

pub fn gpioSet(gpio_num: u8, value: bool) Error!void {
    gpio_mod.gpioSet(&doIoctl, gpio_num, value) catch return Error.IoctlTimeout;
}

pub fn ledSet(on: bool) Error!void {
    gpio_mod.ledSet(&gpioSet, on) catch return Error.IoctlTimeout;
}

// ── IOCTL convenience helpers ──────────────────────────────────────────

fn setIoctlU32(cmd: u32, iface: u8, value: u32) Error!void {
    var ctx = ioctx();
    return ioctl_mod.setIoctlU32(&ctx, &handleEvent, &handleDataPacket, cmd, iface, value);
}

fn setIovar(name: []const u8, data: []const u8) Error!void {
    var ctx = ioctx();
    return ioctl_mod.setIovar(&ctx, &handleEvent, &handleDataPacket, name, data);
}

fn setIovarU32(name: []const u8, value: u32) Error!void {
    var ctx = ioctx();
    return ioctl_mod.setIovarU32(&ctx, &handleEvent, &handleDataPacket, name, value);
}

fn setBsscfgIovarU32(name: []const u8, iface: u32, value: u32) Error!void {
    var ctx = ioctx();
    return ioctl_mod.setBsscfgIovarU32(&ctx, &handleEvent, &handleDataPacket, name, iface, value);
}

// ── WPA2-PSK join ──────────────────────────────────────────────────────

pub fn joinWpa2(ssid: []const u8, passphrase: []const u8) Error!void {
    state = .joining;
    join_mod.join_state = .joining;
    join_mod.joinWpa2(
        ssid,
        passphrase,
        &doIoctl,
        &setIoctlU32,
        &setBsscfgIovarU32,
        &pollDevice,
        &serviceEvent,
        &puts,
    ) catch |e| {
        state = .wifi_idle;
        switch (e) {
            else => {},
        }
        return Error.IoctlTimeout;
    };
    state = .joined;
}

// ── Wi-Fi scan ─────────────────────────────────────────────────────────

fn startScan() Error!void {
    scan_mod.startScan(&doIoctl, &puts) catch return Error.IoctlTimeout;
}

fn handleEvent(rx_bytes: [*]const u8) void {
    events_mod.handleEvent(rx_bytes, &puts, &putDec, &putHex32);
}

fn printScanResults() void {
    scan_mod.printScanResults(&puts, &putDec, &putc);
}

// ── Service loop ───────────────────────────────────────────────────────

pub fn service() void {
    return service_mod.service(&state, &pollDevice, &handleEvent, &handleDataPacket, &rx_buf);
}
