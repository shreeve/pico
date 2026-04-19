const std = @import("std");

/// Atom — a globally unique interned identifier. Fixed atoms are assigned
/// at comptime for core VM/native names. Dynamic atoms start after.
pub const Atom = u16;
pub const INVALID_ATOM: Atom = 0xFFFF;

// ── Well-known atoms (fixed IDs, stable across compilations) ─────────

pub const ATOM_NEW: Atom = 0;
pub const ATOM_INITIALIZE: Atom = 1;
pub const ATOM_TO_S: Atom = 2;
pub const ATOM_INSPECT: Atom = 3;
pub const ATOM_CLASS: Atom = 4;
pub const ATOM_OBJECT_ID: Atom = 5;
pub const ATOM_NIL_Q: Atom = 6;
pub const ATOM_PUTS: Atom = 7;
pub const ATOM_PRINT: Atom = 8;
pub const ATOM_P: Atom = 9;

pub const ATOM_ADD: Atom = 10;
pub const ATOM_SUB: Atom = 11;
pub const ATOM_MUL: Atom = 12;
pub const ATOM_DIV: Atom = 13;
pub const ATOM_MOD: Atom = 14;
pub const ATOM_EQ: Atom = 15;
pub const ATOM_LT: Atom = 16;
pub const ATOM_LE: Atom = 17;
pub const ATOM_GT: Atom = 18;
pub const ATOM_GE: Atom = 19;
pub const ATOM_NE: Atom = 20;
pub const ATOM_CMP: Atom = 21;

pub const ATOM_LENGTH: Atom = 22;
pub const ATOM_SIZE: Atom = 23;
pub const ATOM_EMPTY_Q: Atom = 24;
pub const ATOM_AT: Atom = 25;
pub const ATOM_AT_SET: Atom = 26;
pub const ATOM_PUSH: Atom = 27;
pub const ATOM_POP: Atom = 28;
pub const ATOM_FIRST: Atom = 29;
pub const ATOM_LAST: Atom = 30;
pub const ATOM_KEYS: Atom = 31;
pub const ATOM_VALUES: Atom = 32;
pub const ATOM_EACH: Atom = 33;

pub const ATOM_ABS: Atom = 34;
pub const ATOM_ZERO_Q: Atom = 35;
pub const ATOM_EVEN_Q: Atom = 36;
pub const ATOM_ODD_Q: Atom = 37;
pub const ATOM_TO_I: Atom = 38;
pub const ATOM_TO_F: Atom = 80;

pub const ATOM_CONCAT: Atom = 39;
pub const ATOM_CALL: Atom = 40;

pub const ATOM_GPIO_MODE: Atom = 41;
pub const ATOM_GPIO_WRITE: Atom = 42;
pub const ATOM_GPIO_READ: Atom = 43;
pub const ATOM_GPIO_TOGGLE: Atom = 44;
pub const ATOM_SLEEP_MS: Atom = 45;
pub const ATOM_MILLIS: Atom = 46;
pub const ATOM_WIFI_CONNECT: Atom = 47;
pub const ATOM_WIFI_STATUS: Atom = 48;
pub const ATOM_WIFI_IP: Atom = 49;
pub const ATOM_MQTT_CONNECT: Atom = 50;
pub const ATOM_MQTT_PUBLISH: Atom = 51;
pub const ATOM_MQTT_SUBSCRIBE: Atom = 52;
pub const ATOM_MQTT_STATUS: Atom = 53;

pub const ATOM_NOT: Atom = 54; //  !  (unary logical negation)
pub const ATOM_INCLUDE_Q: Atom = 55;
pub const ATOM_HAS_KEY_Q: Atom = 56;
pub const ATOM_FETCH: Atom = 57;
pub const ATOM_JOIN: Atom = 58;
pub const ATOM_BAND: Atom = 59; // &
pub const ATOM_BOR: Atom = 60; // |
pub const ATOM_BXOR: Atom = 61; // ^
pub const ATOM_SHL: Atom = 62; // <<
pub const ATOM_SHR: Atom = 63; // >>
pub const ATOM_BNOT: Atom = 64; // ~
pub const ATOM_POW: Atom = 65; // **
pub const ATOM_TIMES: Atom = 66;
pub const ATOM_MAP: Atom = 67;
pub const ATOM_LOOP: Atom = 68;
pub const ATOM_EACH_WITH_INDEX: Atom = 69;
pub const ATOM_SELECT: Atom = 70;
pub const ATOM_FILTER: Atom = 71;
pub const ATOM_REJECT: Atom = 72;
pub const ATOM_INJECT: Atom = 73;
pub const ATOM_REDUCE: Atom = 74;
pub const ATOM_SORT: Atom = 75;
pub const ATOM_TO_A: Atom = 76;
pub const ATOM_EACH_PAIR: Atom = 77;
pub const ATOM_UPTO: Atom = 78;
pub const ATOM_DOWNTO: Atom = 79;

