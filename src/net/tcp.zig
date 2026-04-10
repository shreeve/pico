// Minimal TCP — single-connection state machine.
//
// Supports one active connection at a time (client or server).
// Enough for MQTT (single broker connection) and script push.
// No concurrent streams, no fancy congestion control.
//
// Known gap: data segment retransmission is not yet implemented.
// Only SYN retransmission exists. This will be replaced by a
// uIP-inspired app-driven retransmit model (produce_tx callback
// with segment tokens, zero stack payload buffering).
//
// Reference: RFC 793 (TCP), RFC 1122 (host requirements)

const ipv4 = @import("ipv4.zig");
const dhcp = @import("dhcp.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;

pub const TCP_PORT: u16 = 9001;

pub const ConnState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

pub const Error = error{
    NotImplemented,
    NotConnected,
    BufferFull,
    SendFailed,
    Timeout,
};

var state: ConnState = .closed;
var local_port: u16 = 0;
var remote_port: u16 = 0;
var remote_ip: [4]u8 = [_]u8{0} ** 4;

var snd_nxt: u32 = 0;
var snd_una: u32 = 0;
var rcv_nxt: u32 = 0;
var remote_window: u16 = 0;

const RX_BUF_SIZE = 4096;
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_len: usize = 0;

const TX_BUF_SIZE = 2048;
var tx_buf: [TX_BUF_SIZE]u8 = undefined;
var tx_len: usize = 0;

var isn: u32 = 0x12345678;
var retransmit_ms: u64 = 0;
var retransmit_count: u8 = 0;
const RETRANSMIT_TIMEOUT_MS: u64 = 1000;
const MAX_RETRANSMITS: u8 = 5;
const TIME_WAIT_MS: u64 = 2000;
var time_wait_start: u64 = 0;

const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;

fn puts(s: []const u8) void {
    for (s) |ch| {
        if (ch == '\n') rp2040.uartWrite(rp2040.UART0_BASE, '\r');
        rp2040.uartWrite(rp2040.UART0_BASE, ch);
    }
}

// ── Public API ───────────────────────────────────────────────────────

pub fn init() void {
    state = .closed;
    rx_len = 0;
    tx_len = 0;
}

pub fn connect(dst_ip: [4]u8, dst_port: u16) Error!void {
    if (state != .closed) return Error.NotConnected;

    remote_ip = dst_ip;
    remote_port = dst_port;
    local_port = nextEphemeralPort();
    isn = generateIsn();
    snd_nxt = isn +% 1;
    snd_una = isn;
    rx_len = 0;
    tx_len = 0;
    retransmit_count = 0;

    sendSegment(FLAG_SYN, isn, 0, &.{}) catch return Error.SendFailed;
    retransmit_ms = hal.millis() + RETRANSMIT_TIMEOUT_MS;
    state = .syn_sent;
}

pub fn listenOn(port: u16) void {
    state = .listen;
    local_port = port;
    rx_len = 0;
    tx_len = 0;
}

pub fn send(data: []const u8) Error!void {
    if (state != .established and state != .close_wait) return Error.NotConnected;

    const avail = TX_BUF_SIZE - tx_len;
    if (data.len > avail) return Error.BufferFull;

    @memcpy(tx_buf[tx_len..][0..data.len], data);
    tx_len += data.len;

    flushTx() catch return Error.SendFailed;
}

pub fn close() void {
    switch (state) {
        .established => {
            sendSegment(FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
            snd_nxt +%= 1;
            state = .fin_wait_1;
        },
        .close_wait => {
            sendSegment(FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
            snd_nxt +%= 1;
            state = .last_ack;
        },
        else => {
            state = .closed;
        },
    }
}

pub fn isConnected() bool {
    return state == .established;
}

pub fn rxAvailable() usize {
    return rx_len;
}

pub fn rxConsume(buf: []u8) usize {
    const n = @min(buf.len, rx_len);
    @memcpy(buf[0..n], rx_buf[0..n]);
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

// ── Inbound packet handling (called from ipv4.zig) ───────────────────

pub fn handleSegment(src_ip: []const u8, tcp_data: []const u8) void {
    if (tcp_data.len < 20) return;

    const src_port = (@as(u16, tcp_data[0]) << 8) | tcp_data[1];
    const dst_port = (@as(u16, tcp_data[2]) << 8) | tcp_data[3];
    const seq = readBE32(tcp_data[4..8]);
    const ack = readBE32(tcp_data[8..12]);
    const data_off: usize = @as(usize, tcp_data[12] >> 4) * 4;
    const flags = tcp_data[13];
    const window = (@as(u16, tcp_data[14]) << 8) | tcp_data[15];

    if (data_off > tcp_data.len) return;
    const payload = tcp_data[data_off..];

    switch (state) {
        .listen => {
            if (flags & FLAG_SYN == 0) return;
            if (dst_port != local_port) return;

            @memcpy(&remote_ip, src_ip[0..4]);
            remote_port = src_port;
            remote_window = window;
            rcv_nxt = seq +% 1;
            isn = generateIsn();
            snd_nxt = isn +% 1;
            snd_una = isn;

            sendSegment(FLAG_SYN | FLAG_ACK, isn, rcv_nxt, &.{}) catch return;
            state = .syn_received;
            retransmit_ms = hal.millis() + RETRANSMIT_TIMEOUT_MS;
        },
        .syn_sent => {
            if (src_port != remote_port or dst_port != local_port) return;
            if (flags & FLAG_RST != 0) {
                state = .closed;
                return;
            }
            if (flags & FLAG_SYN != 0 and flags & FLAG_ACK != 0) {
                if (ack != snd_nxt) return;
                rcv_nxt = seq +% 1;
                snd_una = ack;
                remote_window = window;
                sendSegment(FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
                state = .established;
                puts("[tcp] connected\n");
            }
        },
        .syn_received => {
            if (flags & FLAG_ACK != 0 and ack == snd_nxt) {
                snd_una = ack;
                remote_window = window;
                state = .established;
                puts("[tcp] accepted\n");
            }
        },
        .established => {
            if (src_port != remote_port or dst_port != local_port) return;
            if (flags & FLAG_RST != 0) {
                state = .closed;
                return;
            }

            if (payload.len > 0 and seq == rcv_nxt) {
                const space = RX_BUF_SIZE - rx_len;
                const n = @min(payload.len, space);
                @memcpy(rx_buf[rx_len..][0..n], payload[0..n]);
                rx_len += n;
                rcv_nxt +%= @intCast(n);
            }

            if (flags & FLAG_ACK != 0) {
                snd_una = ack;
                remote_window = window;
            }

            if (flags & FLAG_FIN != 0) {
                rcv_nxt +%= 1;
                sendSegment(FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
                state = .close_wait;
            } else if (payload.len > 0 or flags & FLAG_ACK != 0) {
                sendSegment(FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
            }
        },
        .fin_wait_1 => {
            if (flags & FLAG_ACK != 0) {
                snd_una = ack;
                if (flags & FLAG_FIN != 0) {
                    rcv_nxt +%= 1;
                    sendSegment(FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
                    state = .time_wait;
                    time_wait_start = hal.millis();
                } else {
                    state = .fin_wait_2;
                }
            }
        },
        .fin_wait_2 => {
            if (flags & FLAG_FIN != 0) {
                rcv_nxt +%= 1;
                sendSegment(FLAG_ACK, snd_nxt, rcv_nxt, &.{}) catch {};
                state = .time_wait;
                time_wait_start = hal.millis();
            }
        },
        .last_ack => {
            if (flags & FLAG_ACK != 0) {
                state = .closed;
            }
        },
        .time_wait => {},
        .closed, .close_wait => {},
    }
}

pub fn tick() void {
    const now = hal.millis();
    switch (state) {
        .syn_sent, .syn_received => {
            if (now >= retransmit_ms) {
                retransmit_count += 1;
                if (retransmit_count > MAX_RETRANSMITS) {
                    state = .closed;
                    return;
                }
                if (state == .syn_sent) {
                    sendSegment(FLAG_SYN, isn, 0, &.{}) catch {};
                } else {
                    sendSegment(FLAG_SYN | FLAG_ACK, isn, rcv_nxt, &.{}) catch {};
                }
                retransmit_ms = now + RETRANSMIT_TIMEOUT_MS;
            }
        },
        .time_wait => {
            if (now - time_wait_start >= TIME_WAIT_MS) {
                state = .closed;
            }
        },
        else => {},
    }
}

// ── Segment building ─────────────────────────────────────────────────

fn sendSegment(flags: u8, seq: u32, ack_num: u32, payload: []const u8) !void {
    var seg: [60 + 1460]u8 = undefined;
    const hdr_len: usize = 20;
    const total = hdr_len + payload.len;
    if (total > seg.len) return error.PacketTooLarge;

    seg[0] = @intCast(local_port >> 8);
    seg[1] = @intCast(local_port & 0xFF);
    seg[2] = @intCast(remote_port >> 8);
    seg[3] = @intCast(remote_port & 0xFF);
    writeBE32(seg[4..8], seq);
    writeBE32(seg[8..12], ack_num);
    seg[12] = (hdr_len / 4) << 4;
    seg[13] = flags;
    const win: u16 = @intCast(RX_BUF_SIZE - rx_len);
    seg[14] = @intCast(win >> 8);
    seg[15] = @intCast(win & 0xFF);
    seg[16] = 0;
    seg[17] = 0;
    seg[18] = 0;
    seg[19] = 0;

    if (payload.len > 0) {
        @memcpy(seg[hdr_len..][0..payload.len], payload);
    }

    const cksum = tcpChecksum(seg[0..total]);
    seg[16] = @intCast(cksum >> 8);
    seg[17] = @intCast(cksum & 0xFF);

    ipv4.sendPacket(remote_ip, ipv4.PROTO_TCP, seg[0..total]) catch return error.SendFailed;
}

fn flushTx() !void {
    while (tx_len > 0) {
        const mss: usize = 1460;
        const n = @min(tx_len, mss);
        try sendSegment(FLAG_ACK | FLAG_PSH, snd_nxt, rcv_nxt, tx_buf[0..n]);
        snd_nxt +%= @intCast(n);

        if (n < tx_len) {
            const remaining = tx_len - n;
            var i: usize = 0;
            while (i < remaining) : (i += 1) {
                tx_buf[i] = tx_buf[n + i];
            }
        }
        tx_len -= n;
    }
}

fn tcpChecksum(seg: []const u8) u16 {
    var sum: u32 = 0;

    // Pseudo-header: src IP, dst IP, zero, protocol (6), TCP length
    sum += (@as(u32, dhcp.ip_addr[0]) << 8) | dhcp.ip_addr[1];
    sum += (@as(u32, dhcp.ip_addr[2]) << 8) | dhcp.ip_addr[3];
    sum += (@as(u32, remote_ip[0]) << 8) | remote_ip[1];
    sum += (@as(u32, remote_ip[2]) << 8) | remote_ip[3];
    sum += 6;
    sum += @as(u32, @intCast(seg.len));

    var i: usize = 0;
    while (i + 1 < seg.len) : (i += 2) {
        sum += (@as(u32, seg[i]) << 8) | seg[i + 1];
    }
    if (i < seg.len) sum += @as(u32, seg[i]) << 8;

    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

// ── Helpers ──────────────────────────────────────────────────────────

fn readBE32(p: []const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

fn writeBE32(p: []u8, val: u32) void {
    p[0] = @intCast((val >> 24) & 0xFF);
    p[1] = @intCast((val >> 16) & 0xFF);
    p[2] = @intCast((val >> 8) & 0xFF);
    p[3] = @intCast(val & 0xFF);
}

var ephemeral_port: u16 = 49152;

fn nextEphemeralPort() u16 {
    ephemeral_port +%= 1;
    if (ephemeral_port < 49152) ephemeral_port = 49152;
    return ephemeral_port;
}

fn generateIsn() u32 {
    isn +%= @as(u32, @intCast(hal.millis() & 0xFFFF)) +% 64000;
    return isn;
}
