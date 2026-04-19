const std = @import("std");
const Value = @import("value.zig").Value;
const IrFunc = @import("vm.zig").IrFunc;

/// .nrb binary format for serialized nanoruby bytecode.
///
/// Layout:
///   [4]  magic    "NRBY"
///   [2]  version  LE u16 (currently 2)
///   [1]  count    function count
///   [n]  funcs    serialized functions (count times)
///   [4]  crc32    IEEE CRC-32 of all preceding bytes
///
/// Each function (v2):
///   [1]  nregs
///   [1]  nlocals
///   [2]  bytecode_len   LE u16
///   [1]  const_count
///   [1]  sym_count
///   [1]  string_count
///   [n]  bytecode       bytecode_len bytes
///   [n]  constants      const_count * 4 bytes (raw Value u32s, LE)
///   [n]  syms           sym_count * 2 bytes (u16 atom IDs, LE)
///   [n]  string_literals: for each, [2] len LE u16 + [len] bytes
///
/// v1 → v2 format change: added `sym_count`, `string_count`, the syms
/// table, and the string-literal table. Without these, any SEND /
/// LOAD_SYM / LOAD_STRING opcode over-indexes into an empty default
/// slice and the VM raises `ConstOutOfBounds`. `child_funcs` and
/// `float_pool` are deliberately NOT yet serialized — blocks and
/// floats are out of Phase A scope (see pico ISSUES.md #15).
/// Firmware rejects v1 blobs with `BadVersion`.

const MAGIC = "NRBY";
const VERSION: u16 = 2;
const HEADER_SIZE = 4 + 2 + 1; // magic + version + count
const CRC_SIZE = 4;
const SERIALIZED_VALUE_SIZE = 4; // portable: always 4 bytes on wire
const SERIALIZED_SYM_SIZE = 2;
const MAX_NRB_SIZE = 32768;

/// Encode a Value for the .nrb binary format (always 4 bytes, LE).
fn serializeValue(val: Value) u32 {
    return val.raw;
}

/// Decode a Value from the .nrb binary format (always 4 bytes, LE).
fn deserializeValue(bits: u32) Value {
    return .{ .raw = bits };
}

pub const NrbError = error{
    BadMagic,
    BadVersion,
    BadCrc,
    Truncated,
    TooLarge,
};

pub fn serialize(func: *const IrFunc, buf: []u8) NrbError![]const u8 {
    if (buf.len < HEADER_SIZE + CRC_SIZE + 5) return NrbError.TooLarge;

    var pos: usize = 0;

    @memcpy(buf[pos..][0..4], MAGIC);
    pos += 4;

    std.mem.writeInt(u16, buf[pos..][0..2], VERSION, .little);
    pos += 2;

    buf[pos] = 1; // function count
    pos += 1;

    pos = try serializeFunc(func, buf, pos);

    const crc = std.hash.crc.Crc32IsoHdlc.hash(buf[0..pos]);
    std.mem.writeInt(u32, buf[pos..][0..4], crc, .little);
    pos += 4;

    return buf[0..pos];
}

