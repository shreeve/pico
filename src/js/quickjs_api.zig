// Manual Zig bindings for the MQuickJS C API.
// We declare these by hand instead of using @cImport because
// @cImport requires libc headers, which aren't available on
// freestanding targets.  This also gives us tighter control
// over exactly which symbols cross the Zig/C boundary.

const std = @import("std");
const CC = std.builtin.CallingConvention;

pub const JSContext = opaque {};
pub const JSValue = u32; // 32-bit on ARM (JSW == 4)
pub const JSWord = u32;
pub const JS_BOOL = c_int;

// Tags
pub const JS_TAG_INT: u32 = 0;
pub const JS_TAG_PTR: u32 = 1;
pub const JS_TAG_SPECIAL: u32 = 3;
pub const JS_TAG_BOOL: u32 = JS_TAG_SPECIAL | (0 << 2);
pub const JS_TAG_NULL: u32 = JS_TAG_SPECIAL | (1 << 2);
pub const JS_TAG_UNDEFINED: u32 = JS_TAG_SPECIAL | (2 << 2);
pub const JS_TAG_EXCEPTION: u32 = JS_TAG_SPECIAL | (3 << 2);

pub const JS_TAG_SPECIAL_BITS: u5 = 5;

pub inline fn JS_VALUE_MAKE_SPECIAL(tag: u32, v: u32) JSValue {
    return tag | (v << JS_TAG_SPECIAL_BITS);
}

pub const JS_NULL: JSValue = JS_VALUE_MAKE_SPECIAL(JS_TAG_NULL, 0);
pub const JS_UNDEFINED: JSValue = JS_VALUE_MAKE_SPECIAL(JS_TAG_UNDEFINED, 0);
pub const JS_FALSE: JSValue = JS_VALUE_MAKE_SPECIAL(JS_TAG_BOOL, 0);
pub const JS_TRUE: JSValue = JS_VALUE_MAKE_SPECIAL(JS_TAG_BOOL, 1);
pub const JS_EXCEPTION: JSValue = JS_VALUE_MAKE_SPECIAL(JS_TAG_EXCEPTION, 0);

// Eval flags
pub const JS_EVAL_RETVAL: c_int = 1 << 0;
pub const JS_EVAL_REPL: c_int = 1 << 1;
pub const JS_EVAL_STRIP_COL: c_int = 1 << 2;
pub const JS_EVAL_JSON: c_int = 1 << 3;

// Dump flags
pub const JS_DUMP_LONG: c_int = 1 << 0;
pub const JS_DUMP_NOQUOTE: c_int = 1 << 1;
pub const JS_DUMP_RAW: c_int = 1 << 2;

// Class IDs
pub const JS_CLASS_OBJECT = 0;
pub const JS_CLASS_TYPE_ERROR = 15;
pub const JS_CLASS_REFERENCE_ERROR = 13;
pub const JS_CLASS_INTERNAL_ERROR = 17;
pub const JS_CLASS_RANGE_ERROR = 12;
pub const JS_CLASS_SYNTAX_ERROR = 14;

// Call flags
pub const FRAME_CF_CTOR: c_int = 1 << 16;

pub const JSCStringBuf = extern struct {
    buf: [5]u8,
};

pub const JSGCRef = extern struct {
    val: JSValue,
    prev: ?*JSGCRef,
};

pub const JSSTDLibraryDef = extern struct {
    stdlib_table: ?*const JSWord,
    c_function_table: ?*const anyopaque,
    c_finalizer_table: ?*const anyopaque,
    stdlib_table_len: u32,
    stdlib_table_align: u32,
    sorted_atoms_offset: u32,
    global_object_offset: u32,
    class_count: u32,
};

pub const JSWriteFunc = *const fn (?*anyopaque, ?[*]const u8, usize) callconv(CC.c) void;
pub const JSCFunction = *const fn (?*JSContext, ?*JSValue, c_int, ?[*]JSValue) callconv(CC.c) JSValue;

// Core API
pub extern fn JS_NewContext(mem_start: ?*anyopaque, mem_size: usize, stdlib_def: *const JSSTDLibraryDef) ?*JSContext;
pub extern fn JS_FreeContext(ctx: *JSContext) void;
pub extern fn JS_SetLogFunc(ctx: *JSContext, write_func: JSWriteFunc) void;
pub extern fn JS_SetContextOpaque(ctx: *JSContext, user_data: ?*anyopaque) void;
pub extern fn JS_SetRandomSeed(ctx: *JSContext, seed: u64) void;

// Eval / Run
pub extern fn JS_Eval(ctx: *JSContext, input: [*]const u8, input_len: usize, filename: [*]const u8, eval_flags: c_int) JSValue;
pub extern fn JS_Parse(ctx: *JSContext, input: [*]const u8, input_len: usize, filename: [*]const u8, eval_flags: c_int) JSValue;
pub extern fn JS_Run(ctx: *JSContext, val: JSValue) JSValue;

