/// pico control protocol handler.
/// Parses commands from the TCP connection and dispatches them.
///
/// Protocol (text, line-delimited):
///   UPLOAD <size>\n<binary JS payload>
///   RUN\n
///   RESTART\n
///   LOGS\n
///   REPL\n
///   PING\n
const tcp = @import("tcp.zig");
const console = @import("../services/console.zig");
const engine = @import("../vm/engine.zig");
const storage = @import("../services/storage.zig");

pub const Command = enum {
    upload,
    run,
    restart,
    logs,
    repl,
    ping,
    unknown,
};

const MAX_SCRIPT_SIZE = 64 * 1024;
var script_buf: [MAX_SCRIPT_SIZE]u8 = undefined;
var script_len: usize = 0;
var pending_upload_size: usize = 0;

const State = enum {
    idle,
    receiving_upload,
};

var proto_state: State = .idle;

pub fn init() void {
    proto_state = .idle;
    script_len = 0;
    pending_upload_size = 0;
}

pub fn poll() void {
    if (!tcp.isConnected()) return;
    if (tcp.rxAvailable() == 0) return;

    switch (proto_state) {
        .idle => processCommand(),
        .receiving_upload => receiveUpload(),
    }
}

fn processCommand() void {
    var line_buf: [256]u8 = undefined;
    const n = tcp.rxConsume(&line_buf);
    if (n == 0) return;

    const line = trimLine(line_buf[0..n]);
    const cmd = parseCommand(line);

    switch (cmd) {
        .ping => {
            tcp.send("PONG\n") catch {};
        },
        .upload => {
            const size = parseSizeArg(line) orelse {
                tcp.send("ERR: bad size\n") catch {};
                return;
            };
            if (size > MAX_SCRIPT_SIZE) {
                tcp.send("ERR: too large\n") catch {};
                return;
            }
            pending_upload_size = size;
            script_len = 0;
            proto_state = .receiving_upload;
            tcp.send("OK: ready\n") catch {};
        },
        .run => {
            if (script_len == 0) {
                tcp.send("ERR: no script\n") catch {};
                return;
            }
            tcp.send("OK: running\n") catch {};
            runScript();
        },
        .restart => {
            // TODO: trigger watchdog reset
            tcp.send("OK: restarting\n") catch {};
        },
        .logs => {
            tcp.send("OK: log streaming not yet implemented\n") catch {};
        },
        .repl => {
            tcp.send("OK: REPL not yet implemented\n") catch {};
        },
        .unknown => {
            tcp.send("ERR: unknown command\n") catch {};
        },
    }
}

fn receiveUpload() void {
    const remaining = pending_upload_size - script_len;
    if (remaining == 0) {
        proto_state = .idle;
        tcp.send("OK: uploaded\n") catch {};
        console.puts("[proto] script uploaded\n");
        return;
    }

    const n = tcp.rxConsume(script_buf[script_len .. script_len + remaining]);
    script_len += n;

    if (script_len >= pending_upload_size) {
        proto_state = .idle;
        tcp.send("OK: uploaded\n") catch {};
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

fn parseCommand(line: []const u8) Command {
    if (startsWith(line, "PING")) return .ping;
    if (startsWith(line, "UPLOAD")) return .upload;
    if (startsWith(line, "RUN")) return .run;
    if (startsWith(line, "RESTART")) return .restart;
    if (startsWith(line, "LOGS")) return .logs;
    if (startsWith(line, "REPL")) return .repl;
    return .unknown;
}

fn parseSizeArg(line: []const u8) ?usize {
    // Find space after command
    var i: usize = 0;
    while (i < line.len and line[i] != ' ') : (i += 1) {}
    if (i >= line.len) return null;
    i += 1; // skip space

    var size: usize = 0;
    while (i < line.len) : (i += 1) {
        const d = line[i];
        if (d < '0' or d > '9') break;
        size = size * 10 + (d - '0');
    }
    if (size == 0) return null;
    return size;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

fn trimLine(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[0..end];
}

const std = @import("std");

pub fn getScriptBuf() []const u8 {
    return script_buf[0..script_len];
}

pub fn hasScript() bool {
    return script_len > 0;
}
