/// Minimal TCP server for the pico control protocol.
/// Sits on top of lwIP (when available) or a raw socket abstraction.
///
/// The server listens on a configurable port and accepts one connection
/// at a time (single-client model for simplicity).
const console = @import("../services/console.zig");

pub const TCP_PORT: u16 = 9001;

pub const ConnState = enum {
    idle,
    listening,
    connected,
    error_state,
};

var state: ConnState = .idle;

const RX_BUF_SIZE = 4096;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_len: usize = 0;

pub fn init() void {
    state = .idle;
    console.puts("[tcp] init\n");
}

pub fn listen(port: u16) bool {
    _ = port;
    // TODO: lwIP tcp_bind + tcp_listen
    state = .listening;
    console.puts("[tcp] listening on port 9001\n");
    return true;
}

pub fn poll() void {
    // TODO: lwIP tcp_poll / accept / recv
}

pub fn send(data: []const u8) bool {
    _ = data;
    // TODO: lwIP tcp_write + tcp_output
    return false;
}

pub fn close() void {
    state = .idle;
    rx_len = 0;
}

pub fn isConnected() bool {
    return state == .connected;
}

pub fn rxAvailable() usize {
    return rx_len;
}

pub fn rxConsume(buf: []u8) usize {
    const n = @min(buf.len, rx_len);
    @memcpy(buf[0..n], rx_buf[0..n]);
    // Shift remaining data
    if (n < rx_len) {
        const remaining = rx_len - n;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            rx_buf[i] = rx_buf[n + i];
        }
    }
    rx_len -= n;
    return n;
}
