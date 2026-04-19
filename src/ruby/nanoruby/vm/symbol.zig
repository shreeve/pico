const std = @import("std");

/// Symbol table for nanoruby — maps string names to compact symbol IDs.
///
/// Symbols are immortal (never freed) and compared by ID, not string content.
/// Uses open-addressed hashing with linear probing for O(1) average lookup.
///
/// Fixed capacity designed for embedded targets (RP2040):
///   - Max 256 symbols
///   - Max 4KB total symbol text
///   - Hash table sized at 512 (2x capacity for low collision rate)
const MAX_SYMBOLS = 256;
const MAX_CHARS = 4096;
const TABLE_SIZE = 512; // must be power of 2

const EMPTY: u16 = 0xFFFF;

pub const SymbolTable = struct {
    chars: [MAX_CHARS]u8 = undefined,
    char_pos: u16 = 0,

    entries: [MAX_SYMBOLS]Entry = [_]Entry{.{}} ** MAX_SYMBOLS,
    count: u16 = 0,

    table: [TABLE_SIZE]u16 = [_]u16{EMPTY} ** TABLE_SIZE,

    const Entry = struct {
        hash: u32 = 0,
        offset: u16 = 0,
        len: u16 = 0,
    };

    pub fn intern(self: *SymbolTable, name: []const u8) ?u16 {
        if (name.len == 0) return null;

        const hash = fnv1a(name);
        var idx = hash & (TABLE_SIZE - 1);

        while (true) {
            const slot = self.table[idx];
            if (slot == EMPTY) break;

            const entry = &self.entries[slot];
            if (entry.hash == hash and entry.len == name.len) {
                const stored = self.chars[entry.offset..][0..entry.len];
                if (std.mem.eql(u8, stored, name)) return slot;
            }

            idx = (idx + 1) & (TABLE_SIZE - 1);
        }

        if (self.count >= MAX_SYMBOLS) return null;
        if (self.char_pos + name.len > MAX_CHARS) return null;

        const id = self.count;
        @memcpy(self.chars[self.char_pos..][0..name.len], name);

        self.entries[id] = .{
            .hash = hash,
            .offset = self.char_pos,
            .len = @intCast(name.len),
        };
        self.char_pos += @intCast(name.len);
        self.count += 1;

        self.table[idx] = id;

        return id;
    }

    pub fn lookup(self: *const SymbolTable, id: u16) ?[]const u8 {
        if (id >= self.count) return null;
        const entry = &self.entries[id];
        return self.chars[entry.offset..][0..entry.len];
    }

    pub fn find(self: *const SymbolTable, name: []const u8) ?u16 {
        if (name.len == 0) return null;

        const hash = fnv1a(name);
        var idx = hash & (TABLE_SIZE - 1);

        while (true) {
            const slot = self.table[idx];
            if (slot == EMPTY) return null;

            const entry = &self.entries[slot];
            if (entry.hash == hash and entry.len == name.len) {
                const stored = self.chars[entry.offset..][0..entry.len];
                if (std.mem.eql(u8, stored, name)) return slot;
            }

            idx = (idx + 1) & (TABLE_SIZE - 1);
        }
    }
};

fn fnv1a(data: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (data) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "symbol: intern and lookup" {
    var syms = SymbolTable{};
    const foo = syms.intern("foo").?;
    const bar = syms.intern("bar").?;
    try std.testing.expect(foo != bar);
    try std.testing.expectEqualStrings("foo", syms.lookup(foo).?);
    try std.testing.expectEqualStrings("bar", syms.lookup(bar).?);
}

test "symbol: intern same name returns same ID" {
    var syms = SymbolTable{};
    const a = syms.intern("hello").?;
    const b = syms.intern("hello").?;
    try std.testing.expectEqual(a, b);
}

test "symbol: find existing" {
    var syms = SymbolTable{};
    const id = syms.intern("test").?;
    try std.testing.expectEqual(id, syms.find("test").?);
}

test "symbol: find non-existing returns null" {
    var syms = SymbolTable{};
    _ = syms.intern("exists");
    try std.testing.expect(syms.find("nope") == null);
}

test "symbol: capacity limit" {
    var syms = SymbolTable{};
    for (0..MAX_SYMBOLS) |i| {
        var buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable;
        try std.testing.expect(syms.intern(name) != null);
    }
    try std.testing.expect(syms.intern("overflow") == null);
}

test "symbol: empty name returns null" {
    var syms = SymbolTable{};
    try std.testing.expect(syms.intern("") == null);
}

test "symbol: IDs are sequential" {
    var syms = SymbolTable{};
    try std.testing.expectEqual(@as(u16, 0), syms.intern("a").?);
    try std.testing.expectEqual(@as(u16, 1), syms.intern("b").?);
    try std.testing.expectEqual(@as(u16, 2), syms.intern("c").?);
    try std.testing.expectEqual(@as(u16, 0), syms.intern("a").?);
}
