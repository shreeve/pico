const std = @import("std");
const Value = @import("value.zig").Value;
const op = @import("opcode.zig");
const Opcode = op.Opcode;
const Decode = op.Decode;
const class = @import("class.zig");
const ClassTable = class.ClassTable;
const ConstantTable = class.ConstantTable;
const GlobalTable = class.GlobalTable;
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const ObjHeader = heap_mod.ObjHeader;
const ObjType = heap_mod.ObjType;
const RClassPayload = heap_mod.RClassPayload;
const RStringPayload = heap_mod.RStringPayload;
const RArrayPayload = heap_mod.RArrayPayload;
const RHashPayload = heap_mod.RHashPayload;
const RRangePayload = heap_mod.RRangePayload;
const RFloatPayload = heap_mod.RFloatPayload;

/// Compiled function descriptor. Immutable after creation.
/// Designed to be flash-resident (all pointers can reference ROM/flash).
pub const IrFunc = struct {
    bytecode: [*]const u8,
    bytecode_len: u16,
    nregs: u8,
    nlocals: u8,
    const_pool: []const Value,
    child_funcs: []const *const IrFunc = &.{},
    syms: []const u16 = &.{},
    param_spec: u24 = 0,
    name_sym: u16 = 0,
    source_line: u16 = 0,
    captured_mask: u32 = 0,
    string_literals: []const []const u8 = &.{},
    /// Raw f64 values that back `LOAD_FLOAT b`. Stored per-function so
    /// the VM can materialise a heap `Float` on first use. Keeping this
    /// separate from `const_pool` (which holds 32-bit `Value`s) avoids
    /// widening the pool and preserves the existing LOAD_CONST path.
    float_pool: []const f64 = &.{},
};

/// A single call frame on the VM's frame stack.
pub const FrameKind = enum(u2) { method = 0, block = 1, top = 2 };

pub const CallFrame = struct {
    pc: [*]const u8,
    func: *const IrFunc,
    stack_base: u16,
    nregs: u8,
    frame_id: u32 = 0,
    self_value: Value = Value.nil,
    current_class: u8 = class.CLASS_OBJECT,
    caller_dest_reg: u8 = 0,
    argc: u8 = 0,
    block_value: Value = Value.nil,
    pending_new_instance: Value = Value.nil,
    kind: FrameKind = .method,
    owner_frame_id: u32 = 0,
};

/// VM execution error.
pub const VmError = error{
    TypeError,
    StackOverflow,
    InvalidOpcode,
    ConstOutOfBounds,
    RegisterOutOfBounds,
    DivisionByZero,
    NoMethodError,
    ArgumentError,
    MethodTableFull,
    ConstantTableFull,
    GlobalTableFull,
    HeapExhausted,
    Halted,
    LocalJumpError,
    RuntimeError,
    IvarOverflow,
    FloatDomainError,
    KeyError,
    RangeError,
};

/// Execution result: either a value or an error.
pub const ExecResult = union(enum) {
    ok: Value,
    err: VmError,
};

/// Capacity constants for arena layout.
pub const MAX_STACK: u16 = 512;
pub const MAX_FRAMES: u8 = 64;
pub const MAX_METHOD_REGISTRY: u16 = 128;
pub const MAX_OBJ_REGISTRY: u16 = 256;
const MAX_CALL_ARGS: u8 = 16;

/// Set to true to enable per-instruction trace output (debug only).
const TRACE = false;
pub const MAX_EXCEPTION_HANDLERS: u8 = 16;
pub const DEFAULT_ARENA_SIZE: u32 = 32768;

const ExceptionHandler = struct {
    frame_idx: u8,
    stack_depth: u16,
    rescue_pc: [*]const u8,
    ensure_pc: ?[*]const u8 = null,
    dest_reg: u8 = 0,
};

pub const ObjRef = struct {
    raw_ptr: ?[*]u8 = null,

    fn isLive(self: ObjRef) bool {
        return self.raw_ptr != null;
    }
};

