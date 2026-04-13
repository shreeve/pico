// TLS 1.2 session adapter — bridges BearSSL engine to our TCP AppVTable.
//
// Architecture:
//   App (MQTT) ←→ TlsSession ←→ TCP NetStack
//
// The TLS session implements TCP AppVTable, intercepting raw TCP events
// and piping them through BearSSL's SSL engine. The app layer sees only
// decrypted plaintext via callbacks.
//
// Key design constraint (from GPT-5.4 review):
//   TLS records are stateful — sequence numbers advance, so ciphertext
//   cannot be regenerated on TCP retransmit. A ciphertext retention buffer
//   holds encrypted bytes until TCP ACKs them.
//
// Buffer layout (static, fits in RP2040 SRAM):
//   BearSSL I/O:  4096 in + 2048 out = 6 KB
//   TX retention:  2048 bytes (ring buffer for TCP retransmit)
//   App RX queue:  1024 bytes (decrypted plaintext for app)
//   App TX queue:  1024 bytes (plaintext from app awaiting encrypt)
//   Total:         ~10 KB per session

const ssl = @import("bearssl.zig");
const entropy = @import("entropy.zig");
const stack_mod = @import("../net/tcpip.zig");
const netif = @import("../net/stack.zig");
const console = @import("../bindings/console.zig");

const ConnId = stack_mod.ConnId;
const AppVTable = stack_mod.AppVTable;
const TxRequest = stack_mod.TxRequest;
const TxResponse = stack_mod.TxResponse;
const CloseReason = stack_mod.CloseReason;

pub const TlsState = enum {
    idle,
    handshake,
    open,
    closing,
    error_state,
};

// ── Buffer sizes ─────────────────────────────────────────────────────

const BEARSSL_IBUF_SIZE = 4096;
const BEARSSL_OBUF_SIZE = 2048;
const TX_RETAIN_SIZE = 2048;
const APP_RX_SIZE = 1024;
const APP_TX_SIZE = 1024;

// ── Ring buffer ──────────────────────────────────────────────────────

fn RingBuffer(comptime N: usize) type {
    comptime {
        if (N > 65535) @compileError("RingBuffer N exceeds u16 range");
    }
    return struct {
        const Self = @This();
        buf: [N]u8 = undefined,
        head: u16 = 0,
        tail: u16 = 0,
        count: u16 = 0,

        fn push(self: *Self, data: []const u8) u16 {
            const n: u16 = @intCast(@min(data.len, N - self.count));
            if (n == 0) return 0;
            const h: usize = self.head;
            const first = @min(n, @as(u16, @intCast(N - h)));
            @memcpy(self.buf[h..][0..first], data[0..first]);
            if (n > first) {
                const second = n - first;
                @memcpy(self.buf[0..second], data[first..][0..second]);
            }
            self.head = @intCast((h + n) % N);
            self.count += n;
            return n;
        }

        fn peek(self: *const Self, dst: []u8) u16 {
            const n: u16 = @intCast(@min(dst.len, self.count));
            if (n == 0) return 0;
            const t: usize = self.tail;
            const first = @min(n, @as(u16, @intCast(N - t)));
            @memcpy(dst[0..first], self.buf[t..][0..first]);
            if (n > first) {
                const second = n - first;
                @memcpy(dst[first..][0..second], self.buf[0..second]);
            }
            return n;
        }

        fn consume(self: *Self, n: u16) void {
            const drop = @min(n, self.count);
            self.tail = @intCast((@as(usize, self.tail) + drop) % N);
            self.count -= drop;
        }

        fn available(self: *const Self) u16 {
            return self.count;
        }

        fn space(self: *const Self) u16 {
            return @intCast(N - self.count);
        }
    };
}

// ── TLS Session ──────────────────────────────────────────────────────

