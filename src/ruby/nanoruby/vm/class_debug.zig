// class_debug.zig — hosted-only native methods extracted from class.zig.
//
// This file is **not** compiled into freestanding firmware builds (such as
// the pico firmware that vendors this tree). It provides:
//
//   • debug Kernel natives (`puts`, `print`, `p`) which write to stderr
//     via `std.debug.print` / `std.Io.File.stderr()` — APIs unavailable on
//     freestanding.
//   • default host-side stub implementations of the platform natives
//     (`gpio_*`, `sleep_ms`, `millis`, `wifi_*`, `mqtt_*`) that print
//     diagnostic lines to stderr. Firmware builds supply their own
//     platform-native table via `class.installPlatformNatives(vm, table)`
//     and do not install these defaults.
//   • `installDebugNatives(vm)` / `installDefaultPlatformNatives(vm)` /
//     back-compat `installNatives(vm, findSym)` wrappers.
//
// Local modifications relative to upstream nanoruby:
//   - Extracted from vm/class.zig to isolate hosted-std usage. See
//     pico/src/ruby/nanoruby/UPSTREAM.md for the full re-vendor procedure.

const std = @import("std");
const Value = @import("value.zig").Value;
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const class = @import("class.zig");
const heap_mod = @import("heap.zig");
const ObjHeader = heap_mod.ObjHeader;
const atom_mod = @import("atom.zig");
const a = atom_mod.atom;

const NativeFn = class.NativeFn;
const NativeMethodDef = class.NativeMethodDef;

// ── Debug natives: puts / print / p ──────────────────────────────────

/// Write a Value in Ruby `puts`/`print` form: strings unquoted, other
/// values rendered via the VM's inspect (which quotes strings). `puts`
/// of a heap string like `"hello"` prints `hello`, not `"hello"`.
fn writeValue(vm: *const VM, v: Value) void {
    if (vm.getStringData(v)) |s| {
        std.debug.print("{s}", .{s});
    } else if (v.isNil()) {
        // nil prints as empty string in puts
    } else {
        inspectValue(vm, v);
    }
}

/// Write a Value in Ruby `p` form (inspect-style): strings quoted,
/// arrays/hashes/ranges fully rendered. Delegates to `VM.inspect`
/// through a local writer that buffers onto stderr.
fn inspectValue(vm: *const VM, v: Value) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    vm.inspect(&fw.interface, v) catch {};
    fw.interface.flush() catch {};
}

fn nativePuts(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) {
        std.debug.print("\n", .{});
    } else {
        for (args) |arg| {
            writeValue(vm, arg);
            std.debug.print("\n", .{});
        }
    }
    return Value.nil;
}

fn nativePrint(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    for (args) |arg| {
        writeValue(vm, arg);
    }
    return Value.nil;
}

fn nativeP(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    for (args, 0..) |arg, i| {
        if (i > 0) std.debug.print(", ", .{});
        inspectValue(vm, arg);
    }
    std.debug.print("\n", .{});
    if (args.len == 1) return args[0];
    return Value.nil;
}

pub const debug_native_table = [_]NativeMethodDef{
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("puts"), .func = &nativePuts },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("print"), .func = &nativePrint },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("p"), .func = &nativeP },
};

// ── Platform stub natives (host-side, mirrors pico bindings API) ─────

fn nativeGpioMode(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len >= 2) {
        const pin = args[0].asFixnum() orelse return Value.nil;
        const mode = args[1].asFixnum() orelse return Value.nil;
        std.debug.print("[gpio] mode pin={d} dir={d}\n", .{ pin, mode });
    }
    return Value.nil;
}

fn nativeGpioWrite(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len >= 2) {
        const pin = args[0].asFixnum() orelse return Value.nil;
        const val = args[1].asFixnum() orelse return Value.nil;
        std.debug.print("[gpio] write pin={d} val={d}\n", .{ pin, val });
    }
    return Value.nil;
}

fn nativeGpioRead(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len >= 1) {
        const pin = args[0].asFixnum() orelse return Value.false_;
        std.debug.print("[gpio] read pin={d}\n", .{pin});
    }
    return Value.fromFixnumUnchecked(0);
}

fn nativeGpioToggle(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len >= 1) {
        const pin = args[0].asFixnum() orelse return Value.nil;
        std.debug.print("[gpio] toggle pin={d}\n", .{pin});
    }
    return Value.nil;
}

fn nativeSleepMs(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len >= 1) {
        const ms = args[0].asFixnum() orelse return Value.nil;
        std.debug.print("[timer] sleep {d}ms\n", .{ms});
    }
    return Value.nil;
}

fn nativeMillis(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return Value.fromFixnumUnchecked(0);
}

fn nativeWifiConnect(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    _ = args;
    std.debug.print("[wifi] connect (stub)\n", .{});
    return Value.false_;
}

fn nativeWifiStatus(vm: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return class.allocString(vm, "disconnected") orelse Value.nil;
}

fn nativeWifiIp(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return Value.nil;
}

fn nativeMqttConnect(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    _ = args;
    std.debug.print("[mqtt] connect (stub)\n", .{});
    return Value.false_;
}

fn nativeMqttPublish(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    _ = args;
    std.debug.print("[mqtt] publish (stub)\n", .{});
    return Value.false_;
}

fn nativeMqttSubscribe(_: *VM, _: Value, args: []const Value, _: ?Value) Value {
    _ = args;
    std.debug.print("[mqtt] subscribe (stub)\n", .{});
    return Value.false_;
}

fn nativeMqttStatus(vm: *VM, _: Value, _: []const Value, _: ?Value) Value {
    return class.allocString(vm, "disconnected") orelse Value.nil;
}

pub const default_platform_native_table = [_]NativeMethodDef{
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("gpio_mode"), .func = &nativeGpioMode },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("gpio_write"), .func = &nativeGpioWrite },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("gpio_read"), .func = &nativeGpioRead },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("gpio_toggle"), .func = &nativeGpioToggle },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("sleep_ms"), .func = &nativeSleepMs },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("millis"), .func = &nativeMillis },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("wifi_connect"), .func = &nativeWifiConnect },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("wifi_status"), .func = &nativeWifiStatus },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("wifi_ip"), .func = &nativeWifiIp },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("mqtt_connect"), .func = &nativeMqttConnect },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("mqtt_publish"), .func = &nativeMqttPublish },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("mqtt_subscribe"), .func = &nativeMqttSubscribe },
    .{ .class_id = class.CLASS_OBJECT, .name_atom = a("mqtt_status"), .func = &nativeMqttStatus },
};

// ── Installers ───────────────────────────────────────────────────────

pub fn installDebugNatives(vm: *VM) void {
    class.installPlatformNatives(vm, &debug_native_table);
}

pub fn installDefaultPlatformNatives(vm: *VM) void {
    class.installPlatformNatives(vm, &default_platform_native_table);
}

/// Back-compat wrapper matching the pre-split `class.installNatives` signature.
/// Used by host-side callers (codegen, pipeline, nrbc) that don't need the
/// finer-grained split. Firmware builds call `class.installCoreNatives` plus
/// their own `installPlatformNatives` instead — they must not reference this
/// function (doing so would pull hosted-std into firmware).
pub fn installNatives(vm: *VM, findSym: *const fn ([]const u8) ?u16) void {
    _ = findSym;
    class.installCoreNatives(vm);
    installDebugNatives(vm);
    installDefaultPlatformNatives(vm);
}
