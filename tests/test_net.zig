// Host-side unit tests for TCP sequence arithmetic, checksums, and
// packet assembly helpers. Run with: zig test tests/test_net.zig
//
// These test pure functions that have no hardware dependencies.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const byteutil = @import("byteutil");

// ── Byte-order helpers ──────────────────────────────────────────────

test "readBE16 / writeBE16 roundtrip" {
    var buf: [2]u8 = undefined;
    byteutil.writeBE16(&buf, 0x1234);
    try expectEqual(@as(u16, 0x1234), byteutil.readBE16(&buf));
    try expectEqual(@as(u8, 0x12), buf[0]);
    try expectEqual(@as(u8, 0x34), buf[1]);
}

test "readBE32 / writeBE32 roundtrip" {
    var buf: [4]u8 = undefined;
    byteutil.writeBE32(&buf, 0xDEADBEEF);
    try expectEqual(@as(u32, 0xDEADBEEF), byteutil.readBE32(&buf));
    try expectEqual(@as(u8, 0xDE), buf[0]);
    try expectEqual(@as(u8, 0xAD), buf[1]);
    try expectEqual(@as(u8, 0xBE), buf[2]);
    try expectEqual(@as(u8, 0xEF), buf[3]);
}

test "readBE32 zero" {
    const buf = [_]u8{ 0, 0, 0, 0 };
    try expectEqual(@as(u32, 0), byteutil.readBE32(&buf));
}

test "readBE32 max" {
    const buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    try expectEqual(@as(u32, 0xFFFFFFFF), byteutil.readBE32(&buf));
}

// ── IPv4 equality ───────────────────────────────────────────────────

test "ipv4Eq same address" {
    try expect(byteutil.ipv4Eq(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 1 }));
}

test "ipv4Eq different address" {
    try expect(!byteutil.ipv4Eq(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 }));
}

test "ipv4Eq zeros" {
    try expect(byteutil.ipv4Eq(.{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }));
}

test "ipv4Eq single byte differs" {
    try expect(!byteutil.ipv4Eq(.{ 192, 168, 1, 1 }, .{ 192, 168, 1, 2 }));
    try expect(!byteutil.ipv4Eq(.{ 192, 168, 1, 1 }, .{ 192, 168, 2, 1 }));
    try expect(!byteutil.ipv4Eq(.{ 192, 168, 1, 1 }, .{ 192, 169, 1, 1 }));
    try expect(!byteutil.ipv4Eq(.{ 192, 168, 1, 1 }, .{ 193, 168, 1, 1 }));
}

// ── IP checksum ─────────────────────────────────────────────────────

test "ipChecksum known IPv4 header" {
    // Standard IPv4 header: version=4, IHL=5, total_len=40,
    // TTL=64, proto=TCP(6), src=10.0.0.1, dst=10.0.0.2
    var hdr = [_]u8{
        0x45, 0x00, 0x00, 0x28, // ver/ihl, tos, total_len
        0x00, 0x00, 0x40, 0x00, // id, flags/frag
        0x40, 0x06, 0x00, 0x00, // ttl, proto, checksum=0
        0x0A, 0x00, 0x00, 0x01, // src: 10.0.0.1
        0x0A, 0x00, 0x00, 0x02, // dst: 10.0.0.2
    };
    const cksum = byteutil.ipChecksum(&hdr);
    // Write checksum back and verify it validates to 0
    hdr[10] = @intCast(cksum >> 8);
    hdr[11] = @intCast(cksum & 0xFF);
    try expectEqual(@as(u16, 0), byteutil.ipChecksum(&hdr));
}

test "ipChecksum odd-length data" {
    const data = [_]u8{ 0x45, 0x00, 0x00 };
    _ = byteutil.ipChecksum(&data);
}

test "ipChecksum empty" {
    const data = [_]u8{};
    try expectEqual(@as(u16, 0xFFFF), byteutil.ipChecksum(&data));
}

// ── Sequence arithmetic (reimplemented for testing) ─────────────────
// These mirror the implementations in tcpip.zig.

fn seqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

test "seqGe basic ordering" {
    try expect(seqGe(100, 100));
    try expect(seqGe(101, 100));
    try expect(!seqGe(99, 100));
}

test "seqGt basic ordering" {
    try expect(!seqGt(100, 100));
    try expect(seqGt(101, 100));
    try expect(!seqGt(99, 100));
}

test "seqLt basic ordering" {
    try expect(!seqLt(100, 100));
    try expect(!seqLt(101, 100));
    try expect(seqLt(99, 100));
}

