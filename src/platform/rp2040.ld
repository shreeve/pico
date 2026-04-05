/* RP2040 linker script for pico firmware
 * Flash: 2 MB at 0x1000_0000 (XIP)
 * SRAM:  264 KB at 0x2000_0000
 *
 * Flash layout:
 *   0x1000_0000 .. 0x1000_00FF  boot2 (256 bytes stage-2 bootloader)
 *   0x1000_0100 .. 0x100F_FFFF  firmware code + read-only data
 *   0x1010_0000 .. 0x101D_FFFF  script storage (896 KB)
 *   0x101E_0000 .. 0x101F_EFFF  config / KV storage (124 KB)
 *   0x101F_F000 .. 0x101F_FFFF  reserved (4 KB)
 */

MEMORY
{
    BOOT2 (rx)   : ORIGIN = 0x10000000, LENGTH = 256
    FLASH (rx)   : ORIGIN = 0x10000100, LENGTH = 1024K - 256
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

_flash_script_base  = 0x10100000;
_flash_script_size  = 896K;
_flash_config_base  = 0x101E0000;
_flash_config_size  = 124K;
