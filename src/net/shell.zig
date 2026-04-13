// Telnet shell — interactive remote console over TCP port 23.
//
// Provides a line-buffered command interface accessible via:
//   telnet <pico-ip>
//
// Commands:
//   help              Show available commands
//   stats             Network stack counters
//   ip                Show IP configuration
//   uptime            System uptime in seconds
//   mem               Memory pool status
//   eval <js>         Evaluate JavaScript expression
//   mqtt <ip>         Connect to MQTT broker on port 1883
//   pub <topic> <msg> Publish MQTT message
//   sub <topic>       Subscribe to MQTT topic
//   mqtt?             Show MQTT connection status
//   led on/off        Control onboard LED
//   reboot            Enter BOOTSEL mode
//   quit              Close connection
//
// Implements AppVTable for app-driven TCP interaction.

const fmt = @import("../lib/fmt.zig");
const netif = @import("stack.zig");
const stack_mod = @import("tcpip.zig");
const hal = @import("../platform/hal.zig");
const engine = @import("../js/runtime.zig");
const memory = @import("../runtime/memory_pool.zig");
const mqtt = @import("../bindings/mqtt.zig");

const LISTEN_PORT: u16 = 23;

var active_conn: ?stack_mod.ConnId = null;

var cmd_buf: [128]u8 = undefined;
var cmd_len: usize = 0;

var reply_buf: [512]u8 = undefined;
var reply_len: usize = 0;
var reply_token: u16 = 0;

// ── AppVTable callbacks ──────────────────────────────────────────────

fn onOpen(_: *anyopaque, id: stack_mod.ConnId) void {
    active_conn = id;
    cmd_len = 0;
    fmt.puts("[shell] client connected\n");
    sendReply("pico v0.1.0 — type 'help' for commands\r\n> ");
}

var iac_skip: u8 = 0;

fn onRecv(_: *anyopaque, _: stack_mod.ConnId, data: []const u8) void {
    for (data) |ch| {
        if (iac_skip > 0) {
            iac_skip -= 1;
            continue;
        }
        if (ch == 0xFF) {
            iac_skip = 2;
            continue;
        }
        if (ch == '\r') continue;
        if (ch == '\n' or ch == 0) {
            processCommand(cmd_buf[0..cmd_len]);
            cmd_len = 0;
        } else if (cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = ch;
            cmd_len += 1;
        }
    }
}

fn onSent(_: *anyopaque, _: stack_mod.ConnId, _: u16) void {
    reply_len = 0;
}

fn onClosed(_: *anyopaque, _: stack_mod.ConnId, _: stack_mod.CloseReason) void {
    active_conn = null;
    cmd_len = 0;
    fmt.puts("[shell] client disconnected\n");
}

fn produceTx(_: *anyopaque, _: stack_mod.ConnId, _: stack_mod.TxRequest, dst: []u8) stack_mod.TxResponse {
    if (reply_len == 0) return .{ .len = 0, .token = reply_token };
    const n = @min(reply_len, dst.len);
    @memcpy(dst[0..n], reply_buf[0..n]);
    return .{ .len = @intCast(n), .token = reply_token };
}

const vtable = stack_mod.AppVTable{
    .ctx = @constCast(@ptrCast(&active_conn)),
    .on_open = &onOpen,
    .on_recv = &onRecv,
    .on_sent = &onSent,
    .on_closed = &onClosed,
    .produce_tx = &produceTx,
};

// ── Public API ───────────────────────────────────────────────────────

pub fn init() void {
    active_conn = null;
    cmd_len = 0;
    reply_len = 0;

    if (!netif.stack().tcpListen(LISTEN_PORT, vtable)) {
        fmt.puts("[shell] failed to register listener\n");
    } else {
        fmt.puts("[shell] listening on port 23\n");
    }
}

// ── Command processing ───────────────────────────────────────────────