/// The nanoruby virtual machine.
/// All storage lives in a single caller-provided arena buffer.
///
/// Arena layout (low to high address):
///   [frames][obj_registry][method_registry][exception_handlers]
///   [heap grows UP -->                                        ]
///   [              --- free gap (GC workspace) ---            ]
///   [                          <-- stack grows DOWN from top  ]
///
/// Heap and stack grow toward each other. Every free byte in the gap
/// is available to whichever side needs it first.
pub const VM = struct {
    // Stack grows downward from the top of the arena.
    // stack_top points to the Value array at the arena's high end.
    // sp counts Values used (growing downward). stack_top[-sp..] is live.
    stack_top: [*]Value,
    arena_end: usize,
    frames: []CallFrame,
    obj_registry: []ObjRef,
    method_registry: []*const IrFunc,
    exception_handlers: []ExceptionHandler,
    heap: Heap,

    class_table: ClassTable,
    constants: ConstantTable = .{},
    globals: GlobalTable = .{},

    sp: u16 = 0,
    fp: u8 = 0,
    next_frame_id: u32 = 1,
    method_registry_count: u16 = 0,
    obj_registry_count: u16 = 0,
    sym_new: ?u16 = null,
    sym_initialize: ?u16 = null,
    current_exception: Value = Value.nil,

    /// `break val` sets these and returns nil from the current block
    /// frame. The outer native that invoked the block (via
    /// `yieldBlock`) checks `break_pending` after each yield and, if
    /// set, clears it and uses `break_value` as its own return value.
    break_pending: bool = false,
    break_value: Value = Value.nil,
    exception_handler_count: u8 = 0,
    gc_stats: GcStats = .{},

    /// One-shot error channel for native methods. Natives that need
    /// to raise a VM-level exception call `vm.raise(err)` (which sets
    /// this field and returns `Value.undef`), then return
    /// immediately. Every native invocation goes through
    /// `VM.invokeNative`, which checks this field after the call,
    /// clears it, and translates the value into an `ExecResult.err`
    /// that the run-loop's exception handler walks the same way it
    /// walks opcode-level errors. See DEFERRED.md (F2, now resolved).
    pending_native_error: ?VmError = null,

    /// Initialize VM with all storage carved from a single aligned buffer.
    pub fn init(buf: []align(8) u8) VM {
        const layout = comptime computeLayout();
        std.debug.assert(buf.len >= layout.min_arena);

        // Fixed tables carved from bottom of arena
        const frames_ptr: [*]CallFrame = @ptrCast(@alignCast(buf.ptr + layout.frames_off));
        const obj_ptr: [*]ObjRef = @ptrCast(@alignCast(buf.ptr + layout.obj_reg_off));
        const method_ptr: [*]*const IrFunc = @ptrCast(@alignCast(buf.ptr + layout.method_reg_off));
        const eh_ptr: [*]ExceptionHandler = @ptrCast(@alignCast(buf.ptr + layout.exc_off));

        const obj_slice = obj_ptr[0..MAX_OBJ_REGISTRY];
        for (obj_slice) |*o| o.* = .{};

        // Stack grows DOWN from top of arena. stack_top points just past
        // the last Value slot at the arena's high end.
        const arena_end_addr = @intFromPtr(buf.ptr) + buf.len;
        const stack_top_addr = std.mem.alignBackward(usize, arena_end_addr, @alignOf(Value));
        const stack_top_ptr: [*]Value = @ptrFromInt(stack_top_addr);

        // Heap gets everything between fixed tables and the arena top.
        // The heap and stack share this space — heap grows up, stack grows down.
        const heap_buf = buf[layout.heap_off..];

        return .{
            .stack_top = stack_top_ptr,
            .arena_end = arena_end_addr,
            .frames = frames_ptr[0..MAX_FRAMES],
            .obj_registry = obj_slice,
            .method_registry = method_ptr[0..MAX_METHOD_REGISTRY],
            .exception_handlers = eh_ptr[0..MAX_EXCEPTION_HANDLERS],
            .heap = Heap.init(heap_buf),
            .class_table = ClassTable.init(),
        };
    }

    /// Initialize with a default-sized static arena (convenience for tests/host).
    pub fn initDefault() VM {
        const S = struct {
            var arena: [DEFAULT_ARENA_SIZE]u8 align(8) = undefined;
        };
        return init(&S.arena);
    }

    fn computeLayout() struct {
        frames_off: usize,
        obj_reg_off: usize,
        method_reg_off: usize,
        exc_off: usize,
        heap_off: usize,
        min_arena: usize,
    } {
        var off: usize = 0;

        // Fixed tables at bottom
        const frames_off = std.mem.alignForward(usize, off, @alignOf(CallFrame));
        off = frames_off + @as(usize, MAX_FRAMES) * @sizeOf(CallFrame);

        const obj_reg_off = std.mem.alignForward(usize, off, @alignOf(ObjRef));
        off = obj_reg_off + @as(usize, MAX_OBJ_REGISTRY) * @sizeOf(ObjRef);

        const method_reg_off = std.mem.alignForward(usize, off, @alignOf(*const IrFunc));
        off = method_reg_off + @as(usize, MAX_METHOD_REGISTRY) * @sizeOf(*const IrFunc);

        const exc_off = std.mem.alignForward(usize, off, @alignOf(ExceptionHandler));
        off = exc_off + @as(usize, MAX_EXCEPTION_HANDLERS) * @sizeOf(ExceptionHandler);

        const heap_off = std.mem.alignForward(usize, off, 4);

        // Minimum arena = fixed tables + stack + at least 1KB heap
        const stack_bytes = @as(usize, MAX_STACK) * @sizeOf(Value);
        const min_arena = heap_off + 1024 + stack_bytes;

        return .{
            .frames_off = frames_off,
            .obj_reg_off = obj_reg_off,
            .method_reg_off = method_reg_off,
            .exc_off = exc_off,
            .heap_off = heap_off,
            .min_arena = min_arena,
        };
    }

    /// Set the symbol ID for "new" and install the Class#new native method.
    pub fn setSymNew(self: *VM, sym_id: u16) void {
        self.sym_new = sym_id;
        self.class_table.defineMethodImpl(
            class.CLASS_CLASS,
            sym_id,
            .{ .native = &class.nativeClassNew },
        ) catch {};
    }

    pub fn setSymInitialize(self: *VM, sym_id: u16) void {
        self.sym_initialize = sym_id;
    }

    const HeapAlloc = struct { val: Value, ptr: [*]u8 };

    /// Allocate a heap object and register it in the object registry.
    /// Triggers GC and retries on *either* heap-bytes exhaustion or
    /// object-registry exhaustion.
    ///
    /// Prior version (pre-M7 in pico/src/ruby/nanoruby/UPSTREAM.md):
    /// short-circuited on `obj_registry_count >= obj_registry.len`
    /// before giving `gc()` a chance. Because `obj_registry_count` is
    /// a high-water mark that `gc()` never decrements (it tombstones
    /// slots via `raw_ptr = null`, letting `registerObj` reclaim
    /// them), any program that ever reached MAX_OBJ_REGISTRY live
    /// objects simultaneously would thereafter fail allocation forever,
    /// even with plenty of dead slots. Observed on pico hardware via
    /// a `puts "blink " + count.to_s; sleep_ms 500` loop failing with
    /// TypeError after ~84 iterations (HWM saturation from per-iter
    /// String allocations); see pico/ISSUES.md #20.
    ///
    /// New flow: try once, then gc() and try once more. Both attempts
    /// go through `registerObj`, which walks for tombstones before
    /// appending to the HWM.
    pub fn allocHeapObj(self: *VM, obj_type: heap_mod.ObjType, payload_bytes: u32) ?HeapAlloc {
        if (self.tryAllocHeapObj(obj_type, payload_bytes)) |r| return r;
        self.gc();
        return self.tryAllocHeapObj(obj_type, payload_bytes);
    }

    fn tryAllocHeapObj(self: *VM, obj_type: heap_mod.ObjType, payload_bytes: u32) ?HeapAlloc {
        const raw = self.heap.allocObj(obj_type, payload_bytes) orelse return null;
        return self.registerObj(obj_type, raw);
    }

    fn registerObj(self: *VM, obj_type: heap_mod.ObjType, raw: [*]u8) ?HeapAlloc {
        _ = obj_type;
        // Reuse a tombstoned slot if available
        var idx: u16 = 0;
        while (idx < self.obj_registry_count) : (idx += 1) {
            if (self.obj_registry[idx].raw_ptr == null) {
                self.obj_registry[idx] = .{ .raw_ptr = raw };
                return .{ .val = encodeObjRef(idx), .ptr = raw };
            }
        }
        // Append to end
        if (self.obj_registry_count >= self.obj_registry.len) return null;
        self.obj_registry[self.obj_registry_count] = .{ .raw_ptr = raw };
        const new_idx = self.obj_registry_count;
        self.obj_registry_count += 1;
        return .{ .val = encodeObjRef(new_idx), .ptr = raw };
    }

    fn encodeObjRef(idx: u16) Value {
        return Value.fromFixnumUnchecked(-@as(i32, idx) - 1);
    }

    fn decodeObjRef(v: Value) ?u16 {
        const n = v.asFixnum() orelse return null;
        if (n >= 0) return null;
        return std.math.cast(u16, -n - 1);
    }

    /// Look up a heap object from a Value.
    pub fn getObjPtr(self: *const VM, v: Value) ?[*]u8 {
        if (v.isHeapPtr() and v.raw != 0) {
            return @ptrFromInt(@as(usize, v.raw));
        }
        const idx = decodeObjRef(v) orelse return null;
        if (idx >= self.obj_registry_count) return null;
        return self.obj_registry[idx].raw_ptr;
    }

    pub fn getObjHeader(self: *const VM, v: Value) ?*ObjHeader {
        const ptr = self.getObjPtr(v) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Register an IrFunc in the method registry, return its index as a fixnum Value.
    fn registerFunc(self: *VM, func: *const IrFunc) ?Value {
        if (self.method_registry_count >= MAX_METHOD_REGISTRY) return null;
        const idx = self.method_registry_count;
        self.method_registry[idx] = func;
        self.method_registry_count += 1;
        return Value.fromFixnumUnchecked(@intCast(idx));
    }

    /// Retrieve an IrFunc from the method registry by fixnum index.
    fn lookupRegisteredFunc(self: *const VM, val: Value) ?*const IrFunc {
        const idx = val.asFixnum() orelse return null;
        if (idx < 0 or idx >= self.method_registry_count) return null;
        return self.method_registry[@intCast(idx)];
    }

    /// Execute an IrFunc and return its result.
    pub fn execute(self: *VM, func: *const IrFunc) ExecResult {
        if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
        if (!self.stackHasRoom(func.nregs)) return .{ .err = VmError.StackOverflow };

        const base = self.sp;
        self.sp += func.nregs;

        var i: u16 = 0;
        while (i < func.nregs) : (i += 1) {
            self.stackAt(base + i).* = Value.nil;
        }

        const frame = &self.frames[self.fp];
        frame.* = .{
            .pc = func.bytecode,
            .func = func,
            .stack_base = base,
            .nregs = func.nregs,
            .frame_id = self.next_frame_id,
            .self_value = Value.nil,
            .current_class = class.CLASS_OBJECT,
        };
        self.next_frame_id +%= 1;
        self.fp += 1;

        return self.run(0);
    }

    /// Main dispatch loop. Runs until the frame stack is popped below
    /// `base_fp` (via a RETURN that would make `self.fp` equal to
    /// `base_fp`), at which point the returning value is handed back.
    /// Top-level execute passes 0; reentrant calls (like yieldBlock)
    /// pass the `self.fp` they observed before pushing their frame.
    ///
    /// When an opcode returns `.err` and a `PUSH_HANDLER`-pushed
    /// exception handler is active within the current execution
    /// window, unwind to it and resume — this is how built-in VM
    /// errors (DivisionByZero, TypeError, NoMethodError, etc.) wind
    /// up caught by `begin/rescue` and the `x rescue y` modifier.
    fn run(self: *VM, base_fp: u8) ExecResult {
        while (true) {
            const result = self.runUntilError(base_fp);
            if (result != .err) return result;
            if (self.exception_handler_count == 0) return result;

            // Route to the innermost handler whose frame is still on
            // the stack at or above base_fp. Handlers above the target
            // frame are stale and discarded (their frames are gone).
            // Cross-boundary handlers (below base_fp) are left in
            // place so an outer `run` layer can consume them — e.g.,
            // a block body raising through `yieldBlock` back into
            // the iterator-native caller back into the opcode-level
            // `begin/rescue` around the iterator call.
            const e = result.err;
            while (self.exception_handler_count > 0) {
                const handler = self.exception_handlers[self.exception_handler_count - 1];
                if (handler.frame_idx < base_fp) return result; // cross-boundary; preserve handler
                self.exception_handler_count -= 1;
                // Unwind to handler's frame.
                self.fp = handler.frame_idx + 1;
                self.sp = handler.stack_depth;
                const target_frame = &self.frames[handler.frame_idx];
                target_frame.pc = handler.rescue_pc;

                // Synthesize an exception Value. We don't yet have
                // full exception objects with `.message` / `.class` /
                // backtrace, but encoding the error name as a Symbol
                // gives user code something meaningful to rescue and
                // compare against, e.g.:
                //
                //   begin 1/0; rescue => e; p e; end     # → :ZeroDivisionError
                //   e == :ZeroDivisionError              # true
                //
                // The symbol id is derived from the error's tag; each
                // unique VmError maps to a distinct symbol.
                const errname = @errorName(e);
                const sym_id = self.errorSym(errname);
                self.current_exception = Value.fromSymbol(sym_id);
                self.reg(target_frame, handler.dest_reg).* = self.current_exception;
                break;
            }
            // Loop: resume dispatching from the handler's code.
        }
    }

    /// Inner dispatch loop — runs opcodes until an error or the frame
    /// stack pops below `base_fp`. Extracted so `run` can wrap it with
    /// exception-handler unwinding on error returns.
    fn runUntilError(self: *VM, base_fp: u8) ExecResult {
        while (true) {
            const frame = &self.frames[self.fp - 1];
            const bytecode_end = frame.func.bytecode + frame.func.bytecode_len;
            if (@intFromPtr(frame.pc) >= @intFromPtr(bytecode_end)) {
                return .{ .err = VmError.InvalidOpcode };
            }

            const opbyte = frame.pc[0];
            const opcode: Opcode = @enumFromInt(opbyte);
            const operands = frame.pc + 1;

            if (TRACE) std.debug.print("[trace] pc={d} op=0x{x:0>2} fp={d} sp={d}\n", .{
                @intFromPtr(frame.pc) - @intFromPtr(frame.func.bytecode),
                opbyte, self.fp, self.sp,
            });

            switch (opcode) {
                .NOP => {
                    frame.pc += Opcode.NOP.size();
                },

                .LOAD_NIL => {
                    const ra = Decode.a(operands);
                    self.reg(frame, ra).* = Value.nil;
                    frame.pc += Opcode.LOAD_NIL.size();
                },

                .LOAD_TRUE => {
                    const ra = Decode.a(operands);
                    self.reg(frame, ra).* = Value.true_;
                    frame.pc += Opcode.LOAD_TRUE.size();
                },

                .LOAD_FALSE => {
                    const ra = Decode.a(operands);
                    self.reg(frame, ra).* = Value.false_;
                    frame.pc += Opcode.LOAD_FALSE.size();
                },

                .LOAD_SELF => {
                    const ra = Decode.a(operands);
                    self.reg(frame, ra).* = frame.self_value;
                    frame.pc += Opcode.LOAD_SELF.size();
                },

                .LOAD_I16 => {
                    const ops = Decode.as_(operands);
                    self.reg(frame, ops.a).* = Value.fromFixnumUnchecked(@as(i32, ops.s));
                    frame.pc += Opcode.LOAD_I16.size();
                },

                .LOAD_I8 => {
                    const ops = Decode.ab(operands);
                    const signed: i8 = @bitCast(ops.b);
                    self.reg(frame, ops.a).* = Value.fromFixnumUnchecked(@as(i32, signed));
                    frame.pc += Opcode.LOAD_I8.size();
                },

                .LOAD_CONST => {
                    const ops = Decode.ab(operands);
                    const pool = frame.func.const_pool;
                    if (ops.b >= pool.len) return .{ .err = VmError.ConstOutOfBounds };
                    self.reg(frame, ops.a).* = pool[ops.b];
                    frame.pc += Opcode.LOAD_CONST.size();
                },

                .LOAD_FLOAT => {
                    const ops = Decode.ab(operands);
                    const pool = frame.func.float_pool;
                    if (ops.b >= pool.len) return .{ .err = VmError.ConstOutOfBounds };
                    const val = self.allocFloat(pool[ops.b]) orelse
                        return .{ .err = VmError.HeapExhausted };
                    self.reg(frame, ops.a).* = val;
                    frame.pc += Opcode.LOAD_FLOAT.size();
                },

                .MOVE => {
                    const ops = Decode.ab(operands);
                    self.reg(frame, ops.a).* = self.reg(frame, ops.b).*;
                    frame.pc += Opcode.MOVE.size();
                },

                .ADD, .SUB, .MUL, .DIV, .MOD, .EQ, .LT, .LE, .GT, .GE => {
                    const ra = Decode.a(operands);
                    const lhs = self.reg(frame, ra).*;
                    const rhs = self.reg(frame, ra + 1).*;

                    // Fast path: both operands are *genuine* immediate
                    // fixnums. Heap objects are encoded as negative fixnums
                    // via obj_registry indirection and must NOT slip through
                    // asFixnum in the hot path — so we first rule out any
                    // heap-backed operand.
                    const lhs_heap = self.getObjHeader(lhs) != null;
                    const rhs_heap = self.getObjHeader(rhs) != null;
                    const both_real_int = !lhs_heap and !rhs_heap and lhs.isFixnum() and rhs.isFixnum();

                    if (both_real_int) {
                        switch (doFixnumBinOp(opcode, lhs, rhs)) {
                            .ok => |v| {
                                self.reg(frame, ra).* = v;
                                frame.pc += opcode.size();
                            },
                            .err => |e| return .{ .err = e },
                        }
                    } else if (self.toFloat(lhs) != null and self.toFloat(rhs) != null) {
                        // Numeric fast path: at least one operand is a
                        // Float (heap-boxed double). Promote the integer
                        // side if needed and execute in f64. Matches
                        // Ruby's implicit Fixnum→Float promotion.
                        const la = self.toFloat(lhs).?;
                        const rb = self.toFloat(rhs).?;
                        switch (self.doFloatBinOp(opcode, la, rb)) {
                            .ok => |v| {
                                self.reg(frame, ra).* = v;
                                frame.pc += opcode.size();
                            },
                            .err => |e| return .{ .err = e },
                        }
                    } else if (opcode == .EQ) {
                        // Type-agnostic equality: bit-identity, or byte-wise
                        // for two heap strings. Everything else: false.
                        var eq = lhs.eql(rhs);
                        if (!eq) {
                            if (self.getStringData(lhs)) |la| {
                                if (self.getStringData(rhs)) |rb| eq = std.mem.eql(u8, la, rb);
                            }
                        }
                        self.reg(frame, ra).* = Value.fromBool(eq);
                        frame.pc += opcode.size();
                    } else {
                        // Non-fixnum: dispatch via method lookup (`:+` etc.).
                        const sym_atom: u16 = switch (opcode) {
                            .ADD => class.atom_mod.ATOM_ADD,
                            .SUB => class.atom_mod.ATOM_SUB,
                            .MUL => class.atom_mod.ATOM_MUL,
                            .DIV => class.atom_mod.ATOM_DIV,
                            .MOD => class.atom_mod.ATOM_MOD,
                            .LT => class.atom_mod.ATOM_LT,
                            .LE => class.atom_mod.ATOM_LE,
                            .GT => class.atom_mod.ATOM_GT,
                            .GE => class.atom_mod.ATOM_GE,
                            else => unreachable,
                        };
                        switch (self.dispatchBinMethod(frame, ra, sym_atom, opcode.size())) {
                            .handled => {},
                            .err => |e| return .{ .err = e },
                        }
                    }
                },

                .JMP => {
                    const offset = Decode.s16(operands);
                    const base: isize = @intCast(@intFromPtr(frame.pc));
                    const target: usize = @intCast(base + @as(isize, offset));
                    frame.pc = @ptrFromInt(target);
                },

                .JMP_IF => {
                    const ops = Decode.as_(operands);
                    if (self.reg(frame, ops.a).*.isTruthy()) {
                        const base: isize = @intCast(@intFromPtr(frame.pc));
                        const target: usize = @intCast(base + @as(isize, ops.s));
                        frame.pc = @ptrFromInt(target);
                    } else {
                        frame.pc += Opcode.JMP_IF.size();
                    }
                },

                .JMP_NOT => {
                    const ops = Decode.as_(operands);
                    if (self.reg(frame, ops.a).*.isFalsy()) {
                        const base: isize = @intCast(@intFromPtr(frame.pc));
                        const target: usize = @intCast(base + @as(isize, ops.s));
                        frame.pc = @ptrFromInt(target);
                    } else {
                        frame.pc += Opcode.JMP_NOT.size();
                    }
                },

                .JMP_NIL => {
                    const ops = Decode.as_(operands);
                    if (self.reg(frame, ops.a).*.isNil()) {
                        const base: isize = @intCast(@intFromPtr(frame.pc));
                        const target: usize = @intCast(base + @as(isize, ops.s));
                        frame.pc = @ptrFromInt(target);
                    } else {
                        frame.pc += Opcode.JMP_NIL.size();
                    }
                },

                .LOAD_SYM => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    self.reg(frame, ops.a).* = Value.fromSymbol(@intCast(syms[ops.b]));
                    frame.pc += Opcode.LOAD_SYM.size();
                },

                .GET_IVAR => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = frame.self_value;
                    const cid = self.class_table.classOfVM(self, recv);
                    if (self.class_table.lookupIvar(cid, name_sym)) |slot| {
                        if (self.getObjPtr(recv)) |obj_ptr| {
                            const ivar_base: [*]u8 = obj_ptr + @sizeOf(ObjHeader);
                            const ivar_ptr: [*]Value = @ptrCast(@alignCast(ivar_base));
                            self.reg(frame, ops.a).* = ivar_ptr[slot];
                        } else {
                            self.reg(frame, ops.a).* = Value.nil;
                        }
                    } else {
                        self.reg(frame, ops.a).* = Value.nil;
                    }
                    frame.pc += Opcode.GET_IVAR.size();
                },

                .SET_IVAR => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = frame.self_value;
                    const cid = self.class_table.classOfVM(self, recv);
                    const slot = self.class_table.ensureIvar(cid, name_sym) orelse
                        return .{ .err = VmError.IvarOverflow };
                    if (self.getObjPtr(recv)) |obj_ptr| {
                        const ivar_base: [*]u8 = obj_ptr + @sizeOf(ObjHeader);
                        const ivar_ptr: [*]Value = @ptrCast(@alignCast(ivar_base));
                        ivar_ptr[slot] = self.reg(frame, ops.a).*;
                    }
                    frame.pc += Opcode.SET_IVAR.size();
                },

                .GET_GLOBAL => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    self.reg(frame, ops.a).* = self.globals.get(name_sym) orelse Value.nil;
                    frame.pc += Opcode.GET_GLOBAL.size();
                },

                .SET_GLOBAL => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    self.globals.set(name_sym, self.reg(frame, ops.a).*) catch
                        return .{ .err = VmError.GlobalTableFull };
                    frame.pc += Opcode.SET_GLOBAL.size();
                },

                .METHOD => {
                    const ops = Decode.ab(operands);
                    const children = frame.func.child_funcs;
                    if (ops.b >= children.len) return .{ .err = VmError.ConstOutOfBounds };
                    self.reg(frame, ops.a).* = self.registerFunc(children[ops.b]) orelse
                        return .{ .err = VmError.StackOverflow };
                    frame.pc += Opcode.METHOD.size();
                },

                .DEF_METHOD => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.a >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.a];
                    const method_val = self.reg(frame, ops.b).*;
                    const func_ptr = self.lookupRegisteredFunc(method_val) orelse
                        return .{ .err = VmError.TypeError };
                    self.class_table.defineMethod(frame.current_class, name_sym, func_ptr) catch
                        return .{ .err = VmError.MethodTableFull };
                    frame.pc += Opcode.DEF_METHOD.size();
                },

                .GET_CONST => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    self.reg(frame, ops.a).* = self.constants.get(name_sym) orelse Value.nil;
                    frame.pc += Opcode.GET_CONST.size();
                },

                .SET_CONST => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    self.constants.set(name_sym, self.reg(frame, ops.a).*) catch
                        return .{ .err = VmError.ConstantTableFull };
                    frame.pc += Opcode.SET_CONST.size();
                },

                .DEF_CLASS => {
                    const ops = Decode.abc(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const super_val = self.reg(frame, ops.c).*;

                    // Determine superclass ID
                    var super_id: u8 = class.CLASS_OBJECT;
                    if (self.getObjPtr(super_val)) |sp_ptr| {
                        const sp_hdr: *const ObjHeader = @ptrCast(@alignCast(sp_ptr));
                        if (sp_hdr.obj_type == .class) {
                            const sp_payload: *const RClassPayload = @ptrCast(@alignCast(sp_ptr + @sizeOf(ObjHeader)));
                            super_id = sp_payload.represented_class_id;
                        }
                    }

                    // Check if class already exists as a constant
                    if (self.constants.get(name_sym)) |existing| {
                        self.reg(frame, ops.a).* = existing;
                    } else {
                        const new_id = self.class_table.allocClass(name_sym, super_id) orelse
                            return .{ .err = VmError.MethodTableFull };

                        const alloc = self.allocHeapObj(.class, @sizeOf(RClassPayload)) orelse
                            return .{ .err = VmError.HeapExhausted };
                        const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                        hdr.class_id = class.CLASS_CLASS;
                        const payload: *RClassPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                        payload.* = .{
                            .name_sym = name_sym,
                            .represented_class_id = new_id,
                            .superclass_id = super_id,
                        };

                        self.constants.set(name_sym, alloc.val) catch
                            return .{ .err = VmError.ConstantTableFull };
                        self.reg(frame, ops.a).* = alloc.val;
                    }
                    frame.pc += Opcode.DEF_CLASS.size();
                },

                .EXEC_BODY => {
                    const ops = Decode.ab(operands);
                    const recv = self.reg(frame, ops.a).*;
                    const children = frame.func.child_funcs;
                    if (ops.b >= children.len) return .{ .err = VmError.ConstOutOfBounds };
                    const body_func = children[ops.b];

                    // Determine current_class from class value
                    var body_class: u8 = frame.current_class;
                    if (self.getObjPtr(recv)) |cp_ptr| {
                        const cp_hdr: *const ObjHeader = @ptrCast(@alignCast(cp_ptr));
                        if (cp_hdr.obj_type == .class) {
                            const cp: *const RClassPayload = @ptrCast(@alignCast(cp_ptr + @sizeOf(ObjHeader)));
                            body_class = cp.represented_class_id;
                        }
                    }

                    frame.pc += Opcode.EXEC_BODY.size();

                    if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                    const callee_nregs = body_func.nregs;
                    if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };

                    const callee_base = self.sp;
                    var ri: u16 = 0;
                    while (ri < callee_nregs) : (ri += 1) {
                        self.stackAt(callee_base + ri).* = Value.nil;
                    }

                    self.sp += callee_nregs;
                    const callee_frame = &self.frames[self.fp];
                    callee_frame.* = .{
                        .pc = body_func.bytecode,
                        .func = body_func,
                        .stack_base = callee_base,
                        .nregs = callee_nregs,
                        .frame_id = self.next_frame_id,
                        .self_value = recv,
                        .current_class = body_class,
                        .caller_dest_reg = ops.a,
                    };
                    self.next_frame_id +%= 1;
                    self.fp += 1;
                },

                .SSEND, .SEND => {
                    const ops = Decode.abc(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const is_ssend = opcode == .SSEND;

                    const recv = if (is_ssend) frame.self_value else self.reg(frame, ops.a).*;
                    const cid = self.class_table.classOfVM(self, recv);
                    const method_impl = self.class_table.lookupMethod(cid, name_sym) orelse
                        return .{ .err = VmError.NoMethodError };

                    const argc: u8 = ops.c;
                    if (argc > MAX_CALL_ARGS) return .{ .err = VmError.ArgumentError };
                    const arg_base: u8 = if (is_ssend) ops.a else ops.a + 1;

                    switch (method_impl) {
                        .native => |native_fn| {
                            var saved_args: [MAX_CALL_ARGS]Value = undefined;
                            var ai: u8 = 0;
                            while (ai < argc) : (ai += 1) {
                                saved_args[ai] = self.reg(frame, arg_base + ai).*;
                            }
                            const result = switch (self.invokeNative(native_fn, recv, saved_args[0..argc], null)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            frame.pc += opcode.size();

                            if (native_fn == &class.nativeClassNew) {
                                switch (self.dispatchInitialize(result, saved_args[0..argc], ops.a)) {
                                    .instance => |i| self.reg(frame, ops.a).* = i,
                                    .frame_pushed => {}, // RETURN will fill dest via pending_new_instance
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                self.reg(frame, ops.a).* = result;
                            }
                        },
                        .bytecode => |method_func| {
                            frame.pc += opcode.size();

                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };

                            var saved_args: [MAX_CALL_ARGS]Value = undefined;
                            var ai: u8 = 0;
                            while (ai < argc) : (ai += 1) {
                                saved_args[ai] = self.reg(frame, arg_base + ai).*;
                            }

                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) {
                                self.stackAt(callee_base + ri).* = Value.nil;
                            }

                            ai = 0;
                            while (ai < argc and ai < callee_nregs) : (ai += 1) {
                                self.stackAt(callee_base + ai).* = saved_args[ai];
                            }

                            self.sp += callee_nregs;
                            const callee_frame = &self.frames[self.fp];
                            callee_frame.* = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = cid,
                                .caller_dest_reg = ops.a,
                                .argc = argc,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .GET_UPVAR => {
                    const ops = Decode.abc(operands);
                    // Walk up 'b' scope levels and read slot 'c'
                    var level: u8 = ops.b;
                    var target_fp = self.fp - 1;
                    while (level > 0 and target_fp > 0) : (level -= 1) {
                        target_fp -= 1;
                    }
                    if (target_fp < self.fp) {
                        const target_frame = &self.frames[target_fp];
                        self.reg(frame, ops.a).* = self.reg(target_frame, ops.c).*;
                    } else {
                        self.reg(frame, ops.a).* = Value.nil;
                    }
                    frame.pc += Opcode.GET_UPVAR.size();
                },

                .SET_UPVAR => {
                    const ops = Decode.abc(operands);
                    var level: u8 = ops.b;
                    var target_fp = self.fp - 1;
                    while (level > 0 and target_fp > 0) : (level -= 1) {
                        target_fp -= 1;
                    }
                    if (target_fp < self.fp) {
                        const target_frame = &self.frames[target_fp];
                        self.reg(target_frame, ops.c).* = self.reg(frame, ops.a).*;
                    }
                    frame.pc += Opcode.SET_UPVAR.size();
                },

                .SEND0 => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = self.reg(frame, ops.a).*;
                    const cid = self.class_table.classOfVM(self, recv);
                    const method_impl = self.class_table.lookupMethod(cid, name_sym) orelse
                        return .{ .err = VmError.NoMethodError };

                    switch (method_impl) {
                        .native => |native_fn| {
                            const result = switch (self.invokeNative(native_fn, recv, &.{}, null)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            frame.pc += Opcode.SEND0.size();
                            if (native_fn == &class.nativeClassNew) {
                                switch (self.dispatchInitialize(result, &.{}, ops.a)) {
                                    .instance => |i| self.reg(frame, ops.a).* = i,
                                    .frame_pushed => {},
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                self.reg(frame, ops.a).* = result;
                            }
                        },
                        .bytecode => |method_func| {
                            frame.pc += Opcode.SEND0.size();
                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };
                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                            self.sp += callee_nregs;
                            self.frames[self.fp] = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = cid,
                                .caller_dest_reg = ops.a,
                                .argc = 0,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .SSEND0 => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = frame.self_value;
                    const cid = self.class_table.classOfVM(self, recv);
                    const method_impl = self.class_table.lookupMethod(cid, name_sym) orelse
                        return .{ .err = VmError.NoMethodError };

                    switch (method_impl) {
                        .native => |native_fn| {
                            const result = switch (self.invokeNative(native_fn, recv, &.{}, null)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            frame.pc += Opcode.SSEND0.size();
                            if (native_fn == &class.nativeClassNew) {
                                switch (self.dispatchInitialize(result, &.{}, ops.a)) {
                                    .instance => |i| self.reg(frame, ops.a).* = i,
                                    .frame_pushed => {},
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                self.reg(frame, ops.a).* = result;
                            }
                        },
                        .bytecode => |method_func| {
                            frame.pc += Opcode.SSEND0.size();
                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };
                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                            self.sp += callee_nregs;
                            self.frames[self.fp] = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = cid,
                                .caller_dest_reg = ops.a,
                                .argc = 0,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .SEND1 => {
                    const ops = Decode.abc(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = self.reg(frame, ops.a).*;
                    const arg0 = self.reg(frame, ops.c).*;
                    const cid = self.class_table.classOfVM(self, recv);
                    const method_impl = self.class_table.lookupMethod(cid, name_sym) orelse
                        return .{ .err = VmError.NoMethodError };

                    switch (method_impl) {
                        .native => |native_fn| {
                            var args = [1]Value{arg0};
                            const result = switch (self.invokeNative(native_fn, recv, &args, null)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            frame.pc += Opcode.SEND1.size();
                            if (native_fn == &class.nativeClassNew) {
                                switch (self.dispatchInitialize(result, &args, ops.a)) {
                                    .instance => |i| self.reg(frame, ops.a).* = i,
                                    .frame_pushed => {},
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                self.reg(frame, ops.a).* = result;
                            }
                        },
                        .bytecode => |method_func| {
                            frame.pc += Opcode.SEND1.size();
                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };
                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                            self.stackAt(callee_base).* = arg0;
                            self.sp += callee_nregs;
                            self.frames[self.fp] = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = cid,
                                .caller_dest_reg = ops.a,
                                .argc = 1,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .YIELD => {
                    const ops = Decode.ab(operands);
                    const argc: u8 = ops.b;

                    // Find the block in the current or enclosing method frame
                    var block_val = frame.block_value;
                    if (block_val.isNil()) {
                        // Walk up frames to find block
                        var fi: u8 = self.fp;
                        while (fi > 0) {
                            fi -= 1;
                            if (!self.frames[fi].block_value.isNil()) {
                                block_val = self.frames[fi].block_value;
                                break;
                            }
                        }
                    }
                    if (block_val.isNil()) return .{ .err = VmError.LocalJumpError };

                    // Block is stored as a registry index referencing a Proc-like IrFunc
                    const block_func = self.lookupRegisteredFunc(block_val) orelse
                        return .{ .err = VmError.TypeError };

                    if (argc > MAX_CALL_ARGS) return .{ .err = VmError.ArgumentError };
                    var saved_args: [MAX_CALL_ARGS]Value = undefined;
                    var ai: u8 = 0;
                    while (ai < argc) : (ai += 1) {
                        saved_args[ai] = self.reg(frame, ops.a + 1 + ai).*;
                    }

                    frame.pc += Opcode.YIELD.size();
                    if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                    const callee_nregs = block_func.nregs;
                    if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };

                    const callee_base = self.sp;
                    var ri: u16 = 0;
                    while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                    ai = 0;
                    while (ai < argc and ai < callee_nregs) : (ai += 1) {
                        self.stackAt(callee_base + ai).* = saved_args[ai];
                    }

                    self.sp += callee_nregs;
                    self.frames[self.fp] = .{
                        .pc = block_func.bytecode,
                        .func = block_func,
                        .stack_base = callee_base,
                        .nregs = callee_nregs,
                        .frame_id = self.next_frame_id,
                        .self_value = frame.self_value,
                        .current_class = frame.current_class,
                        .caller_dest_reg = ops.a,
                        .argc = argc,
                        .kind = .block,
                        .owner_frame_id = frame.frame_id,
                    };
                    self.next_frame_id +%= 1;
                    self.fp += 1;
                },

                .SUPER => {
                    const ops = Decode.ab(operands);
                    const argc: u8 = ops.b;
                    const recv = frame.self_value;

                    // Look up the current method name in the superclass
                    const cur_class = frame.current_class;
                    const super_id = self.class_table.classes[cur_class].superclass_id;
                    if (super_id == 0) return .{ .err = VmError.NoMethodError };

                    // Find current method name from the frame's func
                    const method_name = frame.func.name_sym;
                    const method_impl = self.class_table.lookupMethod(super_id, method_name) orelse
                        return .{ .err = VmError.NoMethodError };

                    if (argc > MAX_CALL_ARGS) return .{ .err = VmError.ArgumentError };
                    var saved_args: [MAX_CALL_ARGS]Value = undefined;
                    var ai: u8 = 0;
                    while (ai < argc) : (ai += 1) {
                        saved_args[ai] = self.reg(frame, ops.a + 1 + ai).*;
                    }

                    switch (method_impl) {
                        .native => |native_fn| {
                            const result = switch (self.invokeNative(native_fn, recv, saved_args[0..argc], null)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            self.reg(frame, ops.a).* = result;
                            frame.pc += Opcode.SUPER.size();
                        },
                        .bytecode => |method_func| {
                            frame.pc += Opcode.SUPER.size();
                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };
                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                            ai = 0;
                            while (ai < argc and ai < callee_nregs) : (ai += 1) {
                                self.stackAt(callee_base + ai).* = saved_args[ai];
                            }
                            self.sp += callee_nregs;
                            self.frames[self.fp] = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = super_id,
                                .caller_dest_reg = ops.a,
                                .argc = argc,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .ARRAY => {
                    const ops = Decode.ab(operands);
                    const count: u16 = ops.b;
                    const payload_bytes = @sizeOf(RArrayPayload) + count * @sizeOf(Value);
                    const alloc = self.allocHeapObj(.array, @intCast(payload_bytes)) orelse
                        return .{ .err = VmError.HeapExhausted };
                    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                    hdr.class_id = class.CLASS_ARRAY;
                    const arr_payload: *RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                    arr_payload.* = .{ .len = count, .capa = count };
                    const elements: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(RArrayPayload)));
                    var i: u16 = 0;
                    while (i < count) : (i += 1) {
                        elements[i] = self.reg(frame, ops.a + @as(u8, @intCast(i))).*;
                    }
                    self.reg(frame, ops.a).* = alloc.val;
                    frame.pc += Opcode.ARRAY.size();
                },

                .HASH => {
                    const ops = Decode.ab(operands);
                    const npairs: u16 = ops.b;
                    const nvals = npairs * 2;
                    const payload_bytes = @sizeOf(RHashPayload) + nvals * @sizeOf(Value);
                    const alloc = self.allocHeapObj(.hash, @intCast(payload_bytes)) orelse
                        return .{ .err = VmError.HeapExhausted };
                    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                    hdr.class_id = class.CLASS_HASH;
                    const hash_payload: *RHashPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                    hash_payload.* = .{ .count = npairs, .capa = npairs };
                    const data: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(RHashPayload)));
                    var i: u16 = 0;
                    while (i < nvals) : (i += 1) {
                        data[i] = self.reg(frame, ops.a + @as(u8, @intCast(i))).*;
                    }
                    self.reg(frame, ops.a).* = alloc.val;
                    frame.pc += Opcode.HASH.size();
                },

                .RANGE => {
                    const ops = Decode.abc(operands);
                    const dst_reg = ops.a & 0x7F;
                    const low = self.reg(frame, ops.b).*;
                    const high = self.reg(frame, ops.c).*;
                    const exclusive: u16 = if (ops.a & 0x80 != 0) 1 else 0;
                    const payload_bytes = @sizeOf(RRangePayload) + 2 * @sizeOf(Value);
                    const alloc = self.allocHeapObj(.range, @intCast(payload_bytes)) orelse
                        return .{ .err = VmError.HeapExhausted };
                    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                    hdr.class_id = class.CLASS_RANGE;
                    const range_payload: *RRangePayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                    range_payload.* = .{ .exclusive = exclusive };
                    const bounds: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(RRangePayload)));
                    bounds[0] = low;
                    bounds[1] = high;
                    self.reg(frame, dst_reg).* = alloc.val;
                    frame.pc += Opcode.RANGE.size();
                },

                .STRING => {
                    const ops = Decode.ab(operands);
                    const lits = frame.func.string_literals;
                    if (ops.b >= lits.len) return .{ .err = VmError.ConstOutOfBounds };
                    const str_data = lits[ops.b];
                    const payload_bytes = @sizeOf(RStringPayload) + @as(u32, @intCast(str_data.len));
                    const alloc = self.allocHeapObj(.string, payload_bytes) orelse
                        return .{ .err = VmError.HeapExhausted };
                    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                    hdr.class_id = class.CLASS_STRING;
                    const str_payload: *RStringPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                    str_payload.* = .{ .len = @intCast(str_data.len) };
                    const dest: [*]u8 = alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(RStringPayload);
                    @memcpy(dest[0..str_data.len], str_data);
                    self.reg(frame, ops.a).* = alloc.val;
                    frame.pc += Opcode.STRING.size();
                },

                .STRCAT => {
                    const ra = Decode.a(operands);
                    const lhs_val = self.reg(frame, ra).*;
                    const rhs_val = self.reg(frame, ra + 1).*;

                    // Format RHS to_s into a local buffer (avoids static aliasing)
                    var rhs_buf: [32]u8 = undefined;
                    var rhs_owned: []const u8 = "";
                    const rhs_is_str = self.getStringData(rhs_val) != null;
                    if (!rhs_is_str) {
                        if (rhs_val.asFixnum()) |n| {
                            rhs_owned = std.fmt.bufPrint(&rhs_buf, "{d}", .{n}) catch "";
                        } else if (rhs_val.isTrue()) {
                            rhs_owned = "true";
                        } else if (rhs_val.isFalse()) {
                            rhs_owned = "false";
                        }
                    }

                    // Compute lengths before allocating (safe if GC runs during alloc)
                    const lhs_len = if (self.getStringData(lhs_val)) |d| d.len else 0;
                    const rhs_len = if (rhs_is_str) self.getStringData(rhs_val).?.len else rhs_owned.len;
                    const new_len = lhs_len + rhs_len;

                    const payload_bytes = @sizeOf(RStringPayload) + @as(u32, @intCast(new_len));
                    const alloc = self.allocHeapObj(.string, payload_bytes) orelse
                        return .{ .err = VmError.HeapExhausted };
                    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                    hdr.class_id = class.CLASS_STRING;
                    const str_payload: *RStringPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                    str_payload.* = .{ .len = @intCast(new_len) };
                    const dest: [*]u8 = alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(RStringPayload);

                    // Re-fetch heap slices after allocation
                    if (self.getStringData(lhs_val)) |ld| {
                        @memcpy(dest[0..ld.len], ld);
                    }
                    if (rhs_is_str) {
                        if (self.getStringData(rhs_val)) |rd| {
                            @memcpy(dest[lhs_len..][0..rd.len], rd);
                        }
                    } else {
                        @memcpy(dest[lhs_len..][0..rhs_owned.len], rhs_owned);
                    }

                    self.reg(frame, ra).* = alloc.val;
                    frame.pc += Opcode.STRCAT.size();
                },

                .BLOCK => {
                    const ops = Decode.ab(operands);
                    const children = frame.func.child_funcs;
                    if (ops.b >= children.len) return .{ .err = VmError.ConstOutOfBounds };
                    self.reg(frame, ops.a).* = self.registerFunc(children[ops.b]) orelse
                        return .{ .err = VmError.StackOverflow };
                    frame.pc += Opcode.BLOCK.size();
                },

                .LAMBDA => {
                    const ops = Decode.ab(operands);
                    const children = frame.func.child_funcs;
                    if (ops.b >= children.len) return .{ .err = VmError.ConstOutOfBounds };
                    self.reg(frame, ops.a).* = self.registerFunc(children[ops.b]) orelse
                        return .{ .err = VmError.StackOverflow };
                    frame.pc += Opcode.LAMBDA.size();
                },

                .SEND_BLOCK => {
                    const ops = Decode.abc(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];
                    const recv = self.reg(frame, ops.a).*;
                    const cid = self.class_table.classOfVM(self, recv);
                    const method_impl = self.class_table.lookupMethod(cid, name_sym) orelse
                        return .{ .err = VmError.NoMethodError };

                    // Last arg position holds the block; actual args are ops.c - 1
                    const total_slots: u8 = ops.c;
                    const block_val = if (total_slots > 0) self.reg(frame, ops.a + total_slots).* else Value.nil;
                    const argc = if (total_slots > 0) total_slots - 1 else 0;

                    if (argc > MAX_CALL_ARGS) return .{ .err = VmError.ArgumentError };
                    var saved_args: [MAX_CALL_ARGS]Value = undefined;
                    var ai: u8 = 0;
                    while (ai < argc) : (ai += 1) {
                        saved_args[ai] = self.reg(frame, ops.a + 1 + ai).*;
                    }

                    switch (method_impl) {
                        .native => |native_fn| {
                            // Only pass the block to the native if it's actually
                            // a block Value; nil means "no block given".
                            const nfn_block: ?Value = if (block_val.isNil()) null else block_val;
                            const result = switch (self.invokeNative(native_fn, recv, saved_args[0..argc], nfn_block)) {
                                .ok => |v| v,
                                .err => |e| return .{ .err = e },
                            };
                            frame.pc += Opcode.SEND_BLOCK.size();
                            if (native_fn == &class.nativeClassNew) {
                                switch (self.dispatchInitialize(result, saved_args[0..argc], ops.a)) {
                                    .instance => |i| self.reg(frame, ops.a).* = i,
                                    .frame_pushed => {},
                                    .err => |e| return .{ .err = e },
                                }
                            } else {
                                self.reg(frame, ops.a).* = result;
                            }
                        },
                        .bytecode => |method_func| {
                            frame.pc += Opcode.SEND_BLOCK.size();
                            if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                            const callee_nregs = method_func.nregs;
                            if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };
                            const callee_base = self.sp;
                            var ri: u16 = 0;
                            while (ri < callee_nregs) : (ri += 1) self.stackAt(callee_base + ri).* = Value.nil;
                            ai = 0;
                            while (ai < argc and ai < callee_nregs) : (ai += 1) {
                                self.stackAt(callee_base + ai).* = saved_args[ai];
                            }
                            self.sp += callee_nregs;
                            self.frames[self.fp] = .{
                                .pc = method_func.bytecode,
                                .func = method_func,
                                .stack_base = callee_base,
                                .nregs = callee_nregs,
                                .frame_id = self.next_frame_id,
                                .self_value = recv,
                                .current_class = cid,
                                .caller_dest_reg = ops.a,
                                .argc = argc,
                                .block_value = block_val,
                            };
                            self.next_frame_id +%= 1;
                            self.fp += 1;
                        },
                    }
                },

                .DEF_MODULE => {
                    const ops = Decode.ab(operands);
                    const syms = frame.func.syms;
                    if (ops.b >= syms.len) return .{ .err = VmError.ConstOutOfBounds };
                    const name_sym = syms[ops.b];

                    if (self.constants.get(name_sym)) |existing| {
                        self.reg(frame, ops.a).* = existing;
                    } else {
                        const new_id = self.class_table.allocClass(name_sym, class.CLASS_OBJECT) orelse
                            return .{ .err = VmError.MethodTableFull };

                        const alloc = self.allocHeapObj(.class, @sizeOf(RClassPayload)) orelse
                            return .{ .err = VmError.HeapExhausted };
                        const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
                        hdr.class_id = class.CLASS_MODULE;
                        const payload: *RClassPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
                        payload.* = .{
                            .name_sym = name_sym,
                            .represented_class_id = new_id,
                            .superclass_id = class.CLASS_OBJECT,
                        };
                        self.constants.set(name_sym, alloc.val) catch
                            return .{ .err = VmError.ConstantTableFull };
                        self.reg(frame, ops.a).* = alloc.val;
                    }
                    frame.pc += Opcode.DEF_MODULE.size();
                },

                .RAISE => {
                    const ra = Decode.a(operands);
                    self.current_exception = self.reg(frame, ra).*;

                    if (self.exception_handler_count > 0) {
                        self.exception_handler_count -= 1;
                        const handler = self.exception_handlers[self.exception_handler_count];
                        // Unwind to the handler's frame
                        self.fp = handler.frame_idx + 1;
                        self.sp = handler.stack_depth;
                        const target_frame = &self.frames[handler.frame_idx];
                        target_frame.pc = handler.rescue_pc;
                        self.reg(target_frame, handler.dest_reg).* = self.current_exception;
                    } else {
                        return .{ .err = VmError.RuntimeError };
                    }
                },

                .EXCEPT => {
                    const ra = Decode.a(operands);
                    self.reg(frame, ra).* = self.current_exception;
                    frame.pc += Opcode.EXCEPT.size();
                },

                .RESCUE => {
                    const ops = Decode.ab(operands);
                    self.reg(frame, ops.a).* = Value.fromBool(!self.current_exception.isNil());
                    frame.pc += Opcode.RESCUE.size();
                },

                .PUSH_HANDLER => {
                    const ops = Decode.as_(operands);
                    if (self.exception_handler_count < MAX_EXCEPTION_HANDLERS) {
                        const base: isize = @intCast(@intFromPtr(frame.pc));
                        const target: usize = @intCast(base + @as(isize, ops.s));
                        self.exception_handlers[self.exception_handler_count] = .{
                            .frame_idx = self.fp - 1,
                            .stack_depth = self.sp,
                            .rescue_pc = @ptrFromInt(target),
                            .dest_reg = ops.a,
                        };
                        self.exception_handler_count += 1;
                    }
                    frame.pc += Opcode.PUSH_HANDLER.size();
                },

                .POP_HANDLER => {
                    if (self.exception_handler_count > 0) {
                        self.exception_handler_count -= 1;
                    }
                    frame.pc += Opcode.POP_HANDLER.size();
                },

                .CLEAR_EXC => {
                    self.current_exception = Value.nil;
                    frame.pc += Opcode.CLEAR_EXC.size();
                },

                .ENTER => {
                    const spec = Decode.w24(operands);
                    const req: u8 = @truncate(spec & 0xFF);
                    if (req > 0 and frame.argc != req)
                        return .{ .err = VmError.ArgumentError };
                    frame.pc += Opcode.ENTER.size();
                },

                .RETURN => {
                    const ra = Decode.a(operands);
                    const raw_result = self.reg(frame, ra).*;
                    const result = if (!frame.pending_new_instance.isNil())
                        frame.pending_new_instance
                    else
                        raw_result;

                    if (frame.kind == .block) {
                        // Non-local return: unwind to owning method frame
                        const owner_id = frame.owner_frame_id;
                        var target_fp: ?u8 = null;
                        var fi: u8 = self.fp;
                        while (fi > 0) {
                            fi -= 1;
                            if (self.frames[fi].frame_id == owner_id and
                                self.frames[fi].kind == .method)
                            {
                                target_fp = fi;
                                break;
                            }
                        }

                        if (target_fp) |tfp| {
                            // Discard exception handlers above target
                            while (self.exception_handler_count > 0 and
                                self.exception_handlers[self.exception_handler_count - 1].frame_idx > tfp)
                            {
                                self.exception_handler_count -= 1;
                            }
                            // Return from the method frame
                            const method_frame = &self.frames[tfp];
                            const dest_reg = method_frame.caller_dest_reg;
                            self.fp = tfp;
                            self.sp = method_frame.stack_base;
                            if (self.fp <= base_fp) return .{ .ok = result };
                            const caller = &self.frames[self.fp - 1];
                            self.reg(caller, dest_reg).* = result;
                        } else {
                            return .{ .err = VmError.LocalJumpError };
                        }
                    } else {
                        // Normal return from method
                        const dest_reg = frame.caller_dest_reg;
                        self.fp -= 1;
                        self.sp = frame.stack_base;
                        if (self.fp <= base_fp) return .{ .ok = result };
                        const caller_frame = &self.frames[self.fp - 1];
                        self.reg(caller_frame, dest_reg).* = result;
                    }
                },

                .STOP => {
                    return .{ .ok = Value.nil };
                },

                .BREAK => {
                    const ra = Decode.a(operands);
                    self.break_value = self.reg(frame, ra).*;
                    self.break_pending = true;
                    // Return nil from the current block frame. The
                    // outer native that invoked via yieldBlock will
                    // observe `break_pending` after the run returns
                    // and use `break_value` as its own return.
                    const dest_reg = frame.caller_dest_reg;
                    self.fp -= 1;
                    self.sp = frame.stack_base;
                    if (self.fp <= base_fp) return .{ .ok = Value.nil };
                    const caller_frame = &self.frames[self.fp - 1];
                    self.reg(caller_frame, dest_reg).* = Value.nil;
                },

                else => {
                    return .{ .err = VmError.InvalidOpcode };
                },
            }
        }
    }

    /// Access a register by index relative to the current frame.
    /// Stack grows downward from arena top.
    inline fn reg(self: *VM, frame: *const CallFrame, index: u8) *Value {
        return self.stackAt(frame.stack_base + index);
    }

    /// Access a stack slot by absolute index. Slot 0 is at the top of the
    /// arena, slot N is N*sizeof(Value) bytes below the top.
    inline fn stackAt(self: *VM, index: anytype) *Value {
        const idx: usize = @intCast(index);
        return &(self.stack_top - (idx + 1))[0];
    }

    /// Check if pushing `nregs` more Values would collide with the heap.
    inline fn stackHasRoom(self: *const VM, nregs: u16) bool {
        const stack_bottom_after = @intFromPtr(self.stack_top) - (@as(usize, self.sp) + nregs) * @sizeOf(Value);
        const heap_top = @intFromPtr(self.heap.buf.ptr) + self.heap.pos;
        return stack_bottom_after >= heap_top;
    }

    /// Outcome of dispatching `initialize` after `Class#new` allocates
    /// the instance. Three-way split because a bytecode init pushes a
    /// frame (caller must NOT overwrite dest reg — RETURN will) while
    /// a native init completes immediately (dest reg takes the
    /// instance), and either can fail via the native-exception
    /// channel.
    pub const InitResult = union(enum) {
        /// Native init finished (or no init defined). Caller stores
        /// `instance` in the destination register.
        instance: Value,
        /// Bytecode init frame is on the call stack. Its RETURN will
        /// overwrite the destination register with the instance;
        /// caller must leave it alone.
        frame_pushed,
        /// Native init raised. Caller propagates up as
        /// `ExecResult.err`.
        err: VmError,
    };

    /// After nativeClassNew allocates an instance, dispatch
    /// `initialize` if defined. See `InitResult` for outcomes.
    fn dispatchInitialize(
        self: *VM,
        instance: Value,
        args: []const Value,
        dest_reg: u8,
    ) InitResult {
        const init_sym = self.sym_initialize orelse return .{ .instance = instance };
        const cid = self.class_table.classOfVM(self, instance);
        const method_impl = self.class_table.lookupMethod(cid, init_sym) orelse
            return .{ .instance = instance };

        switch (method_impl) {
            .native => |native_fn| {
                return switch (self.invokeNative(native_fn, instance, args, null)) {
                    .ok => .{ .instance = instance },
                    .err => |e| .{ .err = e },
                };
            },
            .bytecode => |init_func| {
                if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                const callee_nregs = init_func.nregs;
                if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };

                const callee_base = self.sp;
                var ri: u16 = 0;
                while (ri < callee_nregs) : (ri += 1) {
                    self.stackAt(callee_base + ri).* = Value.nil;
                }
                var ai: u8 = 0;
                while (ai < args.len and ai < callee_nregs) : (ai += 1) {
                    self.stackAt(callee_base + ai).* = args[ai];
                }

                self.sp += callee_nregs;
                self.frames[self.fp] = .{
                    .pc = init_func.bytecode,
                    .func = init_func,
                    .stack_base = callee_base,
                    .nregs = callee_nregs,
                    .frame_id = self.next_frame_id,
                    .self_value = instance,
                    .current_class = cid,
                    .caller_dest_reg = dest_reg,
                    .argc = @intCast(args.len),
                    .pending_new_instance = instance,
                };
                self.next_frame_id +%= 1;
                self.fp += 1;
                return .frame_pushed;
            },
        }
    }

    pub const GcStats = struct {
        collections: u32 = 0,
        bytes_before: u32 = 0,
        bytes_after: u32 = 0,
        bytes_reclaimed: u32 = 0,
        live_objects: u16 = 0,
    };

    /// Run a full GC cycle: mark reachable objects, compact heap, update registry.
    /// Values are stable (registry indices), so only obj_registry.raw_ptr changes.
    /// Forwarding is O(n) via a pre-built reverse map from heap address to registry index.
    pub fn gc(self: *VM) void {
        self.markRoots();

        const bytes_before = self.heap.usedBytes();
        const base = self.heap.basePtr();
        const heap_base_addr = @intFromPtr(base);

        // Build reverse map: heap address -> registry index (O(registry_count))
        const ReverseEntry = struct { addr: usize, idx: u16 };
        var reverse: [MAX_OBJ_REGISTRY]ReverseEntry = undefined;
        var reverse_count: u16 = 0;
        {
            var ri: u16 = 0;
            while (ri < self.obj_registry_count) : (ri += 1) {
                if (self.obj_registry[ri].raw_ptr) |rp| {
                    reverse[reverse_count] = .{ .addr = @intFromPtr(rp), .idx = ri };
                    reverse_count += 1;
                }
            }
        }

        // Sort reverse map by address for O(n) merge with heap walk
        std.mem.sort(ReverseEntry, reverse[0..reverse_count], {}, struct {
            fn cmp(_: void, a: ReverseEntry, b: ReverseEntry) bool {
                return a.addr < b.addr;
            }
        }.cmp);

        // Merge walk: heap objects and sorted registry entries are both in
        // address order, so each match is O(1) — total is O(n + m).
        const Forward = struct { slot_idx: u16, new_offset: u32 };
        var forwards: [MAX_OBJ_REGISTRY]Forward = undefined;
        var forward_count: u16 = 0;
        var write: u32 = 0;
        var read: u32 = 0;
        var rev_cursor: u16 = 0;

        while (read < self.heap.pos) {
            const ptr = base + read;
            const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
            const obj_bytes = @as(u32, hdr.size_words) * 4;
            std.debug.assert(obj_bytes >= @sizeOf(ObjHeader));
            std.debug.assert(read + obj_bytes <= self.heap.pos);

            if (hdr.mark == 1) {
                const target_addr = heap_base_addr + read;
                // Advance reverse cursor to match (both in address order)
                while (rev_cursor < reverse_count and
                    reverse[rev_cursor].addr < target_addr)
                {
                    rev_cursor += 1;
                }
                if (rev_cursor < reverse_count and
                    reverse[rev_cursor].addr == target_addr)
                {
                    std.debug.assert(forward_count < MAX_OBJ_REGISTRY);
                    forwards[forward_count] = .{
                        .slot_idx = reverse[rev_cursor].idx,
                        .new_offset = write,
                    };
                    forward_count += 1;
                    rev_cursor += 1;
                }
                write += obj_bytes;
            }
            read += obj_bytes;
        }

        _ = self.heap.compact();

        // Tombstone all registry entries, then restore live ones
        var idx: u16 = 0;
        while (idx < self.obj_registry_count) : (idx += 1) {
            self.obj_registry[idx].raw_ptr = null;
        }
        var i: u16 = 0;
        while (i < forward_count) : (i += 1) {
            const f = forwards[i];
            self.obj_registry[f.slot_idx].raw_ptr = base + f.new_offset;
        }

        self.validateRegistry();

        // Update telemetry
        self.gc_stats.collections += 1;
        self.gc_stats.bytes_before = bytes_before;
        self.gc_stats.bytes_after = self.heap.usedBytes();
        self.gc_stats.bytes_reclaimed = bytes_before - self.gc_stats.bytes_after;
        self.gc_stats.live_objects = forward_count;
    }

    /// Debug: verify all live registry entries point into valid heap range.
    fn validateRegistry(self: *const VM) void {
        const base = @intFromPtr(self.heap.basePtr());
        const heap_end = base + self.heap.pos;
        var i: u16 = 0;
        while (i < self.obj_registry_count) : (i += 1) {
            if (self.obj_registry[i].raw_ptr) |rp| {
                const p = @intFromPtr(rp);
                std.debug.assert(p >= base and p < heap_end);
                const hdr: *const ObjHeader = @ptrCast(@alignCast(rp));
                const obj_bytes = @as(u32, hdr.size_words) * 4;
                std.debug.assert(obj_bytes >= @sizeOf(ObjHeader));
                std.debug.assert(p + obj_bytes <= heap_end);
            }
        }
    }


    fn markRoots(self: *VM) void {
        // Mark values on the stack
        var i: u16 = 0;
        while (i < self.sp) : (i += 1) {
            self.markValue(self.stackAt(i).*);
        }

        // Mark values in call frames
        var fi: u8 = 0;
        while (fi < self.fp) : (fi += 1) {
            self.markValue(self.frames[fi].self_value);
            self.markValue(self.frames[fi].block_value);
            self.markValue(self.frames[fi].pending_new_instance);
        }

        // Mark constants
        for (self.constants.entries[0..self.constants.count]) |*e| {
            if (e.used) self.markValue(e.value);
        }

        // Mark globals
        for (self.globals.entries[0..self.globals.count]) |*e| {
            if (e.used) self.markValue(e.value);
        }

        // Mark current exception
        self.markValue(self.current_exception);
    }

    /// Mark a Value's heap object and all objects reachable from it.
    /// The mark stack lives in the arena gap between heap and value stack —
    /// no Zig call stack space consumed. Capacity scales with free heap space.
    fn markValue(self: *VM, v: Value) void {
        // Mark stack lives in the gap between heap top and stack bottom.
        const gap_start = self.heap.buf.ptr + self.heap.pos;
        const stack_bottom = @intFromPtr(self.stack_top) - @as(usize, self.sp) * @sizeOf(Value);
        const gap_bytes = stack_bottom - @intFromPtr(gap_start);
        const mark_cap: u32 = @intCast(gap_bytes / @sizeOf(Value));
        if (mark_cap == 0) return;

        const mark_stack: [*]Value = @ptrCast(@alignCast(gap_start));
        var msp: u32 = 0;

        self.markOne(v, mark_stack, mark_cap, &msp);
        while (msp > 0) {
            msp -= 1;
            self.markOne(mark_stack[msp], mark_stack, mark_cap, &msp);
        }
    }

    fn markOne(self: *VM, v: Value, ms: [*]Value, cap: u32, sp: *u32) void {
        const ptr = self.getObjPtr(v) orelse return;
        const hdr: *ObjHeader = @ptrCast(@alignCast(ptr));
        if (hdr.mark == 1) return;
        Heap.markObj(ptr);

        switch (hdr.obj_type) {
            .instance => {
                const ivar_ptr: [*]Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                for (0..heap_mod.MAX_IVARS_PER_INSTANCE) |j| {
                    self.pushMark(ivar_ptr[j], ms, cap, sp);
                }
            },
            .array => {
                const arr: *const RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const elements: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RArrayPayload)));
                for (0..arr.len) |j| {
                    self.pushMark(elements[j], ms, cap, sp);
                }
            },
            .hash => {
                const h: *const RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RHashPayload)));
                const n: usize = @as(usize, h.count) * 2;
                for (0..n) |j| {
                    self.pushMark(data[j], ms, cap, sp);
                }
            },
            .range => {
                const bounds: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RRangePayload)));
                self.pushMark(bounds[0], ms, cap, sp);
                self.pushMark(bounds[1], ms, cap, sp);
            },
            .class => {},
            .string, .float, .method, .proc, .env => {},
        }
    }

    inline fn pushMark(self: *VM, v: Value, ms: [*]Value, cap: u32, sp: *u32) void {
        if (self.getObjPtr(v)) |ptr| {
            const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
            if (hdr.mark == 0) {
                if (sp.* >= cap) @panic("GC mark stack overflow");
                ms[sp.*] = v;
                sp.* += 1;
            }
        }
    }

    /// Result of a fast-path fixnum binary op.
    const FixnumResult = union(enum) { ok: Value, err: VmError };

    /// Execute the fast-path fixnum arithmetic/comparison op. Assumes both
    /// operands are genuine immediate fixnums (caller must verify).
    fn doFixnumBinOp(opcode: Opcode, lhs: Value, rhs: Value) FixnumResult {
        switch (opcode) {
            .ADD => {
                if (lhs.addFixnum(rhs)) |v| return .{ .ok = v };
                return .{ .err = VmError.TypeError };
            },
            .SUB => {
                if (lhs.subFixnum(rhs)) |v| return .{ .ok = v };
                return .{ .err = VmError.TypeError };
            },
            .MUL => {
                if (lhs.mulFixnum(rhs)) |v| return .{ .ok = v };
                return .{ .err = VmError.TypeError };
            },
            .DIV => {
                const la = lhs.asFixnum() orelse return .{ .err = VmError.TypeError };
                const rb = rhs.asFixnum() orelse return .{ .err = VmError.TypeError };
                if (rb == 0) return .{ .err = VmError.DivisionByZero };
                return .{ .ok = Value.fromFixnumUnchecked(@divFloor(la, rb)) };
            },
            .MOD => {
                const la = lhs.asFixnum() orelse return .{ .err = VmError.TypeError };
                const rb = rhs.asFixnum() orelse return .{ .err = VmError.TypeError };
                if (rb == 0) return .{ .err = VmError.DivisionByZero };
                return .{ .ok = Value.fromFixnumUnchecked(@mod(la, rb)) };
            },
            .LT => if (lhs.ltFixnum(rhs)) |v| return .{ .ok = v } else return .{ .err = VmError.TypeError },
            .LE => if (lhs.leFixnum(rhs)) |v| return .{ .ok = v } else return .{ .err = VmError.TypeError },
            .GT => if (lhs.gtFixnum(rhs)) |v| return .{ .ok = v } else return .{ .err = VmError.TypeError },
            .GE => if (lhs.geFixnum(rhs)) |v| return .{ .ok = v } else return .{ .err = VmError.TypeError },
            .EQ => return .{ .ok = Value.fromBool(lhs.eql(rhs)) },
            else => return .{ .err = VmError.TypeError },
        }
    }

    /// Execute the float arithmetic/comparison op. Allocates a new
    /// heap Float for arithmetic results; comparisons return immediate
    /// booleans. Division follows IEEE-754: `1.0/0.0 == Infinity`,
    /// `0.0/0.0 == NaN`, no exception. Modulo is the only numeric op
    /// that still raises on a zero divisor (Ruby's `Float#%` raises
    /// `ZeroDivisionError`), and it uses Ruby's floored-modulo sign
    /// convention — result sign follows the divisor, unlike Zig's
    /// `@mod` which requires a positive divisor.
    fn doFloatBinOp(self: *VM, opcode: Opcode, la: f64, rb: f64) FixnumResult {
        switch (opcode) {
            .ADD => {
                const v = self.allocFloat(la + rb) orelse return .{ .err = VmError.HeapExhausted };
                return .{ .ok = v };
            },
            .SUB => {
                const v = self.allocFloat(la - rb) orelse return .{ .err = VmError.HeapExhausted };
                return .{ .ok = v };
            },
            .MUL => {
                const v = self.allocFloat(la * rb) orelse return .{ .err = VmError.HeapExhausted };
                return .{ .ok = v };
            },
            .DIV => {
                // IEEE-754 semantics: divide-by-zero produces signed
                // infinity (or NaN for 0/0). No VmError — Ruby doesn't
                // raise on float division by zero, so neither do we.
                const v = self.allocFloat(la / rb) orelse return .{ .err = VmError.HeapExhausted };
                return .{ .ok = v };
            },
            .MOD => {
                if (rb == 0.0) return .{ .err = VmError.DivisionByZero };
                const v = self.allocFloat(rubyFloatMod(la, rb)) orelse
                    return .{ .err = VmError.HeapExhausted };
                return .{ .ok = v };
            },
            .EQ => return .{ .ok = Value.fromBool(la == rb) },
            .LT => return .{ .ok = Value.fromBool(la < rb) },
            .LE => return .{ .ok = Value.fromBool(la <= rb) },
            .GT => return .{ .ok = Value.fromBool(la > rb) },
            .GE => return .{ .ok = Value.fromBool(la >= rb) },
            else => return .{ .err = VmError.TypeError },
        }
    }

    /// Ruby's `Float#%` follows the divisor's sign (floored modulo),
    /// whereas C's `fmod` / Zig's `@rem` follows the dividend's. Ruby
    /// doc: `x % y == x - (x / y).floor * y`. We start from `@rem` and
    /// adjust when the sign disagrees with `y`. NaN and infinities
    /// propagate unchanged because `@rem` already returns NaN for
    /// those cases.
    pub fn rubyFloatMod(la: f64, rb: f64) f64 {
        const r = @rem(la, rb);
        if (r != 0.0 and ((r < 0.0) != (rb < 0.0))) return r + rb;
        return r;
    }

    /// Outcome of a native-method call. The wire format of `NativeFn`
    /// is unchanged (returns a `Value`); errors travel through the
    /// sideband `pending_native_error` field and are translated here.
    pub const NativeResult = union(enum) { ok: Value, err: VmError };

    /// Called by native methods that want to raise a VM exception.
    /// Sets the one-shot sideband field and returns `Value.undef` so
    /// the caller can `return vm.raise(.KeyError);` in one line. The
    /// native MUST return immediately after; any subsequent VM
    /// operation before returning would observe the stashed error.
    ///
    /// If a native attempts to raise while a prior error is still
    /// pending (e.g., raising twice, or raising after a yield that
    /// itself raised but wasn't consumed), we `@panic` — this is a
    /// VM-invariant break and silent overwriting in release builds
    /// would degrade into the wrong exception surfacing, which is a
    /// much harder bug to track down than a loud crash. Debug builds
    /// get the same panic via std.debug.assert's RuntimeSafety.
    pub fn raise(self: *VM, err: VmError) Value {
        if (self.pending_native_error != null) {
            @panic("VM.raise called with a pending_native_error already set");
        }
        self.pending_native_error = err;
        return Value.undef;
    }

    /// Invoke a native method. Centralizes the `pending_native_error`
    /// sideband protocol: checks that no stale error is present
    /// before the call, invokes the native, and translates either
    /// the returned value or the raised error into a `NativeResult`
    /// for the caller to unwrap. Every native-method call site goes
    /// through here. Same release-safe panic policy as `raise`.
    pub fn invokeNative(
        self: *VM,
        native_fn: class.NativeFn,
        recv: Value,
        args: []const Value,
        block: ?Value,
    ) NativeResult {
        if (self.pending_native_error != null) {
            @panic("VM.invokeNative entered with a pending_native_error already set");
        }
        const result = native_fn(self, recv, args, block);
        if (self.pending_native_error) |e| {
            self.pending_native_error = null;
            return .{ .err = e };
        }
        return .{ .ok = result };
    }

    const DispatchResult = union(enum) { handled, err: VmError };

    /// Dispatch a binary method `R[ra] = R[ra].send(sym_atom, R[ra+1])`.
    /// Shared fallback for the ADD/SUB/.../GE opcodes when either operand
    /// is non-fixnum. `caller_size` is the size of the calling opcode so
    /// the caller's pc can be advanced correctly when dispatch returns.
    fn dispatchBinMethod(self: *VM, frame: *CallFrame, ra: u8, sym_atom: u16, caller_size: u8) DispatchResult {
        const recv = self.reg(frame, ra).*;
        const arg = self.reg(frame, ra + 1).*;
        const cid = self.class_table.classOfVM(self, recv);
        const method_impl = self.class_table.lookupMethod(cid, sym_atom) orelse
            return .{ .err = VmError.NoMethodError };

        switch (method_impl) {
            .native => |native_fn| {
                const args = [_]Value{arg};
                const result = switch (self.invokeNative(native_fn, recv, args[0..1], null)) {
                    .ok => |v| v,
                    .err => |e| return .{ .err = e },
                };
                self.reg(frame, ra).* = result;
                frame.pc += caller_size;
                return .handled;
            },
            .bytecode => |method_func| {
                frame.pc += caller_size;
                if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
                const callee_nregs = method_func.nregs;
                if (!self.stackHasRoom(callee_nregs)) return .{ .err = VmError.StackOverflow };

                const saved_arg = arg;
                const callee_base = self.sp;
                var ri: u16 = 0;
                while (ri < callee_nregs) : (ri += 1) {
                    self.stackAt(callee_base + ri).* = Value.nil;
                }
                if (callee_nregs > 0) self.stackAt(callee_base).* = saved_arg;

                self.sp += callee_nregs;
                const callee_frame = &self.frames[self.fp];
                callee_frame.* = .{
                    .pc = method_func.bytecode,
                    .func = method_func,
                    .stack_base = callee_base,
                    .nregs = callee_nregs,
                    .frame_id = self.next_frame_id,
                    .self_value = recv,
                    .current_class = cid,
                    .caller_dest_reg = ra,
                    .argc = 1,
                };
                self.next_frame_id +%= 1;
                self.fp += 1;
                return .handled;
            },
        }
    }

    /// Invoke a block (produced by the BLOCK opcode) synchronously from
    /// inside a native method. `block` must be the Value passed to the
    /// native as its `block: ?Value` parameter; it is a register-index
    /// encoded reference to a method-registry entry holding the block's
    /// IrFunc. Arguments populate the block's leading registers; the
    /// return value is the block's last-evaluated expression.
    ///
    /// Implementation: reentrantly calls `execute()` on the block's
    /// IrFunc. The outer `execute` frame is preserved on the VM stack
    /// while the nested one runs; on return, the outer loop picks up
    /// where it left off.
    /// Map a VM error name to a stable symbol id for use as the value
    /// bound to `rescue => e`. Uses a direct hash from the error name
    /// into the high end of the symbol space (well outside the range
    /// the compiler allocates for user-defined symbols), so error
    /// symbols never collide with program-interned ones even when the
    /// program never mentions the error's name.
    fn errorSym(_: *const VM, name: []const u8) u29 {
        // Tiny FNV-1a 32-bit; more than enough to keep the handful of
        // VmError names distinct from each other and from low-range
        // compiler-assigned symbol ids.
        var h: u32 = 2166136261;
        for (name) |b| {
            h ^= b;
            h *%= 16777619;
        }
        // Clamp into the safe symbol range. 0x1FFF_FFFF = u29 max.
        return @intCast((h | 0x1000_0000) & 0x1FFF_FFFF);
    }

    /// If a `break val` ran during the most recent `yieldBlock` call,
    /// clear the flag and return `val`. Otherwise return null. Natives
    /// that iterate via yieldBlock call this after each yield and, on
    /// a non-null return, stop iterating and propagate the value as
    /// their own result.
    pub fn consumeBreak(self: *VM) ?Value {
        if (!self.break_pending) return null;
        self.break_pending = false;
        const v = self.break_value;
        self.break_value = Value.nil;
        return v;
    }

    pub fn yieldBlock(self: *VM, block: Value, args: []const Value) ?Value {
        const func_ptr = self.lookupRegisteredFunc(block) orelse return null;
        if (func_ptr.nregs < args.len) return null;

        const result = self.executeWithArgs(func_ptr, args);
        return switch (result) {
            .ok => |v| v,
            .err => |e| blk: {
                // Block raised. Route the error through the
                // native-exception sideband so the iterator native's
                // outer `invokeNative` sees it and converts back to
                // `ExecResult.err`. Pre-fix we just returned `null`
                // here, which iterator natives interpret as "stop"
                // and swallow the exception — catching `break` but
                // silently eating e.g. `h.fetch(:missing)`.
                //
                // Invariant: inner dispatch consumed any prior raise
                // state before unwinding here. Panic rather than
                // silently overwrite in release builds — same rule
                // as `raise` / `invokeNative`.
                if (self.pending_native_error != null) {
                    @panic("yieldBlock observed block-raised error with pending_native_error already set");
                }
                self.pending_native_error = e;
                break :blk null;
            },
        };
    }

    /// Like `execute`, but pre-populates the new frame's leading registers
    /// from `args` and re-enters the interpreter loop at the current
    /// frame depth so it returns when just this frame pops. Used by
    /// `yieldBlock` to invoke a block from inside a native call.
    fn executeWithArgs(self: *VM, func: *const IrFunc, args: []const Value) ExecResult {
        if (self.fp >= MAX_FRAMES) return .{ .err = VmError.StackOverflow };
        if (!self.stackHasRoom(func.nregs)) return .{ .err = VmError.StackOverflow };

        const saved_fp = self.fp;
        const base = self.sp;
        self.sp += func.nregs;

        var i: u16 = 0;
        while (i < func.nregs) : (i += 1) {
            self.stackAt(base + i).* = Value.nil;
        }
        var ai: usize = 0;
        while (ai < args.len and ai < func.nregs) : (ai += 1) {
            self.stackAt(base + ai).* = args[ai];
        }

        self.frames[self.fp] = .{
            .pc = func.bytecode,
            .func = func,
            .stack_base = base,
            .nregs = func.nregs,
            .frame_id = self.next_frame_id,
            .self_value = Value.nil,
            .current_class = class.CLASS_OBJECT,
            .argc = @intCast(@min(args.len, 255)),
        };
        self.next_frame_id +%= 1;
        self.fp += 1;

        return self.run(saved_fp);
    }

    /// Extract string data from a heap string Value.
    pub fn getStringData(self: *const VM, v: Value) ?[]const u8 {
        const ptr = self.getObjPtr(v) orelse return null;
        const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
        if (hdr.obj_type != .string) return null;
        const str_payload: *const RStringPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
        const data: [*]const u8 = ptr + @sizeOf(ObjHeader) + @sizeOf(RStringPayload);
        return data[0..str_payload.len];
    }

    /// Extract the f64 value from a heap Float, or null for any other kind.
    pub fn getFloatData(self: *const VM, v: Value) ?f64 {
        const ptr = self.getObjPtr(v) orelse return null;
        const hdr: *const ObjHeader = @ptrCast(@alignCast(ptr));
        if (hdr.obj_type != .float) return null;
        const fp: *const RFloatPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
        return fp.get();
    }

    /// Allocate a heap Float containing `f`. GC-driven retry is handled
    /// inside `allocHeapObj`. Returns null only when the heap is
    /// completely exhausted or the obj registry is full.
    pub fn allocFloat(self: *VM, f: f64) ?Value {
        const alloc = self.allocHeapObj(.float, @sizeOf(RFloatPayload)) orelse return null;
        const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
        hdr.class_id = class.CLASS_FLOAT;
        const fp: *RFloatPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
        fp.set(f);
        return alloc.val;
    }

    /// Coerce `v` to f64 if it is numerically inhabited — a genuine
    /// immediate fixnum or a heap Float. Returns null for everything
    /// else (strings, nil, symbols, arrays, …) so the caller can fall
    /// through to method dispatch.
    pub fn toFloat(self: *const VM, v: Value) ?f64 {
        if (self.getObjHeader(v)) |hdr| {
            if (hdr.obj_type == .float) {
                const ptr = self.getObjPtr(v).?;
                const fp: *const RFloatPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                return fp.get();
            }
            return null;
        }
        if (v.asFixnum()) |n| return @floatFromInt(n);
        return null;
    }

    /// Format a Value in IRB-like inspect form (strings quoted, arrays
    /// bracketed, hashes braced, etc.). Heap recursion is depth-limited
    /// so cyclic or deeply nested values degrade gracefully.
    pub fn inspect(self: *const VM, w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
        return self.inspectDepth(w, v, 0);
    }

    /// Format an f64 in Ruby-style into `buf` and return the slice.
    /// Whole numbers keep a trailing `.0`; non-finite values mirror MRI
    /// (`Infinity` / `-Infinity` / `NaN`). Delegates to Zig's `{d}`
    /// formatter (shortest-roundtrip decimal), so `0.1 + 0.2` becomes
    /// `"0.30000000000000004"`. Returns null if `buf` is too small.
    pub fn formatFloatBuf(buf: []u8, f: f64) ?[]const u8 {
        if (std.math.isNan(f)) {
            if (buf.len < 3) return null;
            @memcpy(buf[0..3], "NaN");
            return buf[0..3];
        }
        if (std.math.isInf(f)) {
            const s: []const u8 = if (f < 0) "-Infinity" else "Infinity";
            if (buf.len < s.len) return null;
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        }
        const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch return null;
        var has_dot = false;
        var has_exp = false;
        for (s) |ch| {
            if (ch == '.') has_dot = true;
            if (ch == 'e' or ch == 'E') has_exp = true;
        }
        if (has_dot or has_exp) return s;
        if (s.len + 2 > buf.len) return null;
        buf[s.len] = '.';
        buf[s.len + 1] = '0';
        return buf[0 .. s.len + 2];
    }

    /// Write an f64 through a std.Io.Writer using the Ruby-style
    /// formatter above. Convenience wrapper for `inspect`.
    pub fn writeFloat(w: *std.Io.Writer, f: f64) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        const s = formatFloatBuf(&buf, f) orelse return w.print("{d}", .{f});
        try w.writeAll(s);
    }

    const max_inspect_depth: u8 = 8;

    fn inspectDepth(self: *const VM, w: *std.Io.Writer, v: Value, depth: u8) std.Io.Writer.Error!void {
        if (v.isNil()) return w.writeAll("nil");
        if (v.isTrue()) return w.writeAll("true");
        if (v.isFalse()) return w.writeAll("false");
        if (v.asSymbolId()) |id| return w.print(":sym_{d}", .{id});

        // Heap objects are encoded as negative fixnums (via obj_registry
        // indirection), so resolve heap BEFORE checking for genuine fixnums.
        if (self.getObjHeader(v)) |hdr| {
            if (depth >= max_inspect_depth) return w.print("#<{s}:...>", .{@tagName(hdr.obj_type)});
            return self.inspectHeap(w, v, hdr, depth);
        }

        if (v.asFixnum()) |n| return w.print("{d}", .{n});
        return w.print("<0x{x:0>8}>", .{v.raw});
    }

    fn inspectHeap(self: *const VM, w: *std.Io.Writer, v: Value, hdr: *ObjHeader, depth: u8) std.Io.Writer.Error!void {
        const ptr = self.getObjPtr(v).?;
        switch (hdr.obj_type) {
            .string => {
                const sp: *const RStringPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const data: [*]const u8 = ptr + @sizeOf(ObjHeader) + @sizeOf(RStringPayload);
                try w.print("\"{s}\"", .{data[0..sp.len]});
            },
            .float => {
                const fp: *const RFloatPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                try writeFloat(w, fp.get());
            },
            .array => {
                const ap: *const RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RArrayPayload)));
                try w.writeAll("[");
                var i: u16 = 0;
                while (i < ap.len) : (i += 1) {
                    if (i > 0) try w.writeAll(", ");
                    try self.inspectDepth(w, elems[i], depth + 1);
                }
                try w.writeAll("]");
            },
            .hash => {
                const hp: *const RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RHashPayload)));
                try w.writeAll("{");
                var i: u16 = 0;
                while (i < hp.count) : (i += 1) {
                    if (i > 0) try w.writeAll(", ");
                    try self.inspectDepth(w, data[i * 2], depth + 1);
                    try w.writeAll("=>");
                    try self.inspectDepth(w, data[i * 2 + 1], depth + 1);
                }
                try w.writeAll("}");
            },
            .range => {
                const rp: *const RRangePayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                const bounds: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(RRangePayload)));
                try self.inspectDepth(w, bounds[0], depth + 1);
                try w.writeAll(if (rp.exclusive != 0) "..." else "..");
                try self.inspectDepth(w, bounds[1], depth + 1);
            },
            .class => {
                const cp: *const RClassPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
                try w.print("#<Class:sym_{d}>", .{cp.name_sym});
            },
            .instance => try w.print("#<Object:0x{x:0>8}>", .{v.raw}),
            .method, .proc, .env => try w.print("#<{s}:0x{x:0>8}>", .{ @tagName(hdr.obj_type), v.raw }),
        }
    }
};