test "sequence arithmetic wraps at u32 boundary" {
    const max: u32 = 0xFFFFFFFF;
    try expect(seqGt(0, max)); // 0 is "after" max in sequence space
    try expect(seqLt(max, 0)); // max is "before" 0
    try expect(seqGe(0, max));
    try expect(seqGt(1, max));
    try expect(seqLt(max -% 1, max));
}

test "sequence arithmetic midpoint boundary" {
    // At exactly 2^31, the signed difference is INT_MIN — not > 0
    try expect(!seqGt(0x80000000, 0));
    // One past midpoint wraps to negative
    try expect(!seqGt(0x80000001, 0));
    // One before midpoint is still positive
    try expect(seqGt(0x7FFFFFFF, 0));
}

// ── ackAcceptable ───────────────────────────────────────────────────

fn ackAcceptable(snd_una: u32, snd_nxt: u32, ack_num: u32) bool {
    return seqGe(ack_num, snd_una) and seqGe(snd_nxt, ack_num);
}

test "ackAcceptable: ack at snd_una" {
    try expect(ackAcceptable(100, 200, 100));
}

test "ackAcceptable: ack at snd_nxt" {
    try expect(ackAcceptable(100, 200, 200));
}

test "ackAcceptable: ack in middle" {
    try expect(ackAcceptable(100, 200, 150));
}

test "ackAcceptable: ack before snd_una" {
    try expect(!ackAcceptable(100, 200, 99));
}

test "ackAcceptable: ack after snd_nxt" {
    try expect(!ackAcceptable(100, 200, 201));
}

test "ackAcceptable: wrapping case" {
    const una: u32 = 0xFFFFFFF0;
    const nxt: u32 = 0x00000010;
    try expect(ackAcceptable(una, nxt, 0));
    try expect(ackAcceptable(una, nxt, una));
    try expect(ackAcceptable(una, nxt, nxt));
    try expect(!ackAcceptable(una, nxt, una -% 1));
    try expect(!ackAcceptable(una, nxt, nxt +% 1));
}

// ── segSeqLen ───────────────────────────────────────────────────────

const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_ACK: u8 = 0x10;

fn segSeqLen(flags: u8, payload_len: usize) u32 {
    var n: u32 = @intCast(payload_len);
    if ((flags & FLAG_SYN) != 0) n +%= 1;
    if ((flags & FLAG_FIN) != 0) n +%= 1;
    return n;
}

test "segSeqLen: pure data" {
    try expectEqual(@as(u32, 100), segSeqLen(FLAG_ACK, 100));
}

test "segSeqLen: SYN" {
    try expectEqual(@as(u32, 1), segSeqLen(FLAG_SYN, 0));
}

test "segSeqLen: FIN" {
    try expectEqual(@as(u32, 1), segSeqLen(FLAG_FIN | FLAG_ACK, 0));
}

test "segSeqLen: SYN+ACK" {
    try expectEqual(@as(u32, 1), segSeqLen(FLAG_SYN | FLAG_ACK, 0));
}

test "segSeqLen: data + FIN" {
    try expectEqual(@as(u32, 51), segSeqLen(FLAG_FIN | FLAG_ACK, 50));
}

test "segSeqLen: pure ACK (no data)" {
    try expectEqual(@as(u32, 0), segSeqLen(FLAG_ACK, 0));
}

// ── TCP checksum (pseudo-header) ────────────────────────────────────

