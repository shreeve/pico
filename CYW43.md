# CYW43439 gSPI Protocol Reference

Hard-won findings from bring-up on Pico W hardware, April 2026. Cross-referenced against four implementations: Pico SDK, Embassy (Rust), PicoWi (C bit-bang), and our Zig driver.

## The Pico W SPI Interface

The CYW43439 on the Pico W uses a **nonstandard half-duplex SPI** on a single shared data line:

| Signal | RP2040 GPIO | Function |
|--------|-------------|----------|
| WL_REG_ON | GPIO23 | Power enable (active high) |
| WL_D | GPIO24 | Shared: MOSI + MISO + IRQ |
| WL_CS | GPIO25 | Chip select (active low) |
| WL_CLK | GPIO29 | SPI clock |

GPIO24 is shared via resistor network:
- SDIO_CMD (SPI MOSI) connected directly
- SDIO_DATA0 (SPI MISO) connected via **470 ohm** protection resistor
- SDIO_DATA1 (IRQ) connected via **10K** resistor
- SDIO_DATA2 (mode select) determines SPI vs SDIO at power-up

## Power-Up Sequence (Critical)

The DATA pin state at power-up selects SPI vs SDIO mode:

1. **WL_DATA must be OUTPUT LOW before WL_ON goes high** — this selects SPI mode
2. WL_ON LOW for >= 20ms (power down)
3. WL_ON HIGH (power up, DATA=LOW selects SPI)
4. Wait **250ms** (SDK uses 250ms, not 50ms)
5. Switch DATA to input for SPI operation

If DATA floats high during power-up, the chip enters SDIO mode and will not respond to gSPI commands.

Source: Pico SDK `cyw43_spi_gpio_setup()` + `cyw43_spi_reset()`, PicoWi blog.

## CYW43 Clock Modes (ALP and HT)

The CYW43439 has two internal clock states that gate what the host can do:

- **ALP (Active Low Power)** — a slow clock sufficient for SPI bus access, register reads/writes, and backplane windowing. ALP is available shortly after power-up. With ALP, the host can read chip ID, program the backplane window, and upload firmware to RAM. But the WLAN ARM core cannot execute firmware at full speed on ALP alone.

- **HT (High Throughput)** — the full-speed clock required for firmware execution, packet processing, and radio operation. HT becomes available only after the firmware has been uploaded, the WLAN core is released from reset, and the firmware successfully boots. The firmware itself switches the chip from ALP to HT and sets the `HT_AVAIL` bit in the chip clock CSR (`0x1000E`).

The host bring-up sequence interacts with these clocks as follows:

1. After power-up, request ALP by writing `ALP_AVAIL_REQ` (0x08) to the clock CSR
2. Poll until `ALP_AVAIL` (0x40) appears — the chip is now awake enough for bus access
3. Upload firmware and NVRAM, write the NVRAM token
4. Release the WLAN core from reset
5. Poll the clock CSR for `HT_AVAIL` (0x80) — this means the firmware has booted
6. Once HT is available, the firmware is running and ready for IOCTL commands

"HT-ready" in this project's documentation means: **the firmware has booted and is running at full speed, ready to accept control commands.**

## gSPI Command Word Format

32-bit command, packed as a C bitfield on little-endian ARM:

```
typedef struct {
    uint32_t len:11,   // bits [10:0]  — byte count
             addr:17,  // bits [27:11] — register address
             func:2,   // bits [29:28] — function (0=bus, 1=backplane, 2=WLAN)
             incr:1,   // bit  [30]    — auto-increment address
             wr:1;     // bit  [31]    — 1=write, 0=read
} SPI_MSG_HDR;
```

Functions: 0 = SPI bus core, 1 = backplane (AHB), 2 = WLAN data.

## Wire Byte Order (THE Key Insight)

**gSPI sends command and data bytes in LITTLE-ENDIAN order (LSByte first), with MSbit-first within each byte.**

For command word `0x4000A004` (read, incr, func0, addr=0x14, len=4):
- Memory on LE ARM: `[04, A0, 00, 40]`
- Wire order: `04` first, then `A0`, then `00`, then `40`
- Each byte sent bit 7 first

This was confirmed by cross-referencing three independent implementations:

