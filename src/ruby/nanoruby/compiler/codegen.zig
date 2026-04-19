const std = @import("std");
const syntax = @import("../ruby/syntax.zig");
const Sexp = syntax.Sexp;
const Tag = syntax.Tag;
const parser_mod = @import("../parser.zig");
const ParserSexp = parser_mod.Sexp;
const Value = @import("../vm/value.zig").Value;
const Opcode = @import("../vm/opcode.zig").Opcode;
const vm_mod = @import("../vm/vm.zig");
const IrFunc = vm_mod.IrFunc;
const VM = vm_mod.VM;
const atom_mod = @import("../vm/atom.zig");

pub const CompileError = struct {
    message: []const u8,
};

const MAX_CHILDREN = 8;

/// Compiler state for generating bytecode from a Sexp tree.
/// Each Compiler instance produces one IrFunc (one scope/function).
pub const Compiler = struct {
    source: []const u8,
    code: [4096]u8 = undefined,
    code_len: u16 = 0,
    consts: [256]Value = undefined,
    const_len: u8 = 0,
    locals: [64][]const u8 = undefined,
    local_count: u8 = 0,
    next_reg: u8 = 0,
    max_reg: u8 = 0,
    err: ?CompileError = null,

    // Symbol interning (name -> global ID)
    sym_names: [32][]const u8 = undefined,
    sym_ids: [32]u16 = undefined,
    sym_count: u8 = 0,
    next_sym_id: u16 = 0,

    // Per-function syms table (indices into global sym space)
    func_syms: [16]u16 = undefined,
    func_sym_len: u8 = 0,

    // String literal table
    string_lits: [16][]const u8 = undefined,
    string_lit_len: u8 = 0,

    // Float literal table — backs LOAD_FLOAT. Kept tiny (same budget as
    // string_lits) because most functions have zero or few float
    // literals; anything that outgrows this arena needs a real heap.
    float_lits: [16]f64 = undefined,
    float_lit_len: u8 = 0,

    // Child function storage (for method bodies)
    child_code: [MAX_CHILDREN][1024]u8 = undefined,
    child_consts: [MAX_CHILDREN][64]Value = undefined,
    child_syms_buf: [MAX_CHILDREN][8]u16 = undefined,
    child_str_lits: [MAX_CHILDREN][8][]const u8 = undefined,
    child_float_lits: [MAX_CHILDREN][8]f64 = undefined,
    child_irfuncs: [MAX_CHILDREN]IrFunc = undefined,
    child_func_ptrs: [MAX_CHILDREN]*const IrFunc = undefined,
    child_count: u8 = 0,

    /// Set on block-child compilers so they can resolve unknown
    /// identifiers as UPVARs into the enclosing scope. One-level only
    /// for Phase 3 — nested-block closure support needs chained walks.
    parent: ?*const Compiler = null,

    pub fn init(source: []const u8) Compiler {
        return .{ .source = source };
    }

    /// Result of a multi-level upvar lookup: the enclosing scope's
    /// slot and the number of scope hops from `self` up to that scope.
    const UpvarRef = struct { level: u8, slot: u8 };

    /// Walk the compiler's `parent` chain and return the innermost
    /// ancestor scope (level ≥ 1) that has a local named `name`. Used
    /// to route block-nested variable references through GET_UPVAR /
    /// SET_UPVAR so closures over outer locals compose across arbitrary
    /// nesting depth.
    fn findEnclosingLocal(self: *const Compiler, name: []const u8) ?UpvarRef {
        var scope: ?*const Compiler = self.parent;
        var level: u8 = 1;
        while (scope) |p| : ({
            scope = p.parent;
            level += 1;
        }) {
            for (p.locals[0..p.local_count], 0..) |local, i| {
                if (std.mem.eql(u8, local, name)) {
                    return .{ .level = level, .slot = @intCast(i) };
                }
            }
        }
        return null;
    }

    /// Compile from the parser's Sexp type (same layout, different Zig type).
    pub fn compileProgramAny(self: *Compiler, psexp: ParserSexp) ?IrFunc {
        // ParserSexp and Sexp have identical memory layouts (same union variants
        // in same order, same Tag enum). Safe to reinterpret.
        return self.compileProgram(@as(*const Sexp, @ptrCast(&psexp)).*);
    }

    /// Compile a top-level program Sexp into an IrFunc.
    pub fn compileProgram(self: *Compiler, sexp: Sexp) ?IrFunc {
        if (!sexp.isNode(.program)) {
            self.err = .{ .message = "expected (program ...)" };
            return null;
        }
        const result_reg = self.compileBody(sexp);
        if (self.err != null) return null;
        self.emitA(.RETURN, result_reg);
        return self.build();
    }

    /// Compile a statement body (children of program, if-body, etc.)
    fn compileBody(self: *Compiler, sexp_node: Sexp) u8 {
        const count = sexp_node.childCount();
        if (count == 0) {
            const dst = self.allocReg();
            self.emitA(.LOAD_NIL, dst);
            return dst;
        }

        var result_reg: u8 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // Free the previous statement's temp before compiling the next
            if (i > 0) self.freeReg(result_reg);
            const ch = sexp_node.child(i);
            if (ch.isNode(.stmts)) {
                result_reg = self.compileBody(ch);
            } else {
                result_reg = self.compileExpr(ch, self.allocReg());
            }
        }
        return result_reg;
    }

    /// Compile an expression into the destination register.
    fn compileExpr(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        if (self.err != null) return dst;

        switch (sexp) {
            .nil => {
                self.emitA(.LOAD_NIL, dst);
                return dst;
            },
            .tag => |t| return self.compileTag(t, dst),
            .src, .str => {
                const text = sexp.getText(self.source);
                return self.compileToken(text, dst);
            },
            .list => {
                const tag = sexp.nodeTag() orelse {
                    self.emitA(.LOAD_NIL, dst);
                    return dst;
                };
                return self.compileNode(tag, sexp, dst);
            },
        }
    }

    fn compileTag(self: *Compiler, tag: Tag, dst: u8) u8 {
        switch (tag) {
            .@"true" => self.emitA(.LOAD_TRUE, dst),
            .@"false" => self.emitA(.LOAD_FALSE, dst),
            .nil => self.emitA(.LOAD_NIL, dst),
            .self => self.emitA(.LOAD_SELF, dst),
            else => self.emitA(.LOAD_NIL, dst),
        }
        return dst;
    }

    fn compileToken(self: *Compiler, text: []const u8, dst: u8) u8 {
        if (parseInteger(text)) |val| {
            if (val >= -128 and val <= 127) {
                self.emitAB(.LOAD_I8, dst, @bitCast(@as(i8, @intCast(val))));
            } else {
                const ki = self.addConst(Value.fromFixnum(@intCast(val)) orelse Value.nil);
                self.emitAB(.LOAD_CONST, dst, ki);
            }
            return dst;
        }

        // Float literal: `3.14`, `1.0e10`, `.5` won't appear here — the
        // lexer always emits a leading digit — but `1_000.5` might, so
        // we strip `_` before handing to Zig's float parser.
        if (looksLikeFloat(text)) {
            if (parseFloatLit(text)) |f| {
                const fi = self.addFloatLit(f);
                self.emitAB(.LOAD_FLOAT, dst, fi);
                return dst;
            }
        }

        // Instance variable: @name
        if (text.len > 1 and text[0] == '@') {
            const sym_id = self.internSym(text);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.GET_IVAR, dst, sym_idx);
            return dst;
        }

        // Global variable: $name
        if (text.len > 1 and text[0] == '$') {
            const sym_id = self.internSym(text);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.GET_GLOBAL, dst, sym_idx);
            return dst;
        }

        // String literal: "..." or '...'
        if (text.len >= 2 and (text[0] == '"' or text[0] == '\'')) {
            const str_content = text[1 .. text.len - 1];
            const lit_idx = self.addStringLit(str_content);
            self.emitAB(.STRING, dst, lit_idx);
            return dst;
        }

        // Symbol literal: :name
        if (text.len > 1 and text[0] == ':') {
            const sym_id = self.internSym(text[1..]);
            self.emitAB(.LOAD_SYM, dst, self.addFuncSym(sym_id));
            return dst;
        }

        // Percent-array literal: `%w[foo bar]` / `%i[a b c]`. The
        // lexer emits the full token including delimiters; we strip
        // them, split on whitespace, and emit one STRING / LOAD_SYM
        // per word followed by an ARRAY opcode.
        if (text.len >= 4 and text[0] == '%' and (text[1] == 'w' or text[1] == 'i')) {
            return self.compilePctArray(text, dst);
        }

        if (self.findLocal(text)) |slot| {
            if (slot == dst) return dst;
            self.emitAB(.MOVE, dst, slot);
            return dst;
        }

        // If this compiler is a block-child, walk the parent chain for
        // any lowercase identifier matching an outer local at any depth.
        if (self.findEnclosingLocal(text)) |up| {
            self.emitABC(.GET_UPVAR, dst, up.level, up.slot);
            return dst;
        }

        // Uppercase initial: constant reference (Dog, String, etc.)
        if (text.len > 0 and text[0] >= 'A' and text[0] <= 'Z') {
            const sym_id = self.internSym(text);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.GET_CONST, dst, sym_idx);
            return dst;
        }

        // Unknown lowercase identifier: zero-arg method call (Ruby semantics)
        if (text.len > 0 and ((text[0] >= 'a' and text[0] <= 'z') or text[0] == '_')) {
            const sym_id = self.internSym(text);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitABC(.SSEND, dst, sym_idx, 0);
            return dst;
        }

        self.emitA(.LOAD_NIL, dst);
        return dst;
    }

    fn compileNode(self: *Compiler, tag: Tag, sexp: Sexp, dst: u8) u8 {
        switch (tag) {
            .program => return self.compileBody(sexp),
            .stmts => {
                const result = self.compileBody(sexp);
                if (result != dst) self.emitAB(.MOVE, dst, result);
                return dst;
            },

            .@"true" => { self.emitA(.LOAD_TRUE, dst); return dst; },
            .@"false" => { self.emitA(.LOAD_FALSE, dst); return dst; },
            .nil => { self.emitA(.LOAD_NIL, dst); return dst; },
            .self => { self.emitA(.LOAD_SELF, dst); return dst; },

            .assign => {
                const name = sexp.child(0).getText(self.source);
                if (name.len == 0) return dst;

                // Instance variable assignment: @name = expr
                if (name.len > 1 and name[0] == '@') {
                    _ = self.compileExpr(sexp.child(1), dst);
                    const sym_id = self.internSym(name);
                    const sym_idx = self.addFuncSym(sym_id);
                    self.emitAB(.SET_IVAR, dst, sym_idx);
                    return dst;
                }

                // Global variable assignment: $name = expr
                if (name.len > 1 and name[0] == '$') {
                    _ = self.compileExpr(sexp.child(1), dst);
                    const sym_id = self.internSym(name);
                    const sym_idx = self.addFuncSym(sym_id);
                    self.emitAB(.SET_GLOBAL, dst, sym_idx);
                    return dst;
                }

                // Constant assignment: Name = expr (uppercase initial)
                if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') {
                    _ = self.compileExpr(sexp.child(1), dst);
                    const sym_id = self.internSym(name);
                    const sym_idx = self.addFuncSym(sym_id);
                    self.emitAB(.SET_CONST, dst, sym_idx);
                    return dst;
                }

                // If we're a block-child and `name` is a local in an
                // enclosing scope (any depth), route the assignment
                // through SET_UPVAR so mutations are visible outside.
                if (self.parent != null and self.findLocal(name) == null) {
                    if (self.findEnclosingLocal(name)) |up| {
                        _ = self.compileExpr(sexp.child(1), dst);
                        self.emitABC(.SET_UPVAR, dst, up.level, up.slot);
                        return dst;
                    }
                }

                const slot = self.ensureLocal(name);
                _ = self.compileExpr(sexp.child(1), slot);
                if (slot != dst) self.emitAB(.MOVE, dst, slot);
                return dst;
            },

            .@"+" => return self.compileBinOp(sexp, .ADD, dst),
            .@"-" => return self.compileBinOp(sexp, .SUB, dst),
            .@"*" => return self.compileBinOp(sexp, .MUL, dst),
            .@"/" => return self.compileBinOp(sexp, .DIV, dst),
            .@"%" => return self.compileBinOp(sexp, .MOD, dst),

            .@"==" => return self.compileBinOp(sexp, .EQ, dst),
            .@"<" => return self.compileBinOp(sexp, .LT, dst),
            .@"<=" => return self.compileBinOp(sexp, .LE, dst),
            .@">" => return self.compileBinOp(sexp, .GT, dst),
            .@">=" => return self.compileBinOp(sexp, .GE, dst),
            .@"!=" => return self.compileNe(sexp, dst),

            .@"u-" => {
                _ = self.compileExpr(sexp.child(0), dst + 1);
                self.emitAB(.LOAD_I8, dst, 0);
                self.emitA(.SUB, dst);
                return dst;
            },

            .@"||", .@"or" => return self.compileOr(sexp, dst),
            .@"&&", .@"and" => return self.compileAnd(sexp, dst),
            .not, .@"!" => return self.compileNot(sexp, dst),

            .@"if" => return self.compileIf(sexp, dst),
            .unless => return self.compileUnless(sexp, dst),
            .@"while" => return self.compileWhile(sexp, dst),
            .until => return self.compileUntil(sexp, dst),
            .@"for" => return self.compileFor(sexp, dst),

            .def => return self.compileDef(sexp, dst),
            .send => return self.compileSend(sexp, dst),
            .csend => return self.compileCsend(sexp, dst),
            .class => return self.compileClass(sexp, dst),
            .module => return self.compileModule(sexp, dst),

            .array => return self.compileArray(sexp, dst),
            .hash => return self.compileHash(sexp, dst),
            .dstr => return self.compileDstr(sexp, dst),
            .evstr => return self.compileExpr(sexp.child(0), dst),

            .@".." => return self.compileRange(sexp, dst, false),
            .@"..." => return self.compileRange(sexp, dst, true),
            .case => return self.compileCase(sexp, dst),

            .yield => return self.compileYield(sexp, dst),
            .block => return self.compileBlock(sexp, dst),
            .lambda => return self.compileLambda(sexp, dst),

            .@"return" => return self.compileReturn(sexp, dst),

            // `next val` in a block returns `val` from the current
            // block iteration — the yielding native sees it as the
            // block's result and continues iterating.
            .next => return self.compileReturn(sexp, dst),

            // `break val` exits the enclosing iterator: the block
            // frame pops with `break_pending` set and the yielding
            // native observes it and returns `val` as its own result.
            .@"break" => return self.compileBreakStmt(sexp, dst),

            .begin => return self.compileBegin(sexp, dst),
            .@"super" => return self.compileSuper(sexp, dst),

            .scope => return self.compileScope(sexp, dst),

            .attrasgn => return self.compileAttrAsgn(sexp, dst),

            .@"**" => return self.compilePow(sexp, dst),

            // Index read: a[i] / h[k] → send :[]
            .index => return self.compileIndex(sexp, dst),

            // Phase 2: multiple assignment / defined? / rescue modifier.
            .masgn => return self.compileMasgn(sexp, dst),
            .defined => return self.compileDefined(sexp, dst),
            .rescue => return self.compileRescueModifier(sexp, dst),

            // Bitwise / shift / spaceship / ===: dispatched via SEND so
            // receiver's class controls semantics (Integer vs String etc).
            .@"&" => return self.compileSendBinOp(sexp, "&", dst),
            .@"|" => return self.compileSendBinOp(sexp, "|", dst),
            .@"^" => return self.compileSendBinOp(sexp, "^", dst),
            .@"<<" => return self.compileSendBinOp(sexp, "<<", dst),
            .@">>" => return self.compileSendBinOp(sexp, ">>", dst),
            .@"<=>" => return self.compileSendBinOp(sexp, "<=>", dst),
            .@"===" => return self.compileSendBinOp(sexp, "===", dst),
            .@"~" => return self.compileSendUnary(sexp, "~", dst),

            // Compound assignments: a OP= b → a = a OP b. Trivial-LHS
            // only (local, ivar, gvar, const); complex LHS deferred.
            // Arithmetic forms use the fast-path fixnum opcodes; the
            // rest dispatch via SEND so receiver class controls semantics.
            .@"+=" => return self.compileCompoundAssignOp(sexp, .ADD, dst),
            .@"-=" => return self.compileCompoundAssignOp(sexp, .SUB, dst),
            .@"*=" => return self.compileCompoundAssignOp(sexp, .MUL, dst),
            .@"/=" => return self.compileCompoundAssignOp(sexp, .DIV, dst),
            .@"%=" => return self.compileCompoundAssignOp(sexp, .MOD, dst),
            .@"**=" => return self.compileCompoundAssignSend(sexp, "**", dst),
            .@"&=" => return self.compileCompoundAssignSend(sexp, "&", dst),
            .@"|=" => return self.compileCompoundAssignSend(sexp, "|", dst),
            .@"^=" => return self.compileCompoundAssignSend(sexp, "^", dst),
            .@"<<=" => return self.compileCompoundAssignSend(sexp, "<<", dst),
            .@">>=" => return self.compileCompoundAssignSend(sexp, ">>", dst),
            .@"||=" => return self.compileLogicalAssign(sexp, .or_assign, dst),
            .@"&&=" => return self.compileLogicalAssign(sexp, .and_assign, dst),

            else => {
                self.err = .{ .message = "unsupported Sexp tag" };
                return dst;
            },
        }
    }

    // ── Binary operation helpers ─────────────────────────────────────

    fn compileBinOp(self: *Compiler, sexp: Sexp, opcode: Opcode, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.touchReg(dst + 2);
        self.emitA(opcode, dst);
        return dst;
    }

    fn compileNe(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.emitA(.EQ, dst);
        const jmp_pos = self.code_len;
        self.emitAS(.JMP_NOT, dst, 0);
        self.emitA(.LOAD_FALSE, dst);
        const skip_pos = self.code_len;
        self.emitS(.JMP, 0);
        const else_pos = self.code_len;
        self.emitA(.LOAD_TRUE, dst);
        const end_pos = self.code_len;
        self.patchJumpAS(jmp_pos, @intCast(@as(isize, else_pos) - @as(isize, jmp_pos)));
        self.patchJumpS(skip_pos, @intCast(@as(isize, end_pos) - @as(isize, skip_pos)));
        return dst;
    }

    fn compileOr(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_pos = self.code_len;
        self.emitAS(.JMP_IF, dst, 0);
        _ = self.compileExpr(sexp.child(1), dst);
        const end_pos = self.code_len;
        self.patchJumpAS(jmp_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_pos)));
        return dst;
    }

    fn compileAnd(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_pos = self.code_len;
        self.emitAS(.JMP_NOT, dst, 0);
        _ = self.compileExpr(sexp.child(1), dst);
        const end_pos = self.code_len;
        self.patchJumpAS(jmp_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_pos)));
        return dst;
    }

    fn compileNot(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_pos = self.code_len;
        self.emitAS(.JMP_NOT, dst, 0);
        self.emitA(.LOAD_FALSE, dst);
        const skip_pos = self.code_len;
        self.emitS(.JMP, 0);
        const else_pos = self.code_len;
        self.emitA(.LOAD_TRUE, dst);
        const end_pos = self.code_len;
        self.patchJumpAS(jmp_pos, @intCast(@as(isize, else_pos) - @as(isize, jmp_pos)));
        self.patchJumpS(skip_pos, @intCast(@as(isize, end_pos) - @as(isize, skip_pos)));
        return dst;
    }

    // ── Control flow ─────────────────────────────────────────────────

    fn compileIf(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_not_pos = self.code_len;
        self.emitAS(.JMP_NOT, dst, 0);

        const save_reg = self.next_reg;
        _ = self.compileExpr(sexp.child(1), dst);
        self.next_reg = save_reg;

        const else_child = sexp.child(2);
        if (!else_child.isNil()) {
            const jmp_end_pos = self.code_len;
            self.emitS(.JMP, 0);
            const else_start = self.code_len;
            self.patchJumpAS(jmp_not_pos, @intCast(@as(isize, else_start) - @as(isize, jmp_not_pos)));
            _ = self.compileExpr(else_child, dst);
            self.next_reg = save_reg;
            const end_pos = self.code_len;
            self.patchJumpS(jmp_end_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_end_pos)));
        } else {
            const end_pos = self.code_len;
            self.patchJumpAS(jmp_not_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_not_pos)));
        }
        return dst;
    }

    fn compileUnless(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_pos = self.code_len;
        self.emitAS(.JMP_IF, dst, 0);

        const save_reg = self.next_reg;
        _ = self.compileExpr(sexp.child(1), dst);
        self.next_reg = save_reg;

        const else_child = sexp.child(2);
        if (!else_child.isNil()) {
            const jmp_end_pos = self.code_len;
            self.emitS(.JMP, 0);
            const else_start = self.code_len;
            self.patchJumpAS(jmp_pos, @intCast(@as(isize, else_start) - @as(isize, jmp_pos)));
            _ = self.compileExpr(else_child, dst);
            self.next_reg = save_reg;
            const end_pos = self.code_len;
            self.patchJumpS(jmp_end_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_end_pos)));
        } else {
            const end_pos = self.code_len;
            self.patchJumpAS(jmp_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_pos)));
        }
        return dst;
    }

    fn compileWhile(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        self.emitA(.LOAD_NIL, dst);
        const loop_start = self.code_len;
        _ = self.compileExpr(sexp.child(0), dst + 1);
        const exit_jmp = self.code_len;
        self.emitAS(.JMP_NOT, dst + 1, 0);

        const save_reg = self.next_reg;
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.next_reg = save_reg;

        self.emitS(.JMP, @intCast(@as(isize, loop_start) - @as(isize, self.code_len)));
        const end_pos = self.code_len;
        self.patchJumpAS(exit_jmp, @intCast(@as(isize, end_pos) - @as(isize, exit_jmp)));
        return dst;
    }

    fn compileUntil(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        self.emitA(.LOAD_NIL, dst);
        const loop_start = self.code_len;
        _ = self.compileExpr(sexp.child(0), dst + 1);
        const exit_jmp = self.code_len;
        self.emitAS(.JMP_IF, dst + 1, 0);

        const save_reg = self.next_reg;
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.next_reg = save_reg;

        self.emitS(.JMP, @intCast(@as(isize, loop_start) - @as(isize, self.code_len)));
        const end_pos = self.code_len;
        self.patchJumpAS(exit_jmp, @intCast(@as(isize, end_pos) - @as(isize, exit_jmp)));
        return dst;
    }

    /// `for IDENT in expr; body; end` — desugared to `expr.each { … }`
    /// with the iteration variable bound in the ENCLOSING scope, not
    /// the block. Ruby semantics: after the loop, `IDENT` remains
    /// visible and holds the last yielded value. Block params would
    /// create a new local, so we allocate `IDENT` as an outer local
    /// and route the block's hidden param into it via SET_UPVAR on
    /// each entry.
    ///
    /// Return value: the collection (`.each` returns the receiver) on
    /// normal completion, or the `break val` value if broken. Both
    /// are naturally produced because the SEND_BLOCK result lands in
    /// `dst` — matching Ruby's `for` semantics via the existing
    /// iterator plumbing.
    ///
    /// `break`/`next`/`return` inside the body work because they go
    /// through the same block unwind machinery that already passes
    /// ~11 end-to-end tests for `.each`/`.times`/`.upto`.
    fn compileFor(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const var_sexp = sexp.child(0);
        const coll_sexp = sexp.child(1);
        const body_sexp = sexp.child(2);
        const var_name = var_sexp.getText(self.source);

        if (var_name.len == 0) {
            self.err = .{ .message = "for: missing iteration variable" };
            return dst;
        }

        // Register collision guard. If the iteration variable would
        // naturally land at the same slot as the statement's `dst`
        // (common at top-of-scope because ensureLocal uses
        // `local_count` while the caller used `allocReg` which only
        // touches `next_reg`), the SEND_BLOCK result would clobber
        // the iteration variable on exit — or, for back-to-back
        // `for` loops whose last expression matters (e.g., the tail
        // of a method body), we'd lose the collection return value.
        //
        // Reserve an anonymous slot at `local_count` so the iteration
        // variable lands one slot further along. Uses a zero-length
        // name that `findLocal` will only match against itself, and
        // allocates a FRESH slot on every collision — a single
        // shared name would be reused by subsequent for loops in
        // the same scope and silently fail to pad.
        if (self.findLocal(var_name) == null and self.local_count == dst) {
            self.allocAnonymousLocal();
        }

        // Declare the loop variable in the enclosing scope. Must happen
        // BEFORE the block is compiled so `findEnclosingLocal(var_name)`
        // resolves to an outer slot from the child compiler.
        const outer_slot = self.ensureLocal(var_name);

        // Compile the collection + block into temps *past* the loop
        // variable's slot. If we used `dst` as the .each receiver, the
        // SEND_BLOCK result would clobber the iteration variable when
        // `dst == outer_slot` (happens at top-level `for x in ...`,
        // where the caller's allocReg gave slot 0 and ensureLocal then
        // assigned slot 0 to `x`).
        const recv_reg = self.allocReg();
        const block_reg = self.allocReg();
        self.touchReg(block_reg + 1);

        _ = self.compileExpr(coll_sexp, recv_reg);

        const ci = self.child_count;
        if (ci >= MAX_CHILDREN) {
            self.err = .{ .message = "too many child functions" };
            return dst;
        }

        var child = Compiler.init(self.source);
        child.parent = self;
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        // Hidden param receives the yielded value. Its name uses a
        // character that can't appear in a Ruby identifier (`<`) so
        // user code can't accidentally reference or shadow it.
        const hidden_slot = child.ensureLocal("<for>");
        child.emitW(.ENTER, @as(u24, 1));

        // Write the hidden param into the outer-scope iteration var.
        // Subsequent references / assignments to `var_name` inside the
        // body go through findEnclosingLocal → GET_UPVAR / SET_UPVAR
        // because `var_name` is NOT a local in the block itself.
        child.emitABC(.SET_UPVAR, hidden_slot, 1, outer_slot);

        var result_reg: u8 = 0;
        if (!body_sexp.isNil()) {
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
        } else {
            result_reg = child.allocReg();
            child.emitA(.LOAD_NIL, result_reg);
        }
        if (child.err != null) {
            self.err = child.err;
            return dst;
        }
        child.emitA(.RETURN, result_reg);

        // Propagate sym table back to parent.
        self.next_sym_id = child.next_sym_id;
        self.sym_count = child.sym_count;
        @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
        @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

        @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
        for (0..child.const_len) |i| self.child_consts[ci][i] = child.consts[i];
        for (0..child.func_sym_len) |i| self.child_syms_buf[ci][i] = child.func_syms[i];
        for (0..child.string_lit_len) |i| self.child_str_lits[ci][i] = child.string_lits[i];
        for (0..child.float_lit_len) |i| self.child_float_lits[ci][i] = child.float_lits[i];

        // Grandchildren: any nested block inside the for-body.
        const grandchild_base = ci + 1;
        var gc: u8 = 0;
        while (gc < child.child_count and grandchild_base + gc < MAX_CHILDREN) : (gc += 1) {
            copyGrandchild(self, &child, grandchild_base + gc, gc, grandchild_base);
        }

        self.child_irfuncs[ci] = .{
            .bytecode = &self.child_code[ci],
            .bytecode_len = child.code_len,
            .nregs = if (child.max_reg > 0) child.max_reg else 1,
            .nlocals = child.local_count,
            .const_pool = self.child_consts[ci][0..child.const_len],
            .syms = self.child_syms_buf[ci][0..child.func_sym_len],
            .child_funcs = self.child_func_ptrs[grandchild_base .. grandchild_base + gc],
            .param_spec = @as(u24, 1),
            .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
            .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
        };
        self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
        self.child_count = grandchild_base + gc;

        self.emitAB(.BLOCK, block_reg, ci);

        // SEND_BLOCK recv=recv_reg, sym=:each, argc+1 = 1 (block only).
        const each_sym = self.internSym("each");
        const each_idx = self.addFuncSym(each_sym);
        self.emitABC(.SEND_BLOCK, recv_reg, each_idx, 1);

        // Deliver the expression result (collection on normal completion,
        // or the `break val` value). We leave `outer_slot` alone so the
        // iteration variable's final value survives — only copy when
        // `dst != outer_slot`. In the rare collision case (top-level
        // bare `for x ...` where `x`'s slot equals the statement's dst)
        // the variable wins over the expression value; any sane use of
        // the expression value (RHS of assignment, block body) has a
        // different dst and gets the collection.
        if (dst != outer_slot) {
            self.emitAB(.MOVE, dst, recv_reg);
        }
        self.freeReg(block_reg);
        self.freeReg(recv_reg);

        return dst;
    }

    // ── Method definitions ────────────────────────────────────────────

    fn compileDef(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const ci = self.child_count;
        if (ci >= MAX_CHILDREN) {
            self.err = .{ .message = "too many method definitions" };
            return dst;
        }

        const name = sexp.child(0).getText(self.source);
        const params_sexp = sexp.child(1); // (params "a" "b") or nil
        const body_sexp = sexp.child(2); // stmts or expression

        // Compile method body using a temporary sub-compiler
        var child = Compiler.init(self.source);
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        // Register params as locals (R[0], R[1], ...)
        var param_count: u8 = 0;
        if (!params_sexp.isNil() and params_sexp.isNode(.params)) {
            var i: usize = 0;
            while (i < params_sexp.childCount()) : (i += 1) {
                const pname = params_sexp.child(i).getText(child.source);
                if (pname.len > 0) {
                    _ = child.ensureLocal(pname);
                    param_count += 1;
                }
            }
        }

        child.emitW(.ENTER, @as(u24, param_count));

        // Compile body
        var result_reg: u8 = 0;
        if (!body_sexp.isNil()) {
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
        } else {
            result_reg = child.allocReg();
            child.emitA(.LOAD_NIL, result_reg);
        }
        if (child.err != null) {
            self.err = child.err;
            return dst;
        }
        child.emitA(.RETURN, result_reg);

        // Propagate symbol table back to parent
        self.next_sym_id = child.next_sym_id;
        self.sym_count = child.sym_count;
        @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
        @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

        // Copy child output to persistent parent storage
        @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
        for (0..child.const_len) |i| {
            self.child_consts[ci][i] = child.consts[i];
        }
        for (0..child.func_sym_len) |i| {
            self.child_syms_buf[ci][i] = child.func_syms[i];
        }
        for (0..child.string_lit_len) |i| {
            self.child_str_lits[ci][i] = child.string_lits[i];
        }
        for (0..child.float_lit_len) |i| {
            self.child_float_lits[ci][i] = child.float_lits[i];
        }

        // Propagate grandchildren (block IrFuncs compiled inside the
        // method body). Without this, a block emitted inside a method
        // body has nowhere to live in the parent's child-func storage
        // and the VM's BLOCK opcode hits ConstOutOfBounds. Relative
        // ordering is preserved so each grandchild's own `child_funcs`
        // slice can be rewritten to point into our storage at the
        // same relative offset.
        const grandchild_base = ci + 1;
        var gc: u8 = 0;
        while (gc < child.child_count and grandchild_base + gc < MAX_CHILDREN) : (gc += 1) {
            const gci = grandchild_base + gc;
            const src_ci = gc;
            copyGrandchild(self, &child, gci, src_ci, grandchild_base);
        }

        self.child_irfuncs[ci] = .{
            .bytecode = &self.child_code[ci],
            .bytecode_len = child.code_len,
            .nregs = if (child.max_reg > 0) child.max_reg else 1,
            .nlocals = child.local_count,
            .const_pool = self.child_consts[ci][0..child.const_len],
            .syms = self.child_syms_buf[ci][0..child.func_sym_len],
            .child_funcs = self.child_func_ptrs[grandchild_base .. grandchild_base + gc],
            .param_spec = @as(u24, param_count),
            .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
            .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
        };
        self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
        self.child_count = grandchild_base + gc;

        // Emit METHOD + DEF_METHOD in parent
        const sym_id = self.internSym(name);
        const sym_idx = self.addFuncSym(sym_id);
        self.emitAB(.METHOD, dst, ci);
        self.emitAB(.DEF_METHOD, sym_idx, dst);

        // def returns the symbol name in Ruby; emit nil for now
        self.emitA(.LOAD_NIL, dst);
        return dst;
    }

    /// Copy one grandchild IrFunc from `child_compiler.child_irfuncs[src_ci]`
    /// into `parent.child_irfuncs[gci]`, rewriting `.bytecode`, `.const_pool`,
    /// `.syms`, `.string_literals`, and **`.child_funcs`** to point into
    /// parent's persistent storage. The grandchild's own `child_funcs`
    /// slice is rebased by the same `grandchild_base` offset the
    /// caller is using, preserving relative IrFunc identity across
    /// arbitrary nesting depth.
    fn copyGrandchild(
        parent: *Compiler,
        child_compiler: *const Compiler,
        gci: u8,
        src_ci: u8,
        grandchild_base: u8,
    ) void {
        const src = child_compiler.child_irfuncs[src_ci];

        @memcpy(
            parent.child_code[gci][0..src.bytecode_len],
            child_compiler.child_code[src_ci][0..src.bytecode_len],
        );
        for (0..src.const_pool.len) |j| {
            parent.child_consts[gci][j] = child_compiler.child_consts[src_ci][j];
        }
        for (0..src.syms.len) |j| {
            parent.child_syms_buf[gci][j] = child_compiler.child_syms_buf[src_ci][j];
        }
        for (0..src.string_literals.len) |j| {
            parent.child_str_lits[gci][j] = child_compiler.child_str_lits[src_ci][j];
        }
        for (0..src.float_pool.len) |j| {
            parent.child_float_lits[gci][j] = child_compiler.child_float_lits[src_ci][j];
        }

        // Rebase child_funcs slice. If src had N child funcs starting
        // at offset `k` in child_compiler's storage, the rebased slice
        // lives at the same N positions in parent's storage, offset
        // by `grandchild_base`.
        var rebased: []const *const IrFunc = &.{};
        if (src.child_funcs.len > 0) {
            const src_base_addr = @intFromPtr(&child_compiler.child_func_ptrs[0]);
            const src_ptr_addr = @intFromPtr(src.child_funcs.ptr);
            const byte_offset = src_ptr_addr - src_base_addr;
            const k: usize = byte_offset / @sizeOf(*const IrFunc);
            rebased = parent.child_func_ptrs[grandchild_base + k .. grandchild_base + k + src.child_funcs.len];
        }

        parent.child_irfuncs[gci] = .{
            .bytecode = &parent.child_code[gci],
            .bytecode_len = src.bytecode_len,
            .nregs = src.nregs,
            .nlocals = src.nlocals,
            .const_pool = parent.child_consts[gci][0..src.const_pool.len],
            .syms = parent.child_syms_buf[gci][0..src.syms.len],
            .child_funcs = rebased,
            .param_spec = src.param_spec,
            .string_literals = parent.child_str_lits[gci][0..src.string_literals.len],
            .float_pool = parent.child_float_lits[gci][0..src.float_pool.len],
        };
        parent.child_func_ptrs[gci] = &parent.child_irfuncs[gci];
    }

    // ── Class definitions ─────────────────────────────────────────────

    fn compileClass(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const name = sexp.child(0).getText(self.source);
        const super_sexp = sexp.child(1); // superclass or nil
        const body_sexp = sexp.child(2); // stmts

        // Compile superclass (defaults to Object constant if nil)
        const super_reg = dst + 1;
        if (!super_sexp.isNil()) {
            _ = self.compileExpr(super_sexp, super_reg);
        } else {
            // Load Object class as default superclass via GET_CONST
            const obj_sym = self.internSym("Object");
            const obj_idx = self.addFuncSym(obj_sym);
            self.emitAB(.GET_CONST, super_reg, obj_idx);
        }
        self.touchReg(super_reg + 1);

        // DEF_CLASS R[dst], sym_name, R[super_reg]
        const name_sym = self.internSym(name);
        const name_idx = self.addFuncSym(name_sym);
        self.emitABC(.DEF_CLASS, dst, name_idx, super_reg);

        // Compile class body as child IrFunc, execute with EXEC_BODY
        if (!body_sexp.isNil()) {
            const ci = self.child_count;
            if (ci >= MAX_CHILDREN) {
                self.err = .{ .message = "too many child functions" };
                return dst;
            }

            var child = Compiler.init(self.source);
            child.next_sym_id = self.next_sym_id;
            child.sym_count = self.sym_count;
            @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
            @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

            // Compile class body statements
            var result_reg: u8 = 0;
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
            if (child.err != null) {
                self.err = child.err;
                return dst;
            }
            child.emitA(.RETURN, result_reg);

            // Propagate symbol table
            self.next_sym_id = child.next_sym_id;
            self.sym_count = child.sym_count;
            @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
            @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

            @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
            for (0..child.const_len) |i| {
                self.child_consts[ci][i] = child.consts[i];
            }
            for (0..child.func_sym_len) |i| {
                self.child_syms_buf[ci][i] = child.func_syms[i];
            }

            // Grandchild funcs (methods defined inside class body):
            // The class body compiler's child_irfuncs contain method bodies.
            // These need to be stored in the TOP-LEVEL compiler's child slots
            // so they survive. We place them as additional children of the
            // top-level compiler, and the class body IrFunc references them.
            const grandchild_base = self.child_count + 1; // +1 for the class body itself
            var gc: u8 = 0;
            while (gc < child.child_count and grandchild_base + gc < MAX_CHILDREN) : (gc += 1) {
                const gci = grandchild_base + gc;
                const src_ci = gc;
                @memcpy(self.child_code[gci][0..child.child_irfuncs[src_ci].bytecode_len],
                    child.child_code[src_ci][0..child.child_irfuncs[src_ci].bytecode_len]);
                for (0..child.child_irfuncs[src_ci].const_pool.len) |j| {
                    self.child_consts[gci][j] = child.child_consts[src_ci][j];
                }
                for (0..child.child_irfuncs[src_ci].syms.len) |j| {
                    self.child_syms_buf[gci][j] = child.child_syms_buf[src_ci][j];
                }
                for (0..child.child_irfuncs[src_ci].string_literals.len) |j| {
                    self.child_str_lits[gci][j] = child.child_str_lits[src_ci][j];
                }
                for (0..child.child_irfuncs[src_ci].float_pool.len) |j| {
                    self.child_float_lits[gci][j] = child.child_float_lits[src_ci][j];
                }
                self.child_irfuncs[gci] = .{
                    .bytecode = &self.child_code[gci],
                    .bytecode_len = child.child_irfuncs[src_ci].bytecode_len,
                    .nregs = child.child_irfuncs[src_ci].nregs,
                    .nlocals = child.child_irfuncs[src_ci].nlocals,
                    .const_pool = self.child_consts[gci][0..child.child_irfuncs[src_ci].const_pool.len],
                    .syms = self.child_syms_buf[gci][0..child.child_irfuncs[src_ci].syms.len],
                    .param_spec = child.child_irfuncs[src_ci].param_spec,
                    .string_literals = self.child_str_lits[gci][0..child.child_irfuncs[src_ci].string_literals.len],
                    .float_pool = self.child_float_lits[gci][0..child.child_irfuncs[src_ci].float_pool.len],
                };
                self.child_func_ptrs[gci] = &self.child_irfuncs[gci];
            }

            for (0..child.string_lit_len) |i| {
                self.child_str_lits[ci][i] = child.string_lits[i];
            }
            for (0..child.float_lit_len) |i| {
                self.child_float_lits[ci][i] = child.float_lits[i];
            }

            self.child_irfuncs[ci] = .{
                .bytecode = &self.child_code[ci],
                .bytecode_len = child.code_len,
                .nregs = if (child.max_reg > 0) child.max_reg else 1,
                .nlocals = child.local_count,
                .const_pool = self.child_consts[ci][0..child.const_len],
                .syms = self.child_syms_buf[ci][0..child.func_sym_len],
                .child_funcs = self.child_func_ptrs[grandchild_base..grandchild_base + gc],
                .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
                .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
            };
            self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
            self.child_count = grandchild_base + gc;

            self.emitAB(.EXEC_BODY, dst, ci);
        }

        return dst;
    }

    // ── Method calls ─────────────────────────────────────────────────

    fn compileSend(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const recv = sexp.child(0);
        const name = sexp.child(1).getText(self.source);
        const args_sexp = sexp.child(2); // (args ...) or nil
        const block_sexp = sexp.child(3); // (block (params …) body) or nil

        const has_block = !block_sexp.isNil() and block_sexp.isNode(.block);

        // Block case: compile receiver + args into their normal slots
        // (recv at dst, args at dst+1..dst+argc), THEN place the block
        // at dst+argc+1, THEN emit SEND_BLOCK. This ordering ensures the
        // receiver/args compile doesn't clobber the block register.
        if (has_block) {
            const recv_is_self = recv.isNil() or
                (recv.nodeTag() != null and recv.nodeTag().? == .nil);
            if (recv_is_self) {
                self.emitA(.LOAD_SELF, dst);
            } else {
                _ = self.compileExpr(recv, dst);
            }
            var argc: u8 = 0;
            if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
                var i: usize = 0;
                while (i < args_sexp.childCount()) : (i += 1) {
                    _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                    argc += 1;
                }
            }
            const block_reg = dst + 1 + argc;
            self.touchReg(block_reg + 1);
            _ = self.compileBlockInto(block_sexp, block_reg);

            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitABC(.SEND_BLOCK, dst, sym_idx, argc + 1);
            return dst;
        }

        if (recv.isNil() or (recv.nodeTag() != null and recv.nodeTag().? == .nil)) {
            // Top-level call (receiver is nil): SSEND
            var argc: u8 = 0;
            if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
                var i: usize = 0;
                while (i < args_sexp.childCount()) : (i += 1) {
                    _ = self.compileExpr(args_sexp.child(i), dst + argc);
                    argc += 1;
                }
            }
            self.touchReg(dst + argc);
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitABC(.SSEND, dst, sym_idx, argc);
            return dst;
        } else {
            // Method call on receiver: SEND
            _ = self.compileExpr(recv, dst);
            var argc: u8 = 0;
            if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
                var i: usize = 0;
                while (i < args_sexp.childCount()) : (i += 1) {
                    _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                    argc += 1;
                }
            }
            self.touchReg(dst + 1 + argc);
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitABC(.SEND, dst, sym_idx, argc);
            return dst;
        }
    }

    // ── Module definitions ────────────────────────────────────────────

    fn compileModule(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const name = sexp.child(0).getText(self.source);
        const body_sexp = sexp.child(1);

        const name_sym = self.internSym(name);
        const name_idx = self.addFuncSym(name_sym);
        self.emitAB(.DEF_MODULE, dst, name_idx);

        if (!body_sexp.isNil()) {
            const ci = self.child_count;
            if (ci >= MAX_CHILDREN) {
                self.err = .{ .message = "too many child functions" };
                return dst;
            }
            self.compileClassBodyChild(body_sexp, ci, dst);
        }
        return dst;
    }

    // ── Array literals ────────────────────────────────────────────────

    fn compileArray(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const count = sexp.childCount();
        // ARRAY's B operand is a u8 and element slots live at
        // dst+0..dst+count-1 in a single register window. Bail early
        // with a compile error rather than wrap-around-@intCast'ing
        // into a silently wrong bytecode.
        if (count > 255 or @as(usize, dst) + count > 255) {
            self.err = .{ .message = "array literal too large for register window" };
            return dst;
        }
        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = self.compileExpr(sexp.child(i), dst + @as(u8, @intCast(i)));
        }
        self.touchReg(dst + @as(u8, @intCast(count)));
        self.emitAB(.ARRAY, dst, @intCast(count));
        return dst;
    }

    // ── Hash literals ─────────────────────────────────────────────────

    fn compileHash(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const pair_count = sexp.childCount();
        var slot: u8 = 0;
        var i: usize = 0;
        while (i < pair_count) : (i += 1) {
            const pair = sexp.child(i);
            if (pair.isNode(.pair)) {
                _ = self.compileExpr(pair.child(0), dst + slot);
                slot += 1;
                _ = self.compileExpr(pair.child(1), dst + slot);
                slot += 1;
            }
        }
        self.touchReg(dst + slot);
        self.emitAB(.HASH, dst, @intCast(pair_count));
        return dst;
    }

    // ── String interpolation ──────────────────────────────────────────

    fn compileDstr(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // Interpolated strings compile to: STRING dst, "" ; [STRCAT dst, <part>]*
        //
        // Always seed dst with an empty string so STRCAT's LHS is a real
        // string even when the first part is an `#{...}` evstr that
        // evaluates to a non-string (fixnum, nil, …). The previous form
        // let the first interp land in dst as a bare fixnum and STRCAT
        // silently dropped it.
        const empty_idx = self.addStringLit("");
        self.emitAB(.STRING, dst, empty_idx);

        const count = sexp.childCount();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ch = sexp.child(i);
            if (ch.isNode(.evstr)) {
                _ = self.compileExpr(ch.child(0), dst + 1);
            } else {
                const text = ch.getText(self.source);
                const lit_idx = self.addStringLit(text);
                self.emitAB(.STRING, dst + 1, lit_idx);
            }
            self.touchReg(dst + 2);
            self.emitA(.STRCAT, dst);
        }
        return dst;
    }

    // ── Range literals ────────────────────────────────────────────────

    fn compileRange(self: *Compiler, sexp: Sexp, dst: u8, exclusive: bool) u8 {
        _ = self.compileExpr(sexp.child(0), dst + 1);
        _ = self.compileExpr(sexp.child(1), dst + 2);
        self.touchReg(dst + 3);
        // Exclusive flag in high bit of A: bit 7 = exclusive, bits 6:0 = dst
        const a: u8 = dst | (if (exclusive) @as(u8, 0x80) else 0);
        self.emitABC(.RANGE, a, dst + 1, dst + 2);
        return dst;
    }

    // ── Case/when compilation ─────────────────────────────────────────

    fn compileCase(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const subject = sexp.child(0);
        const has_subject = !subject.isNil();
        const subject_reg = dst + 1;

        if (has_subject) {
            _ = self.compileExpr(subject, subject_reg);
            self.touchReg(subject_reg + 1);
        }

        // Collect when clauses and optional else
        var when_jumps: [16]u16 = undefined;
        var when_count: u8 = 0;
        const count = sexp.childCount();
        var ci: usize = 1;

        while (ci < count) : (ci += 1) {
            const clause = sexp.child(ci);
            if (clause.isNode(.when)) {
                const cond = clause.child(0);
                const body = clause.child(1);

                if (has_subject) {
                    // Compare subject == when value
                    _ = self.compileExpr(cond, dst + 2);
                    self.touchReg(dst + 3);
                    self.emitAB(.MOVE, dst, subject_reg);
                    self.emitAB(.MOVE, dst + 1, dst + 2);
                    self.emitA(.EQ, dst);
                } else {
                    _ = self.compileExpr(cond, dst);
                }

                const skip_jmp = self.code_len;
                self.emitAS(.JMP_NOT, dst, 0);

                const save_reg = self.next_reg;
                _ = self.compileExpr(body, dst);
                self.next_reg = save_reg;

                if (when_count < 16) {
                    when_jumps[when_count] = self.code_len;
                    when_count += 1;
                }
                self.emitS(.JMP, 0);

                const after_body = self.code_len;
                self.patchJumpAS(skip_jmp, @intCast(@as(isize, after_body) - @as(isize, skip_jmp)));
            } else {
                // else clause
                const save_reg = self.next_reg;
                _ = self.compileExpr(clause, dst);
                self.next_reg = save_reg;
            }
        }

        // Patch all when end-jumps to here
        const end_pos = self.code_len;
        var ji: u8 = 0;
        while (ji < when_count) : (ji += 1) {
            self.patchJumpS(when_jumps[ji], @intCast(@as(isize, end_pos) - @as(isize, when_jumps[ji])));
        }

        return dst;
    }

    // ── Yield ─────────────────────────────────────────────────────────

    fn compileYield(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const args_sexp = sexp.child(0);
        var argc: u8 = 0;
        if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
            var i: usize = 0;
            while (i < args_sexp.childCount()) : (i += 1) {
                _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                argc += 1;
            }
        }
        self.touchReg(dst + 1 + argc);
        self.emitAB(.YIELD, dst, argc);
        return dst;
    }

    // ── Block compilation ─────────────────────────────────────────────

    /// Compile a `(block (params …) body)` Sexp as a child function and
    /// emit a `BLOCK` opcode placing the registered block Value into
    /// `target_reg`. The block is NOT invoked here — used by compileSend
    /// when a block is attached to the send node.
    ///
    /// Nested blocks (block inside block inside method body) are now
    /// supported via grandchild-IrFunc propagation — the block's child
    /// functions (any inner blocks it captures) get hoisted into the
    /// parent's child-func storage alongside the block itself.
    fn compileBlockInto(self: *Compiler, block_sexp: Sexp, target_reg: u8) u8 {
        const params_sexp = block_sexp.child(0);
        const body_sexp = block_sexp.child(1);

        const ci = self.child_count;
        if (ci >= MAX_CHILDREN) {
            self.err = .{ .message = "too many child functions" };
            return target_reg;
        }

        var child = Compiler.init(self.source);
        child.parent = self;
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        var param_count: u8 = 0;
        if (!params_sexp.isNil() and params_sexp.isNode(.params)) {
            var i: usize = 0;
            while (i < params_sexp.childCount()) : (i += 1) {
                const pname = params_sexp.child(i).getText(child.source);
                if (pname.len > 0) {
                    _ = child.ensureLocal(pname);
                    param_count += 1;
                }
            }
        }

        if (param_count > 0) child.emitW(.ENTER, @as(u24, param_count));

        var result_reg: u8 = 0;
        if (!body_sexp.isNil()) {
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
        } else {
            result_reg = child.allocReg();
            child.emitA(.LOAD_NIL, result_reg);
        }
        if (child.err != null) {
            self.err = child.err;
            return target_reg;
        }
        child.emitA(.RETURN, result_reg);

        // Propagate sym table back to parent.
        self.next_sym_id = child.next_sym_id;
        self.sym_count = child.sym_count;
        @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
        @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

        // Copy child output into parent's slot `ci`.
        @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
        for (0..child.const_len) |i| self.child_consts[ci][i] = child.consts[i];
        for (0..child.func_sym_len) |i| self.child_syms_buf[ci][i] = child.func_syms[i];
        for (0..child.string_lit_len) |i| self.child_str_lits[ci][i] = child.string_lits[i];
        for (0..child.float_lit_len) |i| self.child_float_lits[ci][i] = child.float_lits[i];

        // Propagate grandchildren (inner blocks compiled inside this
        // block's body) into the parent's child-func storage, then wire
        // them into this block's `child_funcs` slice.
        const grandchild_base = ci + 1;
        var gc: u8 = 0;
        while (gc < child.child_count and grandchild_base + gc < MAX_CHILDREN) : (gc += 1) {
            copyGrandchild(self, &child, grandchild_base + gc, gc, grandchild_base);
        }

        self.child_irfuncs[ci] = .{
            .bytecode = &self.child_code[ci],
            .bytecode_len = child.code_len,
            .nregs = if (child.max_reg > 0) child.max_reg else 1,
            .nlocals = child.local_count,
            .const_pool = self.child_consts[ci][0..child.const_len],
            .syms = self.child_syms_buf[ci][0..child.func_sym_len],
            .child_funcs = self.child_func_ptrs[grandchild_base .. grandchild_base + gc],
            .param_spec = @as(u24, param_count),
            .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
            .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
        };
        self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
        self.child_count = grandchild_base + gc;

        self.emitAB(.BLOCK, target_reg, ci);
        return target_reg;
    }

    fn compileBlock(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // (block (send recv name args) (params ...) body)
        const send_sexp = sexp.child(0);
        const params_sexp = sexp.child(1);
        const body_sexp = sexp.child(2);

        // Compile the block body as a child function
        const ci = self.child_count;
        if (ci >= MAX_CHILDREN) {
            self.err = .{ .message = "too many child functions" };
            return dst;
        }

        var child = Compiler.init(self.source);
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        var param_count: u8 = 0;
        if (!params_sexp.isNil() and params_sexp.isNode(.params)) {
            var i: usize = 0;
            while (i < params_sexp.childCount()) : (i += 1) {
                const pname = params_sexp.child(i).getText(child.source);
                if (pname.len > 0) {
                    _ = child.ensureLocal(pname);
                    param_count += 1;
                }
            }
        }

        if (param_count > 0) child.emitW(.ENTER, @as(u24, param_count));

        var result_reg: u8 = 0;
        if (!body_sexp.isNil()) {
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
        } else {
            result_reg = child.allocReg();
            child.emitA(.LOAD_NIL, result_reg);
        }
        if (child.err != null) { self.err = child.err; return dst; }
        child.emitA(.RETURN, result_reg);

        self.propagateChildCompilerWithSpec(&child, ci, @as(u24, param_count));

        // Emit BLOCK to capture the block body
        const block_reg = dst + 1;
        self.touchReg(block_reg + 1);
        self.emitAB(.BLOCK, block_reg, ci);

        // Now compile the send with the block
        if (!send_sexp.isNil() and send_sexp.isNode(.send)) {
            return self.compileSendWithBlock(send_sexp, dst, block_reg);
        }

        // If no send, just return the block value
        if (block_reg != dst) self.emitAB(.MOVE, dst, block_reg);
        return dst;
    }

    fn compileSendWithBlock(self: *Compiler, sexp: Sexp, dst: u8, block_reg: u8) u8 {
        const recv = sexp.child(0);
        const name = sexp.child(1).getText(self.source);
        const args_sexp = sexp.child(2);

        if (recv.isNil() or (recv.nodeTag() != null and recv.nodeTag().? == .nil)) {
            // SSEND doesn't support blocks in our opcode set, so use SEND with self
            var argc: u8 = 0;
            if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
                var i: usize = 0;
                while (i < args_sexp.childCount()) : (i += 1) {
                    _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                    argc += 1;
                }
            }
            // Place block after args
            self.emitAB(.MOVE, dst + 1 + argc, block_reg);
            self.touchReg(dst + 2 + argc);
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitA(.LOAD_SELF, dst);
            self.emitABC(.SEND_BLOCK, dst, sym_idx, argc + 1);
            return dst;
        } else {
            _ = self.compileExpr(recv, dst);
            var argc: u8 = 0;
            if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
                var i: usize = 0;
                while (i < args_sexp.childCount()) : (i += 1) {
                    _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                    argc += 1;
                }
            }
            self.emitAB(.MOVE, dst + 1 + argc, block_reg);
            self.touchReg(dst + 2 + argc);
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitABC(.SEND_BLOCK, dst, sym_idx, argc + 1);
            return dst;
        }
    }

    // ── Lambda compilation ────────────────────────────────────────────

    fn compileLambda(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const params_sexp = sexp.child(0);
        const body_sexp = sexp.child(1);

        const ci = self.child_count;
        if (ci >= MAX_CHILDREN) {
            self.err = .{ .message = "too many child functions" };
            return dst;
        }

        var child = Compiler.init(self.source);
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        var param_count: u8 = 0;
        if (!params_sexp.isNil() and params_sexp.isNode(.params)) {
            var i: usize = 0;
            while (i < params_sexp.childCount()) : (i += 1) {
                const pname = params_sexp.child(i).getText(child.source);
                if (pname.len > 0) {
                    _ = child.ensureLocal(pname);
                    param_count += 1;
                }
            }
        }

        if (param_count > 0) child.emitW(.ENTER, @as(u24, param_count));

        var result_reg: u8 = 0;
        if (!body_sexp.isNil()) {
            if (body_sexp.isNode(.stmts)) {
                result_reg = child.compileBody(body_sexp);
            } else {
                result_reg = child.compileExpr(body_sexp, child.allocReg());
            }
        } else {
            result_reg = child.allocReg();
            child.emitA(.LOAD_NIL, result_reg);
        }
        if (child.err != null) { self.err = child.err; return dst; }
        child.emitA(.RETURN, result_reg);

        self.propagateChildCompilerWithSpec(&child, ci, @as(u24, param_count));

        self.emitAB(.LAMBDA, dst, ci);
        return dst;
    }

    // ── Return ────────────────────────────────────────────────────────

    /// Given a `(return ...)` / `(break ...)` / `(next ...)` node,
    /// extract the first meaningful value. Grammar wraps flow-stmt
    /// args in an `(args val1 val2 …)` node; we only use the first
    /// arg (multi-value return/break isn't supported yet). Returns
    /// `Sexp.nil` if no value was given.
    fn flowStmtFirstValue(sexp: Sexp) Sexp {
        const c0 = sexp.child(0);
        if (c0.isNil()) return c0;
        if (c0.isNode(.args)) {
            if (c0.childCount() == 0) return .{ .nil = {} };
            return c0.child(0);
        }
        return c0;
    }

    fn compileReturn(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const val = flowStmtFirstValue(sexp);
        if (!val.isNil()) {
            _ = self.compileExpr(val, dst);
        } else {
            self.emitA(.LOAD_NIL, dst);
        }
        self.emitA(.RETURN, dst);
        return dst;
    }

    fn compileBreakStmt(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const val = flowStmtFirstValue(sexp);
        if (!val.isNil()) {
            _ = self.compileExpr(val, dst);
        } else {
            self.emitA(.LOAD_NIL, dst);
        }
        self.emitA(.BREAK, dst);
        return dst;
    }

    // ── Begin/rescue/ensure ───────────────────────────────────────────

    fn compileBegin(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // (begin body (rescue ...) (ensure ...))
        const body = sexp.child(0);
        const rescue_node = sexp.child(1);
        const ensure_node = sexp.child(2);

        const has_rescue = !rescue_node.isNil() and rescue_node.isNode(.rescue);
        const has_ensure = !ensure_node.isNil() and ensure_node.isNode(.ensure);

        if (!has_rescue and !has_ensure) {
            // Plain begin/end with no rescue/ensure
            if (!body.isNil()) {
                if (body.isNode(.stmts)) {
                    const r = self.compileBody(body);
                    if (r != dst) self.emitAB(.MOVE, dst, r);
                } else {
                    _ = self.compileExpr(body, dst);
                }
            }
            return dst;
        }

        // PUSH_HANDLER dst, offset_to_rescue
        var handler_pos: u16 = 0;
        if (has_rescue) {
            handler_pos = self.code_len;
            self.emitAS(.PUSH_HANDLER, dst, 0); // patch later
        }

        // Compile body
        if (!body.isNil()) {
            if (body.isNode(.stmts)) {
                const r = self.compileBody(body);
                if (r != dst) self.emitAB(.MOVE, dst, r);
            } else {
                _ = self.compileExpr(body, dst);
            }
        }

        if (has_rescue) {
            // Normal path: pop handler, jump to ensure/end
            self.emitZ(.POP_HANDLER);
        }

        const jmp_to_ensure = self.code_len;
        if (has_rescue) {
            self.emitS(.JMP, 0); // patch later
        }

        // Rescue target
        if (has_rescue) {
            const rescue_start = self.code_len;
            self.patchJumpAS(handler_pos, @intCast(@as(isize, rescue_start) - @as(isize, handler_pos)));

            // Exception is in dst (set by the handler-unwind machinery).
            // (rescue exception_class bind_var stmts): child(1) is the
            // bind variable name (or nil); child(2) is the body.
            const bind_node = rescue_node.child(1);
            if (!bind_node.isNil()) {
                const name = bind_node.getText(self.source);
                if (name.len > 0) {
                    const slot = self.ensureLocal(name);
                    if (slot != dst) self.emitAB(.MOVE, slot, dst);
                }
            }

            const rescue_body = rescue_node.child(2);
            if (!rescue_body.isNil()) {
                const save_reg = self.next_reg;
                if (rescue_body.isNode(.stmts)) {
                    const r = self.compileBody(rescue_body);
                    if (r != dst) self.emitAB(.MOVE, dst, r);
                } else {
                    _ = self.compileExpr(rescue_body, dst);
                }
                self.next_reg = save_reg;
            }

            self.emitZ(.CLEAR_EXC);
        }

        // Patch jump-to-ensure/end
        if (has_rescue) {
            const ensure_start = self.code_len;
            self.patchJumpS(jmp_to_ensure, @intCast(@as(isize, ensure_start) - @as(isize, jmp_to_ensure)));
        }

        // Ensure block (runs on both paths)
        if (has_ensure) {
            const ensure_body = ensure_node.child(0);
            if (!ensure_body.isNil()) {
                const save_reg = self.next_reg;
                if (ensure_body.isNode(.stmts)) {
                    _ = self.compileBody(ensure_body);
                } else {
                    _ = self.compileExpr(ensure_body, self.allocReg());
                }
                self.next_reg = save_reg;
            }
        }

        return dst;
    }

    // ── Super ─────────────────────────────────────────────────────────

    fn compileSuper(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const args_sexp = sexp.child(0);
        var argc: u8 = 0;
        if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
            var i: usize = 0;
            while (i < args_sexp.childCount()) : (i += 1) {
                _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                argc += 1;
            }
        }
        self.touchReg(dst + 1 + argc);
        self.emitAB(.SUPER, dst, argc);
        return dst;
    }

    // ── Scope (constant path) ─────────────────────────────────────────

    fn compileScope(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // (scope "Foo" "Bar") → GET_CONST for now (simplified)
        const name = sexp.child(1).getText(self.source);
        if (name.len > 0) {
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.GET_CONST, dst, sym_idx);
        } else {
            self.emitA(.LOAD_NIL, dst);
        }
        return dst;
    }

    // ── Attribute assignment ──────────────────────────────────────────

    fn compileAttrAsgn(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // (attrasgn recv "name=" (args val))
        const recv = sexp.child(0);
        const name = sexp.child(1).getText(self.source);
        const args_sexp = sexp.child(2);

        _ = self.compileExpr(recv, dst);
        var argc: u8 = 0;
        if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
            var i: usize = 0;
            while (i < args_sexp.childCount()) : (i += 1) {
                _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                argc += 1;
            }
        }
        self.touchReg(dst + 1 + argc);
        const sym_id = self.internSym(name);
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, argc);
        return dst;
    }

    // ── Power operator ────────────────────────────────────────────────

    fn compilePow(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // Compile as method call: a.send(:**, b)
        _ = self.compileExpr(sexp.child(0), dst);
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.touchReg(dst + 2);
        const sym_id = self.internSym("**");
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, 1);
        return dst;
    }

    // ── Index read: a[i] → a.send(:[], i) ────────────────────────────

    fn compileIndex(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const recv = sexp.child(0);
        const args_sexp = sexp.child(1);
        _ = self.compileExpr(recv, dst);
        var argc: u8 = 0;
        if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
            var i: usize = 0;
            while (i < args_sexp.childCount()) : (i += 1) {
                _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                argc += 1;
            }
        }
        self.touchReg(dst + 1 + argc);
        const sym_id = self.internSym("[]");
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, argc);
        return dst;
    }

    // ── Send-dispatched binary / unary operators ─────────────────────

    fn compileSendBinOp(self: *Compiler, sexp: Sexp, comptime method: []const u8, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        _ = self.compileExpr(sexp.child(1), dst + 1);
        self.touchReg(dst + 2);
        const sym_id = self.internSym(method);
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, 1);
        return dst;
    }

    fn compileSendUnary(self: *Compiler, sexp: Sexp, comptime method: []const u8, dst: u8) u8 {
        _ = self.compileExpr(sexp.child(0), dst);
        self.touchReg(dst + 1);
        const sym_id = self.internSym(method);
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, 0);
        return dst;
    }

    // ── Safe-nav method call: a&.m → (a.nil? ? nil : a.m) ─────────────

    fn compileCsend(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // Evaluate receiver into dst; if nil, skip to end leaving nil there.
        _ = self.compileExpr(sexp.child(0), dst);
        const jmp_nil_pos = self.code_len;
        self.emitAS(.JMP_NIL, dst, 0);

        // Non-nil path: do the call exactly like compileSend for a .send form.
        const name = sexp.child(1).getText(self.source);
        const args_sexp = sexp.child(2);
        var argc: u8 = 0;
        if (!args_sexp.isNil() and args_sexp.isNode(.args)) {
            var i: usize = 0;
            while (i < args_sexp.childCount()) : (i += 1) {
                _ = self.compileExpr(args_sexp.child(i), dst + 1 + argc);
                argc += 1;
            }
        }
        self.touchReg(dst + 1 + argc);
        const sym_id = self.internSym(name);
        const sym_idx = self.addFuncSym(sym_id);
        self.emitABC(.SEND, dst, sym_idx, argc);

        const end_pos = self.code_len;
        self.patchJumpAS(jmp_nil_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_nil_pos)));
        return dst;
    }

    // ── Compound assignments: a OP= b ─────────────────────────────────
    //
    // Restricted to trivial LHS in Phase 1: local, ivar, gvar, const.
    // The LHS is evaluated once by re-compiling its reference (pure,
    // side-effect-free for these forms). Full LHS generality (method
    // receivers, `arr[i] OP= v`) is deferred.

    /// Arithmetic compound assign using the fast-path fixnum opcode
    /// (ADD / SUB / MUL / DIV / MOD).
    fn compileCompoundAssignOp(self: *Compiler, sexp: Sexp, opcode: Opcode, dst: u8) u8 {
        const lhs = sexp.child(0);
        const rhs = sexp.child(1);
        _ = self.compileExpr(lhs, dst);
        _ = self.compileExpr(rhs, dst + 1);
        self.touchReg(dst + 2);
        self.emitA(opcode, dst);
        self.emitStoreByName(lhs, dst);
        return dst;
    }

    /// Non-arithmetic compound assign using `SEND :method`.
    fn compileCompoundAssignSend(self: *Compiler, sexp: Sexp, comptime method: []const u8, dst: u8) u8 {
        const lhs = sexp.child(0);
        const rhs = sexp.child(1);
        _ = self.compileExpr(lhs, dst);
        _ = self.compileExpr(rhs, dst + 1);
        self.touchReg(dst + 2);
        const op_sym = self.internSym(method);
        const op_idx = self.addFuncSym(op_sym);
        self.emitABC(.SEND, dst, op_idx, 1);
        self.emitStoreByName(lhs, dst);
        return dst;
    }

    const LogicalAssignKind = enum { or_assign, and_assign };

    fn compileLogicalAssign(self: *Compiler, sexp: Sexp, kind: LogicalAssignKind, dst: u8) u8 {
        const lhs = sexp.child(0);
        const rhs = sexp.child(1);

        // Load LHS. For ||=, short-circuit when truthy; for &&=, when falsy.
        _ = self.compileExpr(lhs, dst);
        const jmp_pos = self.code_len;
        switch (kind) {
            .or_assign => self.emitAS(.JMP_IF, dst, 0),
            .and_assign => self.emitAS(.JMP_NOT, dst, 0),
        }

        // Otherwise: evaluate RHS into dst and store back into LHS.
        _ = self.compileExpr(rhs, dst);
        self.emitStoreByName(lhs, dst);

        const end_pos = self.code_len;
        self.patchJumpAS(jmp_pos, @intCast(@as(isize, end_pos) - @as(isize, jmp_pos)));
        return dst;
    }

    // ── Multiple assignment: (masgn (mlhs a b …) (mrhs 1 2 …)) ────────

    fn compileMasgn(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const lhs_node = sexp.child(0); // (mlhs a b …)
        const rhs_node = sexp.child(1); // (mrhs 1 2 …)
        if (!lhs_node.isNode(.mlhs) or !rhs_node.isNode(.mrhs)) {
            self.err = .{ .message = "masgn: malformed mlhs/mrhs" };
            return dst;
        }

        const lhs_n = lhs_node.childCount();
        const rhs_n = rhs_node.childCount();

        // Evaluate all RHS expressions left-to-right into a contiguous
        // bank of registers starting at dst. Doing this *before* any
        // store preserves Ruby's semantics for `a, b = b, a`.
        var i: usize = 0;
        while (i < rhs_n) : (i += 1) {
            _ = self.compileExpr(rhs_node.child(i), dst + @as(u8, @intCast(i)));
        }
        self.touchReg(dst + @as(u8, @intCast(rhs_n)));

        // Store into each LHS. LHS[i] takes RHS[i]; missing RHS → nil.
        var li: usize = 0;
        while (li < lhs_n) : (li += 1) {
            const slot = dst + @as(u8, @intCast(li));
            if (li >= rhs_n) self.emitA(.LOAD_NIL, slot);
            self.emitStoreByName(lhs_node.child(li), slot);
        }

        // Return value of a multiple assignment is conventionally the RHS
        // as an array, but for Phase 2 we return the first RHS (or nil),
        // mirroring `a = b` on a single target.
        if (rhs_n == 0) self.emitA(.LOAD_NIL, dst);
        return dst;
    }

    // ── `defined?` (minimal, intentionally narrow) ────────────────────
    //
    // Returns the `"expression"` / `"local-variable"` / `"method"` string
    // depending on what we can see statically, or nil when the reference
    // clearly doesn't resolve. This is partial by design — real Ruby
    // `defined?` has grammar-level semantics (e.g., `defined?(foo.bar)`
    // should not evaluate `foo`). We only do enough to make the common
    // cases useful without running side effects.

    fn compileDefined(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        const target = sexp.child(0);

        // Identifier token: classify as local / method / ivar / gvar / const.
        if (target == .src) {
            const name = target.getText(self.source);
            const category: []const u8 = if (name.len == 0) "expression" else switch (name[0]) {
                '@' => "instance-variable",
                '$' => "global-variable",
                '0'...'9', '-', '+', '.' => "expression",
                'A'...'Z' => blk: {
                    // Constant — look in compile-time sym table; we cannot
                    // query runtime, so assume "constant" if name is pure
                    // CONSTANT identifier. (False positives possible.)
                    break :blk "constant";
                },
                else => if (self.findLocal(name) != null) "local-variable" else "method",
            };
            const lit = self.addStringLit(category);
            self.emitAB(.STRING, dst, lit);
            return dst;
        }

        // Everything else (sends, literals, arithmetic, etc.) — "expression".
        const lit = self.addStringLit("expression");
        self.emitAB(.STRING, dst, lit);
        return dst;
    }

    // ── Rescue modifier: `expr rescue fallback` ───────────────────────

    fn compileRescueModifier(self: *Compiler, sexp: Sexp, dst: u8) u8 {
        // Grammar emits `(rescue expr fallback)` for the modifier form
        // (2 children). The 3-child `(rescue exc bind body)` shape is
        // handled inside compileBegin. We discriminate by child count.
        if (sexp.childCount() != 2) {
            self.err = .{ .message = "rescue: modifier form expects 2 children" };
            return dst;
        }
        const body = sexp.child(0);
        const fallback = sexp.child(1);

        // Push handler pointing at the fallback code.
        const handler_pos = self.code_len;
        self.emitAS(.PUSH_HANDLER, dst, 0); // patched below

        _ = self.compileExpr(body, dst);
        self.emitZ(.POP_HANDLER);
        const jmp_end_pos = self.code_len;
        self.emitS(.JMP, 0); // patched below to skip fallback

        // Fallback block: exception already stashed in dst by handler.
        const fallback_start = self.code_len;
        self.patchJumpAS(handler_pos, @intCast(@as(isize, fallback_start) - @as(isize, handler_pos)));
        _ = self.compileExpr(fallback, dst);
        self.emitZ(.CLEAR_EXC);

        const end = self.code_len;
        self.patchJumpS(jmp_end_pos, @intCast(@as(isize, end) - @as(isize, jmp_end_pos)));
        return dst;
    }

    /// Store register `src` into the LHS referenced by `lhs_sexp`. Supports
    /// local, @ivar, $gvar, and uppercase constant targets. Non-trivial
    /// LHS (method-call receivers, indexing) falls back to a compile error.
    fn emitStoreByName(self: *Compiler, lhs_sexp: Sexp, src: u8) void {
        const name = lhs_sexp.getText(self.source);
        if (name.len == 0) {
            self.err = .{ .message = "compound assignment: empty LHS" };
            return;
        }
        if (name[0] == '@') {
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.SET_IVAR, src, sym_idx);
            return;
        }
        if (name[0] == '$') {
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.SET_GLOBAL, src, sym_idx);
            return;
        }
        if (name[0] >= 'A' and name[0] <= 'Z') {
            const sym_id = self.internSym(name);
            const sym_idx = self.addFuncSym(sym_id);
            self.emitAB(.SET_CONST, src, sym_idx);
            return;
        }
        // Local variable. In a block-child compiler, a name that's
        // already a local of an enclosing scope must write through
        // SET_UPVAR; otherwise `ensureLocal` would silently create a
        // shadowing block-local and compound ops (`s += x`) would
        // never update the outer variable. Mirrors the analogous
        // upvar route in `.assign`.
        if (self.parent != null and self.findLocal(name) == null) {
            if (self.findEnclosingLocal(name)) |up| {
                self.emitABC(.SET_UPVAR, src, up.level, up.slot);
                return;
            }
        }
        const slot = self.ensureLocal(name);
        if (slot != src) self.emitAB(.MOVE, slot, src);
    }

    // ── Child compiler propagation helper ─────────────────────────────

    fn propagateChildCompiler(self: *Compiler, child: *Compiler, ci: u8) void {
        self.propagateChildCompilerWithSpec(child, ci, 0);
    }

    fn propagateChildCompilerWithSpec(self: *Compiler, child: *Compiler, ci: u8, param_spec: u24) void {
        self.next_sym_id = child.next_sym_id;
        self.sym_count = child.sym_count;
        @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
        @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

        @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
        for (0..child.const_len) |i| {
            self.child_consts[ci][i] = child.consts[i];
        }
        for (0..child.func_sym_len) |i| {
            self.child_syms_buf[ci][i] = child.func_syms[i];
        }
        for (0..child.string_lit_len) |i| {
            self.child_str_lits[ci][i] = child.string_lits[i];
        }
        for (0..child.float_lit_len) |i| {
            self.child_float_lits[ci][i] = child.float_lits[i];
        }

        self.child_irfuncs[ci] = .{
            .bytecode = &self.child_code[ci],
            .bytecode_len = child.code_len,
            .nregs = if (child.max_reg > 0) child.max_reg else 1,
            .nlocals = child.local_count,
            .const_pool = self.child_consts[ci][0..child.const_len],
            .syms = self.child_syms_buf[ci][0..child.func_sym_len],
            .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
            .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
            .param_spec = param_spec,
        };
        self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
        self.child_count = ci + 1;
    }

    fn compileClassBodyChild(self: *Compiler, body_sexp: Sexp, ci: u8, dst: u8) void {
        var child = Compiler.init(self.source);
        child.next_sym_id = self.next_sym_id;
        child.sym_count = self.sym_count;
        @memcpy(child.sym_names[0..self.sym_count], self.sym_names[0..self.sym_count]);
        @memcpy(child.sym_ids[0..self.sym_count], self.sym_ids[0..self.sym_count]);

        var result_reg: u8 = 0;
        if (body_sexp.isNode(.stmts)) {
            result_reg = child.compileBody(body_sexp);
        } else {
            result_reg = child.compileExpr(body_sexp, child.allocReg());
        }
        if (child.err != null) { self.err = child.err; return; }
        child.emitA(.RETURN, result_reg);

        self.next_sym_id = child.next_sym_id;
        self.sym_count = child.sym_count;
        @memcpy(self.sym_names[0..child.sym_count], child.sym_names[0..child.sym_count]);
        @memcpy(self.sym_ids[0..child.sym_count], child.sym_ids[0..child.sym_count]);

        @memcpy(self.child_code[ci][0..child.code_len], child.code[0..child.code_len]);
        for (0..child.const_len) |i| {
            self.child_consts[ci][i] = child.consts[i];
        }
        for (0..child.func_sym_len) |i| {
            self.child_syms_buf[ci][i] = child.func_syms[i];
        }
        for (0..child.string_lit_len) |i| {
            self.child_str_lits[ci][i] = child.string_lits[i];
        }
        for (0..child.float_lit_len) |i| {
            self.child_float_lits[ci][i] = child.float_lits[i];
        }

        // Handle grandchild funcs (methods inside class/module body)
        const grandchild_base = ci + 1;
        var gc: u8 = 0;
        while (gc < child.child_count and grandchild_base + gc < MAX_CHILDREN) : (gc += 1) {
            const gci = grandchild_base + gc;
            const src_ci = gc;
            @memcpy(self.child_code[gci][0..child.child_irfuncs[src_ci].bytecode_len],
                child.child_code[src_ci][0..child.child_irfuncs[src_ci].bytecode_len]);
            for (0..child.child_irfuncs[src_ci].const_pool.len) |j| {
                self.child_consts[gci][j] = child.child_consts[src_ci][j];
            }
            for (0..child.child_irfuncs[src_ci].syms.len) |j| {
                self.child_syms_buf[gci][j] = child.child_syms_buf[src_ci][j];
            }
            for (0..child.child_irfuncs[src_ci].string_literals.len) |j| {
                self.child_str_lits[gci][j] = child.child_str_lits[src_ci][j];
            }
            for (0..child.child_irfuncs[src_ci].float_pool.len) |j| {
                self.child_float_lits[gci][j] = child.child_float_lits[src_ci][j];
            }
            self.child_irfuncs[gci] = .{
                .bytecode = &self.child_code[gci],
                .bytecode_len = child.child_irfuncs[src_ci].bytecode_len,
                .nregs = child.child_irfuncs[src_ci].nregs,
                .nlocals = child.child_irfuncs[src_ci].nlocals,
                .const_pool = self.child_consts[gci][0..child.child_irfuncs[src_ci].const_pool.len],
                .syms = self.child_syms_buf[gci][0..child.child_irfuncs[src_ci].syms.len],
                .param_spec = child.child_irfuncs[src_ci].param_spec,
                .string_literals = self.child_str_lits[gci][0..child.child_irfuncs[src_ci].string_literals.len],
                .float_pool = self.child_float_lits[gci][0..child.child_irfuncs[src_ci].float_pool.len],
            };
            self.child_func_ptrs[gci] = &self.child_irfuncs[gci];
        }

        self.child_irfuncs[ci] = .{
            .bytecode = &self.child_code[ci],
            .bytecode_len = child.code_len,
            .nregs = if (child.max_reg > 0) child.max_reg else 1,
            .nlocals = child.local_count,
            .const_pool = self.child_consts[ci][0..child.const_len],
            .syms = self.child_syms_buf[ci][0..child.func_sym_len],
            .child_funcs = self.child_func_ptrs[grandchild_base .. grandchild_base + gc],
            .string_literals = self.child_str_lits[ci][0..child.string_lit_len],
            .float_pool = self.child_float_lits[ci][0..child.float_lit_len],
        };
        self.child_func_ptrs[ci] = &self.child_irfuncs[ci];
        self.child_count = grandchild_base + gc;

        self.emitAB(.EXEC_BODY, dst, ci);
    }

    // ── Symbol management ────────────────────────────────────────────

    pub fn findSymByName(self: *const Compiler, name: []const u8) ?u16 {
        for (0..self.sym_count) |i| {
            if (std.mem.eql(u8, self.sym_names[i], name)) return self.sym_ids[i];
        }
        return null;
    }

    fn internSym(self: *Compiler, name: []const u8) u16 {
        // Check well-known atoms first (O(log n) binary search)
        if (atom_mod.lookupWellKnown(name)) |atom_id| {
            // Ensure it's in our local sym table too
            for (0..self.sym_count) |i| {
                if (self.sym_ids[i] == atom_id) return atom_id;
            }
            if (self.sym_count < self.sym_names.len) {
                self.sym_names[self.sym_count] = name;
                self.sym_ids[self.sym_count] = atom_id;
                self.sym_count += 1;
            }
            return atom_id;
        }

        // Dynamic atom: check if already interned
        for (0..self.sym_count) |i| {
            if (std.mem.eql(u8, self.sym_names[i], name)) return self.sym_ids[i];
        }
        // Assign next dynamic ID (starts after well-known atoms)
        if (self.next_sym_id < atom_mod.FIRST_DYNAMIC) {
            self.next_sym_id = atom_mod.FIRST_DYNAMIC;
        }
        const id = self.next_sym_id;
        self.sym_names[self.sym_count] = name;
        self.sym_ids[self.sym_count] = id;
        self.sym_count += 1;
        self.next_sym_id += 1;
        return id;
    }

    fn addFuncSym(self: *Compiler, sym_id: u16) u8 {
        for (self.func_syms[0..self.func_sym_len], 0..) |s, i| {
            if (s == sym_id) return @intCast(i);
        }
        const idx = self.func_sym_len;
        self.func_syms[idx] = sym_id;
        self.func_sym_len += 1;
        return idx;
    }

    // ── Local variables ──────────────────────────────────────────────

    fn findLocal(self: *Compiler, name: []const u8) ?u8 {
        for (self.locals[0..self.local_count], 0..) |local, i| {
            if (std.mem.eql(u8, local, name)) return @intCast(i);
        }
        return null;
    }

    fn ensureLocal(self: *Compiler, name: []const u8) u8 {
        if (self.findLocal(name)) |slot| return slot;
        const slot = self.local_count;
        self.locals[slot] = name;
        self.local_count += 1;
        if (slot >= self.next_reg) self.next_reg = slot + 1;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
        return slot;
    }

    /// Reserve the next register as a local slot with no findable
    /// name. Used for register-allocation padding (e.g., `compileFor`
    /// needs a slot that won't collide with the caller's `dst` but
    /// doesn't want a named local a user could accidentally reference
    /// or shadow). Saturates at the locals cap to avoid overflow.
    fn allocAnonymousLocal(self: *Compiler) void {
        if (self.local_count >= self.locals.len) return;
        self.locals[self.local_count] = "";
        self.local_count += 1;
        if (self.local_count > self.next_reg) self.next_reg = self.local_count;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    }

    fn allocReg(self: *Compiler) u8 {
        const r = self.next_reg;
        self.next_reg += 1;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
        return r;
    }

    /// Free a temporary register. Only valid if `r` is the most recently
    /// allocated temp (LIFO / stack discipline). Locals are never freed.
    fn freeReg(self: *Compiler, r: u8) void {
        if (r >= self.local_count and r + 1 == self.next_reg) {
            self.next_reg = r;
        }
    }

    /// Record that registers up to (but not including) `end` are touched,
    /// ensuring max_reg accounts for implicit operand slots like dst+1.
    fn touchReg(self: *Compiler, end: u8) void {
        if (end > self.max_reg) self.max_reg = end;
    }

    // ── String literal pool ───────────────────────────────────────────

    /// Compile a `%w[a b c]` (array-of-strings) or `%i[a b c]` (array
    /// of symbols) literal. Token text includes delimiters
    /// (`%w[`…`]` / `%w(`…`)` / …); this strips them, splits the body
    /// on ASCII whitespace, emits one STRING / LOAD_SYM per word into
    /// consecutive registers starting at `dst`, and follows with an
    /// ARRAY opcode. Empty and whitespace-only bodies produce an
    /// empty array. Escape handling (`\\ ` for embedded space) is
    /// out of scope for this phase — words are split greedily on
    /// any run of whitespace.
    fn compilePctArray(self: *Compiler, text: []const u8, dst: u8) u8 {
        if (text.len < 4) {
            self.emitAB(.ARRAY, dst, 0);
            return dst;
        }
        const is_sym = text[1] == 'i';
        // Strip the `%w[` / `%i<` / etc. opener and the single-char close.
        const body = text[3 .. text.len - 1];

        // Register-window ceiling: one slot per word starting at
        // `dst`. Anything that would push the last word past slot
        // 255 is a compile error — refuse rather than wrap around.
        const max_count: u32 = 255 - @as(u32, dst);
        var count: u8 = 0;
        var i: usize = 0;
        while (i < body.len) {
            while (i < body.len and isPctSpace(body[i])) : (i += 1) {}
            if (i >= body.len) break;
            const start = i;
            while (i < body.len and !isPctSpace(body[i])) : (i += 1) {}
            const word = body[start..i];
            if (word.len == 0) continue;

            if (@as(u32, count) >= max_count) {
                self.err = .{ .message = "%w/%i literal too large for register window" };
                return dst;
            }

            const slot = dst + count;
            if (is_sym) {
                const sym_id = self.internSym(word);
                self.emitAB(.LOAD_SYM, slot, self.addFuncSym(sym_id));
            } else {
                const lit_idx = self.addStringLit(word);
                self.emitAB(.STRING, slot, lit_idx);
            }
            count += 1;
        }
        self.touchReg(dst + count);
        self.emitAB(.ARRAY, dst, count);
        return dst;
    }

    fn addStringLit(self: *Compiler, text: []const u8) u8 {
        for (self.string_lits[0..self.string_lit_len], 0..) |s, i| {
            if (std.mem.eql(u8, s, text)) return @intCast(i);
        }
        const idx = self.string_lit_len;
        self.string_lits[idx] = text;
        self.string_lit_len += 1;
        return idx;
    }

    // ── Float literal pool ───────────────────────────────────────────

    fn addFloatLit(self: *Compiler, f: f64) u8 {
        const bits: u64 = @bitCast(f);
        for (self.float_lits[0..self.float_lit_len], 0..) |existing, i| {
            if (@as(u64, @bitCast(existing)) == bits) return @intCast(i);
        }
        const idx = self.float_lit_len;
        self.float_lits[idx] = f;
        self.float_lit_len += 1;
        return idx;
    }

    // ── Constant pool ────────────────────────────────────────────────

    fn addConst(self: *Compiler, val: Value) u8 {
        for (self.consts[0..self.const_len], 0..) |c, i| {
            if (c.eql(val)) return @intCast(i);
        }
        const idx = self.const_len;
        self.consts[idx] = val;
        self.const_len += 1;
        return idx;
    }

    // ── Bytecode emission ────────────────────────────────────────────

    fn emitZ(self: *Compiler, opcode: Opcode) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code_len += 1;
    }

    fn emitA(self: *Compiler, opcode: Opcode, a: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code_len += 2;
    }

    fn emitAB(self: *Compiler, opcode: Opcode, a: u8, b: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = b;
        self.code_len += 3;
    }

    fn emitABC(self: *Compiler, opcode: Opcode, a: u8, b: u8, c: u8) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = b;
        self.code[self.code_len + 3] = c;
        self.code_len += 4;
    }

    fn emitW(self: *Compiler, opcode: Opcode, w: u24) void {
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = @truncate(w >> 16);
        self.code[self.code_len + 2] = @truncate(w >> 8);
        self.code[self.code_len + 3] = @truncate(w);
        self.code_len += 4;
    }

    fn emitAS(self: *Compiler, opcode: Opcode, a: u8, s: i16) void {
        const u: u16 = @bitCast(s);
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = a;
        self.code[self.code_len + 2] = @truncate(u >> 8);
        self.code[self.code_len + 3] = @truncate(u);
        self.code_len += 4;
    }

    fn emitS(self: *Compiler, opcode: Opcode, s: i16) void {
        const u: u16 = @bitCast(s);
        self.code[self.code_len] = @intFromEnum(opcode);
        self.code[self.code_len + 1] = @truncate(u >> 8);
        self.code[self.code_len + 2] = @truncate(u);
        self.code_len += 3;
    }

    fn patchJumpAS(self: *Compiler, pos: u16, offset: i16) void {
        const u: u16 = @bitCast(offset);
        self.code[pos + 2] = @truncate(u >> 8);
        self.code[pos + 3] = @truncate(u);
    }

    fn patchJumpS(self: *Compiler, pos: u16, offset: i16) void {
        const u: u16 = @bitCast(offset);
        self.code[pos + 1] = @truncate(u >> 8);
        self.code[pos + 2] = @truncate(u);
    }

    fn build(self: *Compiler) IrFunc {
        return .{
            .bytecode = &self.code,
            .bytecode_len = self.code_len,
            .nregs = if (self.max_reg > 0) self.max_reg else 1,
            .nlocals = self.local_count,
            .const_pool = self.consts[0..self.const_len],
            .syms = self.func_syms[0..self.func_sym_len],
            .child_funcs = self.child_func_ptrs[0..self.child_count],
            .string_literals = self.string_lits[0..self.string_lit_len],
            .float_pool = self.float_lits[0..self.float_lit_len],
        };
    }
};