fn processCommand(line: []const u8) void {
    const cmd = trim(line);
    if (cmd.len == 0) {
        sendReply("> ");
        return;
    }

    if (eql(cmd, "help")) {
        sendReply(
            "Commands:\r\n" ++
            "  help              Show this help\r\n" ++
            "  stats             Network stack counters\r\n" ++
            "  ip                Show IP configuration\r\n" ++
            "  uptime            System uptime\r\n" ++
            "  mem               Memory pool status\r\n" ++
            "  eval <js>         Evaluate JavaScript\r\n" ++
            "  mqtt <ip>         Connect to MQTT broker\r\n" ++
            "  pub <topic> <msg> Publish message\r\n" ++
            "  sub <topic>       Subscribe to topic\r\n" ++
            "  mqtt?             MQTT connection status\r\n" ++
            "  led on/off        Control onboard LED\r\n" ++
            "  reboot            Enter BOOTSEL mode\r\n" ++
            "  quit              Close connection\r\n" ++
            "> ",
        );
    } else if (eql(cmd, "stats")) {
        writeStats();
    } else if (eql(cmd, "ip")) {
        writeIpConfig();
    } else if (eql(cmd, "uptime")) {
        writeUptime();
    } else if (eql(cmd, "mem")) {
        writeMem();
    } else if (startsWith(cmd, "eval ")) {
        evalJs(cmd[5..]);
    } else if (startsWith(cmd, "mqtt ")) {
        mqttConnect(cmd[5..]);
    } else if (startsWith(cmd, "pub ")) {
        mqttPublish(cmd[4..]);
    } else if (startsWith(cmd, "sub ")) {
        mqttSubscribe(cmd[4..]);
    } else if (eql(cmd, "mqtt?")) {
        mqttStatus();
    } else if (eql(cmd, "led on")) {
        setLed(true);
    } else if (eql(cmd, "led off")) {
        setLed(false);
    } else if (eql(cmd, "reboot")) {
        sendReply("Rebooting into BOOTSEL...\r\n");
        hal.platform.resetToUsbBoot();
    } else if (eql(cmd, "quit")) {
        sendReply("Bye!\r\n");
        if (active_conn) |id| netif.stack().tcpClose(id);
    } else {
        reply_len = 0;
        appendStr("Unknown command: '");
        appendStr(cmd);
        appendStr("'\r\n> ");
        flushReply();
    }
}

// ── Command handlers ─────────────────────────────────────────────────

fn writeStats() void {
    const s = netif.stack().stats;
    reply_len = 0;
    appendStr("Network stats:\r\n");
    appendStat("  ip_rx", s.ip_rx);
    appendStat("  icmp_rx", s.icmp_rx);
    appendStat("  icmp_tx", s.icmp_tx);
    appendStat("  tcp_rx", s.tcp_rx);
    appendStat("  tcp_tx", s.tcp_tx);
    appendStat("  tcp_retx", s.tcp_retx);
    appendStat("  udp_rx", s.udp_rx);
    appendStat("  arp_rx", s.arp_rx);
    appendStat("  arp_hits", s.arp_hits);
    appendStat("  arp_misses", s.arp_misses);
    if (s.ip_bad_checksum > 0) appendStat("  ip_bad_cksum", s.ip_bad_checksum);
    if (s.tcp_bad_checksum > 0) appendStat("  tcp_bad_cksum", s.tcp_bad_checksum);
    if (s.tcp_rst_rx > 0) appendStat("  tcp_rst_rx", s.tcp_rst_rx);
    if (s.tcp_rst_tx > 0) appendStat("  tcp_rst_tx", s.tcp_rst_tx);
    appendStr("> ");
    flushReply();
}

fn writeIpConfig() void {
    const stack = netif.stack();
    reply_len = 0;
    appendStr("IP config:\r\n  ip    ");
    appendIp(stack.local_ip);
    appendStr("\r\n  mask  ");
    appendIp(stack.subnet_mask);
    appendStr("\r\n  gw    ");
    appendIp(stack.gateway_ip);
    appendStr("\r\n> ");
    flushReply();
}

fn writeUptime() void {
    const ms = hal.millis();
    reply_len = 0;
    appendStr("Uptime: ");
    appendU32(@truncate(ms / 1000));
    appendStr("s\r\n> ");
    flushReply();
}

fn writeMem() void {
    reply_len = 0;
    appendStr("Memory:\r\n  pool  ");
    appendU32(@intCast(memory.totalSize()));
    appendStr(" bytes\r\n  stack ");
    appendU32(@intCast(netif.Stack.memoryUsage()));
    appendStr(" bytes\r\n> ");
    flushReply();
}

fn evalJs(expr: []const u8) void {
    const c = @import("../js/quickjs_api.zig");
    reply_len = 0;
    const val = engine.eval(expr, "<telnet>") catch {
        appendStr("error\r\n> ");
        flushReply();
        return;
    };
    if (c.JS_IsUndefined(val)) {
        appendStr("undefined\r\n> ");
    } else {
        const cx = engine.context() orelse {
            appendStr("OK\r\n> ");
            flushReply();
            return;
        };
        const str_val = c.JS_ToString(cx, val);
        if (engine.toCString(str_val)) |s| {
            appendStr(s.ptr[0..s.len]);
            appendStr("\r\n> ");
        } else {
            appendStr("OK\r\n> ");
        }
    }
    flushReply();
}

