// TLS client — integration point for BearSSL or mbedTLS.
//
// Architecture decision (from GPT-5.4 audit):
//   BearSSL is recommended for client-only TLS on Cortex-M0+:
//   - Smallest footprint of available options
//   - Designed for embedded/constrained devices
//   - Sufficient for MQTT over TLS (port 8883) and HTTPS client (OTA)
//
// This module will wrap the TLS library and provide a stream interface
// that sits between tcp.zig and application protocols (MQTT, HTTPS).
//
// Integration steps when ready:
//   1. Vendor BearSSL sources into ext/bearssl/
//   2. Add C compilation to build.zig
//   3. Implement TlsStream wrapping a TCP connection
//   4. Add certificate pinning or CA validation
//   5. Wire into MQTT client for port 8883

const tcp = @import("tcp.zig");

pub const Error = error{
    NotImplemented,
    HandshakeFailed,
    CertificateInvalid,
    ConnectionClosed,
};

pub fn connect(_: [4]u8, _: u16) Error!void {
    return Error.NotImplemented;
}

pub fn send(_: []const u8) Error!void {
    return Error.NotImplemented;
}

pub fn recv(_: []u8) Error!usize {
    return Error.NotImplemented;
}

pub fn close() void {}