// ═════════════════════════════════════════════════════════════════════
// Tests
// ═════════════════════════════════════════════════════════════════════

const Asm = @import("assembler.zig").Assembler;

test "LOAD_CONST and RETURN" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(55).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 55), result.ok.asFixnum().?);
}

test "MOVE" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(77).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.MOVE, 1, 0);
    a.emitA(.RETURN, 1);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 77), result.ok.asFixnum().?);
}

test "ADD: 40 + 2 = 42" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(40).?);
    const k1 = a.addConst(Value.fromFixnum(2).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.LOAD_CONST, 1, k1);
    a.emitA(.ADD, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 42), result.ok.asFixnum().?);
}

test "SUB: 10 - 3 = 7" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(10).?);
    const k1 = a.addConst(Value.fromFixnum(3).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.LOAD_CONST, 1, k1);
    a.emitA(.SUB, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 7), result.ok.asFixnum().?);
}

test "MUL: 6 * 8 = 48" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(6).?);
    const k1 = a.addConst(Value.fromFixnum(8).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.LOAD_CONST, 1, k1);
    a.emitA(.MUL, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 48), result.ok.asFixnum().?);
}

test "DIV: 10 / 3 = 3 (floor)" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(10).?);
    const k1 = a.addConst(Value.fromFixnum(3).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.LOAD_CONST, 1, k1);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 3), result.ok.asFixnum().?);
}