### PicoWi (C bit-bang, definitive proof)
```c
spi_write((uint8_t *)&msg, 32);  // sends raw struct bytes, byte 0 first
```
On LE ARM, byte 0 of a u32 is the LSByte. PicoWi's `spi_write` starts from byte 0, sending MSbit-first within each byte.

### Pico SDK (PIO + DMA)
```c
buf[0] = SWAP32(make_cmd(false, true, fn, reg, 4));
// DMA with BSWAP=true transfers to PIO TX FIFO
```
- `SWAP32` is ARM `rev16` (swap bytes within each halfword)
- DMA BSWAP is a **full byte reverse** for 32-bit transfers (`0xAABBCCDD -> 0xDDCCBBAA`)
- Combined: `rev16` then `bswap32` produce the correct byte order in the PIO FIFO
- PIO shifts MSBit-first, producing LSByte-first on wire

**Critical correction**: DMA BSWAP for 32-bit words is a **full byte reverse**, NOT rev16. This was the source of initial confusion. The RP2040 datasheet says "the two bytes of the two halfwords are each reversed" which is misleading — for word transfers it's a complete reversal.

### Embassy (Rust PIO)
Uses DMA with byte-swap and `shift_out.direction = ShiftDirection::Left` (MSB-first).
The net effect matches: LSByte-first on wire.

### Implication for our Zig PIO driver
Since our PIO shifts bit 31 first (MSB-first), we must **swapEndian (full byte reverse)** the command word before pushing to the TX FIFO:

```zig
txPut(swapEndian(cmd));  // 0x4000A004 -> 0x04A00040 -> PIO sends 04,A0,00,40
```

## Response Byte Order

Responses also arrive in LE byte order. The PIO captures 32 bits MSB-first into the ISR. After `swapEndian`, the correct host-native value is recovered.

For the test register:
- Wire: `AD BE ED FE` (LSByte of 0xFEEDBEAD first)
- PIO ISR: `0xADBEEDFE`
- After swapEndian: `0xFEEDBEAD`

## SPI Clock Phase (SPI Mode)

CYW43 gSPI uses **CPOL=0, CPHA=0** (SPI Mode 0) with a half-duplex twist:

### TX Phase (host to device)
- Host drives data while CLK is LOW
- CYW43 samples on CLK **RISING** edge

### RX Phase (device to host) — SUBTLE
The device drives data on the CLK rising edge. The host must sample **after** the data settles:

| Implementation | Sample point | PIO instruction |
|---------------|-------------|-----------------|
| **PicoWi** (bit-bang) | Before CLK cycle (CLK is LOW from previous) | `read; CLK high; CLK low` |
| **Pico SDK** (high speed) | CLK LOW (falling edge) | `in pins, 1 side 0` |
| **Embassy** (low speed) | CLK HIGH (after rising) | `in pins, 1 side 1` |
| **Embassy** (high speed) | CLK LOW (falling edge) | `in pins, 1 side 0` |

At low SPI speeds (~1 MHz), either edge works because data is stable for a long time. At high speeds (>30 MHz), falling-edge sampling is preferred.

## Turnaround (Direction Switch)

After the 32-bit command, the host releases the DATA line and the CYW43 starts driving it for the response. The **turnaround gap** between TX and RX is implementation-dependent:

| Implementation | Built-in gap clocks | Configurable? |
|---------------|-------------------|---------------|
| **Pico SDK** `spi_gap01_sample0` | 1 (nop side 1) | No |
| **Pico SDK** `spi_gap010_sample1` | 2 | No |
| **PicoWi** (bit-bang) | 0 (just a `usdelay`) | N/A |
| **Embassy** (overclock) | 2 | No |
| **Embassy** (high speed) | 1 | No |
| **Embassy** (low speed) | 1 (nop side 0) | No |

The CYW43's `SPI_RESP_DELAY_Fx` registers add additional device-side delay. These must be coordinated with the host turnaround:

- **Before bus config**: RESP_DELAY defaults to 0. Use minimal host turnaround.
- **After bus config**: Set RESP_DELAY to match host turnaround.

