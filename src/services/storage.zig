// Flash-backed key-value storage.
//
// Uses an append-log format in the CONFIG flash region. Each entry is:
//   [1 byte key_len] [1 byte val_len] [key bytes] [val bytes]
//
// Append-only semantics: new values for a key are appended as new
// entries; the last entry for a key wins. A val_len of 0xFF is a
// delete tombstone — it has zero value bytes following it (no payload
// to skip). An erased region (all 0xFF) marks end-of-log.
//
// Flash reads are via XIP (direct pointer). Flash writes require the
// RP2040 ROM flash routines executed from RAM with interrupts disabled.
// For now, this module supports read-only access to flash-resident KV
// data, with write support gated behind a RAM-resident flash driver
// that will be added when storage.set() is needed in production.

const c = @import("../vm/c.zig");
const console = @import("console.zig");
const flash = @import("../config/flash.zig");

const MAX_KEY_LEN = 63;
const MAX_VAL_LEN = 253;
const ENTRY_OVERHEAD = 2;

var initialized = false;
var entry_count: u32 = 0;

pub fn init() void {
    console.puts("[storage] init\n");
    entry_count = countEntries();
    initialized = true;
}

pub fn get(key: []const u8) ?[]const u8 {
    if (key.len == 0 or key.len > MAX_KEY_LEN) return null;

    const base = flash.flashToPtr(flash.CONFIG_BASE);
    const size = flash.CONFIG_SIZE;
    var result: ?[]const u8 = null;
    var pos: u32 = 0;

    while (pos + ENTRY_OVERHEAD < size) {
        const kl: usize = base[pos];
        const vl: usize = base[pos + 1];
        if (kl == 0xFF) break;
        if (kl == 0) break;
        if (pos + ENTRY_OVERHEAD + kl + vl > size) break;

        const entry_key = base[pos + 2 ..][0..kl];
        if (kl == key.len and eql(entry_key, key)) {
            if (vl == 0xFF) {
                result = null;
            } else {
                result = base[pos + 2 + kl ..][0..vl];
            }
        }
        const entry_vl: usize = if (vl == 0xFF) 0 else vl;
        pos += @intCast(ENTRY_OVERHEAD + kl + entry_vl);
    }

    return result;
}

pub fn set(_: []const u8, _: []const u8) bool {
    console.puts("[storage] write not yet implemented (needs RAM flash driver)\n");
    return false;
}

pub fn del(_: []const u8) bool {
    console.puts("[storage] delete not yet implemented (needs RAM flash driver)\n");
    return false;
}

fn countEntries() u32 {
    const base = flash.flashToPtr(flash.CONFIG_BASE);
    const size = flash.CONFIG_SIZE;
    var count: u32 = 0;
    var pos: u32 = 0;

    while (pos + ENTRY_OVERHEAD < size) {
        const kl: usize = base[pos];
        const vl: usize = base[pos + 1];
        if (kl == 0xFF) break;
        if (kl == 0) break;
        if (pos + ENTRY_OVERHEAD + kl > size) break;
        const entry_vl: usize = if (vl == 0xFF) 0 else vl;
        pos += @intCast(ENTRY_OVERHEAD + kl + entry_vl);
        count += 1;
    }

    return count;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

// ── JS exports ───────────────────────────────────────────────────────

pub export fn js_storage_get(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_NULL;
    const cx = ctx orelse return c.JS_NULL;
    const args = argv orelse return c.JS_NULL;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const key = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_NULL;
    if (get(key[0..len])) |val| return c.JS_NewStringLen(cx, val.ptr, val.len);
    return c.JS_NULL;
}

pub export fn js_storage_set(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 2) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var kb: c.JSCStringBuf = undefined;
    var vb: c.JSCStringBuf = undefined;
    var kl: usize = 0;
    var vl: usize = 0;
    const key = c.JS_ToCStringLen(cx, &kl, args[0], &kb) orelse return c.JS_UNDEFINED;
    const val = c.JS_ToCStringLen(cx, &vl, args[1], &vb) orelse return c.JS_UNDEFINED;
    const ok = set(key[0..kl], val[0..vl]);
    return c.JS_NewBool(@intFromBool(ok));
}

pub export fn js_storage_del(ctx: ?*c.JSContext, _: ?*c.JSValue, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
    if (argc < 1) return c.JS_UNDEFINED;
    const cx = ctx orelse return c.JS_UNDEFINED;
    const args = argv orelse return c.JS_UNDEFINED;
    var buf: c.JSCStringBuf = undefined;
    var len: usize = 0;
    const key = c.JS_ToCStringLen(cx, &len, args[0], &buf) orelse return c.JS_UNDEFINED;
    const ok = del(key[0..len]);
    return c.JS_NewBool(@intFromBool(ok));
}
