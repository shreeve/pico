// Comptime-composed network stack for embedded devices.
//
// Inspired by uIP's philosophy (single TX buffer, app-driven retransmit,
// stop-and-wait TCP, no dynamic allocation) but expressed idiomatically
// in Zig with compile-time protocol inclusion and fixed-capacity structures.
//
// Usage:
//   const net = @import("net/tcpip.zig");
//   const Stack = net.NetStack(.{ .tcp_conn_count = 4, .enable_icmp = true });
//   var stack: Stack = Stack.init();
//   stack.tick(now_ms);

const ipv4 = @import("ipv4.zig");
const byteutil = @import("../lib/byteutil.zig");

pub const Config = struct {
    enable_arp: bool = true,
    enable_icmp: bool = true,
    enable_udp: bool = true,
    enable_tcp: bool = true,

    tcp_conn_count: usize = 4,
    tcp_listener_count: usize = 2,
    arp_entries: usize = 8,
    rx_ring_count: usize = 3,
    mtu: usize = 1500,
    rcv_wnd: u16 = 2048,

    /// TIME-WAIT duration in milliseconds. Larger values reduce risk of
    /// old-segment acceptance on rapid reconnect, but tie up connection slots.
    tcp_timewait_ms: u32 = 30_000,
};

pub const default_config = Config{};

// ── Types shared across the stack ────────────────────────────────────

pub const TcpState = enum(u4) {
    closed,
    listen,
    syn_sent,
    syn_rcvd,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    closing,
    last_ack,
    time_wait,
};

pub const TxReason = enum { send_new, retransmit, probe };

pub const CloseReason = enum { normal, reset, timeout, link_down };

pub const ConnId = u8;

pub const TxRequest = struct {
    max_payload: u16,
    reason: TxReason,
    token: u16,
};

pub const TxResponse = struct {
    len: u16,
    fin: bool = false,
    token: u16,
};

pub const AppVTable = struct {
    ctx: *anyopaque,
    on_open: *const fn (*anyopaque, ConnId) void,
    on_recv: *const fn (*anyopaque, ConnId, []const u8) void,
    on_sent: *const fn (*anyopaque, ConnId, u16) void,
    on_closed: *const fn (*anyopaque, ConnId, CloseReason) void,
    produce_tx: *const fn (*anyopaque, ConnId, TxRequest, []u8) TxResponse,
};

pub const PendingTx = struct {
    seq: u32 = 0,
    len: u16 = 0,
    syn: bool = false,
    fin: bool = false,
    has_data: bool = false,
    retries: u8 = 0,
    rto_ms: u16 = 250,
    token: u16 = 0,
};

pub const WorkFlags = packed struct(u8) {
    has_rx_data: bool = false,
    ack_due: bool = false,
    tx_ready: bool = false,
    retx_due: bool = false,
    close_due: bool = false,
    _pad: u3 = 0,
};

pub const Stats = struct {
    rx_frames: u32 = 0,
    rx_drop_no_slot: u32 = 0,
    ip_rx: u32 = 0,
    ip_bad_checksum: u32 = 0,
    ip_bad_len: u32 = 0,
    ip_fragmented_drop: u32 = 0,
    arp_rx: u32 = 0,
    arp_hits: u32 = 0,
    arp_misses: u32 = 0,
    icmp_rx: u32 = 0,
    icmp_tx: u32 = 0,
    tcp_rx: u32 = 0,
    tcp_tx: u32 = 0,
    tcp_retx: u32 = 0,
    tcp_rst_rx: u32 = 0,
    tcp_rst_tx: u32 = 0,
    tcp_bad_checksum: u32 = 0,
    tcp_connect_timeout: u32 = 0,
    udp_rx: u32 = 0,
    dhcp_renew_fail: u32 = 0,
    link_down_count: u32 = 0,
};

// ── Parameterized stack type ─────────────────────────────────────────

