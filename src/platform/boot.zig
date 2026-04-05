// Startup / vector-table code for RP2040 / RP2350.
const std = @import("std");
const CC = std.builtin.CallingConvention;

extern var _sbss: u32;
extern var _ebss: u32;
extern var _sdata: u32;
extern var _edata: u32;
extern const _etext: u32;
extern const _stack_top: u32;

// The reset handler that the vector table points to.
// It sets up BSS and .data, then enters main.
export fn _reset_handler() callconv(CC.c) noreturn {
    // Zero BSS
    const bss_start: [*]volatile u8 = @ptrCast(&_sbss);
    const bss_end: [*]volatile u8 = @ptrCast(&_ebss);
    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..bss_len], 0);

    // Copy .data from flash (LMA) to SRAM (VMA)
    const data_start: [*]volatile u8 = @ptrCast(&_sdata);
    const data_end: [*]volatile u8 = @ptrCast(&_edata);
    const data_src: [*]const u8 = @ptrCast(&_etext);
    const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
    for (0..data_len) |i| data_start[i] = data_src[i];

    @import("root").main();
}

export fn _default_handler() callconv(CC.c) void {
    while (true) {
        asm volatile ("nop");
    }
}

export fn _hard_fault_handler() callconv(CC.c) void {
    if (@hasDecl(@import("root"), "hardFault")) {
        @import("root").hardFault();
    }
    while (true) asm volatile ("nop");
}

// Cortex-M0+ hardware saves r0-r3, r12, lr, pc, xPSR on exception entry
// and restores on return, so a plain C-ABI function works as an ISR.
// If root doesn't provide usbIrq, disable the NVIC IRQ to prevent re-entry.
export fn _usb_irq_handler() callconv(CC.c) void {
    if (@hasDecl(@import("root"), "usbIrq")) {
        @import("root").usbIrq();
    } else {
        // No handler — disable IRQ5 in NVIC to prevent infinite re-entry
        @as(*volatile u32, @ptrFromInt(0xE000_E180)).* = (1 << 5);
    }
}

// ARM Cortex-M0+ vector table — placed in .vectors linker section.
// 16 system exceptions + 32 external IRQs = 48 entries.
// RP2040 IRQ5 = USBCTRL_IRQ, IRQ7/8 = PIO0, IRQ9/10 = PIO1.
comptime {
    asm (
        \\.section .vectors, "ax"
        \\.balign 4
        \\.global _vector_table
        \\_vector_table:
        \\// System exceptions (entries 0-15)
        \\.word _stack_top
        \\.word _reset_handler
        \\.word _default_handler
        \\.word _hard_fault_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word 0
        \\.word 0
        \\.word 0
        \\.word 0
        \\.word _default_handler
        \\.word 0
        \\.word 0
        \\.word _default_handler
        \\.word _default_handler
        \\// External IRQs (entries 16-47)
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _usb_irq_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
        \\.word _default_handler
    );
}
