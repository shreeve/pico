// MQuickJS engine wrapper.
// Owns the JS context lifecycle, provides safe Zig wrappers
// around the C API, and wires up the pico native functions.
const memory = @import("../runtime/memory_pool.zig");
const c = @import("quickjs_api.zig");

pub const JSValue = c.JSValue;
pub const JSContext = c.JSContext;
pub const JS_UNDEFINED = c.JS_UNDEFINED;
pub const JS_NULL = c.JS_NULL;
pub const JS_EXCEPTION = c.JS_EXCEPTION;
pub const JS_TRUE = c.JS_TRUE;
pub const JS_FALSE = c.JS_FALSE;
pub const JS_EVAL_RETVAL = c.JS_EVAL_RETVAL;

extern const js_stdlib: c.JSSTDLibraryDef;

var ctx: ?*c.JSContext = null;
var vm_heap: ?memory.Region = null;

pub const Config = struct {
    heap_size: usize = 64 * 1024,
    log_fn: ?c.JSWriteFunc = null,
};

pub fn init(config: Config) !void {
    vm_heap = memory.allocVmHeap(config.heap_size) orelse return error.OutOfMemory;
    const heap = vm_heap.?;

    ctx = c.JS_NewContext(heap.base, heap.size, &js_stdlib);
    if (ctx == null) return error.ContextCreationFailed;

    if (config.log_fn) |lf| {
        c.JS_SetLogFunc(ctx.?, lf);
    }
}

pub fn deinit() void {
    if (ctx) |cx| {
        c.JS_FreeContext(cx);
        ctx = null;
    }
    vm_heap = null;
}

pub const EvalError = error{
    NoContext,
    Exception,
};

pub fn eval(source: []const u8, filename: []const u8) EvalError!JSValue {
    const cx = ctx orelse return EvalError.NoContext;
    const val = c.JS_Eval(cx, source.ptr, source.len, filename.ptr, JS_EVAL_RETVAL);
    if (c.JS_IsException(val)) {
        dumpException();
        return EvalError.Exception;
    }
    return val;
}

pub fn run(parsed: JSValue) EvalError!JSValue {
    const cx = ctx orelse return EvalError.NoContext;
    const val = c.JS_Run(cx, parsed);
    if (c.JS_IsException(val)) {
        dumpException();
        return EvalError.Exception;
    }
    return val;
}

pub fn gc() void {
    if (ctx) |cx| c.JS_GC(cx);
}

pub fn newInt(val: i32) JSValue {
    const cx = ctx orelse return JS_UNDEFINED;
    return c.JS_NewInt32(cx, val);
}

pub fn newInt64(val: i64) JSValue {
    const cx = ctx orelse return JS_UNDEFINED;
    return c.JS_NewInt64(cx, val);
}

pub fn newString(s: []const u8) JSValue {
    const cx = ctx orelse return JS_UNDEFINED;
    return c.JS_NewStringLen(cx, s.ptr, s.len);
}

pub fn newBool(val: bool) JSValue {
    return c.JS_NewBool(@intFromBool(val));
}

pub fn toInt(val: JSValue) ?i32 {
    const cx = ctx orelse return null;
    var result: i32 = 0;
    if (c.JS_ToInt32(cx, &result, val) != 0) return null;
    return result;
}

pub fn toCString(val: JSValue) ?struct { ptr: [*]const u8, len: usize } {
    const cx = ctx orelse return null;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen(cx, &len, val, &buf) orelse return null;
    return .{ .ptr = ptr, .len = len };
}

pub fn isString(val: JSValue) bool {
    const cx = ctx orelse return false;
    return c.JS_IsString(cx, val) != 0;
}

pub fn getGlobal() JSValue {
    const cx = ctx orelse return JS_UNDEFINED;
    return c.JS_GetGlobalObject(cx);
}

pub fn dumpException() void {
    const cx = ctx orelse return;
    const exc = c.JS_GetException(cx);
    c.JS_PrintValueF(cx, exc, c.JS_DUMP_LONG);
}

pub fn context() ?*c.JSContext {
    return ctx;
}
