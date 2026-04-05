/* RP2350 linker script for pico firmware
 * Flash: 4 MB at 0x1000_0000 (XIP)
 * SRAM:  520 KB at 0x2000_0000
 *
 * Flash layout:
 *   0x1000_0000 .. 0x1000_00FF  boot2 (256 bytes stage-2 bootloader)
 *   0x1000_0100 .. 0x101F_FFFF  firmware code + read-only data (~2 MB)
 *   0x1020_0000 .. 0x103B_FFFF  script storage (1792 KB)
 *   0x103C_0000 .. 0x103F_EFFF  config / KV storage (252 KB)
 *   0x103F_F000 .. 0x103F_FFFF  reserved (4 KB)
 */

MEMORY
{
    FLASH (rx)   : ORIGIN = 0x10000000, LENGTH = 2048K
    SRAM  (rwx)  : ORIGIN = 0x20000000, LENGTH = 520K
}

ENTRY(_reset_handler)

SECTIONS
{
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
        . = . + 256K;
        _heap_end = .;
    } > SRAM

    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . = . + 16K;
        _stack_top = .;
    } > SRAM

    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.attributes*)
        *(.comment)
        *(.debug*)
    }
}

_flash_script_base  = 0x10200000;
_flash_script_size  = 1792K;
_flash_config_base  = 0x103C0000;
_flash_config_size  = 252K;