test "DIV: -7 / 2 = -4 (Ruby floor division)" {
    var a = Asm.init();
    const k0 = a.addConst(Value.fromFixnum(-7).?);
    const k1 = a.addConst(Value.fromFixnum(2).?);
    a.emitAB(.LOAD_CONST, 0, k0);
    a.emitAB(.LOAD_CONST, 1, k1);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, -4), result.ok.asFixnum().?);
}

test "EQ: 5 == 5 is true, 5 == 3 is false" {
    var a = Asm.init();
    const k5 = a.addConst(Value.fromFixnum(5).?);
    a.emitAB(.LOAD_CONST, 0, k5);
    a.emitAB(.LOAD_CONST, 1, k5);
    a.emitA(.EQ, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expect(result.ok.isTrue());
}

test "LT: 3 < 5 is true" {
    var a = Asm.init();
    const k3 = a.addConst(Value.fromFixnum(3).?);
    const k5 = a.addConst(Value.fromFixnum(5).?);
    a.emitAB(.LOAD_CONST, 0, k3);
    a.emitAB(.LOAD_CONST, 1, k5);
    a.emitA(.LT, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expect(result.ok.isTrue());
}

test "LOAD_I8: small immediate integer" {
    var a = Asm.init();
    a.emitAB(.LOAD_I8, 0, @bitCast(@as(i8, -5)));
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, -5), result.ok.asFixnum().?);
}

