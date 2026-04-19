const std = @import("std");
const Value = @import("value.zig").Value;
const vm_mod = @import("vm.zig");
const IrFunc = vm_mod.IrFunc;
const VM = vm_mod.VM;
const heap_mod = @import("heap.zig");
const ObjHeader = heap_mod.ObjHeader;
const RClassPayload = heap_mod.RClassPayload;
pub const atom_mod = @import("atom.zig");
const Atom = atom_mod.Atom;
const a = atom_mod.atom;

pub const MAX_CLASSES: u8 = 32;
pub const MAX_METHODS_PER_CLASS: u8 = 32;
pub const MAX_CONSTANTS: u8 = 64;
pub const MAX_IVARS_PER_CLASS: u8 = heap_mod.MAX_IVARS_PER_INSTANCE;
pub const MAX_GLOBALS: u8 = 32;

// Bootstrap class IDs — must match classOf() dispatch
pub const CLASS_OBJECT: u8 = 1;
pub const CLASS_INTEGER: u8 = 2;
pub const CLASS_NIL_CLASS: u8 = 3;
pub const CLASS_TRUE_CLASS: u8 = 4;
pub const CLASS_FALSE_CLASS: u8 = 5;
pub const CLASS_SYMBOL: u8 = 6;
pub const CLASS_STRING: u8 = 7;
pub const CLASS_CLASS: u8 = 8;
pub const CLASS_ARRAY: u8 = 9;
pub const CLASS_HASH: u8 = 10;
pub const CLASS_PROC: u8 = 11;
pub const CLASS_MODULE: u8 = 12;
pub const CLASS_RANGE: u8 = 13;
pub const CLASS_FLOAT: u8 = 14;

// ── Native function type ─────────────────────────────────────────────
//
// Natives may receive an optional `block` — a registered block-function
// Value produced by the BLOCK opcode at the call site and passed via
// SEND_BLOCK. Use `vm.yieldBlock(block, args)` to invoke it. Natives
// that don't care about blocks can simply ignore the parameter.

pub const NativeFn = *const fn (vm: *VM, recv: Value, args: []const Value, block: ?Value) Value;

pub const MethodImpl = union(enum) {
    bytecode: *const IrFunc,
    native: NativeFn,
};

pub const MethodEntry = struct {
    name_sym: u16,
    impl: MethodImpl,
};

// ── Constant table ───────────────────────────────────────────────────

pub const ConstantEntry = struct {
    name_sym: u16 = 0,
    value: Value = Value.nil,
    used: bool = false,
};

pub const ConstantTable = struct {
    entries: [MAX_CONSTANTS]ConstantEntry = [_]ConstantEntry{.{}} ** MAX_CONSTANTS,
    count: u8 = 0,

    pub fn get(self: *const ConstantTable, name_sym: u16) ?Value {
        for (self.entries[0..self.count]) |*e| {
            if (e.used and e.name_sym == name_sym) return e.value;
        }
        return null;
    }

    pub fn set(self: *ConstantTable, name_sym: u16, value: Value) error{ConstantTableFull}!void {
        for (self.entries[0..self.count]) |*e| {
            if (e.used and e.name_sym == name_sym) {
                e.value = value;
                return;
            }
        }
        if (self.count >= MAX_CONSTANTS) return error.ConstantTableFull;
        self.entries[self.count] = .{ .name_sym = name_sym, .value = value, .used = true };
        self.count += 1;
    }
};

// ── Class table ──────────────────────────────────────────────────────

pub const ClassInfo = struct {
    used: bool = false,
    name_sym: u16 = 0,
    superclass_id: u8 = 0,
    method_count: u8 = 0,
    methods: [MAX_METHODS_PER_CLASS]MethodEntry = undefined,
    ivar_names: [MAX_IVARS_PER_CLASS]u16 = [_]u16{0} ** MAX_IVARS_PER_CLASS,
    ivar_count: u8 = 0,
};

pub const GlobalEntry = struct {
    name_sym: u16 = 0,
    value: Value = Value.nil,
    used: bool = false,
};

pub const GlobalTable = struct {
    entries: [MAX_GLOBALS]GlobalEntry = [_]GlobalEntry{.{}} ** MAX_GLOBALS,
    count: u8 = 0,

    pub fn get(self: *const GlobalTable, name_sym: u16) ?Value {
        for (self.entries[0..self.count]) |*e| {
            if (e.used and e.name_sym == name_sym) return e.value;
        }
        return null;
    }

    pub fn set(self: *GlobalTable, name_sym: u16, value: Value) error{GlobalTableFull}!void {
        for (self.entries[0..self.count]) |*e| {
            if (e.used and e.name_sym == name_sym) {
                e.value = value;
                return;
            }
        }
        if (self.count >= MAX_GLOBALS) return error.GlobalTableFull;
        self.entries[self.count] = .{ .name_sym = name_sym, .value = value, .used = true };
        self.count += 1;
    }
};

pub const ClassTable = struct {
    classes: [MAX_CLASSES]ClassInfo = [_]ClassInfo{.{}} ** MAX_CLASSES,
    count: u8 = 0,

    pub fn init() ClassTable {
        var ct = ClassTable{};
        ct.addClass(CLASS_OBJECT, 0, 0);
        ct.addClass(CLASS_INTEGER, 0, CLASS_OBJECT);
        ct.addClass(CLASS_NIL_CLASS, 0, CLASS_OBJECT);
        ct.addClass(CLASS_TRUE_CLASS, 0, CLASS_OBJECT);
        ct.addClass(CLASS_FALSE_CLASS, 0, CLASS_OBJECT);
        ct.addClass(CLASS_SYMBOL, 0, CLASS_OBJECT);
        ct.addClass(CLASS_STRING, 0, CLASS_OBJECT);
        ct.addClass(CLASS_CLASS, 0, CLASS_OBJECT);
        ct.addClass(CLASS_ARRAY, 0, CLASS_OBJECT);
        ct.addClass(CLASS_HASH, 0, CLASS_OBJECT);
        ct.addClass(CLASS_PROC, 0, CLASS_OBJECT);
        ct.addClass(CLASS_MODULE, 0, CLASS_OBJECT);
        ct.addClass(CLASS_RANGE, 0, CLASS_OBJECT);
        ct.addClass(CLASS_FLOAT, 0, CLASS_OBJECT);
        return ct;
    }

    pub fn addClass(self: *ClassTable, id: u8, name_sym: u16, superclass_id: u8) void {
        self.classes[id] = .{
            .used = true,
            .name_sym = name_sym,
            .superclass_id = superclass_id,
        };
        if (id >= self.count) self.count = id + 1;
    }

    /// Allocate a new class slot, return its ID.
    pub fn allocClass(self: *ClassTable, name_sym: u16, superclass_id: u8) ?u8 {
        if (self.count >= MAX_CLASSES) return null;
        const id = self.count;
        self.addClass(id, name_sym, superclass_id);
        return id;
    }

    pub fn defineMethodImpl(self: *ClassTable, class_id: u8, name_sym: u16, impl: MethodImpl) error{MethodTableFull}!void {
        const cls = &self.classes[class_id];
        for (cls.methods[0..cls.method_count]) |*m| {
            if (m.name_sym == name_sym) {
                m.impl = impl;
                return;
            }
        }
        if (cls.method_count >= MAX_METHODS_PER_CLASS) return error.MethodTableFull;
        cls.methods[cls.method_count] = .{ .name_sym = name_sym, .impl = impl };
        cls.method_count += 1;
    }

    /// Legacy bytecode-only helper (used by METHOD/DEF_METHOD opcodes)
    pub fn defineMethod(self: *ClassTable, class_id: u8, name_sym: u16, func: *const IrFunc) error{MethodTableFull}!void {
        return self.defineMethodImpl(class_id, name_sym, .{ .bytecode = func });
    }

    /// Look up an ivar slot by name in a class's shape. Returns null if not found.
    pub fn lookupIvar(self: *const ClassTable, class_id: u8, name_sym: u16) ?u8 {
        if (class_id == 0 or class_id >= MAX_CLASSES) return null;
        const cls = &self.classes[class_id];
        for (cls.ivar_names[0..cls.ivar_count], 0..) |name, i| {
            if (name == name_sym) return @intCast(i);
        }
        return null;
    }

    /// Ensure an ivar slot exists in the class shape. Returns slot index or null if full.
    pub fn ensureIvar(self: *ClassTable, class_id: u8, name_sym: u16) ?u8 {
        if (class_id == 0 or class_id >= MAX_CLASSES) return null;
        const cls = &self.classes[class_id];
        for (cls.ivar_names[0..cls.ivar_count], 0..) |name, i| {
            if (name == name_sym) return @intCast(i);
        }
        if (cls.ivar_count >= MAX_IVARS_PER_CLASS) return null;
        const slot = cls.ivar_count;
        cls.ivar_names[slot] = name_sym;
        cls.ivar_count += 1;
        return slot;
    }

    /// Walk ancestor chain to find a method by symbol ID.
    pub fn lookupMethod(self: *const ClassTable, start_class_id: u8, name_sym: u16) ?MethodImpl {
        var cid = start_class_id;
        while (true) {
            if (cid == 0 or cid >= MAX_CLASSES) break;
            const cls = &self.classes[cid];
            if (!cls.used) break;

            for (cls.methods[0..cls.method_count]) |*m| {
                if (m.name_sym == name_sym) return m.impl;
            }

            if (cid == CLASS_OBJECT) break;
            cid = if (cls.superclass_id != 0) cls.superclass_id else CLASS_OBJECT;
        }
        return null;
    }

    /// Determine class ID for any Value, using the object registry for heap objects.
    pub fn classOfVM(_: *const ClassTable, vm_ptr: *const VM, v: Value) u8 {
        if (v.isNil()) return CLASS_NIL_CLASS;
        if (v.isTrue()) return CLASS_TRUE_CLASS;
        if (v.isFalse()) return CLASS_FALSE_CLASS;
        if (v.isSymbol()) return CLASS_SYMBOL;
        if (vm_ptr.getObjHeader(v)) |hdr| return hdr.class_id;
        if (v.isFixnum()) return CLASS_INTEGER;
        return CLASS_OBJECT;
    }

    /// Classify an immediate value (fixnum, nil, true, false, symbol).
    /// For heap objects, use classOfVM which goes through the object registry.
    pub fn classOfImmediate(v: Value) u8 {
        if (v.isNil()) return CLASS_NIL_CLASS;
        if (v.isTrue()) return CLASS_TRUE_CLASS;
        if (v.isFalse()) return CLASS_FALSE_CLASS;
        if (v.isSymbol()) return CLASS_SYMBOL;
        if (v.isFixnum()) return CLASS_INTEGER;
        return CLASS_OBJECT;
    }
};

