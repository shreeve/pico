// pico/src/ruby/bindings_adapter.zig — platform-native adapter table.
//
// Each adapter is a nanoruby `NativeFn` that unpacks Ruby args and calls
// into pico's existing `src/bindings/*.zig` internal Zig APIs (or `hal.*`
// for stateless read-only endpoints like `millis` and direct GPIO). This
// file is what pico passes to `nanoruby.installPlatformNatives` in
// `runtime.zig`. It replaces the hosted stub platform table in
// `src/ruby/nanoruby/vm/class_debug.zig` — the firmware never installs
// the stubs.
//
// Phase A adapter surface (docs/NANORUBY.md A3):
//   gpio_mode, gpio_write, gpio_read, gpio_toggle,
//   led_on, led_off, led_toggle, led_blink,
//   millis, sleep_ms, puts.
//
// GC rooting discipline (docs/NANORUBY.md §"GC and native-binding rooting"):
//   - Adapters read args synchronously; they do not cache `Value` across
//     any call that could allocate.
//   - String args are byte-copied into caller-owned storage if retained;
//     otherwise read and discarded in the same function.
//   - No adapter stores a `Value` in a module-level `var` or in any
//     storage that outlives the current frame.
//
// Error policy (docs/NANORUBY.md resolution #7):
//   - Bad argument counts or types raise a VM-level Ruby exception
//     via `vm.raise(VmError.*)`. This returns `Value.undef` back to the
//     VM's `invokeNative` path, which translates into `ExecResult.err`.
//   - Adapters do NOT `hal.halt`, panic, or silently return `nil` on
//     invalid args.

const nanoruby = @import("nanoruby.zig");
const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;
const led = @import("../bindings/led.zig");
const console = @import("../bindings/console.zig");

const VM = nanoruby.VM;
const Value = nanoruby.Value;
const VmError = nanoruby.VmError;
const NativeMethodDef = nanoruby.NativeMethodDef;

// ── GPIO (stateless; route directly to hal) ──────────────────────────

fn rbGpioMode(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 2) return vm.raise(VmError.ArgumentError);
    const pin_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    const mode_i = args[1].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (pin_i < 0 or pin_i > 29) return vm.raise(VmError.RangeError);
    rp2040.gpioInit(@intCast(pin_i), mode_i != 0);
    return Value.nil;
}

fn rbGpioWrite(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 2) return vm.raise(VmError.ArgumentError);
    const pin_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    const val_i = args[1].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (pin_i < 0 or pin_i > 29) return vm.raise(VmError.RangeError);
    rp2040.gpioSet(@intCast(pin_i), val_i != 0);
    return Value.nil;
}

fn rbGpioRead(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 1) return vm.raise(VmError.ArgumentError);
    const pin_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (pin_i < 0 or pin_i > 29) return vm.raise(VmError.RangeError);
    return Value.fromBool(rp2040.gpioRead(@intCast(pin_i)));
}

fn rbGpioToggle(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 1) return vm.raise(VmError.ArgumentError);
    const pin_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (pin_i < 0 or pin_i > 29) return vm.raise(VmError.RangeError);
    rp2040.gpioToggle(@intCast(pin_i));
    return Value.nil;
}

// ── LED (stateful; route through bindings/led to preserve blink state) ─

fn rbLedOn(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    led.on();
    return Value.nil;
}

fn rbLedOff(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    led.off();
    return Value.nil;
}

fn rbLedToggle(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    led.toggle();
    return Value.fromBool(led.isOn());
}

fn rbLedBlink(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 1) {
        led.blink(500);
        return Value.nil;
    }
    const ms_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (ms_i <= 0) return vm.raise(VmError.RangeError);
    led.blink(@intCast(ms_i));
    return Value.nil;
}

// ── Clock (read-only; route directly to hal) ─────────────────────────

fn rbMillis(_: *VM, _: Value, _: []const Value, _: ?Value) Value {
    const ms_u64 = hal.millis();
    // Fixnum is i32 in this VM. Wrap monotonically past 2^31 ms
    // (≈ 24.85 days) by truncate-then-bitcast; scripts doing signed
    // arithmetic over long uptimes must handle the wrap themselves.
    const ms_u32: u32 = @truncate(ms_u64);
    return Value.fromFixnumUnchecked(@bitCast(ms_u32));
}

// ── Cooperative sleep (body lands at A4; stub for A3) ────────────────

fn rbSleepMs(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len < 1) return vm.raise(VmError.ArgumentError);
    const ms_i = args[0].asFixnum() orelse return vm.raise(VmError.TypeError);
    if (ms_i < 0) return vm.raise(VmError.RangeError);
    // The runtime module owns the cooperative-pump policy.
    const runtime = @import("runtime.zig");
    runtime.sleepMsCooperative(@intCast(ms_i));
    return Value.nil;
}

// ── puts (string-only for Phase A; widening deferred to Phase B) ─────

fn rbPuts(vm: *VM, _: Value, args: []const Value, _: ?Value) Value {
    if (args.len == 0) {
        console.puts("\n");
        return Value.nil;
    }
    for (args) |arg| {
        const s = vm.getStringData(arg) orelse {
            // Phase A: strict String-only. Widen to Object#to_s coercion
            // in Phase B when a use case demands it.
            return vm.raise(VmError.TypeError);
        };
        console.puts(s);
        console.puts("\n");
    }
    return Value.nil;
}

// ── Platform-native table (passed to nanoruby.installPlatformNatives) ─

pub const pico_platform_natives = [_]NativeMethodDef{
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("gpio_mode"), .func = &rbGpioMode },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("gpio_write"), .func = &rbGpioWrite },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("gpio_read"), .func = &rbGpioRead },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("gpio_toggle"), .func = &rbGpioToggle },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("led_on"), .func = &rbLedOn },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("led_off"), .func = &rbLedOff },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("led_toggle"), .func = &rbLedToggle },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("led_blink"), .func = &rbLedBlink },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("millis"), .func = &rbMillis },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("sleep_ms"), .func = &rbSleepMs },
    .{ .class_id = nanoruby.CLASS_OBJECT, .name_atom = nanoruby.atom("puts"), .func = &rbPuts },
};