fn tcpPseudoHeaderSum(src_ip: [4]u8, dst_ip: [4]u8, tcp_len: usize) u32 {
    var sum: u32 = 0;
    sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    sum += 6;
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

test "tcpChecksum: compute then validate roundtrip" {
    const src = [_]u8{ 10, 0, 0, 1 };
    const dst = [_]u8{ 10, 0, 0, 2 };

    // Minimal 20-byte TCP header: src_port=80, dst_port=12345,
    // seq=1, ack=0, data_off=5, flags=SYN, window=2048, cksum=0, urg=0
    var seg = [_]u8{
        0x00, 0x50, 0x30, 0x39, // src_port=80, dst_port=12345
        0x00, 0x00, 0x00, 0x01, // seq = 1
        0x00, 0x00, 0x00, 0x00, // ack = 0
        0x50, 0x02, 0x08, 0x00, // data_off=5, SYN, window=2048
        0x00, 0x00, 0x00, 0x00, // checksum=0, urgent=0
    };

    const cksum = tcpChecksum(src, dst, &seg);
    seg[16] = @intCast(cksum >> 8);
    seg[17] = @intCast(cksum & 0xFF);
    try expect(tcpChecksumValid(src, dst, &seg));
}

test "tcpChecksumValid: rejects too-short segment" {
    try expect(!tcpChecksumValid(.{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, &[_]u8{ 0, 0, 0 }));
}

test "tcpChecksumValid: rejects corrupted segment" {
    const src = [_]u8{ 10, 0, 0, 1 };
    const dst = [_]u8{ 10, 0, 0, 2 };
    var seg = [_]u8{
        0x00, 0x50, 0x30, 0x39,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x02, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const cksum = tcpChecksum(src, dst, &seg);
    seg[16] = @intCast(cksum >> 8);
    seg[17] = @intCast(cksum & 0xFF);
    seg[4] ^= 0xFF; // corrupt seq byte
    try expect(!tcpChecksumValid(src, dst, &seg));
}

// ── MSS option in SYN header ────────────────────────────────────────

test "MSS option: SYN has 24-byte header with MSS 1460" {
    const mtu: usize = 1500;
    const mss: u16 = @intCast(@min(mtu -| 40, 1460));
    try expectEqual(@as(u16, 1460), mss);

    // Verify MSS option encoding
    var opt: [4]u8 = undefined;
    opt[0] = 2; // kind
    opt[1] = 4; // length
    opt[2] = @intCast(mss >> 8);
    opt[3] = @intCast(mss & 0xFF);
    try expectEqual(@as(u8, 2), opt[0]);
    try expectEqual(@as(u8, 4), opt[1]);
    try expectEqual(@as(u8, 0x05), opt[2]); // 1460 >> 8 = 5
    try expectEqual(@as(u8, 0xB4), opt[3]); // 1460 & 0xFF = 180

    // Data offset for 24-byte header
    const hdr_len: u8 = 24;
    try expectEqual(@as(u8, 0x60), (hdr_len / 4) << 4);
}

// ── mix32 ISN finalizer ─────────────────────────────────────────────

fn mix32(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

test "mix32: different inputs produce different outputs" {
    const a = mix32(0);
    const b = mix32(1);
    const c = mix32(2);
    try expect(a != b);
    try expect(b != c);
    try expect(a != c);
}

test "mix32: avalanche — nearby inputs diverge" {
    const a = mix32(1000);
    const b = mix32(1001);
    // Good hash: nearby inputs differ in many bits
    try expect(@popCount(a ^ b) >= 8);
}

// ── Timer wraparound and deadline tests ─────────────────────────────
// These mirror the wrap-safe patterns used in tcpip.zig for
// retransmit deadlines, TIME-WAIT countdown, and elapsed clamping.

fn deadlineExpired(now_ms: u32, deadline_ms: u32) bool {
    const since = now_ms -% deadline_ms;
    return @as(i32, @bitCast(since)) >= 0;
}

test "deadline: basic expiry" {
    try expect(!deadlineExpired(100, 200)); // 100ms before deadline
    try expect(deadlineExpired(200, 200)); // exactly at deadline
    try expect(deadlineExpired(300, 200)); // 100ms past deadline
}

test "deadline: wrap-around at u32 boundary" {
    const deadline: u32 = 0xFFFFFF00; // ~49.7 days minus 256ms
    try expect(!deadlineExpired(deadline -% 1, deadline));
    try expect(deadlineExpired(deadline, deadline));
    try expect(deadlineExpired(deadline +% 1, deadline));
    try expect(deadlineExpired(0, deadline)); // wrapped past
    try expect(deadlineExpired(100, deadline)); // well past wrap
}

test "deadline: half-range boundary is ambiguous (not expired)" {
    // At exactly 2^31 difference, signed interpretation is INT_MIN (negative)
    try expect(!deadlineExpired(0x80000000, 0));
    try expect(!deadlineExpired(0, 0x80000000));
    // Just under half-range: still expired
    try expect(deadlineExpired(0x7FFFFFFF, 0));
}

fn elapsedClamped(now_ms: u32, last_ms: u32) u32 {
    const raw = now_ms -% last_ms;
    return @min(raw, 10_000);
}

test "elapsed: normal case" {
    try expectEqual(@as(u32, 50), elapsedClamped(150, 100));
}

test "elapsed: zero when same timestamp" {
    try expectEqual(@as(u32, 0), elapsedClamped(1000, 1000));
}

test "elapsed: first tick from zero" {
    try expectEqual(@as(u32, 5000), elapsedClamped(5000, 0));
}

test "elapsed: large gap clamped to 10s" {
    try expectEqual(@as(u32, 10_000), elapsedClamped(50_000, 0));
}

test "elapsed: wrapping subtraction" {
    // 0xFFFFFFB6 is -74 as signed, so 50 -% 0xFFFFFFB6 = 124
    try expectEqual(@as(u32, 124), elapsedClamped(50, 0xFFFFFFB6));
}

test "elapsed: huge reverse gap clamped" {
    // If now < last due to a hypothetical glitch, wrapping produces a
    // huge positive value that gets clamped to 10s.
    try expectEqual(@as(u32, 10_000), elapsedClamped(100, 200));
}

fn timewaitStep(remaining_ms: u32, elapsed_ms: u32) ?u32 {
    if (remaining_ms > elapsed_ms) return remaining_ms - elapsed_ms;
    return null; // expired
}

test "timewait: countdown" {
    try expectEqual(@as(?u32, 29_950), timewaitStep(30_000, 50));
}

test "timewait: exact expiry" {
    try expectEqual(@as(?u32, null), timewaitStep(50, 50));
}

test "timewait: overshoot expiry" {
    try expectEqual(@as(?u32, null), timewaitStep(30, 50));
}

test "timewait: zero elapsed" {
    try expectEqual(@as(?u32, 30_000), timewaitStep(30_000, 0));
}

// ── Persist timer logic ─────────────────────────────────────────────
// Models the zero-window probe timer from tcpip.zig.

const PersistState = struct {
    backoff_ms: u16 = 0,
    deadline_ms: u32 = 0,
    remote_window: u16 = 0,
};

fn persistShouldArm(ps: PersistState) bool {
    return ps.remote_window == 0 and ps.backoff_ms == 0;
}

fn persistArm(ps: *PersistState, now_ms: u32) void {
    ps.backoff_ms = 250;
    ps.deadline_ms = now_ms +% 250;
}

fn persistFired(ps: PersistState, now_ms: u32) bool {
    if (ps.backoff_ms == 0) return false;
    const since = now_ms -% ps.deadline_ms;
    return @as(i32, @bitCast(since)) >= 0;
}

fn persistBackoff(ps: *PersistState, now_ms: u32) void {
    ps.backoff_ms = @min(ps.backoff_ms *| 2, 5000);
    ps.deadline_ms = now_ms +% ps.backoff_ms;
}

fn persistClear(ps: *PersistState) void {
    ps.backoff_ms = 0;
}

test "persist: not armed when window > 0" {
    const ps = PersistState{ .remote_window = 1024 };
    try expect(!persistShouldArm(ps));
}

test "persist: arm when window == 0" {
    var ps = PersistState{ .remote_window = 0 };
    try expect(persistShouldArm(ps));
    persistArm(&ps, 1000);
    try expectEqual(@as(u16, 250), ps.backoff_ms);
    try expectEqual(@as(u32, 1250), ps.deadline_ms);
}

test "persist: fires after deadline" {
    var ps = PersistState{};
    persistArm(&ps, 1000);
    try expect(!persistFired(ps, 1100)); // 100ms in, not yet
    try expect(!persistFired(ps, 1249)); // 1ms before
    try expect(persistFired(ps, 1250)); // exactly at deadline
    try expect(persistFired(ps, 1500)); // past deadline
}

test "persist: exponential backoff caps at 5s" {
    var ps = PersistState{};
    persistArm(&ps, 0);
    try expectEqual(@as(u16, 250), ps.backoff_ms);
    persistBackoff(&ps, 250);
    try expectEqual(@as(u16, 500), ps.backoff_ms);
    persistBackoff(&ps, 750);
    try expectEqual(@as(u16, 1000), ps.backoff_ms);
    persistBackoff(&ps, 1750);
    try expectEqual(@as(u16, 2000), ps.backoff_ms);
    persistBackoff(&ps, 3750);
    try expectEqual(@as(u16, 4000), ps.backoff_ms);
    persistBackoff(&ps, 7750);
    try expectEqual(@as(u16, 5000), ps.backoff_ms); // capped
    persistBackoff(&ps, 12750);
    try expectEqual(@as(u16, 5000), ps.backoff_ms); // stays capped
}

test "persist: cleared when window opens" {
    var ps = PersistState{};
    persistArm(&ps, 0);
    try expect(ps.backoff_ms > 0);
    persistClear(&ps);
    try expectEqual(@as(u16, 0), ps.backoff_ms);
    try expect(!persistFired(ps, 1000));
}

test "persist: wrap-safe deadline" {
    var ps = PersistState{};
    persistArm(&ps, 0xFFFFFF00);
    try expectEqual(@as(u32, 0xFFFFFF00 +% 250), ps.deadline_ms);
    try expect(!persistFired(ps, 0xFFFFFF00));
    try expect(persistFired(ps, ps.deadline_ms));
    try expect(persistFired(ps, ps.deadline_ms +% 100));
}