fn serializeFunc(func: *const IrFunc, buf: []u8, start: usize) NrbError!usize {
    var pos = start;

    // Compute total on-wire size including syms + string_literals.
    var strings_bytes: usize = 0;
    for (func.string_literals) |s| strings_bytes += 2 + s.len;
    const func_size = 1 + 1 + 2 + 1 + 1 + 1 +
        func.bytecode_len +
        @as(usize, func.const_pool.len) * SERIALIZED_VALUE_SIZE +
        @as(usize, func.syms.len) * SERIALIZED_SYM_SIZE +
        strings_bytes;
    if (pos + func_size > buf.len - CRC_SIZE) return NrbError.TooLarge;

    // A Phase-A IrFunc with >255 consts / syms / strings would truncate
    // on the u8 count fields below. Reject deliberately rather than
    // silently corrupt the blob. Phase B can widen to u16 if needed.
    if (func.const_pool.len > 255) return NrbError.TooLarge;
    if (func.syms.len > 255) return NrbError.TooLarge;
    if (func.string_literals.len > 255) return NrbError.TooLarge;

    buf[pos] = func.nregs;
    pos += 1;
    buf[pos] = func.nlocals;
    pos += 1;

    std.mem.writeInt(u16, buf[pos..][0..2], func.bytecode_len, .little);
    pos += 2;

    buf[pos] = @intCast(func.const_pool.len);
    pos += 1;
    buf[pos] = @intCast(func.syms.len);
    pos += 1;
    buf[pos] = @intCast(func.string_literals.len);
    pos += 1;

    @memcpy(buf[pos..][0..func.bytecode_len], func.bytecode[0..func.bytecode_len]);
    pos += func.bytecode_len;

    for (func.const_pool) |val| {
        std.mem.writeInt(u32, buf[pos..][0..SERIALIZED_VALUE_SIZE], serializeValue(val), .little);
        pos += SERIALIZED_VALUE_SIZE;
    }

    for (func.syms) |sym| {
        std.mem.writeInt(u16, buf[pos..][0..SERIALIZED_SYM_SIZE], sym, .little);
        pos += SERIALIZED_SYM_SIZE;
    }

    for (func.string_literals) |s| {
        // Each string is length-prefixed (u16 LE) then raw bytes. On
        // deserialize, the byte pointer aliases into the blob's
        // .rodata, which is immutable and never moved by GC.
        if (s.len > 0xFFFF) return NrbError.TooLarge;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(s.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }

    return pos;
}

pub fn deserialize(data: []const u8, out_func: *IrFunc) NrbError!void {
    if (data.len < HEADER_SIZE + CRC_SIZE) return NrbError.Truncated;

    if (!std.mem.eql(u8, data[0..4], MAGIC)) return NrbError.BadMagic;

    const version = std.mem.readInt(u16, data[4..6], .little);
    if (version != VERSION) return NrbError.BadVersion;

    const stored_crc = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
    const computed_crc = std.hash.crc.Crc32IsoHdlc.hash(data[0 .. data.len - 4]);
    if (stored_crc != computed_crc) return NrbError.BadCrc;

    const count = data[6];
    if (count < 1) return NrbError.Truncated;

    var pos: usize = HEADER_SIZE;
    try deserializeFunc(data, &pos, out_func);
}

// Static storage for deserialized IrFunc state. Single-threaded
// embedded target: one function body in flight at a time.
//   const_storage — u32 Values decoded from the blob.
//   sym_storage   — u16 atom IDs (referenced by SEND / LOAD_SYM /
//                   LOAD_GVAR / SET_GVAR / LOAD_CONST_REF /
//                   SET_CONST_REF / SSEND / REFINE / etc.).
//   string_storage — slice headers whose byte pointers alias back
//                    into the .nrb blob's immutable bytes.
var const_storage: [256]Value = undefined;
var sym_storage: [256]u16 = undefined;
var string_storage: [256][]const u8 = undefined;

fn deserializeFunc(data: []const u8, pos: *usize, func: *IrFunc) NrbError!void {
    // Header fields: nregs + nlocals + bytecode_len(u16) + const_count
    // + sym_count + string_count = 7 bytes.
    if (pos.* + 7 > data.len - CRC_SIZE) return NrbError.Truncated;

    func.nregs = data[pos.*];
    pos.* += 1;
    func.nlocals = data[pos.*];
    pos.* += 1;

    func.bytecode_len = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;

    const const_count = data[pos.*];
    pos.* += 1;
    const sym_count = data[pos.*];
    pos.* += 1;
    const string_count = data[pos.*];
    pos.* += 1;

    if (pos.* + func.bytecode_len > data.len - CRC_SIZE) return NrbError.Truncated;
    func.bytecode = @ptrCast(data[pos.*..].ptr);
    pos.* += func.bytecode_len;

    const const_bytes = @as(usize, const_count) * SERIALIZED_VALUE_SIZE;
    if (pos.* + const_bytes > data.len - CRC_SIZE) return NrbError.Truncated;

    for (0..const_count) |i| {
        const_storage[i] = deserializeValue(std.mem.readInt(u32, data[pos.*..][0..SERIALIZED_VALUE_SIZE], .little));
        pos.* += SERIALIZED_VALUE_SIZE;
    }
    func.const_pool = const_storage[0..const_count];

    const sym_bytes = @as(usize, sym_count) * SERIALIZED_SYM_SIZE;
    if (pos.* + sym_bytes > data.len - CRC_SIZE) return NrbError.Truncated;
    for (0..sym_count) |i| {
        sym_storage[i] = std.mem.readInt(u16, data[pos.*..][0..SERIALIZED_SYM_SIZE], .little);
        pos.* += SERIALIZED_SYM_SIZE;
    }
    func.syms = sym_storage[0..sym_count];

    for (0..string_count) |i| {
        if (pos.* + 2 > data.len - CRC_SIZE) return NrbError.Truncated;
        const slen = std.mem.readInt(u16, data[pos.*..][0..2], .little);
        pos.* += 2;
        if (pos.* + slen > data.len - CRC_SIZE) return NrbError.Truncated;
        // Alias the string bytes back into the blob (.rodata on
        // firmware). The VM copies these into the heap when it
        // materialises them via LOAD_STRING, so immutability is fine.
        string_storage[i] = data[pos.* .. pos.* + slen];
        pos.* += slen;
    }
    func.string_literals = string_storage[0..string_count];
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const Assembler = @import("assembler.zig").Assembler;
const Opcode = @import("opcode.zig").Opcode;

test "nrb: serialize and deserialize roundtrip" {
    var a = Assembler.init();
    const k40 = a.addConst(Value.fromFixnum(40).?);
    const k2 = a.addConst(Value.fromFixnum(2).?);
    a.emitAB(.LOAD_CONST, 0, k40);
    a.emitAB(.LOAD_CONST, 1, k2);
    a.emitA(.ADD, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var buf: [1024]u8 = undefined;
    const nrb_data = try serialize(&func, &buf);

    try std.testing.expect(nrb_data.len > HEADER_SIZE + CRC_SIZE);
    try std.testing.expect(std.mem.eql(u8, nrb_data[0..4], "NRBY"));

    var loaded: IrFunc = undefined;
    try deserialize(nrb_data, &loaded);

    try std.testing.expectEqual(func.nregs, loaded.nregs);
    try std.testing.expectEqual(func.nlocals, loaded.nlocals);
    try std.testing.expectEqual(func.bytecode_len, loaded.bytecode_len);

    const orig_bc = func.bytecode[0..func.bytecode_len];
    const load_bc = loaded.bytecode[0..loaded.bytecode_len];
    try std.testing.expect(std.mem.eql(u8, orig_bc, load_bc));
}

test "nrb: bad magic rejected" {
    var buf = [_]u8{ 'B', 'A', 'D', '!', 0, 0, 0, 0, 0, 0, 0 };
    var func: IrFunc = undefined;
    try std.testing.expectError(NrbError.BadMagic, deserialize(&buf, &func));
}

test "nrb: bad crc rejected" {
    var a = Assembler.init();
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var buf: [1024]u8 = undefined;
    const data = try serialize(&func, &buf);

    var tampered: [1024]u8 = undefined;
    @memcpy(tampered[0..data.len], data);
    tampered[data.len - 1] ^= 0xFF; // corrupt CRC

    var loaded: IrFunc = undefined;
    try std.testing.expectError(NrbError.BadCrc, deserialize(tampered[0..data.len], &loaded));
}

test "nrb: serialize, load, execute" {
    var a = Assembler.init();
    const k40 = a.addConst(Value.fromFixnum(40).?);
    const k2 = a.addConst(Value.fromFixnum(2).?);
    a.emitAB(.LOAD_CONST, 0, k40);
    a.emitAB(.LOAD_CONST, 1, k2);
    a.emitA(.ADD, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var buf: [1024]u8 = undefined;
    const nrb_data = try serialize(&func, &buf);

    var loaded: IrFunc = undefined;
    try deserialize(nrb_data, &loaded);

    const VM = @import("vm.zig").VM;
    var vm = VM.initDefault();
    const result = vm.execute(&loaded);
    try std.testing.expectEqual(@as(i32, 42), result.ok.asFixnum().?);
}