// ── Native method: Class#new ─────────────────────────────────────────

pub fn nativeClassNew(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    _ = args;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const payload: *const RClassPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const target_class_id = payload.represented_class_id;

    const result = vm.allocHeapObj(.instance, heap_mod.INSTANCE_PAYLOAD_BYTES) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(result.ptr));
    hdr.class_id = target_class_id;

    const ivar_base: [*]u8 = result.ptr + @sizeOf(ObjHeader);
    const ivar_ptr: [*]Value = @ptrCast(@alignCast(ivar_base));
    for (0..heap_mod.MAX_IVARS_PER_INSTANCE) |i| {
        ivar_ptr[i] = Value.nil;
    }

    return result.val;
}

// ── Native method table ──────────────────────────────────────────────

pub const NativeMethodDef = struct {
    class_id: u8,
    name_atom: Atom,
    func: NativeFn,
};

/// Core native methods required for sane Ruby semantics. Pure Zig; must
/// NOT reference hosted-only APIs (std.debug.print, std.Io.File.stderr,
/// std.Io.Threaded) — those live in `class_debug.zig` and are only
/// installed by hosted callers. Freestanding embedders (pico firmware)
/// install this table via `installCoreNatives` plus a target-specific
/// platform table via `installPlatformNatives`.
pub const core_native_table = [_]NativeMethodDef{
    .{ .class_id = CLASS_CLASS, .name_atom = a("new"), .func = &nativeClassNew },

    // Kernel / Object — excludes puts/print/p (debug natives, see class_debug.zig)
    .{ .class_id = CLASS_OBJECT, .name_atom = a("to_s"), .func = &nativeObjectToS },
    .{ .class_id = CLASS_OBJECT, .name_atom = a("inspect"), .func = &nativeObjectInspect },
    .{ .class_id = CLASS_OBJECT, .name_atom = a("class"), .func = &nativeObjectClass },
    .{ .class_id = CLASS_OBJECT, .name_atom = a("nil?"), .func = &nativeObjectNilQ },
    .{ .class_id = CLASS_OBJECT, .name_atom = a("object_id"), .func = &nativeObjectId },

    // Integer
    .{ .class_id = CLASS_INTEGER, .name_atom = a("to_s"), .func = &nativeIntToS },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("abs"), .func = &nativeIntAbs },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("zero?"), .func = &nativeIntZeroQ },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("even?"), .func = &nativeIntEvenQ },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("odd?"), .func = &nativeIntOddQ },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("<=>"), .func = &nativeIntCmp },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("&"), .func = &nativeIntAnd },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("|"), .func = &nativeIntOr },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("^"), .func = &nativeIntXor },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("<<"), .func = &nativeIntShl },
    .{ .class_id = CLASS_INTEGER, .name_atom = a(">>"), .func = &nativeIntShr },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("~"), .func = &nativeIntNot },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("**"), .func = &nativeIntPow },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("times"), .func = &nativeIntTimes },

    // String
    .{ .class_id = CLASS_STRING, .name_atom = a("length"), .func = &nativeStringLength },
    .{ .class_id = CLASS_STRING, .name_atom = a("size"), .func = &nativeStringLength },
    .{ .class_id = CLASS_STRING, .name_atom = a("empty?"), .func = &nativeStringEmptyQ },
    .{ .class_id = CLASS_STRING, .name_atom = a("to_s"), .func = &nativeStringToS },
    .{ .class_id = CLASS_STRING, .name_atom = a("+"), .func = &nativeStringPlus },
    .{ .class_id = CLASS_STRING, .name_atom = a("*"), .func = &nativeStringMul },
    .{ .class_id = CLASS_STRING, .name_atom = a("=="), .func = &nativeStringEq },
    .{ .class_id = CLASS_STRING, .name_atom = a("[]"), .func = &nativeStringGet },

    // Array
    .{ .class_id = CLASS_ARRAY, .name_atom = a("length"), .func = &nativeArrayLength },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("size"), .func = &nativeArrayLength },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("empty?"), .func = &nativeArrayEmptyQ },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("[]"), .func = &nativeArrayGet },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("push"), .func = &nativeArrayPush },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("first"), .func = &nativeArrayFirst },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("last"), .func = &nativeArrayLast },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("include?"), .func = &nativeArrayIncludeQ },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("+"), .func = &nativeArrayPlus },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("join"), .func = &nativeArrayJoin },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("each"), .func = &nativeArrayEach },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("map"), .func = &nativeArrayMap },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("each_with_index"), .func = &nativeArrayEachWithIndex },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("select"), .func = &nativeArraySelect },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("filter"), .func = &nativeArraySelect },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("reject"), .func = &nativeArrayReject },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("inject"), .func = &nativeArrayInject },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("reduce"), .func = &nativeArrayInject },
    .{ .class_id = CLASS_ARRAY, .name_atom = a("sort"), .func = &nativeArraySort },

    // Range
    .{ .class_id = CLASS_RANGE, .name_atom = a("each"), .func = &nativeRangeEach },
    .{ .class_id = CLASS_RANGE, .name_atom = a("to_a"), .func = &nativeRangeToA },

    // Hash iteration
    .{ .class_id = CLASS_HASH, .name_atom = a("each"), .func = &nativeHashEach },
    .{ .class_id = CLASS_HASH, .name_atom = a("each_pair"), .func = &nativeHashEach },

    // Integer iteration
    .{ .class_id = CLASS_INTEGER, .name_atom = a("upto"), .func = &nativeIntUpto },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("downto"), .func = &nativeIntDownto },

    // Integer numeric coercion
    .{ .class_id = CLASS_INTEGER, .name_atom = a("to_i"), .func = &nativeIntToI },
    .{ .class_id = CLASS_INTEGER, .name_atom = a("to_f"), .func = &nativeIntToF },

    // Float
    .{ .class_id = CLASS_FLOAT, .name_atom = a("to_s"), .func = &nativeFloatToS },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("inspect"), .func = &nativeFloatToS },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("to_i"), .func = &nativeFloatToI },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("to_f"), .func = &nativeFloatToF },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("abs"), .func = &nativeFloatAbs },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("zero?"), .func = &nativeFloatZeroQ },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("<=>"), .func = &nativeFloatCmp },
    // Explicit method-dispatched arithmetic (e.g. `x.send(:+, y)` or
    // subclass overrides). The ADD/SUB/MUL/DIV/MOD opcodes already
    // numerically promote on their own fast path, so these natives are
    // only hit via explicit send; they mirror that promotion logic.
    .{ .class_id = CLASS_FLOAT, .name_atom = a("+"), .func = &nativeFloatAdd },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("-"), .func = &nativeFloatSub },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("*"), .func = &nativeFloatMul },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("/"), .func = &nativeFloatDiv },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("%"), .func = &nativeFloatMod },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("=="), .func = &nativeFloatEq },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("<"), .func = &nativeFloatLt },
    .{ .class_id = CLASS_FLOAT, .name_atom = a("<="), .func = &nativeFloatLe },
    .{ .class_id = CLASS_FLOAT, .name_atom = a(">"), .func = &nativeFloatGt },
    .{ .class_id = CLASS_FLOAT, .name_atom = a(">="), .func = &nativeFloatGe },

    // String parsing
    .{ .class_id = CLASS_STRING, .name_atom = a("to_i"), .func = &nativeStringToI },
    .{ .class_id = CLASS_STRING, .name_atom = a("to_f"), .func = &nativeStringToF },

    // Kernel-ish
    // NOTE: `Kernel#loop { … }` is deliberately NOT registered until
    // `break`-from-block reaches the native caller — a silent no-op
    // would hide bugs and an always-running native would hang the VM.
    // Users get NoMethodError on `loop { … }` for now; see nativeKernelLoop.

    // Hash
    .{ .class_id = CLASS_HASH, .name_atom = a("length"), .func = &nativeHashLength },
    .{ .class_id = CLASS_HASH, .name_atom = a("size"), .func = &nativeHashLength },
    .{ .class_id = CLASS_HASH, .name_atom = a("empty?"), .func = &nativeHashEmptyQ },
    .{ .class_id = CLASS_HASH, .name_atom = a("keys"), .func = &nativeHashKeys },
    .{ .class_id = CLASS_HASH, .name_atom = a("values"), .func = &nativeHashValues },
    .{ .class_id = CLASS_HASH, .name_atom = a("[]"), .func = &nativeHashGet },
    .{ .class_id = CLASS_HASH, .name_atom = a("[]="), .func = &nativeHashSet },
    .{ .class_id = CLASS_HASH, .name_atom = a("include?"), .func = &nativeHashIncludeQ },
    .{ .class_id = CLASS_HASH, .name_atom = a("has_key?"), .func = &nativeHashIncludeQ },
    .{ .class_id = CLASS_HASH, .name_atom = a("fetch"), .func = &nativeHashFetch },

    // NilClass / TrueClass / FalseClass — == and !
    .{ .class_id = CLASS_NIL_CLASS, .name_atom = a("=="), .func = &nativeImmedEq },
    .{ .class_id = CLASS_NIL_CLASS, .name_atom = a("!"), .func = &nativeNot },
    .{ .class_id = CLASS_TRUE_CLASS, .name_atom = a("=="), .func = &nativeImmedEq },
    .{ .class_id = CLASS_TRUE_CLASS, .name_atom = a("!"), .func = &nativeNot },
    .{ .class_id = CLASS_FALSE_CLASS, .name_atom = a("=="), .func = &nativeImmedEq },
    .{ .class_id = CLASS_FALSE_CLASS, .name_atom = a("!"), .func = &nativeNot },
    .{ .class_id = CLASS_SYMBOL, .name_atom = a("=="), .func = &nativeImmedEq },

    // NilClass
    .{ .class_id = CLASS_NIL_CLASS, .name_atom = a("to_s"), .func = &nativeNilToS },
    .{ .class_id = CLASS_NIL_CLASS, .name_atom = a("nil?"), .func = &nativeNilNilQ },
    .{ .class_id = CLASS_NIL_CLASS, .name_atom = a("inspect"), .func = &nativeNilToS },

    // TrueClass / FalseClass
    .{ .class_id = CLASS_TRUE_CLASS, .name_atom = a("to_s"), .func = &nativeTrueToS },
    .{ .class_id = CLASS_FALSE_CLASS, .name_atom = a("to_s"), .func = &nativeFalseToS },
};