pub const WELL_KNOWN_COUNT: Atom = 81;
pub const FIRST_DYNAMIC: Atom = WELL_KNOWN_COUNT;

// ── Name tables ──────────────────────────────────────────────────────

const NameEntry = struct { name: []const u8, id: Atom };

/// Sorted by name for binary search lookup.
pub const well_known_by_name = [_]NameEntry{
    .{ .name = "!", .id = ATOM_NOT },
    .{ .name = "!=", .id = ATOM_NE },
    .{ .name = "%", .id = ATOM_MOD },
    .{ .name = "&", .id = ATOM_BAND },
    .{ .name = "*", .id = ATOM_MUL },
    .{ .name = "**", .id = ATOM_POW },
    .{ .name = "+", .id = ATOM_ADD },
    .{ .name = "-", .id = ATOM_SUB },
    .{ .name = "/", .id = ATOM_DIV },
    .{ .name = "<", .id = ATOM_LT },
    .{ .name = "<<", .id = ATOM_SHL },
    .{ .name = "<=", .id = ATOM_LE },
    .{ .name = "<=>", .id = ATOM_CMP },
    .{ .name = "==", .id = ATOM_EQ },
    .{ .name = ">", .id = ATOM_GT },
    .{ .name = ">=", .id = ATOM_GE },
    .{ .name = ">>", .id = ATOM_SHR },
    .{ .name = "[]", .id = ATOM_AT },
    .{ .name = "[]=", .id = ATOM_AT_SET },
    .{ .name = "^", .id = ATOM_BXOR },
    .{ .name = "abs", .id = ATOM_ABS },
    .{ .name = "call", .id = ATOM_CALL },
    .{ .name = "class", .id = ATOM_CLASS },
    .{ .name = "downto", .id = ATOM_DOWNTO },
    .{ .name = "each", .id = ATOM_EACH },
    .{ .name = "each_pair", .id = ATOM_EACH_PAIR },
    .{ .name = "each_with_index", .id = ATOM_EACH_WITH_INDEX },
    .{ .name = "empty?", .id = ATOM_EMPTY_Q },
    .{ .name = "even?", .id = ATOM_EVEN_Q },
    .{ .name = "fetch", .id = ATOM_FETCH },
    .{ .name = "filter", .id = ATOM_FILTER },
    .{ .name = "first", .id = ATOM_FIRST },
    .{ .name = "gpio_mode", .id = ATOM_GPIO_MODE },
    .{ .name = "gpio_read", .id = ATOM_GPIO_READ },
    .{ .name = "gpio_toggle", .id = ATOM_GPIO_TOGGLE },
    .{ .name = "gpio_write", .id = ATOM_GPIO_WRITE },
    .{ .name = "has_key?", .id = ATOM_HAS_KEY_Q },
    .{ .name = "include?", .id = ATOM_INCLUDE_Q },
    .{ .name = "initialize", .id = ATOM_INITIALIZE },
    .{ .name = "inject", .id = ATOM_INJECT },
    .{ .name = "inspect", .id = ATOM_INSPECT },
    .{ .name = "join", .id = ATOM_JOIN },
    .{ .name = "keys", .id = ATOM_KEYS },
    .{ .name = "last", .id = ATOM_LAST },
    .{ .name = "length", .id = ATOM_LENGTH },
    .{ .name = "loop", .id = ATOM_LOOP },
    .{ .name = "map", .id = ATOM_MAP },
    .{ .name = "millis", .id = ATOM_MILLIS },
    .{ .name = "mqtt_connect", .id = ATOM_MQTT_CONNECT },
    .{ .name = "mqtt_publish", .id = ATOM_MQTT_PUBLISH },
    .{ .name = "mqtt_status", .id = ATOM_MQTT_STATUS },
    .{ .name = "mqtt_subscribe", .id = ATOM_MQTT_SUBSCRIBE },
    .{ .name = "new", .id = ATOM_NEW },
    .{ .name = "nil?", .id = ATOM_NIL_Q },
    .{ .name = "object_id", .id = ATOM_OBJECT_ID },
    .{ .name = "odd?", .id = ATOM_ODD_Q },
    .{ .name = "p", .id = ATOM_P },
    .{ .name = "pop", .id = ATOM_POP },
    .{ .name = "print", .id = ATOM_PRINT },
    .{ .name = "push", .id = ATOM_PUSH },
    .{ .name = "puts", .id = ATOM_PUTS },
    .{ .name = "reduce", .id = ATOM_REDUCE },
    .{ .name = "reject", .id = ATOM_REJECT },
    .{ .name = "select", .id = ATOM_SELECT },
    .{ .name = "size", .id = ATOM_SIZE },
    .{ .name = "sleep_ms", .id = ATOM_SLEEP_MS },
    .{ .name = "sort", .id = ATOM_SORT },
    .{ .name = "times", .id = ATOM_TIMES },
    .{ .name = "to_a", .id = ATOM_TO_A },
    .{ .name = "to_f", .id = ATOM_TO_F },
    .{ .name = "to_i", .id = ATOM_TO_I },
    .{ .name = "to_s", .id = ATOM_TO_S },
    .{ .name = "upto", .id = ATOM_UPTO },
    .{ .name = "values", .id = ATOM_VALUES },
    .{ .name = "wifi_connect", .id = ATOM_WIFI_CONNECT },
    .{ .name = "wifi_ip", .id = ATOM_WIFI_IP },
    .{ .name = "wifi_status", .id = ATOM_WIFI_STATUS },
    .{ .name = "zero?", .id = ATOM_ZERO_Q },
    .{ .name = "|", .id = ATOM_BOR },
    .{ .name = "~", .id = ATOM_BNOT },
};

