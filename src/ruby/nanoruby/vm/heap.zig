const std = @import("std");
const Value = @import("value.zig").Value;

/// Object types for the nanoruby runtime.
pub const ObjType = enum(u4) {
    string = 0,
    array = 1,
    hash = 2,
    class = 3,
    method = 4,
    proc = 5,
    env = 6,
    instance = 7,
    range = 8,
    float = 9,
};

/// 4-byte object header. Every heap object starts with this.
///
///   bits [3:0]   type (ObjType)
///   bit  [4]     mark bit (for GC)
///   bits [7:5]   flags (type-specific)
///   bits [15:8]  class_id (u8, index into class table)
///   bits [31:16] size (u16, total object size in 4-byte words)
pub const ObjHeader = packed struct {
    obj_type: ObjType,
    mark: u1 = 0,
    flags: u3 = 0,
    class_id: u8 = 0,
    size_words: u16,

    comptime {
        std.debug.assert(@sizeOf(ObjHeader) == 4);
    }
};

/// Payload for class objects (follows ObjHeader).
/// Header: obj_type=.class, class_id=CLASS_CLASS
pub const RClassPayload = packed struct {
    name_sym: u16,
    represented_class_id: u8,
    superclass_id: u8,

    comptime {
        std.debug.assert(@sizeOf(RClassPayload) == 4);
    }
};

/// Maximum inline instance variables per object.
pub const MAX_IVARS_PER_INSTANCE: u8 = 4;

/// Instance payload: inline ivar array (follows ObjHeader).
/// Ivars are stored as Value[MAX_IVARS_PER_INSTANCE].
pub const INSTANCE_PAYLOAD_BYTES: u32 = @as(u32, MAX_IVARS_PER_INSTANCE) * @sizeOf(Value);

/// String payload (follows ObjHeader). String bytes follow this struct.
pub const RStringPayload = packed struct {
    len: u16,
    _pad: u16 = 0,

    comptime {
        std.debug.assert(@sizeOf(RStringPayload) == 4);
    }
};

/// Array payload (follows ObjHeader). Value elements follow this struct.
pub const RArrayPayload = packed struct {
    len: u16,
    capa: u16,

    comptime {
        std.debug.assert(@sizeOf(RArrayPayload) == 4);
    }
};

/// Hash payload (follows ObjHeader). Key-value Value pairs follow this struct.
pub const RHashPayload = packed struct {
    count: u16,
    capa: u16,

    comptime {
        std.debug.assert(@sizeOf(RHashPayload) == 4);
    }
};

/// Range payload (follows ObjHeader).
pub const RRangePayload = packed struct {
    exclusive: u16,
    _pad: u16 = 0,

    comptime {
        std.debug.assert(@sizeOf(RRangePayload) == 4);
    }
};

/// Float payload (follows ObjHeader). The IEEE-754 double is stored as
/// two 32-bit halves because heap payloads are only guaranteed 4-byte
/// alignment, and a plain `f64` field would require 8-byte alignment.
/// The split lives entirely inside this struct — callers use `get` /
/// `set` and never touch the halves directly.
///
/// On 64-bit hosts this codegens to a single mov/str; on Cortex-M it
/// naturally lowers to two 32-bit loads.
pub const RFloatPayload = extern struct {
    lo: u32,
    hi: u32,

    pub fn get(self: *const RFloatPayload) f64 {
        const bits = (@as(u64, self.hi) << 32) | @as(u64, self.lo);
        return @bitCast(bits);
    }

    pub fn set(self: *RFloatPayload, v: f64) void {
        const bits: u64 = @bitCast(v);
        self.lo = @truncate(bits);
        self.hi = @truncate(bits >> 32);
    }

    comptime {
        std.debug.assert(@sizeOf(RFloatPayload) == 8);
    }
};