pub const TlsSession = struct {
    state: TlsState = .idle,
    tcp_conn_id: ConnId = 0,

    // BearSSL contexts (large — ~4KB combined)
    client_ctx: ssl.ClientContext = undefined,
    x509_ctx: ssl.X509KnownKeyContext = undefined,
    drbg: ssl.HmacDrbgContext = undefined,

    // BearSSL I/O buffers
    bearssl_ibuf: [BEARSSL_IBUF_SIZE]u8 = undefined,
    bearssl_obuf: [BEARSSL_OBUF_SIZE]u8 = undefined,

    // Ciphertext TX retention: holds encrypted bytes between BearSSL
    // output and TCP ACK. produce_tx() reads from here; on_sent()
    // drains ACKed bytes.
    tx_retain: RingBuffer(TX_RETAIN_SIZE) = .{},

    // Inflight segment tracking — stop-and-wait means at most one
    // TCP segment outstanding. Token correlates produce_tx ↔ on_sent.
    tx_inflight_token: u16 = 0,
    tx_inflight_len: u16 = 0,
    tx_has_inflight: bool = false,
    tx_next_token: u16 = 1,

    // Application-facing queues
    app_rx: RingBuffer(APP_RX_SIZE) = .{},
    app_tx: RingBuffer(APP_TX_SIZE) = .{},

    // Upper-layer app callbacks (MQTT, etc.)
    app_vtable: ?AppVTable = null,
    closed_notified: bool = false,

    // Scratch buffer for delivering decrypted data to app (avoids 1KB stack alloc)
    rx_scratch: [256]u8 = undefined,

    // ── Public API ───────────────────────────────────────────────

    /// Initialize the TLS session with ROSC entropy and known-key trust.
    pub fn init(
        self: *TlsSession,
        broker_rsa_key: *const ssl.RsaPublicKey,
    ) void {
        self.state = .idle;
        self.tx_retain = .{};
        self.app_rx = .{};
        self.app_tx = .{};
        self.tx_inflight_token = 0;
        self.tx_inflight_len = 0;
        self.tx_has_inflight = false;
        self.tx_next_token = 1;
        self.closed_notified = false;

        entropy.seedDrbg(&self.drbg);

        // Known-key trust: pin the broker's RSA public key
        ssl.x509KnownkeyInitRsa(
            &self.x509_ctx,
            broker_rsa_key,
            ssl.KEYTYPE_RSA | ssl.KEYTYPE_KEYX | ssl.KEYTYPE_SIGN,
        );

        // Client context setup: TLS 1.2 only, ECDHE_RSA_WITH_AES_128_GCM
        ssl.clientZero(&self.client_ctx);
        const eng = self.engine();
        ssl.engineSetVersions(eng, ssl.TLS12, ssl.TLS12);

        const suites = [_]u16{
            ssl.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
        };
        ssl.engineSetSuites(eng, &suites);

        // Crypto implementations (BearSSL "default" picks best for platform)
        ssl.clientSetDefaultRsaPub(&self.client_ctx);
        ssl.engineSetDefaultRsaVrfy(eng);
        ssl.engineSetDefaultEcdsa(eng);
        ssl.engineSetDefaultAesGcm(eng);
        ssl.engineSetDefaultEc(eng);

        // Hash functions for handshake and cert validation
        ssl.engineSetHash(eng, ssl.SHA256_ID, ssl.sha256Vtable());
        ssl.engineSetHash(eng, ssl.SHA1_ID, ssl.sha1Vtable());
        ssl.engineSetHash(eng, ssl.SHA384_ID, ssl.sha384Vtable());

        // PRF for TLS 1.2
        ssl.engineSetPrfSha256(eng);

        // Link X.509 trust
        ssl.engineSetX509(eng, @ptrCast(&self.x509_ctx.vtable));

        // Set I/O buffers (separate in/out for full-duplex)
        ssl.engineSetBuffersBidi(eng, &self.bearssl_ibuf, &self.bearssl_obuf);

        // Inject entropy from our DRBG
        var rng_seed: [32]u8 = undefined;
        ssl.hmacDrbgGenerate(&self.drbg, &rng_seed);
        ssl.engineInjectEntropy(eng, &rng_seed);
    }

    /// Connect to a TLS server. The app_vtable receives decrypted events.
    pub fn connect(
        self: *TlsSession,
        ip: [4]u8,
        port: u16,
        server_name: [*:0]const u8,
        app: AppVTable,
    ) bool {
        self.app_vtable = app;
        self.closed_notified = false;

        // TCP connect first — avoids leaving BearSSL in a half-started
        // state if the transport layer rejects the connection.
        const tcp_id = netif.stack().tcpConnect(ip, port, self.tcpVtable()) orelse {
            console.puts("[tls] TCP connect failed\n");
            self.state = .error_state;
            return false;
        };
        self.tcp_conn_id = tcp_id;

        if (!ssl.clientReset(&self.client_ctx, server_name, false)) {
            console.puts("[tls] client reset failed\n");
            self.state = .error_state;
            return false;
        }

        self.state = .handshake;
        console.puts("[tls] connecting...\n");
        return true;
    }

    /// Queue plaintext application data for encryption and sending.
    pub fn send(self: *TlsSession, data: []const u8) u16 {
        if (self.state != .open) return 0;
        const n = self.app_tx.push(data);
        if (n > 0) self.pump();
        return n;
    }

    /// Read decrypted application data. Returns number of bytes read.
    pub fn recv(self: *TlsSession, dst: []u8) u16 {
        const n = self.app_rx.peek(dst);
        if (n > 0) self.app_rx.consume(n);
        return n;
    }

    /// Check if decrypted data is waiting.
    pub fn recvAvailable(self: *const TlsSession) u16 {
        return self.app_rx.available();
    }

    /// Initiate TLS close_notify and TCP teardown.
    pub fn close(self: *TlsSession) void {
        if (self.state == .open or self.state == .handshake) {
            ssl.engineClose(self.engine());
            self.state = .closing;
            self.pump();
        }
    }

    pub fn isOpen(self: *const TlsSession) bool {
        return self.state == .open;
    }

    pub fn getError(self: *const TlsSession) c_int {
        return ssl.engineLastError(@ptrCast(&self.client_ctx.eng));
    }

    // ── Helpers ──────────────────────────────────────────────────

    fn notifyClosed(self: *TlsSession, reason: CloseReason) void {
        if (self.closed_notified) return;
        self.closed_notified = true;
        if (self.app_vtable) |app| {
            app.on_closed(app.ctx, self.tcp_conn_id, reason);
        }
    }

    /// Deliver queued decrypted data to the app layer, then repump
    /// to drain any further BearSSL plaintext that couldn't fit earlier.
    fn deliverAppRx(self: *TlsSession) void {
        while (self.app_rx.available() > 0) {
            const n = self.app_rx.peek(&self.rx_scratch);
            if (n == 0) break;
            self.app_rx.consume(n);
            if (self.app_vtable) |app| {
                app.on_recv(app.ctx, self.tcp_conn_id, self.rx_scratch[0..n]);
            }
        }
    }

    // ── Engine pump ──────────────────────────────────────────────

    /// Drive the BearSSL engine forward. Call after any state change:
    /// receiving TCP data, TCP ACK, app queuing plaintext, or on poll.
    pub fn pump(self: *TlsSession) void {
        if (self.state == .idle or self.state == .error_state) return;

        var progress = true;
        while (progress) {
            progress = false;

            const eng = self.engine();
            const st = ssl.engineCurrentState(eng);

            // Engine closed/failed?
            if ((st & ssl.SSL_CLOSED) != 0) {
                const err = ssl.engineLastError(eng);
                if (err != ssl.ERR_OK) {
                    console.puts("[tls] engine error\n");
                    self.state = .error_state;
                } else {
                    self.state = .idle;
                }
                self.notifyClosed(if (err != ssl.ERR_OK) .reset else .normal);
                return;
            }

            // BearSSL has ciphertext to send → copy to TX retention ring
            if ((st & ssl.SSL_SENDREC) != 0) {
                if (ssl.engineSendrecBuf(eng)) |rec_buf| {
                    const n = self.tx_retain.push(rec_buf);
                    if (n > 0) {
                        ssl.engineSendrecAck(eng, n);
                        netif.stack().tcpMarkSendReady(self.tcp_conn_id);
                        progress = true;
                    }
                }
            }

            // BearSSL has decrypted app data → copy to app RX queue
            if ((st & ssl.SSL_RECVAPP) != 0) {
                if (ssl.engineRecvappBuf(eng)) |app_buf| {
                    const n = self.app_rx.push(app_buf);
                    if (n > 0) {
                        ssl.engineRecvappAck(eng, n);
                        progress = true;
                    }
                }
            }

            // BearSSL can accept plaintext → drain app TX queue
            if ((st & ssl.SSL_SENDAPP) != 0) {
                if (self.state == .handshake) {
                    self.state = .open;
                    console.puts("[tls] handshake complete\n");
                    if (self.app_vtable) |app| {
                        app.on_open(app.ctx, self.tcp_conn_id);
                    }
                }

                if (self.app_tx.available() > 0) {
                    if (ssl.engineSendappBuf(eng)) |send_buf| {
                        const n = self.app_tx.peek(send_buf);
                        if (n > 0) {
                            self.app_tx.consume(n);
                            ssl.engineSendappAck(eng, n);
                            ssl.engineFlush(eng, true);
                            progress = true;
                        }
                    }
                }
            }
        }
    }

    // ── TCP AppVTable callbacks ──────────────────────────────────

    fn tcpOnOpen(ctx: *anyopaque, _: ConnId) void {
        const self: *TlsSession = @ptrCast(@alignCast(ctx));
        console.puts("[tls] TCP connected, starting handshake\n");
        self.pump();
    }

    fn tcpOnRecv(ctx: *anyopaque, _: ConnId, data: []const u8) void {
        const self: *TlsSession = @ptrCast(@alignCast(ctx));

        // Feed incoming ciphertext to BearSSL, pumping between chunks
        // so the engine can process records and free buffer space.
        const eng = self.engine();
        var offset: usize = 0;
        while (offset < data.len) {
            if (ssl.engineRecvrecBuf(eng)) |rec_buf| {
                const n = @min(rec_buf.len, data.len - offset);
                @memcpy(rec_buf[0..n], data[offset..][0..n]);
                ssl.engineRecvrecAck(eng, n);
                offset += n;
                self.pump();
            } else {
                // BearSSL can't accept more — pump to try freeing space
                self.pump();
                if (ssl.engineRecvrecBuf(eng) == null) {
                    // Still can't accept: fail closed rather than silently drop
                    console.puts("[tls] RX overflow, closing\n");
                    self.state = .error_state;
                    self.notifyClosed(.reset);
                    return;
                }
            }
        }

        self.pump();
        self.deliverAppRx();
        self.pump();
    }

    fn tcpOnSent(ctx: *anyopaque, _: ConnId, token: u16) void {
        const self: *TlsSession = @ptrCast(@alignCast(ctx));

        if (!self.tx_has_inflight) return;
        if (token != self.tx_inflight_token) return;

        self.tx_retain.consume(self.tx_inflight_len);
        self.tx_inflight_len = 0;
        self.tx_has_inflight = false;
        self.pump();
    }

    fn tcpOnClosed(ctx: *anyopaque, _: ConnId, reason: CloseReason) void {
        const self: *TlsSession = @ptrCast(@alignCast(ctx));
        self.state = .idle;
        self.notifyClosed(reason);
    }

    fn tcpProduceTx(ctx: *anyopaque, _: ConnId, req: TxRequest, dst: []u8) TxResponse {
        const self: *TlsSession = @ptrCast(@alignCast(ctx));

        if (req.reason == .retransmit) {
            if (!self.tx_has_inflight) return .{ .len = 0, .token = req.token };
            if (dst.len < self.tx_inflight_len) return .{ .len = 0, .token = self.tx_inflight_token };
            const n = self.tx_retain.peek(dst[0..self.tx_inflight_len]);
            return .{ .len = n, .token = self.tx_inflight_token };
        }

        // New send — stop-and-wait: should not be called while inflight
        if (self.tx_has_inflight) return .{ .len = 0, .token = self.tx_next_token };

        const avail = self.tx_retain.available();
        if (avail == 0) return .{ .len = 0, .token = self.tx_next_token };

        const limit: u16 = @intCast(@min(avail, req.max_payload));
        const n = self.tx_retain.peek(dst[0..@min(dst.len, limit)]);
        if (n == 0) return .{ .len = 0, .token = self.tx_next_token };

        const tok = self.tx_next_token;
        self.tx_next_token +%= 1;
        self.tx_inflight_token = tok;
        self.tx_inflight_len = n;
        self.tx_has_inflight = true;

        return .{ .len = n, .token = tok };
    }

    fn tcpVtable(self: *TlsSession) AppVTable {
        return .{
            .ctx = @ptrCast(self),
            .on_open = &tcpOnOpen,
            .on_recv = &tcpOnRecv,
            .on_sent = &tcpOnSent,
            .on_closed = &tcpOnClosed,
            .produce_tx = &tcpProduceTx,
        };
    }

    fn engine(self: *TlsSession) *ssl.EngineContext {
        return &self.client_ctx.eng;
    }
};

// ── Global TLS session (single concurrent TLS connection) ────────────
// RP2040 RAM budget allows one TLS session at a time.

var session: TlsSession = .{};

pub fn getSession() *TlsSession {
    return &session;
}