For backplane reads (function 1), additional **response padding** is inserted before the response data. The SDK defines `CYW43_BACKPLANE_READ_PAD_LEN_BYTES = 16` for SPI (4 words), but the current proven Zig path uses 4-byte padding because the `SPI_RESP_DELAY_F1` write was not yet shown to take effect reliably. Treat 16 bytes as the reference/SDK behavior, and 4 bytes as the currently working implementation detail.

## PIO Pin Configuration (RP2040-specific)

### Side-set drives value, NOT output enable
PIO side-set controls the pin **value** but does NOT set the output enable. You must explicitly set pindirs for the CLK pin:

```zig
// SET_BASE targets data_pin — set data OE
execImmediate(pioSet(DST_PINDIRS, 1));

// Temporarily retarget SET_BASE to clk_pin — set clock OE
hal.regWrite(pinctrl_addr, modified_pinctrl_with_clk_as_set_base);
execImmediate(pioSet(DST_PINDIRS, 1));
hal.regWrite(pinctrl_addr, original_pinctrl);  // restore
```

Without this, the CLK pin stays as input and no clock signal reaches the CYW43.

### PINCTRL must include IN_BASE
The `in pins, 1` instruction reads from `IN_BASE`, not from `OUT_BASE` or `SET_BASE`. If `IN_BASE` is not set to the data pin, reads sample the wrong GPIO.

### FSTAT bit positions
```
FSTAT register for SM0:
  Bit 0:  RXFULL
  Bit 8:  RXEMPTY  <-- use this for "has data" check
  Bit 16: TXFULL
  Bit 24: TXEMPTY
```

Common bug: checking RXFULL (bit 0) instead of RXEMPTY (bit 8). On an empty FIFO, RXFULL=0 which makes `drainRx()` loop forever.

## Pull Configuration

| Implementation | DATA pin pull |
|---------------|--------------|
| **Pico SDK** | Pull-DOWN |
| **Embassy** | No pull |
| **PicoWi** | External pull-up on module |

The SDK uses pull-down. The CYW43 module may have its own pull-ups. For debugging, pull-down is recommended — it distinguishes "line undriven" (reads 0) from "device driving high" (reads 1).

## Register Access Patterns

### Function 0 (bus core) reads
- No response padding
- RESP_DELAY applies directly

### Function 1 (backplane) reads
- **4 extra padding bytes** before response data
- SDK: `if (func == BACKPLANE_FUNCTION) msg.hdr.len += 4;` and reads 4 extra bytes

### All register reads use `incr=true`
The SDK sets the auto-increment bit for ALL register reads, not just block transfers.

## Initial Bus Handshake

1. Read `SPI_TEST_REGISTER` (func 0, addr 0x14) → expect `0xFEEDBEAD`
2. Configure bus: `WORD_LENGTH_32 | HIGH_SPEED | INTERRUPT_POLARITY_HIGH | WAKE_UP`
3. Set response delays to match host turnaround
4. Enable status register

The SDK uses `read_reg_u32_swap()` for the initial test register read, which applies `SWAP32` (rev16) on both command and response. This is because the initial bus state may have different byte ordering before `WORD_LENGTH_32` is configured.

## Proven Zig Bring-Up Configuration

The current proven Zig path uses two distinct SPI access modes:

1. **Pre-config (16-bit halfword mode)** — `swap16x2 + swapEndian` on commands and responses
2. **Post-config (32-bit word mode)** — raw commands and raw 32-bit register access, with bulk payload words packed little-endian

The mode switch in `bus.initBus()` is:

- Phase 1: `readReg32Swap()` reads the test register and verifies `0xFEEDBEAD`
- Phase 2: `writeReg32Swap()` enables `WORD_LENGTH_32`
- Phase 3: all subsequent access uses raw helpers (`cmdReadRaw`, `cmdWriteRaw`)

The proven RP2040 PIO program matches the SDK `spi_gap01_sample0` shape:

```text
0: out pins, 1    side 0   ; TX bit, CLK LOW
1: jmp x--, 0     side 1   ; CLK HIGH, loop
2: set pindirs, 0 side 0   ; turnaround: DATA=input
3: nop             side 1  ; 1 gap clock
4: in pins, 1      side 0  ; RX sample, CLK LOW
5: jmp y--, 4      side 1  ; CLK HIGH, loop
```

