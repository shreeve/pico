/* RP2040 linker script for flash execution via SWD.
 * Boot2 at 0x10000000 (256 bytes), firmware at 0x10000100.
 */

MEMORY
{
    BOOT2 (rx)  : ORIGIN = 0x10000000, LENGTH = 256
    FLASH (rx)  : ORIGIN = 0x10000100, LENGTH = 2048K - 256
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 264K
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
        . = . + 64K;
        _heap_end = .;
    } > SRAM

    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . = . + 4K;
        _stack_top = .;
    } > SRAM

    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.attributes*)
        *(.comment)
        *(.debug*)
    }
}

_flash_script_base = 0x10100000;
_flash_script_size = 896K;
_flash_config_base = 0x101E0000;
_flash_config_size = 124K;
