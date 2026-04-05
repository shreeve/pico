/// Hardware Abstraction Layer interface.
/// Each chip (RP2040 / RP2350) provides a concrete implementation.
const std = @import("std");

pub const Chip = enum { rp2040, rp2350 };

pub const chip: Chip = detectChip();

fn detectChip() Chip {
    const features = @import("builtin").cpu.features;
    const M33 = std.Target.arm.Feature;
    if (features.isEnabled(@intFromEnum(M33.has_v8m))) return .rp2350;
    return .rp2040;
}

pub const platform = switch (chip) {
    .rp2040 => @import("rp2040.zig"),
    .rp2350 => @import("rp2350.zig"),
};

// ── Unified register-access helpers ────────────────────────────────────

pub inline fn regWrite(addr: u32, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

pub inline fn regRead(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn regSet(addr: u32, mask: u32) void {
    regWrite(addr + 0x2000, mask); // atomic SET alias
}

pub inline fn regClr(addr: u32, mask: u32) void {
    regWrite(addr + 0x3000, mask); // atomic CLR alias
}

// ── Common system API ──────────────────────────────────────────────────

pub fn init() void {
    platform.init();
}

pub fn millis() u64 {
    return platform.millis();
}

pub fn delayMs(ms: u32) void {
    const start = millis();
    while (millis() - start < ms) {
        asm volatile ("nop");
    }
}