/// Register the core native methods keyed by their well-known atom ID.
/// The compiler interns well-known operator/method names so their compiler
/// sym_id equals the atom ID, which is what the class table expects.
/// Well-known-atom operators (`+`, `-`, `[]`, …) must be available at
/// runtime even if the user source never mentions the method directly
/// (e.g., `'a' + 'b'` falls back to `String#+` from inside the ADD opcode
/// without the compiler ever interning `"+"`).
///
/// Core natives are freestanding-safe: no hosted-only std APIs. Hosted
/// `puts`/`print`/`p` live in class_debug.zig; platform stubs likewise.
pub fn installCoreNatives(vm: *VM) void {
    installPlatformNatives(vm, &core_native_table);
}

/// Generic native-table installer used for platform-specific tables.
/// Firmware embedders pass their own platform table (pico GPIO/LED/…);
/// host builds pass `class_debug.default_platform_native_table`.
pub fn installPlatformNatives(vm: *VM, table: []const NativeMethodDef) void {
    for (table) |entry| {
        vm.class_table.defineMethodImpl(
            entry.class_id,
            entry.name_atom,
            .{ .native = entry.func },
        ) catch {};
    }
}

// ── Native implementations ───────────────────────────────────────────
//
// Debug Kernel natives (`puts`, `print`, `p`) and default host-side
// platform stubs (`gpio_*`, `sleep_ms`, `millis`, `wifi_*`, `mqtt_*`)
// were extracted to `class_debug.zig` so this file stays freestanding-
// safe. See pico/src/ruby/nanoruby/UPSTREAM.md for the re-vendor log.

fn nativeObjectToS(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return makeString(vm, recv);
}

fn nativeObjectInspect(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return makeString(vm, recv);
}

fn nativeObjectClass(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    // Return class_id as a fixnum for now (class objects not yet wired).
    // Route through classOfVM so heap-boxed types (Float, Array, …) are
    // reported correctly instead of collapsing to CLASS_OBJECT.
    const cid = vm.class_table.classOfVM(vm, recv);
    return Value.fromFixnumUnchecked(@as(i32, cid));
}

fn nativeObjectNilQ(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return Value.false_;
}

fn nativeObjectId(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return Value.fromFixnumUnchecked(@bitCast(recv.raw));
}

fn nativeNilToS(vm: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return allocString(vm, "") orelse Value.nil;
}

fn nativeNilNilQ(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return Value.true_;
}

fn nativeTrueToS(vm: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return allocString(vm, "true") orelse Value.nil;
}

fn nativeFalseToS(vm: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return allocString(vm, "false") orelse Value.nil;
}

fn nativeIntToS(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const n = recv.asFixnum() orelse return Value.nil;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Value.nil;
    return allocString(vm, s) orelse Value.nil;
}

fn nativeIntAbs(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const n = recv.asFixnum() orelse return Value.nil;
    return Value.fromFixnumUnchecked(if (n < 0) -n else n);
}

fn nativeIntZeroQ(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return Value.fromBool((recv.asFixnum() orelse return Value.false_) == 0);
}

