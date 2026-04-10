/// Flash memory layout constants.
/// These must match the linker script definitions.
///
/// RP2040 layout (2 MB):
///   0x1000_0000 .. 0x1000_00FF  boot2 (256 bytes)
///   0x1000_0100 .. 0x100B_FFFF  firmware (~768 KB)
///   0x100C_0000 .. 0x1017_FFFF  OTA staging area (~768 KB)
///   0x1018_0000 .. 0x101B_FFFF  script storage (256 KB)
///   0x101C_0000 .. 0x101E_FFFF  config / KV storage (192 KB)
///   0x101F_0000 .. 0x101F_FFFF  OTA metadata + reserved (64 KB)
const hal = @import("../platform/hal.zig");

pub const FLASH_BASE = hal.platform.FLASH_BASE;
pub const FLASH_SIZE = hal.platform.FLASH_SIZE;
pub const SECTOR_SIZE: u32 = 4096;
pub const PAGE_SIZE: u32 = 256;

pub const FW_BASE = FLASH_BASE + 0x100;
pub const FW_MAX_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 768 * 1024 - 256,
    .rp2350 => 2 * 1024 * 1024 - 256,
};

pub const OTA_STAGING_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x100C_0000,
    .rp2350 => 0x1020_0000,
};
pub const OTA_STAGING_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 768 * 1024,
    .rp2350 => 1024 * 1024,
};

pub const SCRIPT_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x1018_0000,
    .rp2350 => 0x1030_0000,
};
pub const SCRIPT_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 256 * 1024,
    .rp2350 => 512 * 1024,
};

pub const CONFIG_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x101C_0000,
    .rp2350 => 0x1038_0000,
};
pub const CONFIG_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 192 * 1024,
    .rp2350 => 256 * 1024,
};

pub const OTA_META_BASE: u32 = switch (hal.chip) {
    .rp2040 => 0x101F_0000,
    .rp2350 => 0x103C_0000,
};
pub const OTA_META_SIZE: u32 = switch (hal.chip) {
    .rp2040 => 64 * 1024,
    .rp2350 => 64 * 1024,
};

pub fn flashToPtr(addr: u32) [*]const u8 {
    return @ptrFromInt(addr);
}

pub fn isErased(addr: u32, len: u32) bool {
    const ptr = flashToPtr(addr);
    for (ptr[0..len]) |b| {
        if (b != 0xFF) return false;
    }
    return true;
}