fn isPctSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn parseInteger(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var result: i64 = 0;
    var negative = false;
    var i: usize = 0;

    if (text[0] == '-') { negative = true; i = 1; }
    else if (text[0] == '+') { i = 1; }

    if (i >= text.len) return null;

    var has_digit = false;
    while (i < text.len) : (i += 1) {
        if (text[i] == '_') continue;
        if (text[i] < '0' or text[i] > '9') return null;
        has_digit = true;
        result = result * 10 + (text[i] - '0');
    }
    if (!has_digit) return null;
    return if (negative) -result else result;
}

/// Does the token look like a Ruby float literal (`3.14`, `1e9`, `1.0e-3`)?
/// Must start with a digit (or +/- followed by one) and contain either
/// `.` or an exponent marker. Same shape the lexer already requires.
fn looksLikeFloat(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '+' or text[0] == '-') i = 1;
    if (i >= text.len) return false;
    if (text[i] < '0' or text[i] > '9') return false;
    var seen_dot = false;
    var seen_exp = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '.' => seen_dot = true,
            'e', 'E' => seen_exp = true,
            else => {},
        }
    }
    return seen_dot or seen_exp;
}

/// Parse a Ruby-style float literal (with optional `_` separators)
/// into an f64. Returns null on malformed input.
fn parseFloatLit(text: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    if (text.len > buf.len) return null;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch null;
}

