// pico control protocol — script push over TCP via NetStack.
//
// Listens on TCP port 9001. When a client connects, parses
// line-delimited commands: UPLOAD, RUN, RESTART, LOGS, REPL, PING.
//
// Implements AppVTable for app-driven TCP interaction.

const console = @import("../bindings/console.zig");
const engine = @import("../js/runtime.zig");
const netif = @import("stack.zig");
const stack_mod = @import("tcpip.zig");

pub const LISTEN_PORT: u16 = 9001;

const MAX_SCRIPT_SIZE = 64 * 1024;
var script_buf: [MAX_SCRIPT_SIZE]u8 = undefined;
var script_len: usize = 0;
var pending_upload_size: usize = 0;

const ProtoState = enum { idle, receiving_upload };
var proto_state: ProtoState = .idle;

var active_conn: ?stack_mod.ConnId = null;

var reply_buf: [256]u8 = undefined;
var reply_len: usize = 0;
var reply_token: u16 = 0;

// ── AppVTable callbacks ──────────────────────────────────────────────

fn onOpen(_: *anyopaque, id: stack_mod.ConnId) void {
    active_conn = id;
    proto_state = .idle;
    console.puts("[proto] client connected\n");
}

fn onRecv(_: *anyopaque, _: stack_mod.ConnId, data: []const u8) void {
    switch (proto_state) {
        .idle => processCommand(data),
        .receiving_upload => receiveUpload(data),
    }
}

fn onSent(_: *anyopaque, _: stack_mod.ConnId, _: u16) void {
    reply_len = 0;
}

fn onClosed(_: *anyopaque, _: stack_mod.ConnId, _: stack_mod.CloseReason) void {
    active_conn = null;
    proto_state = .idle;
    console.puts("[proto] client disconnected\n");
}

fn produceTx(_: *anyopaque, _: stack_mod.ConnId, _: stack_mod.TxRequest, dst: []u8) stack_mod.TxResponse {
    if (reply_len == 0) return .{ .len = 0, .token = reply_token };
    const n = @min(reply_len, dst.len);
    @memcpy(dst[0..n], reply_buf[0..n]);
    return .{ .len = @intCast(n), .token = reply_token };
}

const vtable = stack_mod.AppVTable{
    .ctx = @constCast(@ptrCast(&proto_state)),
    .on_open = &onOpen,
    .on_recv = &onRecv,
    .on_sent = &onSent,
    .on_closed = &onClosed,
    .produce_tx = &produceTx,
};

// ── Public API ───────────────────────────────────────────────────────

pub fn init() void {
    proto_state = .idle;
    script_len = 0;
    pending_upload_size = 0;
    active_conn = null;
    reply_len = 0;

    if (!netif.stack().tcpListen(LISTEN_PORT, vtable)) {
        console.puts("[proto] failed to register listener\n");
    }
}

// ── Command processing ───────────────────────────────────────────────

fn sendReply(msg: []const u8) void {
    const n = @min(msg.len, reply_buf.len);
    @memcpy(reply_buf[0..n], msg[0..n]);
    reply_len = n;
    reply_token += 1;
    if (active_conn) |id| {
        netif.stack().tcpMarkSendReady(id);
    }
}

fn processCommand(data: []const u8) void {
    const line = trimLine(data);

    if (startsWith(line, "PING")) {
        sendReply("PONG\n");
    } else if (startsWith(line, "UPLOAD")) {
        const size = parseSizeArg(line) orelse {
            sendReply("ERR: bad size\n");
            return;
        };
        if (size > MAX_SCRIPT_SIZE) {
            sendReply("ERR: too large\n");
            return;
        }
        pending_upload_size = size;
        script_len = 0;
        proto_state = .receiving_upload;
        sendReply("OK: ready\n");
    } else if (startsWith(line, "RUN")) {
        if (script_len == 0) {
            sendReply("ERR: no script\n");
            return;
        }
        sendReply("OK: running\n");
        runScript();
    } else if (startsWith(line, "RESTART")) {
        sendReply("OK: restarting\n");
    } else if (startsWith(line, "LOGS")) {
        sendReply("OK: log streaming not yet implemented\n");
    } else if (startsWith(line, "REPL")) {
        sendReply("OK: REPL not yet implemented\n");
    } else {
        sendReply("ERR: unknown command\n");
    }
}

fn receiveUpload(data: []const u8) void {
    const remaining = pending_upload_size - script_len;
    const n = @min(data.len, remaining);
    @memcpy(script_buf[script_len..][0..n], data[0..n]);
    script_len += n;

    if (script_len >= pending_upload_size) {
        proto_state = .idle;
        sendReply("OK: uploaded\n");
        console.puts("[proto] script uploaded\n");
    }
}

fn runScript() void {
    console.puts("[proto] running script...\n");
    _ = engine.eval(script_buf[0..script_len], "<remote>") catch {
        console.puts("[proto] script error\n");
        return;
    };
    console.puts("[proto] script done\n");
}

// ── Helpers ──────────────────────────────────────────────────────────

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn trimLine(s: []const u8) []const u8 {
    var end_pos = s.len;
    while (end_pos > 0 and (s[end_pos - 1] == '\n' or s[end_pos - 1] == '\r')) : (end_pos -= 1) {}
    return s[0..end_pos];
}

fn parseSizeArg(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    if (i >= line.len) return null;
    i += 1;

    var size: usize = 0;
    while (i < line.len) : (i += 1) {
        const d = line[i];
        if (d < '0' or d > '9') break;
        size = size * 10 + (d - '0');
    }
    if (size == 0) return null;
    return size;
}

pub fn getScriptBuf() []const u8 {
    return script_buf[0..script_len];
}

pub fn hasScript() bool {
    return script_len > 0;
}
