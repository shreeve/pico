/// Flash memory layout constants.
/// These must match the linker script definitions.
const hal = @import("../platform/hal.zig");

pub const FLASH_BASE = hal.platform.FLASH_BASE;
pub const FLASH_SIZE = hal.platform.FLASH_SIZE;
pub const SECTOR_SIZE: u32 = 4096;
pub const PAGE_SIZE: u32 = 256;

// Firmware region
pub const FW_BASE = FLASH_BASE + 0x100; // after boot2
pub const FW_MAX_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 1024 * 1024 - 256,
    .rp2350 => 2 * 1024 * 1024 - 256,
};

// Script storage region
pub const SCRIPT_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x1010_0000,
    .rp2350 => 0x1020_0000,
};
pub const SCRIPT_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 896 * 1024,
    .rp2350 => 1792 * 1024,
};

// Config / KV region
pub const CONFIG_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x101E_0000,
    .rp2350 => 0x103C_0000,
};
pub const CONFIG_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 124 * 1024,
    .rp2350 => 252 * 1024,
};

/// Convert a flash address to an XIP pointer for reading.
pub fn flashToPtr(addr: u32) [*]const u8 {
    return @ptrFromInt(addr);
}

/// Check if a flash region is erased (all 0xFF).
pub fn isErased(addr: u32, len: u32) bool {
    const ptr = flashToPtr(addr);
    for (ptr[0..len]) |b| {
        if (b != 0xFF) return false;
    }
    return true;
}