// ═════════════════════════════════════════════════════════════════════
// Tests — using Nexus Sexp format directly
// ═════════════════════════════════════════════════════════════════════

const class_mod = @import("../vm/class.zig");
const class_debug_mod = @import("../vm/class_debug.zig");

fn compileAndRun(source: []const u8, sexp: Sexp) ?Value {
    var compiler = Compiler.init(source);
    const func = compiler.compileProgram(sexp) orelse return null;
    var vm = VM.initDefault();
    const SymLookup = struct {
        var comp: *const Compiler = undefined;
        fn find(name: []const u8) ?u16 {
            return comp.findSymByName(name);
        }
    };
    SymLookup.comp = &compiler;
    class_debug_mod.installNatives(&vm, &SymLookup.find);
    vm.setSymNew(atom_mod.ATOM_NEW);
    vm.setSymInitialize(atom_mod.ATOM_INITIALIZE);
    const result = vm.execute(&func);
    return switch (result) {
        .ok => |v| v,
        .err => null,
    };
}

/// Test helper: build a Sexp list at comptime.
fn S(comptime tag: Tag, comptime children: anytype) Sexp {
    const items = comptime blk: {
        var arr: [children.len + 1]Sexp = undefined;
        arr[0] = .{ .tag = tag };
        for (children, 0..) |c, i| {
            arr[i + 1] = c;
        }
        break :blk arr;
    };
    return .{ .list = &items };
}