test "LOAD_NIL, LOAD_TRUE, LOAD_FALSE" {
    var a = Asm.init();
    a.emitA(.LOAD_NIL, 0);
    a.emitA(.RETURN, 0);
    const f1 = a.build(1);

    var vm = VM.initDefault();
    try std.testing.expect(vm.execute(&f1).ok.isNil());

    var a2 = Asm.init();
    a2.emitA(.LOAD_TRUE, 0);
    a2.emitA(.RETURN, 0);
    const f2 = a2.build(1);
    try std.testing.expect(vm.execute(&f2).ok.isTrue());

    var a3 = Asm.init();
    a3.emitA(.LOAD_FALSE, 0);
    a3.emitA(.RETURN, 0);
    const f3 = a3.build(1);
    try std.testing.expect(vm.execute(&f3).ok.isFalse());
}

test "JMP_NOT: branch on false" {
    // if (false) then 1 else 2 end
    var a = Asm.init();
    const k1 = a.addConst(Value.fromFixnum(1).?);
    const k2 = a.addConst(Value.fromFixnum(2).?);
    a.emitA(.LOAD_FALSE, 0); // r0 = false
    // JMP_NOT r0, +6 (skip over load_const + return = 3+2=5... need to count bytes)
    // LOAD_FALSE=2, JMP_NOT=4, LOAD_CONST=3, RETURN=2, LOAD_CONST=3, RETURN=2
    // JMP_NOT at offset 2, we want to skip to LOAD_CONST k2 at offset 2+4+3+2=11
    // so relative offset from JMP_NOT position = 11-2 = 9
    a.emitAS(.JMP_NOT, 0, 9); // if falsy, jump +9 from current pc
    a.emitAB(.LOAD_CONST, 0, k1); // then: r0 = 1
    a.emitA(.RETURN, 0); // return 1
    a.emitAB(.LOAD_CONST, 0, k2); // else: r0 = 2
    a.emitA(.RETURN, 0); // return 2
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 2), result.ok.asFixnum().?);
}

