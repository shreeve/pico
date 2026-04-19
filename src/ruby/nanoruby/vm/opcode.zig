const std = @import("std");

/// Nanoruby bytecode opcodes.
///
/// Operand formats:
///   Z  = no operands         (1 byte total)
///   A  = 1 register          (2 bytes)
///   AB = 2 registers         (3 bytes)
///   ABC = 3 registers        (4 bytes)
///   AS = register + signed16 (4 bytes)
///   W  = 24-bit unsigned     (4 bytes)
pub const Opcode = enum(u8) {
    // ── Loads ────────────────────────────────────────────────────────
    NOP = 0x00, //  Z   no operation
    MOVE = 0x01, //  AB  R[a] = R[b]
    LOAD_NIL = 0x02, //  A   R[a] = nil
    LOAD_TRUE = 0x03, //  A   R[a] = true
    LOAD_FALSE = 0x04, //  A   R[a] = false
    LOAD_SELF = 0x05, //  A   R[a] = self
    LOAD_I8 = 0x06, //  AB  R[a] = fixnum(signed_8(b))
    LOAD_I16 = 0x07, //  AS  R[a] = fixnum(signed_16(s))
    LOAD_CONST = 0x08, //  AB  R[a] = ConstPool[b]
    LOAD_SYM = 0x09, //  AB  R[a] = Syms[b]
    LOAD_FLOAT = 0x0A, // AB  R[a] = heap_float(FloatPool[b])

    // ── Variables ────────────────────────────────────────────────────
    GET_IVAR = 0x0C, //  AB  R[a] = self.ivar[Syms[b]]
    SET_IVAR = 0x0D, //  AB  self.ivar[Syms[b]] = R[a]
    GET_CONST = 0x0E, //  AB  R[a] = const_lookup(Syms[b])
    SET_CONST = 0x0F, //  AB  const_set(Syms[b], R[a])
    GET_GLOBAL = 0x10, //  AB  R[a] = Globals[Syms[b]]
    SET_GLOBAL = 0x11, //  AB  Globals[Syms[b]] = R[a]
    GET_UPVAR = 0x12, //  ABC R[a] = UpEnv[b].slot[c]
    SET_UPVAR = 0x13, //  ABC UpEnv[b].slot[c] = R[a]

    // ── Sends ────────────────────────────────────────────────────────
    SEND = 0x14, //  ABC R[a] = R[a].send(Syms[b], R[a+1..a+c])
    SEND0 = 0x15, //  AB  R[a] = R[a].send(Syms[b])
    SEND1 = 0x16, //  ABC R[a] = R[a].send(Syms[b], R[c])
    SSEND = 0x17, //  ABC R[a] = self.send(Syms[b], R[a..a+c])
    SSEND0 = 0x18, //  AB  R[a] = self.send(Syms[b])
    SEND_BLOCK = 0x19, //  ABC R[a] = R[a].send(Syms[b], ..., block=R[a+c])
    SUPER = 0x1A, //  AB  R[a] = super(R[a+1..a+b])
    YIELD = 0x1B, //  AB  R[a] = yield(R[a+1..a+b])

    // ── Branches ─────────────────────────────────────────────────────
    JMP = 0x1C, //  S   pc += signed_16(s)
    JMP_IF = 0x1D, //  AS  if R[a] truthy: pc += signed_16(s)
    JMP_NOT = 0x1E, //  AS  if R[a] falsy:  pc += signed_16(s)
    JMP_NIL = 0x1F, //  AS  if R[a] == nil: pc += signed_16(s)

    // ── Arithmetic (fixnum fast-path) ────────────────────────────────
    ADD = 0x20, //  A   R[a] = R[a] + R[a+1]
    SUB = 0x21, //  A   R[a] = R[a] - R[a+1]
    MUL = 0x22, //  A   R[a] = R[a] * R[a+1]
    DIV = 0x23, //  A   R[a] = R[a] / R[a+1]
    MOD = 0x24, //  A   R[a] = R[a] % R[a+1]
    EQ = 0x25, //  A   R[a] = R[a] == R[a+1]
    LT = 0x26, //  A   R[a] = R[a] <  R[a+1]
    LE = 0x27, //  A   R[a] = R[a] <= R[a+1]
    GT = 0x28, //  A   R[a] = R[a] >  R[a+1]
    GE = 0x29, //  A   R[a] = R[a] >= R[a+1]

    // ── Collections ──────────────────────────────────────────────────
    ARRAY = 0x2A, //  AB  R[a] = Array.new(R[a..a+b-1])
    HASH = 0x2B, //  AB  R[a] = Hash.new(R[a..a+b*2-1])
    RANGE = 0x2C, //  ABC R[a] = Range.new(R[b], R[c], exclusive=flag)
    STRING = 0x2D, //  AB  R[a] = String.dup(ConstPool[b])
    STRCAT = 0x2E, //  A   R[a] = R[a] + R[a+1].to_s

    // ── Functions ────────────────────────────────────────────────────
    ENTER = 0x2F, //  W   param descriptor (24-bit aspec)
    RETURN = 0x30, //  A   return R[a]
    BLOCK = 0x31, //  AB  R[a] = Block.new(IrFunc[b], env)
    LAMBDA = 0x32, //  AB  R[a] = Lambda.new(IrFunc[b], env)
    METHOD = 0x33, //  AB  R[a] = Method.new(IrFunc[b])

    // ── Definitions ──────────────────────────────────────────────────
    DEF_METHOD = 0x34, //  AB  current_class.define(Syms[a], R[b])
    DEF_CLASS = 0x35, //  ABC R[a] = class Syms[b] < R[c]
    DEF_MODULE = 0x36, //  AB  R[a] = module Syms[b]
    DEF_SCLASS = 0x37, //  AB  R[a] = class << R[b]

    // ── Exceptions ───────────────────────────────────────────────────
    EXCEPT = 0x38, //  A   R[a] = current_exception (or nil)
    RESCUE = 0x39, //  AB  R[a] = R[b].is_a?(current_exception)
    RAISE = 0x3A, //  A   raise R[a]
    PUSH_HANDLER = 0x3D, //  AS  push handler: dest=R[a], rescue_pc=pc+s
    POP_HANDLER = 0x3E, //  Z   pop top exception handler
    CLEAR_EXC = 0x3F, //  Z   current_exception = nil

    // ── Body execution ──────────────────────────────────────────────
    EXEC_BODY = 0x3C, //  AB  execute IrFunc[b] with self=R[a]

    // ── Control ──────────────────────────────────────────────────────
    STOP = 0x3B, //  Z   halt VM
    BREAK = 0x40, //  A   break out of current block with R[a]

    _,

    /// Returns the operand format for instruction size calculation.
    pub fn operandFormat(self: Opcode) Format {
        return switch (self) {
            .NOP, .STOP, .POP_HANDLER, .CLEAR_EXC => .Z,
            .LOAD_NIL, .LOAD_TRUE, .LOAD_FALSE, .LOAD_SELF, .ADD, .SUB, .MUL, .DIV, .MOD, .EQ, .LT, .LE, .GT, .GE, .STRCAT, .RETURN, .EXCEPT, .RAISE, .BREAK => .A,
            .MOVE, .LOAD_I8, .LOAD_CONST, .LOAD_SYM, .LOAD_FLOAT, .GET_IVAR, .SET_IVAR, .GET_CONST, .SET_CONST, .GET_GLOBAL, .SET_GLOBAL, .SEND0, .SSEND0, .SUPER, .YIELD, .ARRAY, .HASH, .STRING, .BLOCK, .LAMBDA, .METHOD, .DEF_METHOD, .DEF_MODULE, .DEF_SCLASS, .RESCUE, .EXEC_BODY => .AB,
            .GET_UPVAR, .SET_UPVAR, .SEND, .SEND1, .SSEND, .SEND_BLOCK, .RANGE, .DEF_CLASS => .ABC,
            .JMP => .S,
            .LOAD_I16, .JMP_IF, .JMP_NOT, .JMP_NIL, .PUSH_HANDLER => .AS,
            .ENTER => .W,
            _ => .Z,
        };
    }

    /// Instruction size in bytes (opcode + operands).
    pub fn size(self: Opcode) u8 {
        return switch (self.operandFormat()) {
            .Z => 1,
            .A => 2,
            .AB, .S => 3,
            .ABC, .AS, .W => 4,
        };
    }

    pub const Format = enum { Z, A, AB, ABC, S, AS, W };
};