fn Tok(comptime text: []const u8) Sexp {
    return .{ .str = text };
}

fn TRUE() Sexp { return .{ .tag = .@"true" }; }
fn FALSE() Sexp { return .{ .tag = .@"false" }; }
fn NIL() Sexp { return .{ .tag = .nil }; }

test "compile integer literal (Nexus Sexp)" {
    const tree = S(.program, &.{Tok("42")});
    const result = compileAndRun("42", tree).?;
    try std.testing.expectEqual(@as(i32, 42), result.asFixnum().?);
}

test "compile true/false/nil (Nexus Sexp)" {
    try std.testing.expect(compileAndRun("true", S(.program, &.{TRUE()})).?.isTrue());
    try std.testing.expect(compileAndRun("false", S(.program, &.{FALSE()})).?.isFalse());
    try std.testing.expect(compileAndRun("nil", S(.program, &.{NIL()})).?.isNil());
}

test "compile addition (Nexus Sexp)" {
    const tree = S(.program, &.{S(.@"+", &.{ Tok("40"), Tok("2") })});
    try std.testing.expectEqual(@as(i32, 42), compileAndRun("", tree).?.asFixnum().?);
}

test "compile nested arithmetic (Nexus Sexp)" {
    const tree = S(.program, &.{
        S(.@"*", &.{
            S(.@"+", &.{ Tok("10"), Tok("20") }),
            Tok("2"),
        }),
    });
    try std.testing.expectEqual(@as(i32, 60), compileAndRun("", tree).?.asFixnum().?);
}