test "JMP_NOT: no branch on true" {
    // if (true) then 1 else 2 end
    var a = Asm.init();
    const k1 = a.addConst(Value.fromFixnum(1).?);
    const k2 = a.addConst(Value.fromFixnum(2).?);
    a.emitA(.LOAD_TRUE, 0);
    a.emitAS(.JMP_NOT, 0, 9);
    a.emitAB(.LOAD_CONST, 0, k1);
    a.emitA(.RETURN, 0);
    a.emitAB(.LOAD_CONST, 0, k2);
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 1), result.ok.asFixnum().?);
}

test "TypeError on ADD with non-fixnum" {
    var a = Asm.init();
    a.emitA(.LOAD_TRUE, 0);
    a.emitAB(.LOAD_I8, 1, 1);
    a.emitA(.ADD, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    // Non-fixnum operand in ADD now falls back to method dispatch; with no
    // `TrueClass#+` method defined, the fallback surfaces NoMethodError.
    try std.testing.expectEqual(VmError.NoMethodError, result.err);
}

test "STOP returns nil" {
    var a = Asm.init();
    a.emitZ(.STOP);
    const func = a.build(0);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expect(result.ok.isNil());
}

// ── Hardening tests ──────────────────────────────────────────────────

test "bad const index returns error" {
    var a = Asm.init();
    a.emitAB(.LOAD_CONST, 0, 99); // no constant at index 99
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.ConstOutOfBounds, result.err);
}

