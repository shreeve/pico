// FTDI device driver + ASTM session for Piccolo Xpress.
//
// Layers:
//   USB host (host.zig) → FTDI driver (this file) → ASTM session
//
// After enumeration, onDeviceConfigured() calls ftdiSetup() which:
//   1. Sends 5 FTDI vendor commands (reset, latency, baud, DTR/RTS, flow)
//   2. Starts bulk IN polling on EP1
//   3. Processes incoming data: strips 2-byte FTDI status, accumulates
//      bytes into a receive buffer, detects ASTM control characters
//      (ENQ/EOT) and frame boundaries (CR LF)

const host = @import("host.zig");
const desc = @import("descriptors.zig");
const console = @import("../services/console.zig");

// ── ASTM control characters ────────────────────────────────────────────

const STX: u8 = 0x02;
const ETX: u8 = 0x03;
const EOT: u8 = 0x04;
const ENQ: u8 = 0x05;
const ACK: u8 = 0x06;
const NAK: u8 = 0x15;
const CR: u8 = 0x0D;
const LF: u8 = 0x0A;

// ── Session state ──────────────────────────────────────────────────────

const RX_BUF_SIZE = 2048;
const BULK_BUF_SIZE = 64;

const SessionState = enum {
    idle,
    receiving,
};

var state: SessionState = .idle;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_len: usize = 0;
var bulk_buf: [BULK_BUF_SIZE]u8 = undefined;
var active_dev: u8 = 0;
var pipe_in: ?*host.Pipe = null;
var pipe_out: ?*host.Pipe = null;
var setup_done: bool = false;

// ── FTDI vendor setup ──────────────────────────────────────────────────

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

    setup_done = true;
    state = .idle;
    rx_len = 0;

    console.puts("[ftdi] ready — polling for data\n");
    startBulkIn();
}

fn findBulkPipe(dev_addr: u8, dir_in: bool) ?*host.Pipe {
    // EP1 is IN, EP2 is OUT for Piccolo
    const ep_num: u8 = if (dir_in) 1 else 2;
    return findPipeSafe(dev_addr, ep_num);
}

fn findPipeSafe(dev_addr: u8, ep_num: u8) ?*host.Pipe {
    for (&host.pipes) |*pp| {
        if (pp.status != .unconfigured) {
            if (pp.dev_addr == dev_addr and pp.ep_num == @as(u4, @intCast(ep_num & 0x0F)))
                return pp;
        }
    }
    return null;
}

// ── Bulk IN polling ────────────────────────────────────────────────────

fn startBulkIn() void {
    const pp = pipe_in orelse return;
    if (pp.status == .started) return;

    pp.ep_in = true;
    host.bulkTransferAsync(pp, &bulk_buf, BULK_BUF_SIZE, onBulkInComplete, null);
}

fn onBulkInComplete(ctx: ?*anyopaque, result: *const host.TransferResult) void {
    _ = ctx;

    if (result.len < 2) {
        startBulkIn();
        return;
    }

    // Strip FTDI 2-byte modem/line status prefix
    const payload = result.user_buf[2..result.len];
    if (payload.len == 0) {
        startBulkIn();
        return;
    }

    processPayload(payload);
    startBulkIn();
}

// ── Bulk OUT (send control characters) ─────────────────────────────────

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
}

fn sendAck() void {
    sendByte(ACK);
}

// ── ASTM session logic ─────────────────────────────────────────────────

fn processPayload(payload: []const u8) void {
    for (payload) |byte| {
        switch (byte) {
            ENQ => {
                console.puts("[astm] ENQ received — sending ACK\n");
                sendAck();
                state = .receiving;
                rx_len = 0;
            },
            EOT => {
                console.puts("[astm] EOT — transfer complete\n");
                state = .idle;
                rx_len = 0;
            },
            else => {
                if (state == .receiving) {
                    if (rx_len < RX_BUF_SIZE) {
                        rx_buf[rx_len] = byte;
                        rx_len += 1;
                    }

                    if (byte == LF and rx_len >= 2 and rx_buf[rx_len - 2] == CR) {
                        processFrame();
                        sendAck();
                    }
                }
            },
        }
    }
}

fn processFrame() void {
    if (rx_len < 7) {
        rx_len = 0;
        return;
    }

    // Frame: STX seq data ETX/ETB checksum CR LF
    // Strip framing: skip STX (byte 0), stop before ETX checksum CR LF (last 5)
    // The display content is between byte 1 and len-5
    const start: usize = if (rx_buf[0] == STX) 1 else 0;
    const end: usize = if (rx_len >= 5) rx_len - 5 else rx_len;

    if (end > start) {
        console.puts(rx_buf[start..end]);
        console.puts("\n");
    }

    rx_len = 0;
}

// ── Polling (called from event loop via host.zig) ──────────────────────

pub fn pollTick() void {
    if (!setup_done) return;

    const pp = pipe_in orelse return;
    if (pp.status != .started and pp.status != .unconfigured) {
        startBulkIn();
    }
}