test "compile local variables (Nexus Sexp)" {
    const tree = S(.program, &.{
        S(.stmts, &.{
            S(.assign, &.{ Tok("a"), Tok("5") }),
            S(.assign, &.{ Tok("b"), Tok("3") }),
            S(.@"+", &.{ Tok("a"), Tok("b") }),
        }),
    });
    try std.testing.expectEqual(@as(i32, 8), compileAndRun("", tree).?.asFixnum().?);
}

test "compile if/else (Nexus Sexp)" {
    const tree = S(.program, &.{
        S(.@"if", &.{ TRUE(), Tok("1"), Tok("2") }),
    });
    try std.testing.expectEqual(@as(i32, 1), compileAndRun("", tree).?.asFixnum().?);

    const tree2 = S(.program, &.{
        S(.@"if", &.{ FALSE(), Tok("1"), Tok("2") }),
    });
    try std.testing.expectEqual(@as(i32, 2), compileAndRun("", tree2).?.asFixnum().?);
}

test "compile while loop (Nexus Sexp)" {
    const tree = S(.program, &.{
        S(.stmts, &.{
            S(.assign, &.{ Tok("i"), Tok("0") }),
            S(.@"while", &.{
                S(.@"<", &.{ Tok("i"), Tok("5") }),
                S(.assign, &.{ Tok("i"), S(.@"+", &.{ Tok("i"), Tok("1") }) }),
            }),
            Tok("i"),
        }),
    });
    try std.testing.expectEqual(@as(i32, 5), compileAndRun("", tree).?.asFixnum().?);
}

