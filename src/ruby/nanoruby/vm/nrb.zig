const std = @import("std");
const Value = @import("value.zig").Value;
const IrFunc = @import("vm.zig").IrFunc;

/// .nrb binary format for serialized nanoruby bytecode.
///
/// Layout:
///   [4]  magic    "NRBY"
///   [2]  version  LE u16 (currently 1)
///   [1]  count    function count
///   [n]  funcs    serialized functions (count times)
///   [4]  crc32    IEEE CRC-32 of all preceding bytes
///
/// Each function:
///   [1]  nregs
///   [1]  nlocals
///   [2]  bytecode_len  LE u16
///   [1]  const_count
///   [n]  bytecode      bytecode_len bytes
///   [n]  constants     const_count * 4 bytes (raw Value u32s, LE)

const MAGIC = "NRBY";
const VERSION: u16 = 1;
const HEADER_SIZE = 4 + 2 + 1; // magic + version + count
const CRC_SIZE = 4;
const SERIALIZED_VALUE_SIZE = 4; // portable: always 4 bytes on wire
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

    const func_size = 1 + 1 + 2 + 1 + func.bytecode_len + @as(usize, func.const_pool.len) * SERIALIZED_VALUE_SIZE;
    if (pos + func_size > buf.len - CRC_SIZE) return NrbError.TooLarge;

    buf[pos] = func.nregs;
    pos += 1;
    buf[pos] = func.nlocals;
    pos += 1;

    std.mem.writeInt(u16, buf[pos..][0..2], func.bytecode_len, .little);
    pos += 2;

    buf[pos] = @intCast(func.const_pool.len);
    pos += 1;

    @memcpy(buf[pos..][0..func.bytecode_len], func.bytecode[0..func.bytecode_len]);
    pos += func.bytecode_len;

    for (func.const_pool) |val| {
        std.mem.writeInt(u32, buf[pos..][0..SERIALIZED_VALUE_SIZE], serializeValue(val), .little);
        pos += SERIALIZED_VALUE_SIZE;
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

// Static storage for deserialized constants (single-threaded embedded target)
var const_storage: [256]Value = undefined;

fn deserializeFunc(data: []const u8, pos: *usize, func: *IrFunc) NrbError!void {
    if (pos.* + 5 > data.len - CRC_SIZE) return NrbError.Truncated;

    func.nregs = data[pos.*];
    pos.* += 1;
    func.nlocals = data[pos.*];
    pos.* += 1;

    func.bytecode_len = std.mem.readInt(u16, data[pos.*..][0..2], .little);
    pos.* += 2;

    const const_count = data[pos.*];
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
