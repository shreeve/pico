const std = @import("std");
const Value = @import("value.zig").Value;
const Opcode = @import("opcode.zig").Opcode;
const IrFunc = @import("vm.zig").IrFunc;

/// Simple bytecode builder for tests and demos.
/// Emits instructions into a fixed buffer and builds an IrFunc.
pub const Assembler = struct {
    code: [1024]u8 = undefined,
    code_len: u16 = 0,
    consts: [64]Value = undefined,
    const_len: u8 = 0,
    syms: [32]u16 = undefined,
    sym_len: u8 = 0,
    children: [8]*const IrFunc = undefined,
    child_len: u8 = 0,

    pub fn init() Assembler {
        return .{};
    }

    /// Add a constant to the pool, return its index.
    pub fn addConst(self: *Assembler, val: Value) u8 {
        const idx = self.const_len;
        self.consts[idx] = val;
        self.const_len += 1;
        return idx;
    }

    /// Add a symbol ID to the sym table, return its index.
    pub fn addSym(self: *Assembler, sym_id: u16) u8 {
        for (self.syms[0..self.sym_len], 0..) |s, i| {
            if (s == sym_id) return @intCast(i);
        }
        const idx = self.sym_len;
        self.syms[idx] = sym_id;
        self.sym_len += 1;
        return idx;
    }

    /// Add a child function, return its index.
    pub fn addChild(self: *Assembler, func: *const IrFunc) u8 {
        const idx = self.child_len;
        self.children[idx] = func;
        self.child_len += 1;
        return idx;
    }

    /// Emit a Z-format instruction (no operands).
    pub fn emitZ(self: *Assembler, opcode: Opcode) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code_len += 1;
    }

    /// Emit an A-format instruction (1 register operand).
    pub fn emitA(self: *Assembler, opcode: Opcode, a: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code_len += 2;
    }

    /// Emit an AB-format instruction (2 register operands).
    pub fn emitAB(self: *Assembler, opcode: Opcode, a: u8, b: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = b;
        self.code_len += 3;
    }

    /// Emit an ABC-format instruction (3 register operands).
    pub fn emitABC(self: *Assembler, opcode: Opcode, a: u8, b: u8, c: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = b;
        self.code[self.code_len + 3] = c;
        self.code_len += 4;
    }

    /// Emit an AS-format instruction (register + signed 16-bit offset).
    pub fn emitAS(self: *Assembler, opcode: Opcode, a: u8, s: i16) void {
        const u: u16 = @bitCast(s);
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = @truncate(u >> 8);
        self.code[self.code_len + 3] = @truncate(u);
        self.code_len += 4;
    }

    /// Emit an S-format instruction (signed 16-bit offset, no register).
    pub fn emitS(self: *Assembler, opcode: Opcode, s: i16) void {
        const u: u16 = @bitCast(s);
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = @truncate(u >> 8);
        self.code[self.code_len + 2] = @truncate(u);
        self.code_len += 3;
    }

    /// Emit a W-format instruction (24-bit unsigned immediate).
    pub fn emitW(self: *Assembler, opcode: Opcode, w: u24) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = @truncate(w >> 16);
        self.code[self.code_len + 2] = @truncate(w >> 8);
        self.code[self.code_len + 3] = @truncate(w);
        self.code_len += 4;
    }

    /// Current bytecode offset (for computing jump targets).
    pub fn offset(self: *const Assembler) u16 {
        return self.code_len;
    }

    /// Build an IrFunc from the accumulated bytecode and constants.
    /// The returned IrFunc references the Assembler's internal buffers,
    /// so the Assembler must outlive the IrFunc.
    pub fn build(self: *Assembler, nregs: u8) IrFunc {
        return .{
            .bytecode = &self.code,
            .bytecode_len = self.code_len,
            .nregs = nregs,
            .nlocals = 0,
            .const_pool = self.consts[0..self.const_len],
            .syms = self.syms[0..self.sym_len],
            .child_funcs = self.children[0..self.child_len],
        };
    }
};