/// ID -> name for debugging and to_s. Index = atom ID.
pub const atom_names = [WELL_KNOWN_COUNT][]const u8{
    "new",     "initialize", "to_s",        "inspect",     "class",
    "object_id", "nil?",     "puts",        "print",       "p",
    "+",       "-",          "*",           "/",           "%",
    "==",      "<",          "<=",          ">",           ">=",
    "!=",      "<=>",
    "length",  "size",       "empty?",      "[]",          "[]=",
    "push",    "pop",        "first",       "last",        "keys",   "values", "each",
    "abs",     "zero?",      "even?",       "odd?",        "to_i",
    "_",       "call",
    "gpio_mode",    "gpio_write",    "gpio_read",    "gpio_toggle",
    "sleep_ms",     "millis",
    "wifi_connect", "wifi_status",   "wifi_ip",
    "mqtt_connect", "mqtt_publish",  "mqtt_subscribe", "mqtt_status",
    "!",       "include?",   "has_key?",    "fetch",       "join",
    "&",       "|",          "^",           "<<",          ">>",
    "~",       "**",         "times",       "map",         "loop",
    "each_with_index", "select", "filter",   "reject",      "inject",
    "reduce",  "sort",       "to_a",        "each_pair",   "upto",
    "downto",
    "to_f",
};

// ── Lookup ───────────────────────────────────────────────────────────

/// Look up a well-known atom by name. O(log n) binary search.
pub fn lookupWellKnown(name: []const u8) ?Atom {
    @setEvalBranchQuota(10000);
    var lo: usize = 0;
    var hi: usize = well_known_by_name.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, well_known_by_name[mid].name, name);
        switch (cmp) {
            .eq => return well_known_by_name[mid].id,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Get the name of an atom (well-known only for now).
pub fn nameOf(id: Atom) ?[]const u8 {
    if (id < WELL_KNOWN_COUNT) return atom_names[id];
    return null;
}

/// Comptime helper: resolve a name to its well-known atom ID.
/// Fails to compile if the name is not a well-known atom.
pub fn atom(comptime name: []const u8) Atom {
    return comptime lookupWellKnown(name) orelse @compileError("unknown atom: " ++ name);
}

// ── Tests ────────────────────────────────────────────────────────────

test "atom: well-known lookup" {
    try std.testing.expectEqual(ATOM_NEW, lookupWellKnown("new").?);
    try std.testing.expectEqual(ATOM_PUTS, lookupWellKnown("puts").?);
    try std.testing.expectEqual(ATOM_ADD, lookupWellKnown("+").?);
    try std.testing.expectEqual(ATOM_LENGTH, lookupWellKnown("length").?);
    try std.testing.expectEqual(ATOM_EMPTY_Q, lookupWellKnown("empty?").?);
    try std.testing.expect(lookupWellKnown("nonexistent") == null);
}

test "atom: nameOf roundtrip" {
    try std.testing.expectEqualStrings("new", nameOf(ATOM_NEW).?);
    try std.testing.expectEqualStrings("puts", nameOf(ATOM_PUTS).?);
    try std.testing.expectEqualStrings("+", nameOf(ATOM_ADD).?);
    try std.testing.expect(nameOf(WELL_KNOWN_COUNT) == null);
}

test "atom: comptime atom() helper" {
    try std.testing.expectEqual(ATOM_INITIALIZE, atom("initialize"));
    try std.testing.expectEqual(ATOM_AT, atom("[]"));
}

test "atom: well_known_by_name is sorted" {
    var i: usize = 1;
    while (i < well_known_by_name.len) : (i += 1) {
        const prev = well_known_by_name[i - 1].name;
        const curr = well_known_by_name[i].name;
        try std.testing.expect(std.mem.order(u8, prev, curr) == .lt);
    }
}
