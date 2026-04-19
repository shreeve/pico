const std = @import("std");

/// 32-bit tagged value — the universal runtime type for nanoruby.
///
/// Encoding (low bits determine type):
///   xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxx1  Fixnum  (31-bit signed, ASR 1)
///   pppppppp pppppppp pppppppp pppppp00  Heap pointer (4-byte aligned)
///   ssssssss ssssssss ssssssss sssss110  Symbol  (upper 29 bits = sym_id)
///   00000000 00000000 00000000 00000000  nil     (0x00)
///   00000000 00000000 00000000 00000010  false   (0x02)
///   00000000 00000000 00000000 00001010  true    (0x0A)
///   00000000 00000000 00000000 00010010  undef   (0x12)
pub const Value = struct {
    raw: u32,

    // ── Tag constants ────────────────────────────────────────────────

    const TAG_FIXNUM: u32 = 0b001;
    const TAG_SYMBOL: u32 = 0b110;
    const MASK_1: u32 = 0b001;
    const MASK_2: u32 = 0b011;
    const MASK_3: u32 = 0b111;

    const RAW_NIL: u32 = 0x00;
    const RAW_FALSE: u32 = 0x02;
    const RAW_TRUE: u32 = 0x0A;
    const RAW_UNDEF: u32 = 0x12;

    // ── Special constants ────────────────────────────────────────────

    pub const nil = Value{ .raw = RAW_NIL };
    pub const false_ = Value{ .raw = RAW_FALSE };
    pub const true_ = Value{ .raw = RAW_TRUE };
    pub const undef = Value{ .raw = RAW_UNDEF };

    // ── Constructors ─────────────────────────────────────────────────

    /// Encode a 31-bit signed integer as an immediate fixnum.
    /// Returns null if the value is outside the representable range.
    pub fn fromFixnum(n: i32) ?Value {
        if (n < min_fixnum or n > max_fixnum) return null;
        const bits: u32 = @bitCast(n);
        return .{ .raw = (bits << 1) | TAG_FIXNUM };
    }

    /// Unchecked fixnum encoding for internal use where the value is
    /// known to be in range (e.g., after arithmetic range validation).
    pub fn fromFixnumUnchecked(n: i32) Value {
        const bits: u32 = @bitCast(n);
        return .{ .raw = (bits << 1) | TAG_FIXNUM };
    }

    pub fn fromSymbol(id: u29) Value {
        return .{ .raw = (@as(u32, id) << 3) | TAG_SYMBOL };
    }

    pub fn fromBool(b: bool) Value {
        return if (b) true_ else false_;
    }

    pub fn fromPtr(ptr: *anyopaque) Value {
        const addr: u32 = @intFromPtr(ptr);
        std.debug.assert(addr & MASK_2 == 0);
        return .{ .raw = addr };
    }

    // ── Type predicates ──────────────────────────────────────────────

    pub fn isFixnum(self: Value) bool {
        return self.raw & MASK_1 == TAG_FIXNUM;
    }

    pub fn isNil(self: Value) bool {
        return self.raw == RAW_NIL;
    }

    pub fn isFalse(self: Value) bool {
        return self.raw == RAW_FALSE;
    }

    pub fn isTrue(self: Value) bool {
        return self.raw == RAW_TRUE;
    }

    pub fn isUndef(self: Value) bool {
        return self.raw == RAW_UNDEF;
    }

    pub fn isBool(self: Value) bool {
        return self.raw == RAW_FALSE or self.raw == RAW_TRUE;
    }

    pub fn isSymbol(self: Value) bool {
        return !self.isFixnum() and (self.raw & MASK_3 == TAG_SYMBOL);
    }

    /// True if this value is a 4-byte-aligned heap object pointer.
    /// Invariant: no immediate value except nil uses low bits 00.
    pub fn isHeapPtr(self: Value) bool {
        return self.raw != 0 and (self.raw & MASK_2 == 0);
    }

    /// Ruby truthiness: only nil and false are falsy.
    pub fn isFalsy(self: Value) bool {
        return self.raw == RAW_NIL or self.raw == RAW_FALSE;
    }

    pub fn isTruthy(self: Value) bool {
        return !self.isFalsy();
    }

    pub fn isImmediate(self: Value) bool {
        return !self.isHeapPtr();
    }

    // ── Extractors ───────────────────────────────────────────────────

    pub fn asFixnum(self: Value) ?i32 {
        if (!self.isFixnum()) return null;
        const signed: i32 = @bitCast(self.raw);
        return signed >> 1; // arithmetic shift right
    }

    pub fn asSymbolId(self: Value) ?u29 {
        if (!self.isSymbol()) return null;
        return @truncate(self.raw >> 3);
    }

    pub fn asPtr(self: Value, comptime T: type) ?*T {
        if (!self.isHeapPtr()) return null;
        return @ptrFromInt(self.raw);
    }

    // ── Equality ─────────────────────────────────────────────────────

    pub fn eql(self: Value, other: Value) bool {
        return self.raw == other.raw;
    }

    // ── Fixnum arithmetic (returns null on type mismatch or overflow) ─

    pub fn addFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        const result = @as(i64, a) + @as(i64, b);
        if (result > max_fixnum or result < min_fixnum) return null;
        return fromFixnumUnchecked(@intCast(result));
    }

    pub fn subFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        const result = @as(i64, a) - @as(i64, b);
        if (result > max_fixnum or result < min_fixnum) return null;
        return fromFixnumUnchecked(@intCast(result));
    }

    pub fn mulFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        const result = @as(i64, a) * @as(i64, b);
        if (result > max_fixnum or result < min_fixnum) return null;
        return fromFixnumUnchecked(@intCast(result));
    }

    pub fn negFixnum(self: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        if (a == min_fixnum) return null;
        return fromFixnumUnchecked(-a);
    }

    // ── Comparison (fixnum only, returns null for non-fixnum) ────────

    pub fn ltFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        return fromBool(a < b);
    }

    pub fn leFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        return fromBool(a <= b);
    }

    pub fn gtFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        return fromBool(a > b);
    }

    pub fn geFixnum(self: Value, other: Value) ?Value {
        const a = self.asFixnum() orelse return null;
        const b = other.asFixnum() orelse return null;
        return fromBool(a >= b);
    }

    // ── Debug formatting ─────────────────────────────────────────────

    /// Renders a human-readable representation of this value.
    /// Callable directly as `value.format(writer)` or via `std.fmt`
    /// with the `{f}` specifier.
    pub fn format(self: Value, writer: anytype) !void {
        if (self.isNil()) {
            try writer.writeAll("nil");
        } else if (self.isTrue()) {
            try writer.writeAll("true");
        } else if (self.isFalse()) {
            try writer.writeAll("false");
        } else if (self.isUndef()) {
            try writer.writeAll("undef");
        } else if (self.asFixnum()) |n| {
            try writer.print("{d}", .{n});
        } else if (self.asSymbolId()) |id| {
            try writer.print(":sym_{d}", .{id});
        } else if (self.isHeapPtr()) {
            try writer.print("<obj@0x{x:0>8}>", .{self.raw});
        } else {
            try writer.print("<unknown:0x{x:0>8}>", .{self.raw});
        }
    }

    // ── Constants ────────────────────────────────────────────────────

    pub const max_fixnum: i32 = std.math.maxInt(i31);
    pub const min_fixnum: i32 = std.math.minInt(i31);
};

