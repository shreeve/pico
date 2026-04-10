// Comptime-composed network stack for embedded devices.
//
// Inspired by uIP's philosophy (single TX buffer, app-driven retransmit,
// stop-and-wait TCP, no dynamic allocation) but expressed idiomatically
// in Zig with compile-time protocol inclusion and fixed-capacity structures.
//
// Usage:
//   const net = @import("net/stack.zig");
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

        // ── Compile-time info ────────────────────────────────────

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
