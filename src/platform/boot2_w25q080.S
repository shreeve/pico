// Raspberry Pi Pico SDK boot stage 2 for W25Q080 / W25Q16JV flash
// Source: pico-sdk/src/rp2_common/boot_stage2/boot2_w25q080.S
// Copyright (c) 2021 Raspberry Pi (Trading) Ltd. (BSD-3-Clause)
//
// Configures SSI for QSPI XIP mode, then vectors through to 0x10000100.

.cpu cortex-m0plus
.thumb
.section .boot2, "ax"

.equ XIP_SSI_BASE,          0x18000000
.equ SSI_CTRLR0_OFFSET,     0x00
.equ SSI_CTRLR1_OFFSET,     0x04
.equ SSI_SSIENR_OFFSET,     0x08
.equ SSI_BAUDR_OFFSET,      0x14
.equ SSI_SPI_CTRLR0_OFFSET, 0xf4
.equ SSI_SR_OFFSET,         0x28
.equ SSI_DR0_OFFSET,        0x60
.equ SSI_RXFLR_OFFSET,      0x24

.equ PADS_QSPI_BASE,        0x40020000
.equ PADS_QSPI_GPIO_QSPI_SCLK, 0x04
.equ PADS_QSPI_GPIO_QSPI_SD0,  0x08

.equ CMD_READ_STATUS2,      0x35
.equ CMD_WRITE_ENABLE,      0x06
.equ CMD_WRITE_STATUS2,     0x31
.equ CMD_READ_QUAD,         0xeb
.equ MODE_CONTINUOUS,       0xa0
.equ ADDR_LEN_24,           0x06

.equ CTRLR0_XIP,            0x001f0300
.equ SPI_CTRLR0_XIP,        0x03000218

_boot2_start:
    push {lr}

    // Disable SSI for configuration
    ldr r3, =XIP_SSI_BASE
    mov r0, #0
    str r0, [r3, #SSI_SSIENR_OFFSET]

    // Set baud rate to div/4 for fast reads
    mov r1, #4
    str r1, [r3, #SSI_BAUDR_OFFSET]

    // Configure QSPI pads: drive strength, slew, schmitt
    ldr r0, =PADS_QSPI_BASE
    ldr r1, =(2 << 4 | 1 << 0) // drive 4mA, schmitt enable
    str r1, [r0, #PADS_QSPI_GPIO_QSPI_SCLK]
    str r1, [r0, #PADS_QSPI_GPIO_QSPI_SD0]
    str r1, [r0, #(PADS_QSPI_GPIO_QSPI_SD0 + 4)]
    str r1, [r0, #(PADS_QSPI_GPIO_QSPI_SD0 + 8)]
    str r1, [r0, #(PADS_QSPI_GPIO_QSPI_SD0 + 12)]

    // Check if SR2 QE bit is already set
    mov r0, #CMD_READ_STATUS2
    bl _read_flash_sr
    mov r2, #2  // QE bit
    tst r0, r2
    bne _qe_already_set

    // Set QE bit: write enable, then write SR2
    mov r0, #CMD_WRITE_ENABLE
    bl _write_flash_cmd
    mov r0, #CMD_WRITE_STATUS2
    mov r1, #2  // QE=1
    bl _write_flash_cmd2
    // Wait for write to complete
    mov r0, #CMD_READ_STATUS2
1:
    bl _read_flash_sr
    mov r2, #1  // busy bit
    tst r0, r2
    bne 1b

_qe_already_set:
    // Configure SSI for quad reads in XIP mode
    ldr r1, =CTRLR0_XIP
    str r1, [r3, #SSI_CTRLR0_OFFSET]
    mov r1, #0
    str r1, [r3, #SSI_CTRLR1_OFFSET]
    ldr r1, =SPI_CTRLR0_XIP
    str r1, [r3, #SSI_SPI_CTRLR0_OFFSET]

    // Enable SSI
    mov r1, #1
    str r1, [r3, #SSI_SSIENR_OFFSET]

    // Do a dummy read to trigger continuous read mode
    mov r1, #CMD_READ_QUAD
    str r1, [r3, #SSI_DR0_OFFSET]
    mov r1, #MODE_CONTINUOUS
    str r1, [r3, #SSI_DR0_OFFSET]
    // 4 dummy bytes for address + mode
    mov r1, #0
    str r1, [r3, #SSI_DR0_OFFSET]
    str r1, [r3, #SSI_DR0_OFFSET]
    str r1, [r3, #SSI_DR0_OFFSET]

    // Wait for and discard response
    bl _wait_ssi_ready
    ldr r0, [r3, #SSI_RXFLR_OFFSET]
1:
    ldr r1, [r3, #SSI_DR0_OFFSET]
    subs r0, #1
    bne 1b

    // Now configure for XIP continuous read (no command byte needed)
    mov r1, #0
    str r1, [r3, #SSI_SSIENR_OFFSET]
    ldr r1, =0x001f0300
    str r1, [r3, #SSI_CTRLR0_OFFSET]
    ldr r1, =0x03000018  // continuous read, no cmd prefix
    str r1, [r3, #SSI_SPI_CTRLR0_OFFSET]
    mov r1, #1
    str r1, [r3, #SSI_SSIENR_OFFSET]

    // Vector through to real firmware
    ldr r0, =(0x10000100 + 1)  // entry point, thumb bit
    bx r0

_read_flash_sr:
    push {lr}
    str r0, [r3, #SSI_DR0_OFFSET]
    str r0, [r3, #SSI_DR0_OFFSET]
    bl _wait_ssi_ready
    ldr r0, [r3, #SSI_DR0_OFFSET]
    ldr r0, [r3, #SSI_DR0_OFFSET]
    pop {pc}

_write_flash_cmd:
    push {lr}
    str r0, [r3, #SSI_DR0_OFFSET]
    bl _wait_ssi_ready
    ldr r0, [r3, #SSI_DR0_OFFSET]
    pop {pc}

_write_flash_cmd2:
    push {lr}
    str r0, [r3, #SSI_DR0_OFFSET]
    str r1, [r3, #SSI_DR0_OFFSET]
    bl _wait_ssi_ready
    ldr r0, [r3, #SSI_DR0_OFFSET]
    ldr r0, [r3, #SSI_DR0_OFFSET]
    pop {pc}

_wait_ssi_ready:
    push {r1, lr}
1:
    ldr r1, [r3, #SSI_SR_OFFSET]
    mov r0, #4  // TFE (transmit FIFO empty)
    tst r1, r0
    beq 1b
    mov r0, #1  // BUSY
    tst r1, r0
    bne 1b
    pop {r1, pc}

// Pad to 252 bytes, then CRC placeholder (linker/tool will fill CRC)
.align 2
.space _boot2_start + 252 - ., 0
.word 0x00000000  // CRC32 placeholder