Operational notes from the proven path:

- host preloads `X = tx_bits - 1` and `Y = rx_bits - 1` for each transfer
- autopull/autopush use 32-bit thresholds
- current proven backplane read path uses **1 padding word (4 bytes)**
- backplane block writes use **64-byte chunks**
- `STATUS_ENABLE` remains disabled on the current Zig path because it prepends a status word to every response and complicates parsing during bring-up
- the current proven clock pad config matches the SDK: **12 mA drive + fast slew**

## Key Test Values

| Register | Address | Expected Value |
|----------|---------|---------------|
| SPI_TEST_REGISTER | 0x14 | `0xFEEDBEAD` |
| SPI_TEST_RW | 0x18 | Write/readback |
| CHIPCOMMON_CHIPID | backplane 0x18000000 | raw word `0x1545A9AF`; low 16 bits `0xA9AF` = `43439` decimal = CYW43439 |

## Firmware Blobs Required

The current Zig build uses two embedded files:
1. **43439A0_combined.bin** (~227 KB) — combined WLAN firmware + CLM blob in the SDK/Embassy combined layout
2. **43439A0_nvram.bin** (~742 B) — board-specific config (antenna, crystal, power)

Internally, `core.zig` slices `43439A0_combined.bin` into:
- firmware payload
- CLM payload

The older separate `43439A0.bin` and `43439A0_clm.bin` files are useful only as reference/source artifacts and are not required by the current build.

Source lineage: `pico-sdk/lib/cyw43-driver/firmware/` and Embassy's matched combined blob layout.

## References

- **Pico SDK**: `pico-sdk/src/rp2_common/pico_cyw43_driver/cyw43_bus_pio_spi.c` — PIO+DMA transfer
- **Pico SDK**: `pico-sdk/lib/cyw43-driver/src/cyw43_spi.c` — command packing
- **Pico SDK**: `pico-sdk/lib/cyw43-driver/src/cyw43_ll.c` — bus init sequence
- **Embassy**: `embassy-rs/embassy/cyw43-pio/src/lib.rs` — PIO programs for different speeds
- **PicoWi**: https://iosoft.blog/picowi_part1 — bit-bang SPI with oscilloscope traces
- **CYW43439 datasheet**: https://www.infineon.com/cms/en/product/wireless-connectivity/airoc-wi-fi-plus-bluetooth-combos/wi-fi-4-802.11n/cyw43439/

## 8-bit Register Access in 32-bit Word Mode

In 32-bit word mode, ALL SPI transfers are 32-bit words, even for 8-bit register accesses.

**Empirically working path (proven on Pico W hardware):**
- **Write**: `cmdWriteRaw(cmd, &[_]u32{@as(u32, val)})` — value in LSByte of u32
- **Read**: `@truncate(result[0])` — extract LSByte from raw PIO result

The CYW43 direct backplane registers (0x1000x range) appear to handle byte-lane positioning internally. The earlier hypothesis that 8-bit values needed `val << 24` (MSByte positioning) was investigated but the LSByte path works empirically for all tested registers including the backplane window bytes and clock CSR.

The critical companion fix was **PIO TXSTALL wait**: without waiting for the PIO shift engine to finish before CS release, write-only transactions could be truncated on the wire, causing register writes to silently fail.

The successful bring-up path ended up being:
- ALP available (`csr_raw=0x48`)
- backplane window readback `low=0x00 mid=0x00 high=0x18`
- chipcommon register 0 raw word `0x1545A9AF`
- firmware verify `OK` (231KB Embassy-matched pair, 64-byte chunks, LE packing)
- HT clock `OK` after firmware upload
- F2 ready wait before first IOCTL
- MAC read via `cur_etheraddr` iovar: `28:CD:C1:10:3E:1B`
- CLM upload via `clmload` iovar: status 0
- LED blink via `gpioout` iovar: visually confirmed
- Wi-Fi UP via `WLC_DOWN` → `country` → `event_msgs` → `WLC_UP`
- Wi-Fi scan via `escan` iovar: 56 ESCAN_RESULT events, real SSIDs discovered