test "empty constant pool with LOAD_CONST" {
    var a = Asm.init();
    a.emitAB(.LOAD_CONST, 0, 0); // pool is empty
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.ConstOutOfBounds, result.err);
}

test "code falls off end returns error" {
    var a = Asm.init();
    a.emitZ(.NOP); // no RETURN or STOP
    const func = a.build(0);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.InvalidOpcode, result.err);
}

test "unknown opcode returns error" {
    var a = Asm.init();
    a.code[0] = 0xFF; // not a valid opcode
    a.code_len = 1;
    const func = a.build(0);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.InvalidOpcode, result.err);
}

test "DIV: negative dividend, Ruby floor division" {
    var a = Asm.init();
    // -7 / 3 = -3 (Ruby floor), not -2 (C truncation)
    const kn7 = a.addConst(Value.fromFixnum(-7).?);
    const k3 = a.addConst(Value.fromFixnum(3).?);
    a.emitAB(.LOAD_CONST, 0, kn7);
    a.emitAB(.LOAD_CONST, 1, k3);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    try std.testing.expectEqual(@as(i32, -3), vm.execute(&func).ok.asFixnum().?);
}

test "DIV: negative divisor, Ruby floor division" {
    var a = Asm.init();
    // 7 / -3 = -3 (Ruby floor)
    const k7 = a.addConst(Value.fromFixnum(7).?);
    const kn3 = a.addConst(Value.fromFixnum(-3).?);
    a.emitAB(.LOAD_CONST, 0, k7);
    a.emitAB(.LOAD_CONST, 1, kn3);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    try std.testing.expectEqual(@as(i32, -3), vm.execute(&func).ok.asFixnum().?);
}

test "DIV: both negative, Ruby floor division" {
    var a = Asm.init();
    // -7 / -3 = 2 (Ruby floor)
    const kn7 = a.addConst(Value.fromFixnum(-7).?);
    const kn3 = a.addConst(Value.fromFixnum(-3).?);
    a.emitAB(.LOAD_CONST, 0, kn7);
    a.emitAB(.LOAD_CONST, 1, kn3);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    try std.testing.expectEqual(@as(i32, 2), vm.execute(&func).ok.asFixnum().?);
}