fn setLed(on: bool) void {
    const cyw43 = @import("../cyw43/cyw43.zig");
    cyw43.ledSet(on) catch {
        sendReply("LED error\r\n> ");
        return;
    };
    if (on) sendReply("LED on\r\n> ") else sendReply("LED off\r\n> ");
}

// ── MQTT command handlers ────────────────────────────────────────────

fn mqttConnect(arg: []const u8) void {
    const ip_str = trim(arg);
    const ip = parseIp(ip_str) orelse {
        reply_len = 0;
        appendStr("Invalid IP: ");
        appendStr(ip_str);
        appendStr("\r\n> ");
        flushReply();
        return;
    };
    reply_len = 0;
    appendStr("Connecting to ");
    appendIp(ip);
    appendStr(":1883...\r\n> ");
    flushReply();
    _ = mqtt.connectBroker(ip, 1883, "pico");
}

fn mqttPublish(arg: []const u8) void {
    const s = trim(arg);
    // Split on first space: "topic message goes here"
    var split: usize = 0;
    while (split < s.len and s[split] != ' ') : (split += 1) {}
    if (split == 0 or split >= s.len) {
        sendReply("Usage: pub <topic> <message>\r\n> ");
        return;
    }
    const topic = s[0..split];
    const msg = trim(s[split + 1 ..]);
    if (msg.len == 0) {
        sendReply("Usage: pub <topic> <message>\r\n> ");
        return;
    }
    if (mqtt.publish(topic, msg)) {
        reply_len = 0;
        appendStr("Published to ");
        appendStr(topic);
        appendStr("\r\n> ");
        flushReply();
    } else {
        sendReply("Publish failed (not connected?)\r\n> ");
    }
}

fn mqttSubscribe(arg: []const u8) void {
    const topic = trim(arg);
    if (topic.len == 0) {
        sendReply("Usage: sub <topic>\r\n> ");
        return;
    }
    if (mqtt.subscribe(topic)) {
        reply_len = 0;
        appendStr("Subscribed to ");
        appendStr(topic);
        appendStr("\r\n> ");
        flushReply();
    } else {
        sendReply("Subscribe failed (not connected?)\r\n> ");
    }
}

fn mqttStatus() void {
    reply_len = 0;
    appendStr("MQTT: ");
    if (mqtt.isConnected()) {
        appendStr("connected\r\n");
    } else {
        appendStr("disconnected\r\n");
    }
    appendStr("> ");
    flushReply();
}

fn parseIp(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var octet: u16 = 0;
    var dots: u8 = 0;
    var digits: u8 = 0;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            octet = octet * 10 + (ch - '0');
            if (octet > 255) return null;
            digits += 1;
        } else if (ch == '.') {
            if (digits == 0 or dots >= 3) return null;
            ip[dots] = @intCast(octet);
            dots += 1;
            octet = 0;
            digits = 0;
        } else return null;
    }
    if (dots != 3 or digits == 0) return null;
    ip[3] = @intCast(octet);
    return ip;
}

// ── Reply buffer helpers ─────────────────────────────────────────────

fn sendReply(msg: []const u8) void {
    const n = @min(msg.len, reply_buf.len);
    @memcpy(reply_buf[0..n], msg[0..n]);
    reply_len = n;
    reply_token += 1;
    if (active_conn) |id| {
        netif.stack().tcpMarkSendReady(id);
    }
}

fn flushReply() void {
    reply_token += 1;
    if (active_conn) |id| {
        netif.stack().tcpMarkSendReady(id);
    }
}

fn appendStr(s: []const u8) void {
    const avail = reply_buf.len - reply_len;
    const n = @min(s.len, avail);
    @memcpy(reply_buf[reply_len..][0..n], s[0..n]);
    reply_len += n;
}

fn appendU32(val: u32) void {
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) {
        appendStr("0");
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    appendStr(buf[i..]);
}

fn appendStat(name: []const u8, val: u32) void {
    appendStr(name);
    appendStr(": ");
    appendU32(val);
    appendStr("\r\n");
}

fn appendIp(addr: [4]u8) void {
    for (addr, 0..) |b, i| {
        if (i > 0) appendStr(".");
        appendU32(b);
    }
}

// ── String helpers ───────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var e = s.len;
    while (e > start and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r' or s[e - 1] == '\n')) : (e -= 1) {}
    return s[start..e];
}