// ═════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════

test "fixnum roundtrip" {
    const cases = [_]i32{ 0, 1, -1, 42, -42, 1000, -1000, Value.max_fixnum, Value.min_fixnum };
    for (cases) |n| {
        const v = Value.fromFixnum(n).?;
        try std.testing.expect(v.isFixnum());
        try std.testing.expect(!v.isNil());
        try std.testing.expect(!v.isHeapPtr());
        try std.testing.expect(!v.isSymbol());
        try std.testing.expectEqual(n, v.asFixnum().?);
    }
}

test "fixnum checked rejects out-of-range" {
    try std.testing.expect(Value.fromFixnum(std.math.maxInt(i32)) == null);
    try std.testing.expect(Value.fromFixnum(std.math.minInt(i32)) == null);
    try std.testing.expect(Value.fromFixnum(Value.max_fixnum + 1) == null);
    try std.testing.expect(Value.fromFixnum(Value.min_fixnum - 1) == null);
}

test "special values identity" {
    try std.testing.expect(Value.nil.isNil());
    try std.testing.expect(!Value.nil.isTrue());
    try std.testing.expect(!Value.nil.isFalse());
    try std.testing.expect(!Value.nil.isFixnum());

    try std.testing.expect(Value.true_.isTrue());
    try std.testing.expect(Value.true_.isBool());
    try std.testing.expect(!Value.true_.isNil());

    try std.testing.expect(Value.false_.isFalse());
    try std.testing.expect(Value.false_.isBool());
    try std.testing.expect(!Value.false_.isTrue());

    try std.testing.expect(Value.undef.isUndef());
    try std.testing.expect(!Value.undef.isNil());
}