pub fn NetStack(comptime cfg: Config) type {
    const max_frame = cfg.mtu + 14 + 4;

    const RxSlot = struct {
        buf: [max_frame]u8 align(4) = undefined,
        len: u16 = 0,
        used: bool = false,
    };

    const Connection = struct {
        used: bool = false,
        state: TcpState = .closed,

        local_port: u16 = 0,
        remote_port: u16 = 0,
        remote_ip: [4]u8 = [_]u8{0} ** 4,

        snd_una: u32 = 0,
        snd_nxt: u32 = 0,
        rcv_nxt: u32 = 0,
        iss: u32 = 0,

        remote_window: u16 = 0,

        pending_tx: ?PendingTx = null,
        work: WorkFlags = .{},

        retx_deadline_ms: u32 = 0,
        timer_timewait_ms: u32 = 0,
        persist_deadline_ms: u32 = 0,
        persist_backoff_ms: u16 = 0,
        arp_pending: bool = false,
        arp_retry_ms: u16 = 0,

        app: ?AppVTable = null,
    };

    const Listener = struct {
        used: bool = false,
        port: u16 = 0,
        app: ?AppVTable = null,
    };

    return struct {
        const Self = @This();

        tx_buf: [max_frame]u8 align(4),
        rx_slots: [cfg.rx_ring_count]RxSlot,
        conns: [cfg.tcp_conn_count]Connection,
        listeners: [cfg.tcp_listener_count]Listener,
        stats: Stats,
        ticks: u32,
        isn_secret: u32,
        isn_counter: u32,
        next_port: u16,

        // Stack-owned IPv4 configuration (canonical source of network identity)
        local_ip: [4]u8,
        subnet_mask: [4]u8,
        gateway_ip: [4]u8,

        last_tick_ms: u32,

        pub fn init() Self {
            return .{
                .tx_buf = undefined,
                .rx_slots = [_]RxSlot{.{}} ** cfg.rx_ring_count,
                .conns = [_]Connection{.{}} ** cfg.tcp_conn_count,
                .listeners = [_]Listener{.{}} ** cfg.tcp_listener_count,
                .stats = .{},
                .ticks = 0,
                .isn_secret = 0x6d2b79f5,
                .isn_counter = 0,
                .next_port = 49152,
                .local_ip = .{ 0, 0, 0, 0 },
                .subnet_mask = .{ 0, 0, 0, 0 },
                .gateway_ip = .{ 0, 0, 0, 0 },
                .last_tick_ms = 0,
            };
        }

        /// Set the stack's IPv4 configuration. Called by DHCP on lease
        /// acquisition/renewal, or directly for static IP configuration.
        /// Note: does not invalidate active TCP connections. If the address
        /// changes (e.g. DHCP rebind to new IP), existing connections will
        /// silently break — acceptable for embedded single-interface use.
        pub fn setIpv4(self: *Self, ip: [4]u8, mask: [4]u8, gw: [4]u8) void {
            self.local_ip = ip;
            self.subnet_mask = mask;
            self.gateway_ip = gw;
        }

        /// Advance stack timers and process TCP output. Call once per
        /// main loop iteration with current wall-clock milliseconds.
        /// Wrapping subtraction is safe for u32 ms (~49 day wrap).
        /// Elapsed is clamped to 10s to prevent timer drain after
        /// long stalls or the first call when last_tick_ms == 0.
        pub fn tick(self: *Self, now_ms: u32) void {
            self.ticks +%= 1;
            const raw_elapsed = now_ms -% self.last_tick_ms;
            const elapsed_ms = @min(raw_elapsed, 10_000);
            self.last_tick_ms = now_ms;
            self.tcpPollTimers(elapsed_ms);
            self.tcpPollOutput(elapsed_ms);
        }

        // ── RX ring ──────────────────────────────────────────────

        pub fn rxAllocSlot(self: *Self) ?*RxSlot {
            for (&self.rx_slots) |*slot| {
                if (!slot.used) return slot;
            }
            self.stats.rx_drop_no_slot += 1;
            return null;
        }

        pub fn rxFreeSlot(_: *Self, slot: *RxSlot) void {
            slot.used = false;
            slot.len = 0;
        }

        // ── Connection management ────────────────────────────────

        pub fn allocConn(self: *Self) ?ConnId {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) {
                    conn.* = .{};
                    conn.used = true;
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn freeConn(self: *Self, id: ConnId) void {
            if (id >= cfg.tcp_conn_count) return;
            self.conns[id] = .{};
        }

        pub fn getConn(self: *Self, id: ConnId) ?*Connection {
            if (id >= cfg.tcp_conn_count) return null;
            if (!self.conns[id].used) return null;
            return &self.conns[id];
        }

        pub fn findConn(self: *Self, local_port: u16, remote_port: u16, remote_ip: [4]u8) ?ConnId {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) continue;
                if (conn.local_port != local_port) continue;
                if (conn.remote_port != remote_port) continue;
                if (!ipv4Eq(conn.remote_ip, remote_ip)) continue;
                return @intCast(i);
            }
            return null;
        }

        pub fn findListener(self: *Self, port: u16) ?*Listener {
            for (&self.listeners) |*l| {
                if (l.used and l.port == port) return l;
            }
            return null;
        }

        // ── Port allocation ──────────────────────────────────────

        pub fn ephemeralPort(self: *Self) u16 {
            self.next_port +%= 1;
            if (self.next_port < 49152) self.next_port = 49152;
            return self.next_port;
        }

        pub fn seedIsn(self: *Self, boot_ticks: u32, timer_low: u32) void {
            var x = boot_ticks ^ timer_low ^ 0x6d2b79f5;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.isn_secret = x;
        }

        pub fn generateIsn(self: *Self, local_port: u16, remote_ip: [4]u8, remote_port: u16) u32 {
            self.isn_counter +%= 1;
            const lip = @as(u32, @bitCast(self.local_ip));
            const rip = @as(u32, @bitCast(remote_ip));
            const ports = (@as(u32, local_port) << 16) | @as(u32, remote_port);
            return mix32(lip ^ rip ^ ports ^ self.last_tick_ms ^ self.isn_secret ^ self.isn_counter);
        }

        // ── TCP segment input ─────────────────────────────────

        pub fn tcpInput(self: *Self, src_ip: [4]u8, tcp_data: []const u8) void {
            if (tcp_data.len < 20) return;
            self.stats.tcp_rx += 1;

            const src_port = (@as(u16, tcp_data[0]) << 8) | tcp_data[1];
            const dst_port = (@as(u16, tcp_data[2]) << 8) | tcp_data[3];
            const seq = readBE32(tcp_data[4..8]);
            const ack_num = readBE32(tcp_data[8..12]);
            const data_off: usize = @as(usize, tcp_data[12] >> 4) * 4;
            const flags = tcp_data[13];
            const window = (@as(u16, tcp_data[14]) << 8) | tcp_data[15];

            if (data_off < 20 or data_off > tcp_data.len) return;
            const payload = tcp_data[data_off..];

            if (!tcpChecksumValid(src_ip, self.local_ip, tcp_data)) {
                self.stats.tcp_bad_checksum += 1;
                return;
            }

            if ((flags & FLAG_RST) != 0) self.stats.tcp_rst_rx += 1;

            if (self.findConn(dst_port, src_port, src_ip)) |id| {
                self.onConnSegment(id, seq, ack_num, flags, window, payload);
                return;
            }

            if ((flags & FLAG_SYN) != 0 and (flags & FLAG_ACK) == 0) {
                if (self.findListener(dst_port)) |listener| {
                    self.onListenSyn(listener, src_ip, src_port, dst_port, seq, window);
                    return;
                }
            }

            if ((flags & FLAG_RST) == 0) {
                self.sendResetForUnmatched(src_ip, src_port, dst_port, seq, ack_num, flags, payload.len);
            }
        }

        fn onConnSegment(self: *Self, id: ConnId, seq: u32, ack_num: u32, flags: u8, window: u16, payload: []const u8) void {
            const conn = &self.conns[id];

            switch (conn.state) {
                .syn_sent => {
                    if ((flags & FLAG_RST) != 0) {
                        if ((flags & FLAG_ACK) != 0 and ack_num == conn.snd_nxt) {
                            self.closeConn(id, .reset);
                        }
                        return;
                    }

                    // Simultaneous open: peer SYN without ACK
                    if ((flags & FLAG_SYN) != 0 and (flags & FLAG_ACK) == 0) {
                        conn.rcv_nxt = seq +% 1;
                        conn.remote_window = window;
                        conn.state = .syn_rcvd;
                        conn.work.ack_due = true;
                        return;
                    }

                    if ((flags & FLAG_SYN) != 0 and (flags & FLAG_ACK) != 0) {
                        if (!ackAcceptable(conn, ack_num)) return;
                        if (ack_num != conn.snd_nxt) return;

                        conn.rcv_nxt = seq +% 1;
                        conn.snd_una = ack_num;
                        conn.remote_window = window;
                        conn.pending_tx = null;
                        conn.state = .established;
                        conn.work.ack_due = true;
                        if (conn.app) |app| app.on_open(app.ctx, id);
                    }
                },

                .syn_rcvd => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    // Duplicate SYN from client: resend our SYN-ACK
                    if ((flags & FLAG_SYN) != 0 and (flags & FLAG_ACK) == 0) {
                        if (seq == conn.rcv_nxt -% 1) {
                            _ = self.emitSegment(conn, FLAG_SYN | FLAG_ACK, conn.iss, conn.rcv_nxt, &.{});
                        }
                        return;
                    }

                    if ((flags & FLAG_ACK) != 0) {
                        if (!ackAcceptable(conn, ack_num)) return;
                        if (ack_num != conn.snd_nxt) return;

                        conn.snd_una = ack_num;
                        conn.remote_window = window;
                        conn.pending_tx = null;
                        conn.state = .established;
                        if (conn.app) |app| app.on_open(app.ctx, id);
                    }
                },

                .established => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    conn.remote_window = window;

                    if (!seqAcceptable(conn, seq, flags, payload)) {
                        conn.work.ack_due = true;
                        return;
                    }

                    if ((flags & FLAG_ACK) != 0) {
                        if (ackAcceptable(conn, ack_num)) {
                            self.processAck(id, ack_num, window);
                        }
                    }

                    if (payload.len > 0) {
                        conn.rcv_nxt +%= @as(u32, @intCast(payload.len));
                        conn.work.ack_due = true;
                        if (conn.app) |app| app.on_recv(app.ctx, id, payload);
                    }

                    if ((flags & FLAG_FIN) != 0) {
                        conn.rcv_nxt +%= 1;
                        conn.state = .close_wait;
                        conn.work.ack_due = true;
                    }
                },

                .close_wait => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    conn.remote_window = window;

                    if ((flags & FLAG_ACK) != 0 and ackAcceptable(conn, ack_num)) {
                        self.processAck(id, ack_num, window);
                    }

                    if (!seqAcceptable(conn, seq, flags, payload) or
                        payload.len > 0 or (flags & FLAG_FIN) != 0)
                    {
                        conn.work.ack_due = true;
                    }
                },

                .fin_wait_1 => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    conn.remote_window = window;

                    if (!seqAcceptable(conn, seq, flags, payload)) {
                        conn.work.ack_due = true;
                        return;
                    }

                    var fin_acked = false;
                    if ((flags & FLAG_ACK) != 0) {
                        if (ackAcceptable(conn, ack_num)) {
                            self.processAck(id, ack_num, window);
                            fin_acked = seqGe(ack_num, conn.snd_nxt);
                        }
                    }

                    if (payload.len > 0) {
                        conn.rcv_nxt +%= @as(u32, @intCast(payload.len));
                        conn.work.ack_due = true;
                        if (conn.app) |app| app.on_recv(app.ctx, id, payload);
                    }

                    if ((flags & FLAG_FIN) != 0) {
                        conn.rcv_nxt +%= 1;
                        conn.work.ack_due = true;
                        if (fin_acked) {
                            conn.state = .time_wait;
                            conn.timer_timewait_ms = cfg.tcp_timewait_ms;
                        } else {
                            conn.state = .closing;
                        }
                        return;
                    }

                    if (fin_acked) {
                        conn.state = .fin_wait_2;
                    }
                },

                .fin_wait_2 => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    conn.remote_window = window;

                    if (!seqAcceptable(conn, seq, flags, payload)) {
                        conn.work.ack_due = true;
                        return;
                    }

                    if ((flags & FLAG_ACK) != 0 and ackAcceptable(conn, ack_num)) {
                        self.processAck(id, ack_num, window);
                    }

                    if (payload.len > 0) {
                        conn.rcv_nxt +%= @as(u32, @intCast(payload.len));
                        conn.work.ack_due = true;
                        if (conn.app) |app| app.on_recv(app.ctx, id, payload);
                    }

                    if ((flags & FLAG_FIN) != 0) {
                        conn.rcv_nxt +%= 1;
                        conn.work.ack_due = true;
                        conn.state = .time_wait;
                        conn.timer_timewait_ms = cfg.tcp_timewait_ms;
                    }
                },

                .closing => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    conn.remote_window = window;

                    if ((flags & FLAG_ACK) != 0 and ackAcceptable(conn, ack_num)) {
                        self.processAck(id, ack_num, window);
                        if (ack_num == conn.snd_nxt) {
                            conn.state = .time_wait;
                            conn.timer_timewait_ms = cfg.tcp_timewait_ms;
                        }
                    }
                },

                .last_ack => {
                    if ((flags & FLAG_RST) != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    if ((flags & FLAG_ACK) != 0 and ackAcceptable(conn, ack_num)) {
                        self.processAck(id, ack_num, window);
                        if (ack_num == conn.snd_nxt) {
                            self.closeConn(id, .normal);
                        }
                    }
                },

                .time_wait => {
                    if ((flags & FLAG_FIN) != 0) {
                        conn.work.ack_due = true;
                        conn.timer_timewait_ms = cfg.tcp_timewait_ms;
                    }
                },

                else => {},
            }
        }

        fn onListenSyn(self: *Self, listener: *Listener, src_ip: [4]u8, src_port: u16, dst_port: u16, seq: u32, window: u16) void {
            const id = self.allocConn() orelse return;
            const conn = &self.conns[id];
            conn.remote_ip = src_ip;
            conn.remote_port = src_port;
            conn.local_port = dst_port;
            conn.remote_window = window;
            conn.rcv_nxt = seq +% 1;
            conn.iss = self.generateIsn(dst_port, src_ip, src_port);
            conn.snd_nxt = conn.iss +% 1;
            conn.snd_una = conn.iss;
            conn.app = listener.app;
            conn.state = .syn_rcvd;
            conn.pending_tx = .{ .seq = conn.iss, .syn = true, .rto_ms = 250 };
            conn.retx_deadline_ms = self.last_tick_ms +% 250;
            conn.work.ack_due = true;
        }

        fn processAck(self: *Self, id: ConnId, ack_num: u32, window: u16) void {
            const conn = &self.conns[id];
            const was_zero = conn.remote_window == 0;
            conn.remote_window = window;

            if (was_zero and window > 0 and conn.persist_backoff_ms > 0) {
                conn.persist_backoff_ms = 0;
                conn.work.tx_ready = true;
            }

            if (!ackAcceptable(conn, ack_num)) return;

            if (seqGt(ack_num, conn.snd_una)) {
                conn.snd_una = ack_num;
            }

            if (conn.pending_tx) |ptx| {
                const end_seq = ptx.seq +% ptx.len +
                    @as(u32, if (ptx.syn) 1 else 0) +
                    @as(u32, if (ptx.fin) 1 else 0);
                if (seqGe(ack_num, end_seq)) {
                    if (ptx.has_data) {
                        if (conn.app) |app| app.on_sent(app.ctx, id, ptx.token);
                    }
                    conn.pending_tx = null;
                }
            }
        }

        fn closeConn(self: *Self, id: ConnId, reason: CloseReason) void {
            const conn = &self.conns[id];
            if (conn.app) |app| app.on_closed(app.ctx, id, reason);
            self.freeConn(id);
        }

        // ── TCP output processing (work-flag driven) ─────────

        pub fn tcpPollOutput(self: *Self, elapsed_ms: u32) void {
            self.retryArpPending(elapsed_ms);
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) continue;
                const id: ConnId = @intCast(i);
                self.processConnOutput(id, conn);
            }
        }

        fn retryArpPending(self: *Self, elapsed_ms: u32) void {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used or !conn.arp_pending) continue;
                if (conn.arp_retry_ms > elapsed_ms) {
                    conn.arp_retry_ms -= @intCast(@min(elapsed_ms, conn.arp_retry_ms));
                    continue;
                }
                conn.arp_retry_ms = 0;
                if (conn.pending_tx) |ptx| {
                    const result = self.arpRetryEmit(@intCast(i), conn, ptx);
                    if (result == .sent) {
                        conn.arp_pending = false;
                    } else {
                        conn.arp_retry_ms = 50;
                    }
                } else {
                    conn.arp_pending = false;
                }
            }
        }

        fn arpRetryEmit(self: *Self, id: ConnId, conn: *Connection, ptx: PendingTx) EmitResult {
            if (ptx.syn) {
                const f: u8 = FLAG_SYN | (if (conn.state == .syn_rcvd) FLAG_ACK else 0);
                const ack_val: u32 = if (conn.state == .syn_rcvd) conn.rcv_nxt else 0;
                return self.emitSegment(conn, f, ptx.seq, ack_val, &.{});
            } else if (ptx.has_data) {
                if (conn.app) |app| {
                    const req = TxRequest{
                        .max_payload = @intCast(@min(1460, conn.remote_window)),
                        .reason = .retransmit,
                        .token = ptx.token,
                    };
                    var payload_buf: [1460]u8 = undefined;
                    const resp = app.produce_tx(app.ctx, id, req, &payload_buf);
                    var f: u8 = FLAG_ACK;
                    if (resp.len > 0) f |= FLAG_PSH;
                    if (ptx.fin) f |= FLAG_FIN;
                    return self.emitSegment(conn, f, ptx.seq, conn.rcv_nxt, payload_buf[0..resp.len]);
                }
                return .sent;
            } else if (ptx.fin) {
                return self.emitSegment(conn, FLAG_FIN | FLAG_ACK, ptx.seq, conn.rcv_nxt, &.{});
            }
            return .sent;
        }

        fn processConnOutput(self: *Self, id: ConnId, conn: *Connection) void {
            if (conn.work.retx_due) {
                conn.work.retx_due = false;
                self.retransmit(id, conn);
            }

            if (conn.work.ack_due) {
                conn.work.ack_due = false;
                self.sendAck(conn);
            }

            if (conn.work.tx_ready and conn.pending_tx == null) {
                conn.work.tx_ready = false;
                self.produceAndSend(id, conn);
            }

            if (conn.work.close_due and conn.pending_tx == null) {
                conn.work.close_due = false;
                self.sendFin(conn);
            }
        }

        fn retransmit(self: *Self, id: ConnId, conn: *Connection) void {
            if (conn.pending_tx) |*ptx| {
                ptx.retries += 1;
                if (ptx.retries > 5) {
                    self.stats.tcp_connect_timeout += 1;
                    self.closeConn(id, .timeout);
                    return;
                }
                self.stats.tcp_retx += 1;

                if (ptx.syn) {
                    const f: u8 = FLAG_SYN | (if (conn.state == .syn_rcvd) FLAG_ACK else 0);
                    const ack_val: u32 = if (conn.state == .syn_rcvd) conn.rcv_nxt else 0;
                    _ = self.emitSegment(conn, f, ptx.seq, ack_val, &.{});
                } else if (ptx.has_data) {
                    if (conn.app) |app| {
                        const req = TxRequest{
                            .max_payload = @intCast(@min(1460, conn.remote_window)),
                            .reason = .retransmit,
                            .token = ptx.token,
                        };
                        var payload_buf: [1460]u8 = undefined;
                        const resp = app.produce_tx(app.ctx, id, req, &payload_buf);
                        var f: u8 = FLAG_ACK;
                        if (resp.len > 0) f |= FLAG_PSH;
                        if (ptx.fin) f |= FLAG_FIN;
                        _ = self.emitSegment(conn, f, ptx.seq, conn.rcv_nxt, payload_buf[0..resp.len]);
                    }
                } else if (ptx.fin) {
                    _ = self.emitSegment(conn, FLAG_FIN | FLAG_ACK, ptx.seq, conn.rcv_nxt, &.{});
                }

                ptx.rto_ms = @min(ptx.rto_ms *| 2, 5000);
                conn.retx_deadline_ms = self.last_tick_ms +% ptx.rto_ms;
            }
        }

        fn produceAndSend(self: *Self, id: ConnId, conn: *Connection) void {
            if (conn.state != .established and conn.state != .close_wait) return;
            const app = conn.app orelse return;

            const is_probe = conn.remote_window == 0 and conn.persist_backoff_ms > 0;
            const mss: u16 = if (is_probe)
                1
            else
                @intCast(@min(1460, conn.remote_window));

            if (mss == 0) {
                if (conn.persist_backoff_ms == 0) {
                    conn.persist_backoff_ms = 250;
                    conn.persist_deadline_ms = self.last_tick_ms +% 250;
                }
                return;
            }

            const req = TxRequest{
                .max_payload = mss,
                .reason = if (is_probe) .probe else .send_new,
                .token = 0,
            };
            var payload_buf: [1460]u8 = undefined;
            const resp = app.produce_tx(app.ctx, id, req, &payload_buf);
            if (resp.len == 0 and !resp.fin) return;

            var f: u8 = FLAG_ACK;
            if (resp.len > 0) f |= FLAG_PSH;
            if (resp.fin) f |= FLAG_FIN;

            _ = self.emitSegment(conn, f, conn.snd_nxt, conn.rcv_nxt, payload_buf[0..resp.len]);

            conn.pending_tx = .{
                .seq = conn.snd_nxt,
                .len = resp.len,
                .has_data = resp.len > 0,
                .fin = resp.fin,
                .rto_ms = 250,
                .token = resp.token,
            };
            conn.snd_nxt +%= resp.len + @as(u32, if (resp.fin) 1 else 0);
            conn.retx_deadline_ms = self.last_tick_ms +% 250;

            if (is_probe) {
                conn.persist_backoff_ms = @min(conn.persist_backoff_ms *| 2, 5000);
                conn.persist_deadline_ms = self.last_tick_ms +% conn.persist_backoff_ms;
            } else {
                conn.persist_backoff_ms = 0;
            }

            if (resp.fin) {
                conn.state = switch (conn.state) {
                    .established => .fin_wait_1,
                    .close_wait => .last_ack,
                    else => conn.state,
                };
            }
        }

        fn sendAck(self: *Self, conn: *Connection) void {
            const f: u8 = FLAG_ACK | (if (conn.state == .syn_rcvd) FLAG_SYN else 0);
            const seq = if (conn.state == .syn_rcvd) conn.iss else conn.snd_nxt;
            _ = self.emitSegment(conn, f, seq, conn.rcv_nxt, &.{});
        }

        fn sendFin(self: *Self, conn: *Connection) void {
            _ = self.emitSegment(conn, FLAG_FIN | FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
            conn.pending_tx = .{ .seq = conn.snd_nxt, .fin = true, .rto_ms = 250 };
            conn.snd_nxt +%= 1;
            conn.retx_deadline_ms = self.last_tick_ms +% 250;
            conn.state = switch (conn.state) {
                .established => .fin_wait_1,
                .close_wait => .last_ack,
                else => conn.state,
            };
        }

        const EmitResult = enum { sent, arp_pending };

        fn emitSegment(self: *Self, conn: *Connection, flags: u8, seq: u32, ack_num: u32, payload: []const u8) EmitResult {
            const has_syn = (flags & FLAG_SYN) != 0;
            const opt_len: usize = if (has_syn) 4 else 0;
            const hdr_len: usize = 20 + opt_len;
            const total = hdr_len + payload.len;
            if (total > self.tx_buf.len) return .sent;

            self.tx_buf[0] = @intCast(conn.local_port >> 8);
            self.tx_buf[1] = @intCast(conn.local_port & 0xFF);
            self.tx_buf[2] = @intCast(conn.remote_port >> 8);
            self.tx_buf[3] = @intCast(conn.remote_port & 0xFF);
            writeBE32(self.tx_buf[4..8], seq);
            writeBE32(self.tx_buf[8..12], ack_num);
            self.tx_buf[12] = @intCast((hdr_len / 4) << 4);
            self.tx_buf[13] = flags;
            self.tx_buf[14] = @intCast(cfg.rcv_wnd >> 8);
            self.tx_buf[15] = @intCast(cfg.rcv_wnd & 0xFF);
            self.tx_buf[16] = 0;
            self.tx_buf[17] = 0;
            self.tx_buf[18] = 0;
            self.tx_buf[19] = 0;

            if (has_syn) {
                const mss: u16 = @intCast(@min(cfg.mtu -| 40, 1460));
                self.tx_buf[20] = 2; // MSS option kind
                self.tx_buf[21] = 4; // MSS option length
                self.tx_buf[22] = @intCast(mss >> 8);
                self.tx_buf[23] = @intCast(mss & 0xFF);
            }

            if (payload.len > 0) {
                @memcpy(self.tx_buf[hdr_len..][0..payload.len], payload);
            }

            const cksum = tcpChecksum(self.local_ip, conn.remote_ip, self.tx_buf[0..total]);
            self.tx_buf[16] = @intCast(cksum >> 8);
            self.tx_buf[17] = @intCast(cksum & 0xFF);

            ipv4.sendPacket(conn.remote_ip, ipv4.PROTO_TCP, self.tx_buf[0..total]) catch |err| switch (err) {
                error.ArpPending => return .arp_pending,
                else => return .arp_pending,
            };
            self.stats.tcp_tx += 1;
            return .sent;
        }

        fn sendResetForUnmatched(
            self: *Self,
            src_ip: [4]u8,
            src_port: u16,
            dst_port: u16,
            seq: u32,
            ack_num_in: u32,
            flags: u8,
            payload_len: usize,
        ) void {
            var tmp = Connection{};
            tmp.used = true;
            tmp.local_port = dst_port;
            tmp.remote_port = src_port;
            tmp.remote_ip = src_ip;

            if ((flags & FLAG_ACK) != 0) {
                _ = self.emitSegment(&tmp, FLAG_RST, ack_num_in, 0, &.{});
            } else {
                const ack_out = seq +% segSeqLen(flags, payload_len);
                _ = self.emitSegment(&tmp, FLAG_RST | FLAG_ACK, 0, ack_out, &.{});
            }
            self.stats.tcp_rst_tx += 1;
        }

        // ── TCP timer processing ─────────────────────────────

        pub fn tcpPollTimers(self: *Self, elapsed_ms: u32) void {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) continue;

                if (conn.pending_tx != null) {
                    const since = self.last_tick_ms -% conn.retx_deadline_ms;
                    if (@as(i32, @bitCast(since)) >= 0) {
                        conn.work.retx_due = true;
                    }
                }

                if (conn.persist_backoff_ms > 0) {
                    if (conn.pending_tx != null) {
                        // Probe is outstanding; normal retransmit handles it.
                        // Don't re-fire persist until probe is ACKed/timed out.
                    } else {
                        const ps = self.last_tick_ms -% conn.persist_deadline_ms;
                        if (@as(i32, @bitCast(ps)) >= 0) {
                            conn.work.tx_ready = true;
                        }
                    }
                }

                if (conn.state == .time_wait) {
                    if (conn.timer_timewait_ms > elapsed_ms) {
                        conn.timer_timewait_ms -= elapsed_ms;
                    } else {
                        self.freeConn(@intCast(i));
                    }
                }
            }
        }

        // ── TCP client connect ───────────────────────────────

        pub fn tcpConnect(self: *Self, dst_ip: [4]u8, dst_port: u16, app: AppVTable) ?ConnId {
            const id = self.allocConn() orelse return null;
            const conn = &self.conns[id];
            conn.remote_ip = dst_ip;
            conn.remote_port = dst_port;
            conn.local_port = self.ephemeralPort();
            conn.iss = self.generateIsn(conn.local_port, dst_ip, dst_port);
            conn.snd_nxt = conn.iss +% 1;
            conn.snd_una = conn.iss;
            conn.app = app;
            conn.state = .syn_sent;
            conn.pending_tx = .{ .seq = conn.iss, .syn = true, .rto_ms = 250 };
            conn.retx_deadline_ms = self.last_tick_ms +% 250;

            conn.arp_pending = self.emitSegment(conn, FLAG_SYN, conn.iss, 0, &.{}) == .arp_pending;
            return id;
        }

        // ── TCP listener ─────────────────────────────────────

        pub fn tcpListen(self: *Self, port: u16, app: AppVTable) bool {
            for (&self.listeners) |*l| {
                if (!l.used) {
                    l.* = .{ .used = true, .port = port, .app = app };
                    return true;
                }
            }
            return false;
        }

        // ── TCP close request ────────────────────────────────

        pub fn tcpClose(self: *Self, id: ConnId) void {
            if (id >= cfg.tcp_conn_count) return;
            if (!self.conns[id].used) return;
            self.conns[id].work.close_due = true;
        }

        // ── TCP send request ─────────────────────────────────

        pub fn tcpMarkSendReady(self: *Self, id: ConnId) void {
            if (id >= cfg.tcp_conn_count) return;
            self.conns[id].work.tx_ready = true;
        }

        // ── Compile-time info ────────────────────────────────

        pub fn memoryUsage() usize {
            var total: usize = 0;
            total += max_frame;
            total += max_frame * cfg.rx_ring_count;
            total += @sizeOf(Connection) * cfg.tcp_conn_count;
            total += @sizeOf(Listener) * cfg.tcp_listener_count;
            total += @sizeOf(Stats);
            return total;
        }

        pub fn configSummary() []const u8 {
            return "NetStack: " ++
                (if (cfg.enable_arp) "ARP " else "") ++
                (if (cfg.enable_icmp) "ICMP " else "") ++
                (if (cfg.enable_udp) "UDP " else "") ++
                (if (cfg.enable_tcp) "TCP " else "");
        }
    };
}

