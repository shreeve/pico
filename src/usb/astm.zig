// ASTM E1394 session protocol for medical device data exchange.
//
// Parses ASTM-framed records from a serial stream (ENQ/ACK handshake,
// STX-delimited frames with checksum, EOT termination).
// Used by Piccolo Xpress blood chemistry analyzer.
//
// Transport-independent: receives stripped payload bytes via onData(),
// sends control characters via a configurable send callback.

const console = @import("../bindings/console.zig");

const STX: u8 = 0x02;
const ETX: u8 = 0x03;
const EOT: u8 = 0x04;
const ETB: u8 = 0x17;
const ENQ: u8 = 0x05;
const ACK: u8 = 0x06;
const CR: u8 = 0x0D;
const LF: u8 = 0x0A;

const RX_BUF_SIZE = 2048;

const SessionState = enum { idle, receiving };

var state: SessionState = .idle;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_len: usize = 0;

var send_ack_fn: ?*const fn () void = null;

pub fn init(ack_fn: *const fn () void) void {
    send_ack_fn = ack_fn;
    state = .idle;
    rx_len = 0;
}

pub fn reset() void {
    state = .idle;
    rx_len = 0;
}

pub fn onData(payload: []const u8) bool {
    var sent_ack = false;

    for (payload) |byte| {
        switch (byte) {
            ENQ => {
                console.puts("[astm] ENQ received — sending ACK\n");
                state = .receiving;
                rx_len = 0;
                if (!sent_ack) {
                    if (send_ack_fn) |f| f();
                    sent_ack = true;
                }
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
                        if (!sent_ack) {
                            if (send_ack_fn) |f| f();
                            sent_ack = true;
                        }
                    }
                }
            },
        }
    }

    return sent_ack;
}

fn processFrame() void {
    if (rx_len < 2) {
        rx_len = 0;
        return;
    }

    var start: usize = 0;
    var end: usize = rx_len;

    if (start < end and rx_buf[start] == STX) start += 1;
    if (end >= 2 and rx_buf[end - 1] == LF and rx_buf[end - 2] == CR) end -= 2;
    if (end >= 3 and (rx_buf[end - 3] == ETX or rx_buf[end - 3] == ETB)) end -= 3;

    if (end > start) {
        console.puts(rx_buf[start..end]);
        console.puts("\n");
    }

    rx_len = 0;
}