test "truthiness" {
    try std.testing.expect(Value.nil.isFalsy());
    try std.testing.expect(Value.false_.isFalsy());
    try std.testing.expect(Value.true_.isTruthy());
    try std.testing.expect(Value.fromFixnum(0).?.isTruthy()); // 0 is truthy in Ruby!
    try std.testing.expect(Value.fromFixnum(1).?.isTruthy());
    try std.testing.expect(Value.fromSymbol(0).isTruthy());
}

test "symbol roundtrip" {
    const cases = [_]u29{ 0, 1, 42, 255, 1000, 500_000_000 };
    for (cases) |id| {
        const v = Value.fromSymbol(id);
        try std.testing.expect(v.isSymbol());
        try std.testing.expect(!v.isFixnum());
        try std.testing.expect(!v.isNil());
        try std.testing.expect(!v.isHeapPtr());
        try std.testing.expectEqual(id, v.asSymbolId().?);
    }
}

test "fixnum arithmetic" {
    const a = Value.fromFixnum(40).?;
    const b = Value.fromFixnum(2).?;

    const sum = a.addFixnum(b).?;
    try std.testing.expectEqual(@as(i32, 42), sum.asFixnum().?);

    const diff = a.subFixnum(b).?;
    try std.testing.expectEqual(@as(i32, 38), diff.asFixnum().?);

    const prod = a.mulFixnum(b).?;
    try std.testing.expectEqual(@as(i32, 80), prod.asFixnum().?);
}

test "fixnum arithmetic with negatives" {
    const a = Value.fromFixnum(-10).?;
    const b = Value.fromFixnum(3).?;

    try std.testing.expectEqual(@as(i32, -7), a.addFixnum(b).?.asFixnum().?);
    try std.testing.expectEqual(@as(i32, -13), a.subFixnum(b).?.asFixnum().?);
    try std.testing.expectEqual(@as(i32, -30), a.mulFixnum(b).?.asFixnum().?);
}

test "fixnum overflow returns null" {
    const big = Value.fromFixnum(Value.max_fixnum).?;
    const one = Value.fromFixnum(1).?;
    try std.testing.expect(big.addFixnum(one) == null);

    const small = Value.fromFixnum(Value.min_fixnum).?;
    try std.testing.expect(small.subFixnum(one) == null);
}

test "fixnum comparison" {
    const a = Value.fromFixnum(3).?;
    const b = Value.fromFixnum(5).?;

    try std.testing.expect(a.ltFixnum(b).?.isTrue());
    try std.testing.expect(b.ltFixnum(a).?.isFalse());
    try std.testing.expect(a.leFixnum(a).?.isTrue());
    try std.testing.expect(b.gtFixnum(a).?.isTrue());
    try std.testing.expect(a.geFixnum(a).?.isTrue());
}

test "type mismatch returns null" {
    const num = Value.fromFixnum(1).?;
    try std.testing.expect(num.addFixnum(Value.nil) == null);
    try std.testing.expect(num.ltFixnum(Value.true_) == null);
    try std.testing.expect(Value.nil.asFixnum() == null);
    try std.testing.expect(Value.nil.asSymbolId() == null);
}

test "equality" {
    try std.testing.expect(Value.nil.eql(Value.nil));
    try std.testing.expect(Value.true_.eql(Value.true_));
    try std.testing.expect(Value.fromFixnum(42).?.eql(Value.fromFixnum(42).?));
    try std.testing.expect(!Value.fromFixnum(1).?.eql(Value.fromFixnum(2).?));
    try std.testing.expect(!Value.nil.eql(Value.false_));
    try std.testing.expect(Value.fromSymbol(7).eql(Value.fromSymbol(7)));
    try std.testing.expect(!Value.fromSymbol(1).eql(Value.fromSymbol(2)));
}

test "debug formatting" {
    var buf: [64]u8 = undefined;

    const cases = .{
        .{ Value.nil, "nil" },
        .{ Value.true_, "true" },
        .{ Value.false_, "false" },
        .{ Value.fromFixnum(42).?, "42" },
        .{ Value.fromFixnum(-1).?, "-1" },
        .{ Value.fromFixnum(0).?, "0" },
        .{ Value.fromSymbol(5), ":sym_5" },
    };

    inline for (cases) |case| {
        const actual = std.fmt.bufPrint(&buf, "{f}", .{case[0]}) catch unreachable;
        try std.testing.expectEqualStrings(case[1], actual);
    }
}