// ── Shared helpers (outside the generic type) ────────────────────────

const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;

const ipv4Eq = byteutil.ipv4Eq;
const readBE32 = byteutil.readBE32;
const writeBE32 = byteutil.writeBE32;

// Compact 32-bit finalizer (lowbias32) for ISN generation.
fn mix32(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

fn seqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

fn ackAcceptable(conn: anytype, ack_num: u32) bool {
    return seqGe(ack_num, conn.snd_una) and seqGe(conn.snd_nxt, ack_num);
}

// Minimal sequence acceptability for stop-and-wait: data/FIN must start
// at rcv_nxt; pure ACKs tolerate old duplicates.
fn seqAcceptable(conn: anytype, seq: u32, flags: u8, payload: []const u8) bool {
    if (payload.len == 0 and (flags & FLAG_FIN) == 0) {
        return seq == conn.rcv_nxt or seqLt(seq, conn.rcv_nxt);
    }
    return seq == conn.rcv_nxt;
}

fn segSeqLen(flags: u8, payload_len: usize) u32 {
    var n: u32 = @intCast(payload_len);
    if ((flags & FLAG_SYN) != 0) n +%= 1;
    if ((flags & FLAG_FIN) != 0) n +%= 1;
    return n;
}

fn tcpPseudoHeaderSum(src_ip: [4]u8, dst_ip: [4]u8, tcp_len: usize) u32 {
    var sum: u32 = 0;
    sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    sum += 6; // TCP protocol number
    sum += @as(u32, @intCast(tcp_len));
    return sum;
}

fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, seg: []const u8) u16 {
    var sum: u32 = tcpPseudoHeaderSum(src_ip, dst_ip, seg.len);

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

fn tcpChecksumValid(src_ip: [4]u8, dst_ip: [4]u8, seg: []const u8) bool {
    if (seg.len < 20) return false;
    var sum: u32 = tcpPseudoHeaderSum(src_ip, dst_ip, seg.len);

    var i: usize = 0;
    while (i + 1 < seg.len) : (i += 2) {
        sum += (@as(u32, seg[i]) << 8) | seg[i + 1];
    }
    if (i < seg.len) sum += @as(u32, seg[i]) << 8;

    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (@as(u16, @intCast(sum)) == 0xFFFF);
}
