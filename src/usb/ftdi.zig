// FTDI USB-to-serial device driver.
//
// Handles FTDI vendor setup commands (reset, baud, flow control),
// bulk IN/OUT transfers, and 2-byte modem status stripping.
// Passes clean serial data to the ASTM protocol handler.

const host = @import("host.zig");
const astm = @import("astm.zig");
const console = @import("../bindings/console.zig");

const ACK: u8 = 0x06;
const BULK_BUF_SIZE = 64;

var bulk_buf: [BULK_BUF_SIZE]u8 = undefined;
var active_dev: u8 = 0;
var pipe_in: ?*host.Pipe = null;
var pipe_out: ?*host.Pipe = null;
var setup_done: bool = false;
var last_rx_time: u64 = 0;
var timeout_reported: bool = false;

// ── FTDI vendor setup ────────────────────────────────────────────────

pub fn ftdiSetup(dev: *host.Device) void {
    if (dev.vid != 0x0403) return;

    console.puts("[ftdi] setup: reset\n");
    host.command(dev, 0x40, 0, 0, 1, 0);

    console.puts("[ftdi] setup: latency 16ms\n");
    host.command(dev, 0x40, 9, 16, 1, 0);

    console.puts("[ftdi] setup: 9600 baud\n");
    host.command(dev, 0x40, 3, 0x4138, 1, 0);

    console.puts("[ftdi] setup: DTR/RTS on\n");
    host.command(dev, 0x40, 1, 0x0303, 1, 0);

    console.puts("[ftdi] setup: XON/XOFF flow\n");
    host.command(dev, 0x40, 2, 0x1311, 1, 0);

    console.puts("[ftdi] setup complete\n");

    active_dev = dev.dev_addr;
    pipe_in = findBulkPipe(dev.dev_addr, true);
    pipe_out = findBulkPipe(dev.dev_addr, false);

    if (pipe_in == null) {
        console.puts("[ftdi] ERROR: no bulk IN pipe\n");
        return;
    }
    if (pipe_out == null) {
        console.puts("[ftdi] ERROR: no bulk OUT pipe\n");
        return;
    }

    const hal = @import("../platform/hal.zig");
    setup_done = true;
    last_rx_time = hal.millis();
    timeout_reported = false;

    astm.init(&sendAck);
    console.puts("[ftdi] ready — polling for data\n");
    startBulkIn();
}

fn findBulkPipe(dev_addr: u8, dir_in: bool) ?*host.Pipe {
    const ep_num: u8 = if (dir_in) 1 else 2;
    for (&host.pipes) |*pp| {
        if (pp.status != .unconfigured) {
            if (pp.dev_addr == dev_addr and pp.ep_num == @as(u4, @intCast(ep_num & 0x0F)))
                return pp;
        }
    }
    return null;
}

// ── Bulk IN polling ──────────────────────────────────────────────────

fn startBulkIn() void {
    const pp = pipe_in orelse return;
    if (pp.status == .started) return;

    if (pipe_out) |po| {
        if (po.status == .started) return;
    }

    pp.ep_in = true;
    host.bulkTransferAsync(pp, &bulk_buf, BULK_BUF_SIZE, onBulkInComplete, null);
}

fn onBulkInComplete(ctx: ?*anyopaque, result: *const host.TransferResult) void {
    _ = ctx;

    if (result.status != 0 or result.len < 2) {
        startBulkIn();
        return;
    }

    const payload = result.user_buf[2..result.len];
    if (payload.len == 0) {
        startBulkIn();
        return;
    }

    const hal = @import("../platform/hal.zig");
    last_rx_time = hal.millis();
    timeout_reported = false;

    const need_ack = astm.onData(payload);
    if (!need_ack) {
        startBulkIn();
    }
}

// ── Bulk OUT ─────────────────────────────────────────────────────────

var out_buf: [1]u8 = undefined;

fn sendByte(byte: u8) void {
    const pp = pipe_out orelse return;
    if (pp.status == .started) return;

    out_buf[0] = byte;
    pp.ep_in = false;
    host.bulkTransferAsync(pp, &out_buf, 1, onBulkOutComplete, null);
}

fn onBulkOutComplete(ctx: ?*anyopaque, result: *const host.TransferResult) void {
    _ = ctx;
    _ = result;
    startBulkIn();
}

fn sendAck() void {
    sendByte(ACK);
}

// ── Reset and polling ────────────────────────────────────────────────

pub fn resetState() void {
    setup_done = false;
    pipe_in = null;
    pipe_out = null;
    active_dev = 0;
    last_rx_time = 0;
    timeout_reported = false;
    astm.reset();
}

const IDLE_TIMEOUT_MS: u64 = 30_000;

pub fn pollTick() void {
    if (!setup_done) return;

    const pp = pipe_in orelse return;
    if (pp.status != .started and pp.status != .unconfigured) {
        startBulkIn();
    }

    if (!timeout_reported and last_rx_time > 0) {
        const hal = @import("../platform/hal.zig");
        const now = hal.millis();
        if (now - last_rx_time > IDLE_TIMEOUT_MS) {
            console.puts("[ftdi] no data for 30s — device may be idle\n");
            timeout_reported = true;
        }
    }
}