fn nativeIntEvenQ(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return Value.fromBool(@mod(recv.asFixnum() orelse return Value.false_, 2) == 0);
}

fn nativeIntOddQ(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return Value.fromBool(@mod(recv.asFixnum() orelse return Value.false_, 2) != 0);
}

fn nativeStringLength(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const data = vm.getStringData(recv) orelse return Value.fromFixnumUnchecked(0);
    return Value.fromFixnumUnchecked(@intCast(data.len));
}

fn nativeStringEmptyQ(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const data = vm.getStringData(recv) orelse return Value.true_;
    return Value.fromBool(data.len == 0);
}

fn nativeStringToS(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return recv;
}

fn nativeStringPlus(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return recv;
    const a_data = vm.getStringData(recv) orelse return Value.nil;
    const b_data = vm.getStringData(args[0]) orelse return Value.nil;
    const total: u32 = @as(u32, @intCast(a_data.len)) + @as(u32, @intCast(b_data.len));
    if (total > std.math.maxInt(u16)) return Value.nil;
    const payload_bytes = @sizeOf(heap_mod.RStringPayload) + total;
    const alloc = vm.allocHeapObj(.string, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_STRING;
    const sp: *heap_mod.RStringPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    sp.* = .{ .len = @intCast(total) };
    const dst: [*]u8 = alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RStringPayload);
    @memcpy(dst[0..a_data.len], a_data);
    @memcpy(dst[a_data.len..][0..b_data.len], b_data);
    return alloc.val;
}

fn nativeStringMul(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return recv;
    const n_i = args[0].asFixnum() orelse return Value.nil;
    if (n_i < 0) return Value.nil;
    const n: u32 = @intCast(n_i);
    const a_data = vm.getStringData(recv) orelse return Value.nil;
    const total: u32 = @as(u32, @intCast(a_data.len)) * n;
    if (total > std.math.maxInt(u16)) return Value.nil;
    const payload_bytes = @sizeOf(heap_mod.RStringPayload) + total;
    const alloc = vm.allocHeapObj(.string, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_STRING;
    const sp: *heap_mod.RStringPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    sp.* = .{ .len = @intCast(total) };
    const dst: [*]u8 = alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RStringPayload);
    var off: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        @memcpy(dst[off..][0..a_data.len], a_data);
        off += @intCast(a_data.len);
    }
    return alloc.val;
}

fn nativeStringEq(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.false_;
    return Value.fromBool(stringsEqual(vm, recv, args[0]));
}

fn nativeStringGet(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    // str[i] → 1-char string, or nil if out of bounds.
    if (args.len == 0) return Value.nil;
    const idx = args[0].asFixnum() orelse return Value.nil;
    const data = vm.getStringData(recv) orelse return Value.nil;
    const real: i32 = if (idx < 0) @as(i32, @intCast(data.len)) + idx else idx;
    if (real < 0 or real >= data.len) return Value.nil;
    const one = data[@intCast(real)..@intCast(@as(i32, real) + 1)];
    return allocString(vm, one) orelse Value.nil;
}

fn nativeArrayLength(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.fromFixnumUnchecked(0);
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    return Value.fromFixnumUnchecked(@intCast(arr.len));
}

fn nativeArrayEmptyQ(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.true_;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    return Value.fromBool(arr.len == 0);
}

fn nativeArrayGet(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const idx = args[0].asFixnum() orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elements: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    const real_idx: i32 = if (idx < 0) @as(i32, @intCast(arr.len)) + idx else idx;
    if (real_idx < 0 or real_idx >= arr.len) return Value.nil;
    return elements[@intCast(real_idx)];
}

fn nativeArrayPush(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    // Simplified: can't grow arrays in current fixed-size heap model
    _ = vm;
    if (args.len > 0) return args[0];
    return Value.nil;
}

fn nativeArrayIncludeQ(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.false_;
    const needle = args[0];
    const ptr = vm.getObjPtr(recv) orelse return Value.false_;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        if (valuesEqual(vm, elems[i], needle)) return Value.true_;
    }
    return Value.false_;
}

fn nativeArrayPlus(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return recv;
    const other = args[0];
    const pa = vm.getObjPtr(recv) orelse return Value.nil;
    const pb = vm.getObjPtr(other) orelse return Value.nil;
    const ap: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(pa + @sizeOf(ObjHeader)));
    const bp: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(pb + @sizeOf(ObjHeader)));
    const a_elems: [*]const Value = @ptrCast(@alignCast(pa + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    const b_elems: [*]const Value = @ptrCast(@alignCast(pb + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    const total: u32 = @as(u32, ap.len) + @as(u32, bp.len);
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + total * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_ARRAY;
    const out: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    out.* = .{ .len = @intCast(total), .capa = @intCast(total) };
    const dst: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < ap.len) : (i += 1) dst[i] = a_elems[i];
    var j: u16 = 0;
    while (j < bp.len) : (j += 1) dst[ap.len + j] = b_elems[j];
    return alloc.val;
}

fn nativeArrayJoin(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    const sep: []const u8 = if (args.len > 0) (vm.getStringData(args[0]) orelse "") else "";
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        if (i > 0 and sep.len > 0) {
            if (len + sep.len > buf.len) return Value.nil;
            @memcpy(buf[len..][0..sep.len], sep);
            len += sep.len;
        }
        const s = stringifyInto(vm, elems[i], buf[len..]) orelse return Value.nil;
        len += s.len;
    }
    return allocString(vm, buf[0..len]) orelse Value.nil;
}

fn nativeArrayFirst(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    if (arr.len == 0) return Value.nil;
    const elements: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    return elements[0];
}

fn nativeArrayLast(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    if (arr.len == 0) return Value.nil;
    const elements: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    return elements[arr.len - 1];
}

// ── String allocation helper ─────────────────────────────────────────

fn makeString(vm: *VM, v: Value) Value {
    if (v.asFixnum()) |n| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Value.nil;
        return allocString(vm, s) orelse Value.nil;
    }
    if (v.isNil()) return allocString(vm, "") orelse Value.nil;
    if (v.isTrue()) return allocString(vm, "true") orelse Value.nil;
    if (v.isFalse()) return allocString(vm, "false") orelse Value.nil;
    if (vm.getStringData(v)) |_| return v; // already a string
    return allocString(vm, "") orelse Value.nil;
}

// ── Hash natives ─────────────────────────────────────────────────────

fn nativeHashLength(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.fromFixnumUnchecked(0);
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    return Value.fromFixnumUnchecked(@intCast(h.count));
}

fn nativeHashEmptyQ(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.true_;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    return Value.fromBool(h.count == 0);
}

fn nativeHashKeys(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    const count: u16 = h.count;
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + @as(u32, count) * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const ahdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    ahdr.class_id = CLASS_ARRAY;
    const arr: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    arr.* = .{ .len = count, .capa = count };
    const elements: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        elements[i] = data[i * 2]; // keys are at even indices
    }
    return alloc.val;
}

fn nativeHashGet(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const key = args[0];
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    var i: u16 = 0;
    while (i < h.count) : (i += 1) {
        if (hashKeysEqual(vm, data[i * 2], key)) return data[i * 2 + 1];
    }
    return Value.nil;
}

fn nativeHashSet(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    // Only supports mutation of existing keys. Adding new keys would
    // require growing the heap-allocated hash; not supported yet.
    if (args.len < 2) return Value.nil;
    const key = args[0];
    const val = args[1];
    const ptr = vm.getObjPtr(recv) orelse return val;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    var i: u16 = 0;
    while (i < h.count) : (i += 1) {
        if (hashKeysEqual(vm, data[i * 2], key)) {
            data[i * 2 + 1] = val;
            return val;
        }
    }
    return val; // silently no-op for new keys (heap is fixed-size)
}

fn nativeHashIncludeQ(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.false_;
    const key = args[0];
    const ptr = vm.getObjPtr(recv) orelse return Value.false_;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    var i: u16 = 0;
    while (i < h.count) : (i += 1) {
        if (hashKeysEqual(vm, data[i * 2], key)) return Value.true_;
    }
    return Value.false_;
}