/// Decode operands from a bytecode stream.
/// All functions take a pointer to the first operand byte (i.e., one past
/// the opcode byte). The caller is responsible for advancing past the opcode.
pub const Decode = struct {
    pub fn a(operands: [*]const u8) u8 {
        return operands[0];
    }

    pub fn ab(operands: [*]const u8) struct { a: u8, b: u8 } {
        return .{ .a = operands[0], .b = operands[1] };
    }

    pub fn abc(operands: [*]const u8) struct { a: u8, b: u8, c: u8 } {
        return .{ .a = operands[0], .b = operands[1], .c = operands[2] };
    }

    pub fn s16(operands: [*]const u8) i16 {
        const hi: u16 = @as(u16, operands[0]) << 8;
        const lo: u16 = operands[1];
        return @bitCast(hi | lo);
    }

    pub fn as_(operands: [*]const u8) struct { a: u8, s: i16 } {
        return .{
            .a = operands[0],
            .s = s16(operands + 1),
        };
    }

    pub fn w24(operands: [*]const u8) u24 {
        const b0: u24 = operands[0];
        const b1: u24 = operands[1];
        const b2: u24 = operands[2];
        return (b0 << 16) | (b1 << 8) | b2;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "opcode size" {
    try std.testing.expectEqual(@as(u8, 1), Opcode.NOP.size());
    try std.testing.expectEqual(@as(u8, 1), Opcode.STOP.size());
    try std.testing.expectEqual(@as(u8, 2), Opcode.RETURN.size());
    try std.testing.expectEqual(@as(u8, 2), Opcode.ADD.size());
    try std.testing.expectEqual(@as(u8, 3), Opcode.MOVE.size());
    try std.testing.expectEqual(@as(u8, 3), Opcode.LOAD_CONST.size());
    try std.testing.expectEqual(@as(u8, 4), Opcode.SEND.size());
    try std.testing.expectEqual(@as(u8, 4), Opcode.JMP_NOT.size());
    try std.testing.expectEqual(@as(u8, 4), Opcode.ENTER.size());
}

test "decode AB operands" {
    const bytes = [_]u8{ 3, 7 };
    const ops = Decode.ab(&bytes);
    try std.testing.expectEqual(@as(u8, 3), ops.a);
    try std.testing.expectEqual(@as(u8, 7), ops.b);
}

test "decode signed16" {
    // +256 = 0x0100
    const pos = [_]u8{ 0x01, 0x00 };
    try std.testing.expectEqual(@as(i16, 256), Decode.s16(&pos));

    // -1 = 0xFFFF
    const neg = [_]u8{ 0xFF, 0xFF };
    try std.testing.expectEqual(@as(i16, -1), Decode.s16(&neg));
}

test "decode W24 operands" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56 };
    try std.testing.expectEqual(@as(u24, 0x123456), Decode.w24(&bytes));
}