/// Bump allocator for heap objects backed by an external buffer.
///
/// All allocations are 4-byte aligned. The heap operates on a slice
/// of a larger arena buffer provided at init time.
pub const Heap = struct {
    buf: []u8,
    pos: u32 = 0,

    pub fn init(buf: []u8) Heap {
        return .{ .buf = buf };
    }

    pub fn allocObj(self: *Heap, obj_type: ObjType, payload_bytes: u32) ?[*]u8 {
        const total = @sizeOf(ObjHeader) + payload_bytes;
        const aligned = (total + 3) & ~@as(u32, 3);
        const size_words: u16 = @intCast(aligned >> 2);

        if (self.pos + aligned > self.buf.len) return null;

        const ptr = self.buf.ptr + self.pos;
        const header: *ObjHeader = @ptrCast(@alignCast(ptr));
        header.* = .{ .obj_type = obj_type, .size_words = size_words };
        self.pos += aligned;

        return ptr;
    }

    pub fn usedBytes(self: *const Heap) u32 {
        return self.pos;
    }

    pub fn freeBytes(self: *const Heap) u32 {
        return @intCast(self.buf.len - self.pos);
    }

    pub fn reset(self: *Heap) void {
        self.pos = 0;
    }

    /// Free the most recently allocated block (tail-trim optimization).
    /// Only works if `ptr` points to the last allocation. No-op otherwise.
    pub fn freeLast(self: *Heap, ptr: [*]u8) void {
        const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
        const obj_bytes = @as(u32, hdr.size_words) * 4;
        const obj_start = @intFromPtr(ptr) - @intFromPtr(self.buf.ptr);
        if (obj_start + obj_bytes == self.pos) {
            self.pos = @intCast(obj_start);
        }
    }

    /// Shrink the most recently allocated block, returning excess to the heap.
    pub fn shrinkLast(self: *Heap, ptr: [*]u8, new_payload_bytes: u32) void {
        const new_total = @sizeOf(ObjHeader) + new_payload_bytes;
        const new_aligned = (new_total + 3) & ~@as(u32, 3);
        const obj_start = @intFromPtr(ptr) - @intFromPtr(self.buf.ptr);
        const hdr: *ObjHeader = @ptrCast(@alignCast(ptr));
        const old_bytes = @as(u32, hdr.size_words) * 4;
        if (obj_start + old_bytes == self.pos and new_aligned < old_bytes) {
            hdr.size_words = @intCast(new_aligned >> 2);
            self.pos = @intCast(obj_start + new_aligned);
        }
    }

    pub fn basePtr(self: anytype) [*]u8 {
        return @constCast(self.buf.ptr);
    }

    pub fn markObj(ptr: [*]u8) void {
        const hdr: *ObjHeader = @ptrCast(@alignCast(ptr));
        hdr.mark = 1;
    }

    pub fn isMarked(ptr: [*]u8) bool {
        const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
        return hdr.mark == 1;
    }

    /// Compact the heap by sliding live (marked) objects left.
    /// Clears mark bits on surviving objects. Returns bytes reclaimed.
    pub fn compact(self: *Heap) u32 {
        const base = self.basePtr();
        var read: u32 = 0;
        var write: u32 = 0;
        var reclaimed: u32 = 0;
        const old_pos = self.pos;

        while (read < self.pos) {
            const ptr = base + read;
            const hdr: *ObjHeader = @ptrCast(@alignCast(ptr));
            const obj_bytes = @as(u32, hdr.size_words) * 4;

            std.debug.assert(obj_bytes >= @sizeOf(ObjHeader));
            std.debug.assert(read + obj_bytes <= self.pos);

            if (hdr.mark == 1) {
                hdr.mark = 0;
                if (write != read) {
                    const dest = base + write;
                    std.mem.copyForwards(u8, dest[0..obj_bytes], ptr[0..obj_bytes]);
                }
                write += obj_bytes;
            } else {
                reclaimed += obj_bytes;
            }
            read += obj_bytes;
        }
        self.pos = write;

        if (write < old_pos) {
            @memset(base[write..old_pos], 0xA5);
        }

        return reclaimed;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const HEAP_TEST_SIZE = 16384;

test "heap: object allocation" {
    var buf: [HEAP_TEST_SIZE]u8 align(4) = undefined;
    var heap = Heap.init(&buf);
    const ptr = heap.allocObj(.string, 12) orelse return error.TestUnexpectedResult;
    const header: *ObjHeader = @ptrCast(@alignCast(ptr));
    try std.testing.expectEqual(ObjType.string, header.obj_type);
    try std.testing.expectEqual(@as(u1, 0), header.mark);
    try std.testing.expect(header.size_words >= 4);
}

test "heap: allocation alignment" {
    var buf: [HEAP_TEST_SIZE]u8 align(4) = undefined;
    var heap = Heap.init(&buf);
    const p1 = heap.allocObj(.string, 5);
    const p2 = heap.allocObj(.array, 7);
    try std.testing.expect(p1 != null);
    try std.testing.expect(p2 != null);
    try std.testing.expectEqual(@as(u32, 0), @intFromPtr(p1.?) % 4);
    try std.testing.expectEqual(@as(u32, 0), @intFromPtr(p2.?) % 4);
}

test "heap: exhaustion returns null" {
    var buf: [HEAP_TEST_SIZE]u8 align(4) = undefined;
    var heap = Heap.init(&buf);
    var count: u32 = 0;
    while (heap.allocObj(.string, 64) != null) count += 1;
    try std.testing.expect(count > 0);
    try std.testing.expect(count < HEAP_TEST_SIZE);
    try std.testing.expect(heap.allocObj(.string, HEAP_TEST_SIZE) == null);
}

test "heap: used and free bytes" {
    var buf: [HEAP_TEST_SIZE]u8 align(4) = undefined;
    var heap = Heap.init(&buf);
    try std.testing.expectEqual(@as(u32, 0), heap.usedBytes());
    try std.testing.expectEqual(@as(u32, HEAP_TEST_SIZE), heap.freeBytes());
    _ = heap.allocObj(.string, 12);
    try std.testing.expect(heap.usedBytes() > 0);
    try std.testing.expect(heap.freeBytes() < HEAP_TEST_SIZE);
}

test "heap: header is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ObjHeader));
}
