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
//   stack.tick();

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
    rto_ticks: u16 = 25,
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

        rx_window: u16 = 0,
        remote_window: u16 = 0,

        pending_tx: ?PendingTx = null,
        work: WorkFlags = .{},

        retx_deadline: u32 = 0,
        timer_timewait: u16 = 0,

        app: ?AppVTable = null,
        priority: u8 = 0,

        rx_buf: [2048]u8 = undefined,
        rx_len: u16 = 0,
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
        isn_state: u32,
        next_port: u16,

        pub fn init() Self {
            return .{
                .tx_buf = undefined,
                .rx_slots = [_]RxSlot{.{}} ** cfg.rx_ring_count,
                .conns = [_]Connection{.{}} ** cfg.tcp_conn_count,
                .listeners = [_]Listener{.{}} ** cfg.tcp_listener_count,
                .stats = .{},
                .ticks = 0,
                .isn_state = 0x12345678,
                .next_port = 49152,
            };
        }

        pub fn tick(self: *Self) void {
            self.ticks +%= 1;
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
                if (conn.used and conn.local_port == local_port and
                    conn.remote_port == remote_port and
                    conn.remote_ip[0] == remote_ip[0] and
                    conn.remote_ip[1] == remote_ip[1] and
                    conn.remote_ip[2] == remote_ip[2] and
                    conn.remote_ip[3] == remote_ip[3])
                {
                    return @intCast(i);
                }
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

        pub fn generateIsn(self: *Self) u32 {
            self.isn_state +%= self.ticks +% 64000;
            return self.isn_state;
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

            if (data_off > tcp_data.len) return;
            const payload = tcp_data[data_off..];

            if (flags & FLAG_RST != 0) self.stats.tcp_rst_rx += 1;

            if (self.findConn(dst_port, src_port, src_ip)) |id| {
                self.onConnSegment(id, seq, ack_num, flags, window, payload);
                return;
            }

            if (flags & FLAG_SYN != 0) {
                if (self.findListener(dst_port)) |listener| {
                    self.onListenSyn(listener, src_ip, src_port, dst_port, seq, window);
                    return;
                }
            }
        }

        fn onConnSegment(self: *Self, id: ConnId, seq: u32, ack_num: u32, flags: u8, window: u16, payload: []const u8) void {
            const conn = &self.conns[id];

            switch (conn.state) {
                .syn_sent => {
                    if (flags & FLAG_RST != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }
                    if (flags & FLAG_SYN != 0 and flags & FLAG_ACK != 0) {
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
                    if (flags & FLAG_ACK != 0 and ack_num == conn.snd_nxt) {
                        conn.snd_una = ack_num;
                        conn.remote_window = window;
                        conn.pending_tx = null;
                        conn.state = .established;
                        if (conn.app) |app| app.on_open(app.ctx, id);
                    }
                },
                .established => {
                    if (flags & FLAG_RST != 0) {
                        self.closeConn(id, .reset);
                        return;
                    }

                    if (payload.len > 0 and seq == conn.rcv_nxt) {
                        const space = conn.rx_buf.len - conn.rx_len;
                        const n: u16 = @intCast(@min(payload.len, space));
                        @memcpy(conn.rx_buf[conn.rx_len..][0..n], payload[0..n]);
                        conn.rx_len += n;
                        conn.rcv_nxt +%= n;
                        conn.work.has_rx_data = true;
                        conn.work.ack_due = true;

                        if (conn.app) |app| app.on_recv(app.ctx, id, payload[0..n]);
                    }

                    if (flags & FLAG_ACK != 0) {
                        self.processAck(id, ack_num, window);
                    }

                    if (flags & FLAG_FIN != 0) {
                        conn.rcv_nxt +%= 1;
                        conn.state = .close_wait;
                        conn.work.ack_due = true;
                    } else if (payload.len > 0) {
                        conn.work.ack_due = true;
                    }
                },
                .fin_wait_1 => {
                    if (flags & FLAG_ACK != 0) {
                        conn.snd_una = ack_num;
                        if (flags & FLAG_FIN != 0) {
                            conn.rcv_nxt +%= 1;
                            conn.state = .time_wait;
                            conn.timer_timewait = 3000;
                            conn.work.ack_due = true;
                        } else {
                            conn.state = .fin_wait_2;
                        }
                    }
                },
                .fin_wait_2 => {
                    if (flags & FLAG_FIN != 0) {
                        conn.rcv_nxt +%= 1;
                        conn.state = .time_wait;
                        conn.timer_timewait = 3000;
                        conn.work.ack_due = true;
                    }
                },
                .last_ack => {
                    if (flags & FLAG_ACK != 0) {
                        self.closeConn(id, .normal);
                    }
                },
                .closing => {
                    if (flags & FLAG_ACK != 0) {
                        conn.state = .time_wait;
                        conn.timer_timewait = 3000;
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
            conn.iss = self.generateIsn();
            conn.snd_nxt = conn.iss +% 1;
            conn.snd_una = conn.iss;
            conn.app = listener.app;
            conn.state = .syn_rcvd;
            conn.pending_tx = .{ .seq = conn.iss, .syn = true, .rto_ticks = 25 };
            conn.work.ack_due = true;
        }

        fn processAck(self: *Self, id: ConnId, ack_num: u32, window: u16) void {
            const conn = &self.conns[id];
            conn.remote_window = window;

            if (conn.pending_tx) |ptx| {
                const end_seq = ptx.seq +% ptx.len + @as(u32, if (ptx.syn) 1 else 0) + @as(u32, if (ptx.fin) 1 else 0);
                if (seqGe(ack_num, end_seq)) {
                    if (ptx.has_data) {
                        if (conn.app) |app| app.on_sent(app.ctx, id, ptx.token);
                    }
                    conn.pending_tx = null;
                    conn.snd_una = ack_num;
                    self.stats.tcp_tx += 1;
                }
            } else {
                conn.snd_una = ack_num;
            }
        }

        fn closeConn(self: *Self, id: ConnId, reason: CloseReason) void {
            const conn = &self.conns[id];
            if (conn.app) |app| app.on_closed(app.ctx, id, reason);
            self.freeConn(id);
        }

        // ── TCP output processing (work-flag driven) ─────────

        pub fn tcpPollOutput(self: *Self) void {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) continue;
                const id: ConnId = @intCast(i);
                self.processConnOutput(id, conn);
            }
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
                    self.emitSegment(conn, f, ptx.seq, if (conn.state == .syn_rcvd) conn.rcv_nxt else 0, &.{});
                } else if (ptx.has_data) {
                    if (conn.app) |app| {
                        const req = TxRequest{
                            .max_payload = @intCast(@min(1460, conn.remote_window)),
                            .reason = .retransmit,
                            .token = ptx.token,
                        };
                        var payload_buf: [1460]u8 = undefined;
                        const resp = app.produce_tx(app.ctx, id, req, &payload_buf);
                        self.emitSegment(conn, FLAG_ACK | FLAG_PSH, ptx.seq, conn.rcv_nxt, payload_buf[0..resp.len]);
                    }
                }

                ptx.rto_ticks = @min(ptx.rto_ticks *| 2, 500);
                conn.retx_deadline = self.ticks + ptx.rto_ticks;
            }
        }

        fn produceAndSend(self: *Self, id: ConnId, conn: *Connection) void {
            const app = conn.app orelse return;
            const mss: u16 = @intCast(@min(1460, conn.remote_window));
            if (mss == 0) return;

            const req = TxRequest{
                .max_payload = mss,
                .reason = .send_new,
                .token = 0,
            };
            var payload_buf: [1460]u8 = undefined;
            const resp = app.produce_tx(app.ctx, id, req, &payload_buf);
            if (resp.len == 0 and !resp.fin) return;

            var f: u8 = FLAG_ACK;
            if (resp.len > 0) f |= FLAG_PSH;
            if (resp.fin) f |= FLAG_FIN;

            self.emitSegment(conn, f, conn.snd_nxt, conn.rcv_nxt, payload_buf[0..resp.len]);

            conn.pending_tx = .{
                .seq = conn.snd_nxt,
                .len = resp.len,
                .has_data = resp.len > 0,
                .fin = resp.fin,
                .rto_ticks = 25,
                .token = resp.token,
            };
            conn.snd_nxt +%= resp.len + @as(u32, if (resp.fin) 1 else 0);
            conn.retx_deadline = self.ticks + 25;

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
            self.emitSegment(conn, f, seq, conn.rcv_nxt, &.{});
        }

        fn sendFin(self: *Self, conn: *Connection) void {
            self.emitSegment(conn, FLAG_FIN | FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
            conn.pending_tx = .{ .seq = conn.snd_nxt, .fin = true, .rto_ticks = 25 };
            conn.snd_nxt +%= 1;
            conn.retx_deadline = self.ticks + 25;
            conn.state = switch (conn.state) {
                .established => .fin_wait_1,
                .close_wait => .last_ack,
                else => conn.state,
            };
        }

        fn emitSegment(self: *Self, conn: *Connection, flags: u8, seq: u32, ack_num: u32, payload: []const u8) void {
            const hdr_len: usize = 20;
            const total = hdr_len + payload.len;
            if (total > self.tx_buf.len) return;

            self.tx_buf[0] = @intCast(conn.local_port >> 8);
            self.tx_buf[1] = @intCast(conn.local_port & 0xFF);
            self.tx_buf[2] = @intCast(conn.remote_port >> 8);
            self.tx_buf[3] = @intCast(conn.remote_port & 0xFF);
            writeBE32(self.tx_buf[4..8], seq);
            writeBE32(self.tx_buf[8..12], ack_num);
            self.tx_buf[12] = (hdr_len / 4) << 4;
            self.tx_buf[13] = flags;
            const win: u16 = @intCast(conn.rx_buf.len - conn.rx_len);
            self.tx_buf[14] = @intCast(win >> 8);
            self.tx_buf[15] = @intCast(win & 0xFF);
            self.tx_buf[16] = 0;
            self.tx_buf[17] = 0;
            self.tx_buf[18] = 0;
            self.tx_buf[19] = 0;

            if (payload.len > 0) {
                @memcpy(self.tx_buf[hdr_len..][0..payload.len], payload);
            }

            const cksum = tcpChecksum(self.tx_buf[0..total], conn);
            self.tx_buf[16] = @intCast(cksum >> 8);
            self.tx_buf[17] = @intCast(cksum & 0xFF);

            const ipv4 = @import("ipv4.zig");
            ipv4.sendPacket(conn.remote_ip, ipv4.PROTO_TCP, self.tx_buf[0..total]) catch {};
            self.stats.tcp_tx += 1;
        }

        // ── TCP timer processing ─────────────────────────────

        pub fn tcpPollTimers(self: *Self) void {
            for (&self.conns, 0..) |*conn, i| {
                if (!conn.used) continue;

                if (conn.pending_tx != null and self.ticks >= conn.retx_deadline) {
                    conn.work.retx_due = true;
                }

                if (conn.state == .time_wait) {
                    if (conn.timer_timewait > 0) {
                        conn.timer_timewait -= 1;
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
            conn.iss = self.generateIsn();
            conn.snd_nxt = conn.iss +% 1;
            conn.snd_una = conn.iss;
            conn.app = app;
            conn.state = .syn_sent;
            conn.pending_tx = .{ .seq = conn.iss, .syn = true, .rto_ticks = 25 };
            conn.retx_deadline = self.ticks + 25;

            self.emitSegment(conn, FLAG_SYN, conn.iss, 0, &.{});
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

fn readBE32(p: []const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

fn writeBE32(p: []u8, val: u32) void {
    p[0] = @intCast((val >> 24) & 0xFF);
    p[1] = @intCast((val >> 16) & 0xFF);
    p[2] = @intCast((val >> 8) & 0xFF);
    p[3] = @intCast(val & 0xFF);
}

fn seqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

fn tcpChecksum(seg: []const u8, conn: anytype) u16 {
    const dhcp = @import("dhcp_client.zig");
    var sum: u32 = 0;

    sum += (@as(u32, dhcp.ip_addr[0]) << 8) | dhcp.ip_addr[1];
    sum += (@as(u32, dhcp.ip_addr[2]) << 8) | dhcp.ip_addr[3];
    sum += (@as(u32, conn.remote_ip[0]) << 8) | conn.remote_ip[1];
    sum += (@as(u32, conn.remote_ip[2]) << 8) | conn.remote_ip[3];
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