fn nativeHashFetch(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return vm.raise(error.ArgumentError);
    const found = nativeHashGet(vm, recv, args[0..1], null);
    if (!found.isNil()) return found;
    // Key missing: Ruby returns `default` when a second arg is passed,
    // otherwise raises `KeyError`. The `isNil` check above treats a
    // hash value of `nil` as missing — a known limitation until
    // `Hash#default` / `Hash#has_key?`-backed fetch lands (then we'd
    // key off presence, not value). Documented as a pragmatic
    // approximation; affects only code that stores `nil` as a value.
    if (args.len >= 2) return args[1];
    return vm.raise(error.KeyError);
}

fn nativeHashValues(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    const count: u16 = h.count;
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + @as(u32, count) * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const ahdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    ahdr.class_id = CLASS_ARRAY;
    const arr: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    arr.* = .{ .len = count, .capa = count };
    const elements: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        elements[i] = data[i * 2 + 1]; // values are at odd indices
    }
    return alloc.val;
}

// ── Shared value helpers used by collection natives ──────────────────

fn stringsEqual(vm: *const VM, a_val: Value, b_val: Value) bool {
    const a_data = vm.getStringData(a_val) orelse return false;
    const b_data = vm.getStringData(b_val) orelse return false;
    return std.mem.eql(u8, a_data, b_data);
}

/// `==`-shaped equality. Mirrors Ruby's `==`: immediates use Value.eql,
/// two strings compare byte-wise, and numeric values (fixnum or heap
/// Float) compare by f64 value — so `5 == 5.0`, `[1,2].include?(1.0)`,
/// and two separately-allocated heap `1.5`s all work. Drives
/// `Array#include?`, `case/when`, and operator-`==`-style lookups.
///
/// NaN follows `==`: `NaN != NaN`. That means a NaN key in a Hash is
/// never findable even by itself — same as MRI using `==` semantics
/// (MRI's Hash uses `eql?`, but we don't yet expose an `eql?` protocol).
fn valuesEqual(vm: *const VM, a_val: Value, b_val: Value) bool {
    if (a_val.eql(b_val)) return true;
    if (vm.getStringData(a_val) != null and vm.getStringData(b_val) != null) {
        return stringsEqual(vm, a_val, b_val);
    }
    if (vm.toFloat(a_val)) |af| {
        if (vm.toFloat(b_val)) |bf| return af == bf;
    }
    return false;
}

/// `eql?`-shaped equality used by Hash lookup. Ruby's Hash keys off
/// `eql?`, which is strict about type: `1.eql?(1.0) == false`. So we
/// require matching representation — two fixnums compare via Value.eql,
/// two heap Floats compare by payload, two heap Strings compare
/// byte-wise, and cross-type pairs are always unequal. This is the
/// single entry point for hash-key equality; if/when we add an
/// explicit `Object#eql?` method, route its default through here.
fn hashKeysEqual(vm: *const VM, a_val: Value, b_val: Value) bool {
    if (a_val.eql(b_val)) return true;
    // Both-string: byte-wise.
    if (vm.getStringData(a_val)) |as_| {
        if (vm.getStringData(b_val)) |bs_| return std.mem.eql(u8, as_, bs_);
        return false;
    }
    // Both-float: payload-wise (NaN still unequal per IEEE; matches
    // MRI's observed behavior for NaN keys even though MRI reaches
    // that result via a different protocol).
    const a_is_float = vm.getFloatData(a_val) != null;
    const b_is_float = vm.getFloatData(b_val) != null;
    if (a_is_float and b_is_float) {
        return vm.getFloatData(a_val).? == vm.getFloatData(b_val).?;
    }
    // Anything else: strict. Cross-type (int vs float, string vs int,
    // etc.) never matches — that's Ruby's `eql?` semantics and what
    // distinguishes a Hash key match from an `==` match.
    return false;
}

