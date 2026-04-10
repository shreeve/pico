/* RP2040 linker script for pico firmware
 * Flash: 2 MB at 0x1000_0000 (XIP)
 * SRAM:  264 KB at 0x2000_0000
 *
 * Flash layout:
 *   0x1000_0000 .. 0x1000_00FF  boot2 (256 bytes stage-2 bootloader)
 *   0x1000_0100 .. 0x100B_FFFF  firmware (~768 KB)
 *   0x100C_0000 .. 0x1017_FFFF  OTA staging area (~768 KB)
 *   0x1018_0000 .. 0x101B_FFFF  script storage (256 KB)
 *   0x101C_0000 .. 0x101E_FFFF  config / KV storage (192 KB)
 *   0x101F_0000 .. 0x101F_FFFF  OTA metadata + reserved (64 KB)
 */

MEMORY
{
    BOOT2 (rx)   : ORIGIN = 0x10000000, LENGTH = 256
    FLASH (rx)   : ORIGIN = 0x10000100, LENGTH = 768K - 256
    SRAM  (rwx)  : ORIGIN = 0x20000000, LENGTH = 264K
}

ENTRY(_reset_handler)

SECTIONS
{
    .boot2 : {
        KEEP(*(.boot2))
    } > BOOT2

    .text : {
        KEEP(*(.vectors))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
        _etext = .;
    } > FLASH

    .data : AT(_etext) {
        _sdata = .;
        *(.data .data.*)
        . = ALIGN(4);
        _edata = .;
    } > SRAM

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > SRAM

    .heap (NOLOAD) : {
        . = ALIGN(8);
        _heap_start = .;
        . = . + 96K;
        _heap_end = .;
    } > SRAM

    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . = . + 8K;
        _stack_top = .;
    } > SRAM

    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.ARM.attributes*)
        *(.comment)
        *(.debug*)
    }
}

_flash_ota_base     = 0x100C0000;
_flash_ota_size     = 768K;
_flash_script_base  = 0x10180000;
_flash_script_size  = 256K;
_flash_config_base  = 0x101C0000;
_flash_config_size  = 192K;
_flash_ota_meta     = 0x101F0000;
_flash_ota_meta_sz  = 64K;