test "compile comparison (Nexus Sexp)" {
    const tree = S(.program, &.{S(.@"<", &.{ Tok("3"), Tok("5") })});
    try std.testing.expect(compileAndRun("", tree).?.isTrue());
}

test "compile or short-circuit (Nexus Sexp)" {
    const tree = S(.program, &.{S(.@"||", &.{ NIL(), Tok("42") })});
    try std.testing.expectEqual(@as(i32, 42), compileAndRun("", tree).?.asFixnum().?);
}

test "compile and short-circuit (Nexus Sexp)" {
    const tree = S(.program, &.{S(.@"&&", &.{ TRUE(), Tok("7") })});
    try std.testing.expectEqual(@as(i32, 7), compileAndRun("", tree).?.asFixnum().?);
}

test "compile negation (Nexus Sexp)" {
    const tree = S(.program, &.{S(.@"!", &.{TRUE()})});
    try std.testing.expect(compileAndRun("", tree).?.isFalse());
}

test "compile negative integer (Nexus Sexp)" {
    const tree = S(.program, &.{Tok("-5")});
    try std.testing.expectEqual(@as(i32, -5), compileAndRun("-5", tree).?.asFixnum().?);
}

test "compile unless (Nexus Sexp)" {
    const tree = S(.program, &.{S(.unless, &.{ FALSE(), Tok("3") })});
    try std.testing.expectEqual(@as(i32, 3), compileAndRun("", tree).?.asFixnum().?);
}