/// Write `v` as human-readable text into `buf` and return the slice. For
/// heap strings the raw bytes are copied in; immediates go through the
/// standard formatter. Returns null if `buf` is too small.
fn stringifyInto(vm: *const VM, v: Value, buf: []u8) ?[]const u8 {
    if (vm.getStringData(v)) |s| {
        if (s.len > buf.len) return null;
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    if (v.asFixnum()) |n| return std.fmt.bufPrint(buf, "{d}", .{n}) catch null;
    if (v.isNil()) return "";
    if (v.isTrue()) {
        if (buf.len < 4) return null;
        @memcpy(buf[0..4], "true");
        return buf[0..4];
    }
    if (v.isFalse()) {
        if (buf.len < 5) return null;
        @memcpy(buf[0..5], "false");
        return buf[0..5];
    }
    if (v.asSymbolId()) |id| return std.fmt.bufPrint(buf, "sym_{d}", .{id}) catch null;
    return std.fmt.bufPrint(buf, "#<0x{x}>", .{v.raw}) catch null;
}

fn nativeIntAnd(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    const b_n = args[0].asFixnum() orelse return Value.nil;
    return Value.fromFixnumUnchecked(a_n & b_n);
}

fn nativeIntOr(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    const b_n = args[0].asFixnum() orelse return Value.nil;
    return Value.fromFixnumUnchecked(a_n | b_n);
}

fn nativeIntXor(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    const b_n = args[0].asFixnum() orelse return Value.nil;
    return Value.fromFixnumUnchecked(a_n ^ b_n);
}

fn nativeIntShl(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    const b_n = args[0].asFixnum() orelse return Value.nil;
    if (b_n < 0 or b_n >= 31) return Value.fromFixnumUnchecked(0);
    const shift: u5 = @intCast(b_n);
    const r64: i64 = @as(i64, a_n) << shift;
    if (r64 > Value.max_fixnum or r64 < Value.min_fixnum) return Value.nil;
    return Value.fromFixnumUnchecked(@intCast(r64));
}

fn nativeIntShr(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    const b_n = args[0].asFixnum() orelse return Value.nil;
    if (b_n < 0) return Value.nil;
    if (b_n >= 31) return Value.fromFixnumUnchecked(if (a_n < 0) -1 else 0);
    const shift: u5 = @intCast(b_n);
    return Value.fromFixnumUnchecked(a_n >> shift);
}

fn nativeIntNot(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const a_n = recv.asFixnum() orelse return Value.nil;
    return Value.fromFixnumUnchecked(~a_n);
}

/// `n.times { |i| ... }` — yields i = 0, 1, …, n-1 to the block.
/// Returns the receiver. If no block, returns nil (real Ruby returns an
/// Enumerator here — we don't support those yet).
fn nativeIntTimes(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const n = recv.asFixnum() orelse return Value.nil;
    if (n <= 0) return recv;
    const blk = block orelse return Value.nil;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const arg = Value.fromFixnumUnchecked(i);
        const one = [_]Value{arg};
        _ = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `arr.each { |x| ... }` — yields each element; returns the array.
fn nativeArrayEach(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        const one = [_]Value{elems[i]};
        _ = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `arr.map { |x| ... }` — yields each element, returns a new array
/// of the block's results.
fn nativeArrayMap(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const src_ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const src_arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(src_ptr + @sizeOf(ObjHeader)));
    const src_len: u32 = src_arr.len;
    const src_elems: [*]const Value = @ptrCast(@alignCast(src_ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    // Allocate output array up front; populate as we yield.
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + src_len * @sizeOf(Value);
    const out = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const out_hdr: *ObjHeader = @ptrCast(@alignCast(out.ptr));
    out_hdr.class_id = CLASS_ARRAY;
    const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(out.ptr + @sizeOf(ObjHeader)));
    out_payload.* = .{ .len = @intCast(src_len), .capa = @intCast(src_len) };
    const out_elems: [*]Value = @ptrCast(@alignCast(out.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    var i: u16 = 0;
    while (i < src_len) : (i += 1) {
        const one = [_]Value{src_elems[i]};
        out_elems[i] = vm.yieldBlock(blk, one[0..1]) orelse Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return out.val;
}

/// `arr.each_with_index { |x, i| ... }` — yields element and index.
fn nativeArrayEachWithIndex(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        const pair = [_]Value{ elems[i], Value.fromFixnumUnchecked(@intCast(i)) };
        _ = vm.yieldBlock(blk, pair[0..2]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `arr.select { |x| cond }` — returns a new array of elements for
/// which the block yielded a truthy value. `filter` is an alias.
fn nativeArraySelect(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    // Two-pass: count surviving, then allocate and populate. Simpler
    // than a grow-on-demand path given our fixed-size array heap.
    var kept: u16 = 0;
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        const one = [_]Value{elems[i]};
        const r = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
        if (r.isTruthy()) kept += 1;
    }

    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + @as(u32, kept) * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_ARRAY;
    const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    out_payload.* = .{ .len = kept, .capa = kept };
    const out_elems: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    // Second pass: re-evaluate to populate. Recomputing the block is
    // slightly wasteful but side-effect-correct (the block already
    // ran once for each element on the counting pass).
    const ptr2 = vm.getObjPtr(recv) orelse return Value.nil;
    const arr2: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr2 + @sizeOf(ObjHeader)));
    const elems2: [*]const Value = @ptrCast(@alignCast(ptr2 + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var w: u16 = 0;
    i = 0;
    while (i < arr2.len and w < kept) : (i += 1) {
        const one = [_]Value{elems2[i]};
        const r = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
        if (r.isTruthy()) {
            out_elems[w] = elems2[i];
            w += 1;
        }
    }
    return alloc.val;
}

/// `arr.reject { |x| cond }` — inverse of select.
fn nativeArrayReject(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    // Reuse select by inverting via a wrapper — simplest implementation
    // is to just inline the same structure but negate the predicate.
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var kept: u16 = 0;
    var i: u16 = 0;
    while (i < arr.len) : (i += 1) {
        const one = [_]Value{elems[i]};
        const r = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
        if (r.isFalsy()) kept += 1;
    }
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + @as(u32, kept) * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_ARRAY;
    const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    out_payload.* = .{ .len = kept, .capa = kept };
    const out_elems: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    const ptr2 = vm.getObjPtr(recv) orelse return Value.nil;
    const arr2: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr2 + @sizeOf(ObjHeader)));
    const elems2: [*]const Value = @ptrCast(@alignCast(ptr2 + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var w: u16 = 0;
    i = 0;
    while (i < arr2.len and w < kept) : (i += 1) {
        const one = [_]Value{elems2[i]};
        const r = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
        if (r.isFalsy()) {
            out_elems[w] = elems2[i];
            w += 1;
        }
    }
    return alloc.val;
}

/// `arr.inject(init) { |acc, x| … }` / `arr.reduce(init) { … }`
/// Threads an accumulator through each element. If no init is given,
/// the first element seeds the accumulator (classic Enumerable shape).
fn nativeArrayInject(vm: *VM, recv: Value, args: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const elems: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    var acc: Value = if (args.len > 0) args[0] else blk: {
        if (arr.len == 0) break :blk Value.nil;
        break :blk elems[0];
    };
    const start: u16 = if (args.len > 0) 0 else 1;
    var i: u16 = start;
    while (i < arr.len) : (i += 1) {
        const pair = [_]Value{ acc, elems[i] };
        acc = vm.yieldBlock(blk, pair[0..2]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return acc;
}

/// `arr.sort` — in-place-ish: allocates a new sorted array using
/// fixnum ordering. Non-fixnum elements fall back to byte order for
/// strings; other types sort by raw Value bits (consistent but not
/// meaningful). A sort-with-block variant is TODO.
fn nativeArraySort(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const arr: *const heap_mod.RArrayPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const n: u32 = arr.len;

    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + n * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_ARRAY;
    const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    out_payload.* = .{ .len = @intCast(n), .capa = @intCast(n) };
    const dst: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));

    // Re-fetch source pointer after heap alloc (GC may have compacted).
    const ptr_after = vm.getObjPtr(recv) orelse return Value.nil;
    const src_after: [*]const Value = @ptrCast(@alignCast(ptr_after + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: u32 = 0;
    while (i < n) : (i += 1) dst[i] = src_after[i];

    // Comparator: fixnum-aware when both sides are ints, byte-order for
    // two strings, otherwise fall back to raw Value bits (deterministic
    // though not semantically meaningful).
    const Cmp = struct {
        fn lessThan(vmptr: *VM, lhs: Value, rhs: Value) bool {
            if (lhs.asFixnum()) |ax| if (rhs.asFixnum()) |bx| return ax < bx;
            if (vmptr.getStringData(lhs)) |ad| if (vmptr.getStringData(rhs)) |bd| {
                return std.mem.lessThan(u8, ad, bd);
            };
            return lhs.raw < rhs.raw;
        }
    };
    std.mem.sort(Value, dst[0..n], vm, Cmp.lessThan);

    return alloc.val;
}

/// `hash.each { |k, v| ... }` — yields each key/value pair.
fn nativeHashEach(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const h: *const heap_mod.RHashPayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const data: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RHashPayload)));
    var i: u16 = 0;
    while (i < h.count) : (i += 1) {
        const pair = [_]Value{ data[i * 2], data[i * 2 + 1] };
        _ = vm.yieldBlock(blk, pair[0..2]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `n.upto(m) { |i| ... }` — yields i = n, n+1, …, m inclusive.
fn nativeIntUpto(vm: *VM, recv: Value, args: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    if (args.len == 0) return Value.nil;
    const start = recv.asFixnum() orelse return Value.nil;
    const end_v = args[0].asFixnum() orelse return Value.nil;
    var i: i32 = start;
    while (i <= end_v) : (i += 1) {
        const one = [_]Value{Value.fromFixnumUnchecked(i)};
        _ = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `n.downto(m) { |i| ... }` — yields i = n, n-1, …, m inclusive.
fn nativeIntDownto(vm: *VM, recv: Value, args: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    if (args.len == 0) return Value.nil;
    const start = recv.asFixnum() orelse return Value.nil;
    const end_v = args[0].asFixnum() orelse return Value.nil;
    var i: i32 = start;
    while (i >= end_v) : (i -= 1) {
        const one = [_]Value{Value.fromFixnumUnchecked(i)};
        _ = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `(a..b).to_a` — materializes the range into a flat array. Essential
/// because many Ruby idioms like `(1..10).select { … }` start with a
/// range rather than an array.
fn nativeRangeToA(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const rp: *const heap_mod.RRangePayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const bounds: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RRangePayload)));
    const lo = bounds[0].asFixnum() orelse return Value.nil;
    const hi = bounds[1].asFixnum() orelse return Value.nil;
    const end: i32 = if (rp.exclusive != 0) hi else hi + 1;
    if (end <= lo) {
        const payload_bytes = @sizeOf(heap_mod.RArrayPayload);
        const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
        const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
        hdr.class_id = CLASS_ARRAY;
        const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
        out_payload.* = .{ .len = 0, .capa = 0 };
        return alloc.val;
    }
    const n: u32 = @intCast(end - lo);
    const payload_bytes = @sizeOf(heap_mod.RArrayPayload) + n * @sizeOf(Value);
    const alloc = vm.allocHeapObj(.array, payload_bytes) orelse return Value.nil;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_ARRAY;
    const out_payload: *heap_mod.RArrayPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    out_payload.* = .{ .len = @intCast(n), .capa = @intCast(n) };
    const out_elems: [*]Value = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RArrayPayload)));
    var i: i32 = lo;
    var w: u32 = 0;
    while (i < end) : (i += 1) {
        out_elems[w] = Value.fromFixnumUnchecked(i);
        w += 1;
    }
    return alloc.val;
}

/// `(a..b).each { |x| ... }` — yields successive integers; returns the
/// range. Only supports integer endpoints in Phase 3.
fn nativeRangeEach(vm: *VM, recv: Value, _: []const Value, block: ?Value) Value {
    const blk = block orelse return Value.nil;
    const ptr = vm.getObjPtr(recv) orelse return Value.nil;
    const rp: *const heap_mod.RRangePayload = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader)));
    const bounds: [*]const Value = @ptrCast(@alignCast(ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RRangePayload)));
    const lo = bounds[0].asFixnum() orelse return Value.nil;
    const hi = bounds[1].asFixnum() orelse return Value.nil;
    const end: i32 = if (rp.exclusive != 0) hi else hi + 1;
    var i: i32 = lo;
    while (i < end) : (i += 1) {
        const one = [_]Value{Value.fromFixnumUnchecked(i)};
        _ = vm.yieldBlock(blk, one[0..1]) orelse return Value.nil;
        if (vm.consumeBreak()) |bv| return bv;
    }
    return recv;
}

/// `loop { ... }` — infinite loop; only terminates if the block breaks
/// or raises. Since `break`-from-block has not been wired through native
/// boundaries yet, invoking `loop` would either hang the VM (if we ran
/// the block forever) or silently no-op (if we skipped it, hiding user
/// bugs). We choose to fail loudly: a single yield whose return value is
/// ignored, then an explicit RuntimeError surfaced to the caller.
fn nativeKernelLoop(vm: *VM, _: Value, _: []const Value, block: ?Value) Value {
    _ = block;
    _ = vm;
    // Intentionally unimplemented: return an undef sentinel so the VM
    // propagates an error at the call site rather than silently pass.
    // When `break`-from-block is wired, restore the iterative yield
    // loop here and drop this stub.
    return Value.undef;
}

fn nativeIntPow(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const base = recv.asFixnum() orelse return Value.nil;
    const exp = args[0].asFixnum() orelse return Value.nil;
    if (exp < 0) return Value.nil;
    var r: i64 = 1;
    var b: i64 = base;
    var e: i32 = exp;
    while (e > 0) : (e >>= 1) {
        if ((e & 1) != 0) {
            r *= b;
            if (r > Value.max_fixnum or r < Value.min_fixnum) return Value.nil;
        }
        if (e > 1) {
            b *= b;
            if (b > Value.max_fixnum or b < Value.min_fixnum) return Value.nil;
        }
    }
    return Value.fromFixnumUnchecked(@intCast(r));
}

fn nativeIntCmp(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_n = recv.asFixnum() orelse return Value.nil;
    // Mixed receiver: `5 <=> 3.14` promotes self to f64 and re-enters
    // float comparison so the NaN/Infinity rules match `Float#<=>`.
    if (vm.getFloatData(args[0])) |b_f| {
        const a_f: f64 = @floatFromInt(a_n);
        if (std.math.isNan(b_f)) return Value.nil;
        if (a_f < b_f) return Value.fromFixnumUnchecked(-1);
        if (a_f > b_f) return Value.fromFixnumUnchecked(1);
        return Value.fromFixnumUnchecked(0);
    }
    const b_n = args[0].asFixnum() orelse return Value.nil;
    if (a_n < b_n) return Value.fromFixnumUnchecked(-1);
    if (a_n > b_n) return Value.fromFixnumUnchecked(1);
    return Value.fromFixnumUnchecked(0);
}

fn nativeImmedEq(_: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.false_;
    return Value.fromBool(recv.eql(args[0]));
}

fn nativeNot(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return Value.fromBool(recv.isFalsy());
}

// ── Float / numeric coercion natives ─────────────────────────────────

fn nativeIntToI(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return recv;
}

fn nativeIntToF(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const n = recv.asFixnum() orelse return Value.nil;
    return vm.allocFloat(@floatFromInt(n)) orelse Value.nil;
}

fn nativeFloatToS(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const f = vm.getFloatData(recv) orelse return Value.nil;
    var buf: [64]u8 = undefined;
    const s = VM.formatFloatBuf(&buf, f) orelse return Value.nil;
    return allocString(vm, s) orelse Value.nil;
}

/// Ruby-style truncation toward zero.
/// - NaN / ±Infinity raise `FloatDomainError` (MRI-compatible).
/// - Values outside the 31-bit fixnum range raise `RangeError` (MRI
///   returns a Bignum; we don't have one yet, so we surface the
///   condition as a catchable error instead of silent nil).
fn nativeFloatToI(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const f = vm.getFloatData(recv) orelse return Value.nil;
    if (std.math.isNan(f) or std.math.isInf(f)) return vm.raise(error.FloatDomainError);
    const truncated = @trunc(f);
    if (truncated > @as(f64, @floatFromInt(Value.max_fixnum))) return vm.raise(error.RangeError);
    if (truncated < @as(f64, @floatFromInt(Value.min_fixnum))) return vm.raise(error.RangeError);
    return Value.fromFixnumUnchecked(@intFromFloat(truncated));
}

fn nativeFloatToF(_: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    return recv;
}

fn nativeFloatAbs(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const f = vm.getFloatData(recv) orelse return Value.nil;
    return vm.allocFloat(@abs(f)) orelse Value.nil;
}

fn nativeFloatZeroQ(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const f = vm.getFloatData(recv) orelse return Value.false_;
    return Value.fromBool(f == 0.0);
}

fn nativeFloatCmp(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) return Value.nil;
    const a_f = vm.getFloatData(recv) orelse return Value.nil;
    const b_f = vm.toFloat(args[0]) orelse return Value.nil;
    // Ruby: `NaN <=> x` and `x <=> NaN` return nil because NaN is
    // unordered. Without this, Comparable-based methods (sort, min,
    // max) silently bucket NaN as "equal" to everything.
    if (std.math.isNan(a_f) or std.math.isNan(b_f)) return Value.nil;
    if (a_f < b_f) return Value.fromFixnumUnchecked(-1);
    if (a_f > b_f) return Value.fromFixnumUnchecked(1);
    return Value.fromFixnumUnchecked(0);
}

/// Shared shape for the explicit-dispatch Float operators. Each op
/// extracts lhs/rhs as f64 (with fixnum promotion), performs the
/// computation, and allocates a new heap Float — mirroring the inline
/// arithmetic path in `doFloatBinOp`. `/` lets IEEE-754 produce
/// signed infinity / NaN instead of raising (Ruby-compatible). `%`
/// still returns nil on a zero divisor because native methods can't
/// currently surface a VmError to a rescue handler; the VM opcode
/// path raises properly and is what `a % b` actually dispatches to.
fn floatBinArith(vm: *VM, recv: Value, args: []const Value, comptime op: u8) Value {
    if (args.len == 0) return Value.nil;
    const a_f = vm.getFloatData(recv) orelse return Value.nil;
    const b_f = vm.toFloat(args[0]) orelse return Value.nil;
    const r: f64 = switch (op) {
        '+' => a_f + b_f,
        '-' => a_f - b_f,
        '*' => a_f * b_f,
        '/' => a_f / b_f,
        // `/` uses IEEE (Infinity / NaN, no raise). `%` matches the
        // opcode path: Ruby raises ZeroDivisionError on a zero
        // divisor. Now that natives have an exception channel, the
        // explicit-dispatch path agrees with `a % 0.0`.
        '%' => if (b_f == 0.0) return vm.raise(error.DivisionByZero) else VM.rubyFloatMod(a_f, b_f),
        else => return Value.nil,
    };
    return vm.allocFloat(r) orelse Value.nil;
}

fn nativeFloatAdd(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinArith(vm, recv, args, '+');
}
fn nativeFloatSub(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinArith(vm, recv, args, '-');
}
fn nativeFloatMul(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinArith(vm, recv, args, '*');
}
fn nativeFloatDiv(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinArith(vm, recv, args, '/');
}
fn nativeFloatMod(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinArith(vm, recv, args, '%');
}

fn floatBinCmp(vm: *VM, recv: Value, args: []const Value, comptime op: u8) Value {
    if (args.len == 0) return Value.false_;
    const a_f = vm.getFloatData(recv) orelse return Value.false_;
    const b_f = vm.toFloat(args[0]) orelse return Value.false_;
    return Value.fromBool(switch (op) {
        '=' => a_f == b_f,
        '<' => a_f < b_f,
        'L' => a_f <= b_f,
        '>' => a_f > b_f,
        'G' => a_f >= b_f,
        else => false,
    });
}

fn nativeFloatEq(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinCmp(vm, recv, args, '=');
}
fn nativeFloatLt(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinCmp(vm, recv, args, '<');
}
fn nativeFloatLe(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinCmp(vm, recv, args, 'L');
}
fn nativeFloatGt(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinCmp(vm, recv, args, '>');
}
fn nativeFloatGe(vm: *VM, recv: Value, args: []const Value, _: ?Value) Value {
    return floatBinCmp(vm, recv, args, 'G');
}

fn nativeStringToI(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const s = vm.getStringData(recv) orelse return Value.fromFixnumUnchecked(0);
    // Ruby-lenient: skip leading whitespace, accept a prefix of digits
    // (with optional sign), return 0 if no digits. Doesn't parse 0x/0b
    // prefixes yet — a close-enough approximation for Phase 1.
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    var n: i64 = 0;
    var any = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        any = true;
        n = n * 10 + (s[i] - '0');
    }
    if (!any) return Value.fromFixnumUnchecked(0);
    if (neg) n = -n;
    if (n > Value.max_fixnum or n < Value.min_fixnum) return Value.nil;
    return Value.fromFixnumUnchecked(@intCast(n));
}

fn nativeStringToF(vm: *VM, recv: Value, _: []const Value, _: ?Value) Value {
    const s = vm.getStringData(recv) orelse return vm.allocFloat(0.0) orelse Value.nil;
    // Ruby's `String#to_f` is lenient: skip leading whitespace, parse
    // the longest valid numeric prefix, ignore trailing garbage, and
    // return 0.0 if no valid prefix exists. `parseFloat` over the
    // whole slice would fail on `"3.14abc"`, so we walk the prefix
    // manually and hand just that slice to the parser.
    const f = parseFloatPrefix(s);
    return vm.allocFloat(f) orelse Value.nil;
}

/// Scan the Ruby-compatible longest float prefix out of `s` and parse
/// it with Zig's stdlib. Returns 0.0 when no valid prefix is present.
/// Accepts: optional ws, optional sign, integer part (digits and `_`),
/// optional `.digits`, optional `[eE][+-]?digits`. Trailing junk is
/// ignored, matching `"3.14abc".to_f # => 3.14`.
fn parseFloatPrefix(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    const prefix_start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const digits_start = i;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
    const had_int_digits = i > digits_start;
    var had_frac_digits = false;
    if (i < s.len and s[i] == '.' and i + 1 < s.len and std.ascii.isDigit(s[i + 1])) {
        i += 1;
        const frac_start = i;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
        had_frac_digits = i > frac_start;
    }
    if (!had_int_digits and !had_frac_digits) return 0.0;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var look: usize = i + 1;
        if (look < s.len and (s[look] == '+' or s[look] == '-')) look += 1;
        if (look < s.len and std.ascii.isDigit(s[look])) {
            i = look;
            while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) i += 1;
        }
    }

    // Strip underscores into a scratch buffer before handing to stdlib.
    const slice = s[prefix_start..i];
    var buf: [64]u8 = undefined;
    if (slice.len > buf.len) return 0.0;
    var n: usize = 0;
    for (slice) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch 0.0;
}