The `CHIPCOMMON_CHIPID` register uses the standard Broadcom Silicon Backplane format:
- bits [15:0] = chip ID (decimal chip number as hex: 43439 = `0xA9AF`)
- bits [19:16] = chip revision (`0x5` for our CYW43439)
- bits [31:20] = package/other info

Full raw word `0x1545A9AF` breaks down as: ID=`0xA9AF`, rev=`0x5`, pkg=`0x154`.

This encoding is standard across the Broadcom SBP family: BCM4329 stores `0x4329`, BCM43438 stores `0xA99E`, CYW43439 stores `0xA9AF`. The marketing name `0x4373` is NOT the chipcommon register value.

## Bugs Found During Bring-Up

1. **CLK pin OE not set** — side-set drives value only; must explicitly set pindirs
2. **FSTAT RXEMPTY vs RXFULL** — bit 8, not bit 0; wrong check causes infinite drain loop
3. **Command byte order** — must be LE on wire; requires swapEndian before PIO TX
4. **swap16x2 is required before `WORD_LENGTH_32`** — the initial 16-bit halfword mode swaps bytes within each halfword; the test-register path must account for this.
5. **1-bit alignment behavior differs at low speed** — the SDK gap program can produce a 1-bit response shift around ~1 MHz, while Embassy's no-gap path works there. At >30 MHz, the proven path is the SDK-style gap program.
6. **DATA pin must be LOW at power-up** — selects SPI mode; floating high = SDIO mode
7. **DMA BSWAP is full byte reverse** — not rev16 as RP2040 docs misleadingly suggest
8. **`STATUS_ENABLE` prepends a status word** — enabling it adds an extra 32-bit word to every response. The current proven Zig path leaves it disabled.
9. **PIO TXSTALL wait required for write-only transactions** — without waiting for `FDEBUG.TXSTALL`, CS releases before final bits leave the wire, causing backplane window writes to silently fail. Copied from the SDK's write-only PIO path.
10. **Backplane window write order matters** — must be HIGH/MID/LOW (matching SDK), not LOW/MID/HIGH.
11. **CHIPCOMMON_CHIPID uses decimal chip number in low 16 bits** — CYW43439 reports `0xA9AF` in low 16 bits, not `0x4373`.
12. **SPI backplane block writes must use 64-byte chunks** — SDK defines `CYW43_BUS_MAX_BLOCK_SIZE = 64` for SPI. This is a hardware constraint of the CYW43's SPI-to-backplane bridge FIFO. Writing 512-byte blocks silently corrupts firmware uploads even if small synthetic test writes appear fine.
13. **Bulk firmware payload words must be little-endian packed** — the final firmware boot blocker was a host-side byte swap inside each 32-bit bulk payload word. Full-image verification caught this at offset `0x1000`: expected `0x00801BD4`, got `0xD41B8000`. Little-endian payload packing fixed the upload and allowed the firmware to boot.
14. **Backplane window registers are write-only from SPI** — cannot read back `0x1000A/B/C` to verify. Track window state in software and only write changed bytes. Force-write all three bytes after any error recovery. The SDK resets to `CHIPCOMMON_BASE_ADDRESS` after each backplane access.
15. **SDK documents 16-byte SPI backplane read padding, but the current proven path uses 4 bytes** — keep this distinction explicit in docs until the `SPI_RESP_DELAY_F1` configuration path is independently verified.
16. **Firmware and CLM must be a matched pair** — using a 224KB firmware with a 984-byte CLM from a different release produced `clmload_status=3` (BCME_BADOPTION). Switching to Embassy's matched pair (231KB FW + 984B CLM from the same `wb43439A0_7_95_49_00_combined.h`) gave status 0.
17. **F2 ready wait is required before first IOCTL** — after HT clock, poll `STATUS_F2_RX_READY` (bit 5 of SPI status register) before sending any IOCTLs. Without this, the first IOCTL times out.
18. **Event mask must be configured before scan** — set `event_msgs` iovar to enable ESCAN_RESULT delivery. Without this, scan events are never generated and the scan poll loop sees zero packets.
19. **`pollDevice()` must drain all pending packets** — event and control responses can arrive back-to-back. Reading only one packet per poll loses the second.
20. **BDC TX header must use version 2 (`0x20`)** — version 0 silently drops data-channel frames; both Pico SDK and Embassy use BDC v2.