// GC
pub extern fn JS_GC(ctx: *JSContext) void;
pub extern fn JS_PushGCRef(ctx: *JSContext, ref: *JSGCRef) *JSValue;
pub extern fn JS_PopGCRef(ctx: *JSContext, ref: *JSGCRef) JSValue;

// Value creation
pub extern fn JS_NewInt32(ctx: *JSContext, val: i32) JSValue;
pub extern fn JS_NewUint32(ctx: *JSContext, val: u32) JSValue;
pub extern fn JS_NewInt64(ctx: *JSContext, val: i64) JSValue;
pub extern fn JS_NewFloat64(ctx: *JSContext, d: f64) JSValue;
pub extern fn JS_NewStringLen(ctx: *JSContext, buf: [*]const u8, buf_len: usize) JSValue;
pub extern fn JS_NewString(ctx: *JSContext, buf: [*:0]const u8) JSValue;
pub extern fn JS_NewObject(ctx: *JSContext) JSValue;
pub extern fn JS_NewArray(ctx: *JSContext, initial_len: c_int) JSValue;

// Value conversion
pub extern fn JS_ToInt32(ctx: *JSContext, pres: *i32, val: JSValue) c_int;
pub extern fn JS_ToUint32(ctx: *JSContext, pres: *u32, val: JSValue) c_int;
pub extern fn JS_ToNumber(ctx: *JSContext, pres: *f64, val: JSValue) c_int;
pub extern fn JS_ToCStringLen(ctx: *JSContext, plen: *usize, val: JSValue, buf: *JSCStringBuf) ?[*]const u8;
pub extern fn JS_ToCString(ctx: *JSContext, val: JSValue, buf: *JSCStringBuf) ?[*:0]const u8;
pub extern fn JS_ToString(ctx: *JSContext, val: JSValue) JSValue;

// Value inspection
pub extern fn JS_IsNumber(ctx: *JSContext, val: JSValue) JS_BOOL;
pub extern fn JS_IsString(ctx: *JSContext, val: JSValue) JS_BOOL;
pub extern fn JS_IsError(ctx: *JSContext, val: JSValue) JS_BOOL;
pub extern fn JS_IsFunction(ctx: *JSContext, val: JSValue) JS_BOOL;

pub inline fn JS_IsException(v: JSValue) bool {
    return v == JS_EXCEPTION;
}
pub inline fn JS_IsUndefined(v: JSValue) bool {
    return v == JS_UNDEFINED;
}
pub inline fn JS_IsNull(v: JSValue) bool {
    return v == JS_NULL;
}
pub inline fn JS_NewBool(val: c_int) JSValue {
    return JS_VALUE_MAKE_SPECIAL(JS_TAG_BOOL, if (val != 0) 1 else 0);
}

// Property access
pub extern fn JS_GetGlobalObject(ctx: *JSContext) JSValue;
pub extern fn JS_GetPropertyStr(ctx: *JSContext, this_obj: JSValue, str: [*:0]const u8) JSValue;
pub extern fn JS_SetPropertyStr(ctx: *JSContext, this_obj: JSValue, str: [*:0]const u8, val: JSValue) JSValue;
pub extern fn JS_GetPropertyUint32(ctx: *JSContext, obj: JSValue, idx: u32) JSValue;
pub extern fn JS_SetPropertyUint32(ctx: *JSContext, this_obj: JSValue, idx: u32, val: JSValue) JSValue;

// Object / opaque
pub extern fn JS_GetClassID(ctx: *JSContext, val: JSValue) c_int;
pub extern fn JS_SetOpaque(ctx: *JSContext, val: JSValue, op: ?*anyopaque) void;
pub extern fn JS_GetOpaque(ctx: *JSContext, val: JSValue) ?*anyopaque;

// Error handling
pub extern fn JS_GetException(ctx: *JSContext) JSValue;
pub extern fn JS_Throw(ctx: *JSContext, obj: JSValue) JSValue;

// Call
pub extern fn JS_StackCheck(ctx: *JSContext, len: u32) c_int;
pub extern fn JS_PushArg(ctx: *JSContext, val: JSValue) void;
pub extern fn JS_Call(ctx: *JSContext, call_flags: c_int) JSValue;

// Debug
pub extern fn JS_PrintValue(ctx: *JSContext, val: JSValue) void;
pub extern fn JS_PrintValueF(ctx: *JSContext, val: JSValue, flags: c_int) void;
pub extern fn JS_DumpMemory(ctx: *JSContext, is_long: JS_BOOL) void;