test "compile def + call (Nexus Sexp)" {
    // def add(a, b); a + b; end; add(20, 22)
    const tree = S(.program, &.{
        S(.stmts, &.{
            S(.def, &.{
                Tok("add"),
                S(.params, &.{ Tok("a"), Tok("b") }),
                S(.stmts, &.{S(.@"+", &.{ Tok("a"), Tok("b") })}),
                NIL(), // rescues
                NIL(), // ensure
            }),
            S(.send, &.{
                NIL(), // receiver (nil = implicit self)
                Tok("add"),
                S(.args, &.{ Tok("20"), Tok("22") }),
                NIL(), // block
            }),
        }),
    });
    const result = compileAndRun("", tree);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 42), result.?.asFixnum().?);
}

test "compile def no-arg method (Nexus Sexp)" {
    // def answer; 42; end; answer
    const tree = S(.program, &.{
        S(.stmts, &.{
            S(.def, &.{
                Tok("answer"),
                NIL(), // no params
                Tok("42"),
                NIL(),
                NIL(),
            }),
            S(.send, &.{
                NIL(),
                Tok("answer"),
                NIL(), // no args
                NIL(),
            }),
        }),
    });
    const result = compileAndRun("", tree);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 42), result.?.asFixnum().?);
}

test "compile class + method (Nexus Sexp)" {
    // class Dog; def speak; 42; end; end; Dog.new.speak
    const tree = S(.program, &.{
        S(.stmts, &.{
            S(.class, &.{
                Tok("Dog"),
                NIL(),
                S(.stmts, &.{
                    S(.def, &.{
                        Tok("speak"),
                        NIL(),
                        Tok("42"),
                        NIL(),
                        NIL(),
                    }),
                }),
            }),
            S(.send, &.{
                S(.send, &.{
                    Tok("Dog"),
                    Tok("new"),
                    NIL(),
                    NIL(),
                }),
                Tok("speak"),
                NIL(),
                NIL(),
            }),
        }),
    });
    const result = compileAndRun("", tree);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 42), result.?.asFixnum().?);
}