test "DIV by zero returns error" {
    var a = Asm.init();
    const k1 = a.addConst(Value.fromFixnum(1).?);
    const k0 = a.addConst(Value.fromFixnum(0).?);
    a.emitAB(.LOAD_CONST, 0, k1);
    a.emitAB(.LOAD_CONST, 1, k0);
    a.emitA(.DIV, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    try std.testing.expectEqual(VmError.DivisionByZero, vm.execute(&func).err);
}

test "MOD: Ruby sign-of-divisor semantics" {
    var vm = VM.initDefault();

    // -7 % 3 = 2 (Ruby: sign of divisor)
    {
        var a = Asm.init();
        const kn7 = a.addConst(Value.fromFixnum(-7).?);
        const k3 = a.addConst(Value.fromFixnum(3).?);
        a.emitAB(.LOAD_CONST, 0, kn7);
        a.emitAB(.LOAD_CONST, 1, k3);
        a.emitA(.MOD, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expectEqual(@as(i32, 2), vm.execute(&func).ok.asFixnum().?);
    }

    // 7 % -3 = -2 (Ruby: sign of divisor)
    {
        var a = Asm.init();
        const k7 = a.addConst(Value.fromFixnum(7).?);
        const kn3 = a.addConst(Value.fromFixnum(-3).?);
        a.emitAB(.LOAD_CONST, 0, k7);
        a.emitAB(.LOAD_CONST, 1, kn3);
        a.emitA(.MOD, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expectEqual(@as(i32, -2), vm.execute(&func).ok.asFixnum().?);
    }

    // -7 % -3 = -1 (Ruby: sign of divisor)
    {
        var a = Asm.init();
        const kn7 = a.addConst(Value.fromFixnum(-7).?);
        const kn3 = a.addConst(Value.fromFixnum(-3).?);
        a.emitAB(.LOAD_CONST, 0, kn7);
        a.emitAB(.LOAD_CONST, 1, kn3);
        a.emitA(.MOD, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expectEqual(@as(i32, -1), vm.execute(&func).ok.asFixnum().?);
    }
}

test "EQ: nil == nil, true == true, false == false" {
    var vm = VM.initDefault();

    {
        var a = Asm.init();
        a.emitA(.LOAD_NIL, 0);
        a.emitA(.LOAD_NIL, 1);
        a.emitA(.EQ, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isTrue());
    }
    {
        var a = Asm.init();
        a.emitA(.LOAD_TRUE, 0);
        a.emitA(.LOAD_TRUE, 1);
        a.emitA(.EQ, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isTrue());
    }
    {
        var a = Asm.init();
        a.emitA(.LOAD_TRUE, 0);
        a.emitA(.LOAD_FALSE, 1);
        a.emitA(.EQ, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isFalse());
    }
}

test "LOAD_SELF returns frame self_value" {
    var a = Asm.init();
    a.emitA(.LOAD_SELF, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    // Top-level self is nil (not yet set to main object)
    try std.testing.expect(result.ok.isNil());
}

test "JMP forward: skip an instruction" {
    var a = Asm.init();
    // JMP at offset 0 (3 bytes: S format). LOAD_I8 at offset 3 (3 bytes: AB format).
    // We want to skip over the LOAD_I8 99 and land at the LOAD_I8 42 at offset 6.
    // JMP offset is relative to JMP's own position, so offset = 6.
    a.emitS(.JMP, 6);          // offset 0: jump to offset 6
    a.emitAB(.LOAD_I8, 0, 99); // offset 3: skipped
    a.emitAB(.LOAD_I8, 0, 42); // offset 6: landed here
    a.emitA(.RETURN, 0);       // offset 9
    const func = a.build(1);

    var vm = VM.initDefault();
    try std.testing.expectEqual(@as(i32, 42), vm.execute(&func).ok.asFixnum().?);
}

test "JMP_IF: 0 is truthy in Ruby" {
    var a = Asm.init();
    // LOAD_I8=3 bytes, JMP_IF=4 bytes, LOAD_I8=3 bytes, RETURN=2 bytes
    // JMP_IF at offset 3, target LOAD_I8 42 at offset 3+4+3+2=12. Relative = 12-3 = 9.
    a.emitAB(.LOAD_I8, 0, 0); // offset 0: 0 is truthy in Ruby!
    a.emitAS(.JMP_IF, 0, 9);  // offset 3: should jump because 0 is truthy
    a.emitAB(.LOAD_I8, 0, 1); // offset 7: not taken
    a.emitA(.RETURN, 0);      // offset 10
    a.emitAB(.LOAD_I8, 0, 42); // offset 12: jump target
    a.emitA(.RETURN, 0);       // offset 15
    const func = a.build(1);

    var vm = VM.initDefault();
    try std.testing.expectEqual(@as(i32, 42), vm.execute(&func).ok.asFixnum().?);
}

test "LE, GT, GE comparisons" {
    var vm = VM.initDefault();

    // 3 <= 3 = true
    {
        var a = Asm.init();
        const k3 = a.addConst(Value.fromFixnum(3).?);
        a.emitAB(.LOAD_CONST, 0, k3);
        a.emitAB(.LOAD_CONST, 1, k3);
        a.emitA(.LE, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isTrue());
    }
    // 5 > 3 = true
    {
        var a = Asm.init();
        const k5 = a.addConst(Value.fromFixnum(5).?);
        const k3 = a.addConst(Value.fromFixnum(3).?);
        a.emitAB(.LOAD_CONST, 0, k5);
        a.emitAB(.LOAD_CONST, 1, k3);
        a.emitA(.GT, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isTrue());
    }
    // 3 >= 5 = false
    {
        var a = Asm.init();
        const k3 = a.addConst(Value.fromFixnum(3).?);
        const k5 = a.addConst(Value.fromFixnum(5).?);
        a.emitAB(.LOAD_CONST, 0, k3);
        a.emitAB(.LOAD_CONST, 1, k5);
        a.emitA(.GE, 0);
        a.emitA(.RETURN, 0);
        const func = a.build(2);
        try std.testing.expect(vm.execute(&func).ok.isFalse());
    }
}

test "LT on non-fixnum falls back to method dispatch" {
    var a = Asm.init();
    a.emitA(.LOAD_NIL, 0);
    a.emitAB(.LOAD_I8, 1, 1);
    a.emitA(.LT, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    // No `NilClass#<` method is defined, so the fallback dispatch surfaces
    // NoMethodError rather than the old fast-path TypeError.
    try std.testing.expectEqual(VmError.NoMethodError, vm.execute(&func).err);
}

test "MOD by zero returns error" {
    var a = Asm.init();
    const k1 = a.addConst(Value.fromFixnum(1).?);
    const k0 = a.addConst(Value.fromFixnum(0).?);
    a.emitAB(.LOAD_CONST, 0, k1);
    a.emitAB(.LOAD_CONST, 1, k0);
    a.emitA(.MOD, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(2);

    var vm = VM.initDefault();
    try std.testing.expectEqual(VmError.DivisionByZero, vm.execute(&func).err);
}

test "JMP_NIL: branches on nil, not on false" {
    var vm = VM.initDefault();

    // nil triggers jump
    // LOAD_NIL=2, JMP_NIL=4, LOAD_I8=3, RETURN=2
    // JMP_NIL at offset 2, target at 2+4+3+2=11. Relative = 11-2 = 9.
    {
        var a = Asm.init();
        a.emitA(.LOAD_NIL, 0);     // offset 0
        a.emitAS(.JMP_NIL, 0, 9);  // offset 2
        a.emitAB(.LOAD_I8, 0, 1);  // offset 6
        a.emitA(.RETURN, 0);       // offset 9
        a.emitAB(.LOAD_I8, 0, 42); // offset 11
        a.emitA(.RETURN, 0);       // offset 14
        const func = a.build(1);
        try std.testing.expectEqual(@as(i32, 42), vm.execute(&func).ok.asFixnum().?);
    }
    // false does NOT trigger JMP_NIL
    {
        var a = Asm.init();
        a.emitA(.LOAD_FALSE, 0);    // offset 0
        a.emitAS(.JMP_NIL, 0, 9);   // offset 2
        a.emitAB(.LOAD_I8, 0, 1);   // offset 6
        a.emitA(.RETURN, 0);        // offset 9
        a.emitAB(.LOAD_I8, 0, 42);  // offset 11
        a.emitA(.RETURN, 0);        // offset 14
        const func = a.build(1);
        try std.testing.expectEqual(@as(i32, 1), vm.execute(&func).ok.asFixnum().?);
    }
}

// ── Method dispatch tests ────────────────────────────────────────────

test "METHOD + DEF_METHOD + SSEND: def add(a,b); a+b; end; add(20,22) = 42" {
    // Child func: the body of add(a, b) -> a + b
    //   R[0] = a, R[1] = b (passed by caller)
    //   ENTER req=2
    //   ADD R[0]        ; R[0] = R[0] + R[1]
    //   RETURN R[0]
    var child_asm = Asm.init();
    child_asm.emitW(.ENTER, 2); // req=2
    child_asm.emitA(.ADD, 0);
    child_asm.emitA(.RETURN, 0);
    var child_func = child_asm.build(2);

    // Top-level func:
    //   METHOD R[0], child0     ; R[0] = method wrapper for child_func
    //   DEF_METHOD sym0, R[0]   ; Object.define(:add, R[0])
    //   LOAD_I8 R[0], 20        ; arg 0
    //   LOAD_I8 R[1], 22        ; arg 1
    //   SSEND R[0], sym0, 2     ; self.add(R[0], R[1]) -> R[0]
    //   RETURN R[0]
    var top_asm = Asm.init();
    const sym_add = top_asm.addSym(42); // arbitrary symbol ID for "add"
    const child_idx = top_asm.addChild(&child_func);

    top_asm.emitAB(.METHOD, 0, child_idx);
    top_asm.emitAB(.DEF_METHOD, sym_add, 0);
    top_asm.emitAB(.LOAD_I8, 0, 20);
    top_asm.emitAB(.LOAD_I8, 1, 22);
    top_asm.emitABC(.SSEND, 0, sym_add, 2);
    top_asm.emitA(.RETURN, 0);
    const top_func = top_asm.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&top_func);
    try std.testing.expectEqual(@as(i32, 42), result.ok.asFixnum().?);
}

test "SSEND: NoMethodError for undefined method" {
    var a = Asm.init();
    const sym_missing = a.addSym(999);
    a.emitABC(.SSEND, 0, sym_missing, 0);
    a.emitA(.RETURN, 0);
    const func = a.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.NoMethodError, result.err);
}

test "ENTER: ArgumentError on wrong argc" {
    var child_asm = Asm.init();
    child_asm.emitW(.ENTER, 2); // expects 2 args
    child_asm.emitA(.RETURN, 0);
    var child_func = child_asm.build(2);

    var top_asm = Asm.init();
    const sym = top_asm.addSym(50);
    const ci = top_asm.addChild(&child_func);
    top_asm.emitAB(.METHOD, 0, ci);
    top_asm.emitAB(.DEF_METHOD, sym, 0);
    top_asm.emitAB(.LOAD_I8, 0, 1);
    top_asm.emitABC(.SSEND, 0, sym, 1); // only 1 arg, method expects 2
    top_asm.emitA(.RETURN, 0);
    const func = top_asm.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(VmError.ArgumentError, result.err);
}

test "SEND: receiver dispatch with SEND opcode" {
    // Method body: R[0] is the single arg, return it + 1
    var child_asm = Asm.init();
    child_asm.emitW(.ENTER, 1); // req=1
    child_asm.emitAB(.LOAD_I8, 1, 1);
    child_asm.emitA(.ADD, 0); // R[0] = R[0] + R[1]
    child_asm.emitA(.RETURN, 0);
    var child_func = child_asm.build(2);

    // Define method "inc" on Object, then call via SEND on nil receiver
    var top_asm = Asm.init();
    const sym_inc = top_asm.addSym(77);
    const ci = top_asm.addChild(&child_func);
    top_asm.emitAB(.METHOD, 0, ci);
    top_asm.emitAB(.DEF_METHOD, sym_inc, 0);
    top_asm.emitA(.LOAD_NIL, 0); // receiver = nil
    top_asm.emitAB(.LOAD_I8, 1, 41); // arg = 41
    top_asm.emitABC(.SEND, 0, sym_inc, 1); // nil.inc(41) -> 42
    top_asm.emitA(.RETURN, 0);
    const func = top_asm.build(2);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 42), result.ok.asFixnum().?);
}

test "nested method calls: f calls g" {
    // g(x): return x * 2
    var g_asm = Asm.init();
    g_asm.emitW(.ENTER, 1);
    g_asm.emitAB(.LOAD_I8, 1, 2);
    g_asm.emitA(.MUL, 0);
    g_asm.emitA(.RETURN, 0);
    var g_func = g_asm.build(2);

    // f(x): return g(x + 1)
    // R[0]=x, R[1]=1, ADD R[0] -> x+1, then SSEND g
    var f_asm = Asm.init();
    const f_sym_g = f_asm.addSym(200);
    f_asm.emitW(.ENTER, 1);
    f_asm.emitAB(.LOAD_I8, 1, 1);
    f_asm.emitA(.ADD, 0); // R[0] = x + 1
    f_asm.emitABC(.SSEND, 0, f_sym_g, 1); // g(R[0])
    f_asm.emitA(.RETURN, 0);
    var f_func = f_asm.build(2);

    // Top-level: def g, def f, call f(20) -> g(21) -> 42
    var top_asm = Asm.init();
    const sym_g = top_asm.addSym(200);
    const sym_f = top_asm.addSym(100);
    const ci_g = top_asm.addChild(&g_func);
    const ci_f = top_asm.addChild(&f_func);

    top_asm.emitAB(.METHOD, 0, ci_g);
    top_asm.emitAB(.DEF_METHOD, sym_g, 0);
    top_asm.emitAB(.METHOD, 0, ci_f);
    top_asm.emitAB(.DEF_METHOD, sym_f, 0);
    top_asm.emitAB(.LOAD_I8, 0, 20);
    top_asm.emitABC(.SSEND, 0, sym_f, 1); // f(20) -> g(21) -> 42
    top_asm.emitA(.RETURN, 0);
    const func = top_asm.build(1);

    var vm = VM.initDefault();
    const result = vm.execute(&func);
    try std.testing.expectEqual(@as(i32, 42), result.ok.asFixnum().?);
}

// ── GC tests ─────────────────────────────────────────────────────────

test "GC: compact reclaims dead objects" {
    var vm = VM.initDefault();

    const a1 = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;
    _ = vm.allocHeapObj(.string, 8); // dead: no reference kept
    const a3 = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;

    vm.stackAt(0).* = a1.val;
    vm.stackAt(1).* = a3.val;
    vm.sp = 2;

    const used_before = vm.heap.usedBytes();
    vm.gc();
    const used_after = vm.heap.usedBytes();

    try std.testing.expect(used_after < used_before);
    try std.testing.expect(vm.getObjPtr(a1.val) != null);
    try std.testing.expect(vm.getObjPtr(a3.val) != null);
}

test "GC: allocation succeeds after compaction frees space" {
    var vm = VM.initDefault();

    const kept = vm.allocHeapObj(.string, 64) orelse return error.TestUnexpectedResult;
    vm.stackAt(0).* = kept.val;
    vm.sp = 1;

    // Fill heap with dead objects via raw heap alloc (bypasses GC trigger)
    var count: u32 = 0;
    while (vm.heap.allocObj(.string, 64) != null) count += 1;
    try std.testing.expect(count > 0);

    // Heap is full but only one object is live. GC compacts, freeing space.
    vm.gc();
    const after_gc = vm.allocHeapObj(.string, 64);
    try std.testing.expect(after_gc != null);
}

test "GC: dead registry entries become null" {
    var vm = VM.initDefault();

    const a1 = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;
    const a2 = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;

    vm.stackAt(0).* = a1.val;
    vm.sp = 1;

    vm.gc();

    try std.testing.expect(vm.getObjPtr(a1.val) != null);
    try std.testing.expect(vm.getObjPtr(a2.val) == null);
}

test "GC: compact preserves object contents" {
    var vm = VM.initDefault();

    const alloc = vm.allocHeapObj(.instance, heap_mod.INSTANCE_PAYLOAD_BYTES) orelse
        return error.TestUnexpectedResult;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = 42;
    const ivar_ptr: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    ivar_ptr[0] = Value.fromFixnum(99).?;

    _ = vm.allocHeapObj(.string, 64); // dead gap

    vm.stackAt(0).* = alloc.val;
    vm.sp = 1;

    vm.gc();

    const new_ptr = vm.getObjPtr(alloc.val) orelse return error.TestUnexpectedResult;
    const new_hdr: *const ObjHeader = @ptrCast(@alignCast(new_ptr));
    try std.testing.expectEqual(@as(u8, 42), new_hdr.class_id);
    const new_ivar: [*]const Value = @ptrCast(@alignCast(new_ptr + @sizeOf(ObjHeader)));
    try std.testing.expectEqual(@as(i32, 99), new_ivar[0].asFixnum().?);
}

test "GC: allocHeapObj auto-triggers GC on heap full" {
    var vm = VM.initDefault();

    const kept = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;
    vm.stackAt(0).* = kept.val;
    vm.sp = 1;

    // Fill heap with dead objects (raw alloc, bypass registry/GC)
    while (vm.heap.allocObj(.string, 64) != null) {}

    // allocHeapObj should trigger GC internally and succeed
    const after = vm.allocHeapObj(.string, 8);
    try std.testing.expect(after != null);
}

test "GC: stats are updated after collection" {
    var vm = VM.initDefault();

    const kept = vm.allocHeapObj(.string, 8) orelse return error.TestUnexpectedResult;
    _ = vm.allocHeapObj(.string, 8); // dead
    _ = vm.allocHeapObj(.string, 8); // dead

    vm.stackAt(0).* = kept.val;
    vm.sp = 1;

    try std.testing.expectEqual(@as(u32, 0), vm.gc_stats.collections);
    vm.gc();

    try std.testing.expectEqual(@as(u32, 1), vm.gc_stats.collections);
    try std.testing.expect(vm.gc_stats.bytes_reclaimed > 0);
    try std.testing.expect(vm.gc_stats.bytes_after < vm.gc_stats.bytes_before);
    try std.testing.expectEqual(@as(u16, 1), vm.gc_stats.live_objects);
}