// ── String allocation helper ─────────────────────────────────────────

pub fn allocString(vm: *VM, data: []const u8) ?Value {
    const payload_bytes = @sizeOf(heap_mod.RStringPayload) + @as(u32, @intCast(data.len));
    const alloc = vm.allocHeapObj(.string, payload_bytes) orelse return null;
    const hdr: *ObjHeader = @ptrCast(@alignCast(alloc.ptr));
    hdr.class_id = CLASS_STRING;
    const str_payload: *heap_mod.RStringPayload = @ptrCast(@alignCast(alloc.ptr + @sizeOf(ObjHeader)));
    str_payload.* = .{ .len = @intCast(data.len) };
    const dest: [*]u8 = alloc.ptr + @sizeOf(ObjHeader) + @sizeOf(heap_mod.RStringPayload);
    @memcpy(dest[0..data.len], data);
    return alloc.val;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

const Asm = @import("assembler.zig").Assembler;

fn makeStubFunc() IrFunc {
    const S = struct {
        var code = [_]u8{ @intFromEnum(@as(@import("opcode.zig").Opcode, .LOAD_I8)), 0, 99, @intFromEnum(@as(@import("opcode.zig").Opcode, .RETURN)), 0 };
    };
    return .{
        .bytecode = &S.code,
        .bytecode_len = 5,
        .nregs = 1,
        .nlocals = 0,
        .const_pool = &.{},
    };
}

test "class: bootstrap classes exist" {
    const ct = ClassTable.init();
    try std.testing.expect(ct.classes[CLASS_OBJECT].used);
    try std.testing.expect(ct.classes[CLASS_INTEGER].used);
    try std.testing.expect(ct.classes[CLASS_NIL_CLASS].used);
    try std.testing.expectEqual(@as(u8, 0), ct.classes[CLASS_OBJECT].superclass_id);
    try std.testing.expectEqual(CLASS_OBJECT, ct.classes[CLASS_INTEGER].superclass_id);
}

test "class: define and lookup method" {
    var ct = ClassTable.init();
    const func = makeStubFunc();
    try ct.defineMethod(CLASS_OBJECT, 42, &func);
    const found = ct.lookupMethod(CLASS_OBJECT, 42);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(&func, found.?.bytecode);
}

test "class: method lookup walks superclass" {
    var ct = ClassTable.init();
    const func = makeStubFunc();
    try ct.defineMethod(CLASS_OBJECT, 10, &func);
    const found = ct.lookupMethod(CLASS_INTEGER, 10);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(&func, found.?.bytecode);
}

test "class: method not found returns null" {
    const ct = ClassTable.init();
    try std.testing.expect(ct.lookupMethod(CLASS_OBJECT, 999) == null);
}

test "class: redefine method overwrites" {
    var ct = ClassTable.init();
    const func1 = makeStubFunc();
    const func2 = makeStubFunc();
    try ct.defineMethod(CLASS_OBJECT, 5, &func1);
    try ct.defineMethod(CLASS_OBJECT, 5, &func2);
    try std.testing.expectEqual(&func2, ct.lookupMethod(CLASS_OBJECT, 5).?.bytecode);
    try std.testing.expectEqual(@as(u8, 1), ct.classes[CLASS_OBJECT].method_count);
}

test "class: classOfImmediate" {
    try std.testing.expectEqual(CLASS_INTEGER, ClassTable.classOfImmediate(Value.fromFixnum(42).?));
    try std.testing.expectEqual(CLASS_NIL_CLASS, ClassTable.classOfImmediate(Value.nil));
    try std.testing.expectEqual(CLASS_TRUE_CLASS, ClassTable.classOfImmediate(Value.true_));
    try std.testing.expectEqual(CLASS_FALSE_CLASS, ClassTable.classOfImmediate(Value.false_));
    try std.testing.expectEqual(CLASS_SYMBOL, ClassTable.classOfImmediate(Value.fromSymbol(7)));
}

test "class: NilClass inherits Object methods" {
    var ct = ClassTable.init();
    const func = makeStubFunc();
    try ct.defineMethod(CLASS_OBJECT, 77, &func);
    try std.testing.expect(ct.lookupMethod(CLASS_NIL_CLASS, 77) != null);
    try std.testing.expect(ct.lookupMethod(CLASS_TRUE_CLASS, 77) != null);
    try std.testing.expect(ct.lookupMethod(CLASS_FALSE_CLASS, 77) != null);
}

test "class: constant table set and get" {
    var ct = ConstantTable{};
    try ct.set(10, Value.fromFixnum(42).?);
    try std.testing.expectEqual(@as(i32, 42), ct.get(10).?.asFixnum().?);
    try std.testing.expect(ct.get(99) == null);
}

test "class: native method dispatch" {
    var ct = ClassTable.init();
    const stub_native: NativeFn = &struct {
        fn f(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
            return Value.fromFixnum(99).?;
        }
    }.f;
    try ct.defineMethodImpl(CLASS_OBJECT, 42, .{ .native = stub_native });
    const found = ct.lookupMethod(CLASS_OBJECT, 42);
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == .native);
}
