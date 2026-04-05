// CYW43439 gSPI register definitions.
//
// The host talks to the CYW43 via a 32-bit gSPI protocol over a half-duplex
// PIO SPI bus. Commands address one of three "functions":
//   Function 0: SPI bus core (configuration, status, interrupts)
//   Function 1: Backplane (AHB bridge to internal ARM core)
//   Function 2: WLAN data (802.11 frames via SDPCM)
//
// Reference: Pico SDK cyw43_ll.c, Embassy cyw43 runner.rs

// ── gSPI command word layout (32 bits, big-endian on wire) ──────────────

pub const CMD_WRITE: u32 = 1 << 31;
pub const CMD_READ: u32 = 0;
pub const CMD_INCR_ADDR: u32 = 1 << 30;
pub const CMD_FIXED_ADDR: u32 = 0;
pub const CMD_FUNC_SHIFT: u5 = 28;
pub const CMD_ADDR_SHIFT: u5 = 11;
pub const CMD_LEN_MASK: u32 = 0x7FF;

pub const FUNC_BUS: u32 = 0;
pub const FUNC_BACKPLANE: u32 = 1;
pub const FUNC_WLAN: u32 = 2;

pub fn makeCmd(write: bool, incr: bool, func: u32, addr: u32, len: u32) u32 {
    var cmd: u32 = 0;
    if (write) cmd |= CMD_WRITE;
    if (incr) cmd |= CMD_INCR_ADDR;
    cmd |= (func & 0x3) << CMD_FUNC_SHIFT;
    cmd |= (addr & 0x1FFFF) << CMD_ADDR_SHIFT;
    cmd |= len & CMD_LEN_MASK;
    return cmd;
}

// ── Function 0: SPI bus core registers ──────────────────────────────────

pub const SPI_BUS_CONTROL: u32 = 0x0000;
pub const SPI_RESPONSE_DELAY: u32 = 0x0001; // Global response delay (within SPI_BUS_CONTROL block)
pub const SPI_RESP_DELAY_F0: u32 = 0x001C; // Per-function response delay (corerev >= 3)
pub const SPI_RESP_DELAY_F1: u32 = 0x001D;
pub const SPI_RESP_DELAY_F2: u32 = 0x001E;
pub const SPI_RESP_DELAY_F3: u32 = 0x001F;
pub const SPI_STATUS_ENABLE: u32 = 0x0004;
pub const SPI_STATUS_REGISTER: u32 = 0x0005;
pub const SPI_INTERRUPT_REGISTER: u32 = 0x0006;
pub const SPI_INTERRUPT_ENABLE: u32 = 0x0007;
pub const SPI_STATUS_REG_ADDR: u32 = 0x0008;
pub const SPI_TEST_REGISTER: u32 = 0x0014;
pub const SPI_TEST_MAGIC: u32 = 0xFEEDBEAD;

// SPI_BUS_CONTROL bits
pub const WORD_LENGTH_32: u32 = 0x01;
pub const ENDIAN_BIG: u32 = 0x02;
pub const HIGH_SPEED: u32 = 0x10;
pub const INTERRUPT_POLARITY_HIGH: u32 = 0x20;
pub const WAKE_UP: u32 = 0x80;

// SPI_STATUS_ENABLE bits
pub const STATUS_ENABLE: u32 = 0x01;
pub const INTR_WITH_STATUS: u32 = 0x04;

// SPI_INTERRUPT bits
pub const DATA_UNAVAILABLE: u32 = 0x01;
pub const F2_F3_FIFO_RD_UNDERFLOW: u32 = 0x02;
pub const F2_F3_FIFO_WR_OVERFLOW: u32 = 0x04;
pub const COMMAND_ERROR: u32 = 0x08;
pub const DATA_ERROR: u32 = 0x10;
pub const F2_PACKET_AVAILABLE: u32 = 0x20;
pub const F1_OVERFLOW: u32 = 0x80;

// ── Function 1: Backplane registers ─────────────────────────────────────

pub const BACKPLANE_WINDOW_ADDR: u32 = 0x1000A;
pub const BACKPLANE_CHIP_CLOCK_CSR: u32 = 0x1000E;
pub const BACKPLANE_PULL_UP: u32 = 0x1000F;

// Chip clock CSR bits
pub const ALP_AVAIL_REQ: u32 = 0x08;
pub const ALP_AVAIL: u32 = 0x40;
pub const HT_AVAIL_REQ: u32 = 0x10;
pub const HT_AVAIL: u32 = 0x80;

// ── Backplane addresses for CYW43439 ARM core ──────────────────────────

pub const CHIPCOMMON_BASE: u32 = 0x1800_0000;
pub const SDIO_BASE: u32 = 0x1800_2000;
pub const WLAN_BASE: u32 = 0x1800_3000;
pub const ARMCM3_BASE: u32 = WLAN_BASE; // WLAN core IS the ARM CM3 core
pub const SOCSRAM_BASE: u32 = 0x1800_4000;

pub const WRAPPER_OFFSET: u32 = 0x100000;

// Chip ID
pub const CHIPCOMMON_CHIPID: u32 = CHIPCOMMON_BASE + 0x00;

// SOCSRAM registers
pub const SOCSRAM_BANKX_INDEX: u32 = SOCSRAM_BASE + WRAPPER_OFFSET + 0x10;
pub const SOCSRAM_BANKX_PDA: u32 = SOCSRAM_BASE + WRAPPER_OFFSET + 0x44;

// Reset/enable for ARM core
pub const AI_IOCTRL_OFFSET: u32 = 0x408;
pub const AI_RESETCTRL_OFFSET: u32 = 0x800;
pub const AI_RESETSTATUS_OFFSET: u32 = 0x804;

pub const AIRC_RESET: u32 = 1;
pub const SICF_CPUHALT: u32 = 0x0020;
pub const SICF_FGC: u32 = 0x0002;
pub const SICF_CLOCK_EN: u32 = 0x0001;

// ── Firmware download addresses ─────────────────────────────────────────

pub const ATCM_RAM_BASE: u32 = 0;
pub const RAM_SIZE_CYW43439: u32 = 512 * 1024;
// CHIPCOMMON_CHIPID low 16 bits are the decimal chip number encoded as hex.
// CYW43439 => 43439 decimal => 0xA9AF.
pub const CHIP_ID_CYW43439: u32 = 0xA9AF;
// SDK configures CYW43_BACKPLANE_READ_PAD_LEN_BYTES = 16, but our
// SPI_RESP_DELAY_F1 write may not be taking effect. Use 4 bytes (1 word)
// which matches the default/working behavior until the config issue is resolved.
pub const BACKPLANE_READ_PAD_BYTES: u8 = 4;
pub const BACKPLANE_READ_PAD_WORDS: u32 = BACKPLANE_READ_PAD_BYTES / 4;

// ── SPI status register (function 0, addr 0x0008, 32-bit) ───────────

pub const STATUS_F2_PKT_AVAILABLE: u32 = 1 << 8;
pub const STATUS_F2_PKT_LEN_MASK: u32 = 0x000F_FE00;
pub const STATUS_F2_PKT_LEN_SHIFT: u5 = 9;
pub const STATUS_F2_RX_READY: u32 = 1 << 5;
pub const STATUS_F2_F3_FIFO_RD_UNDERFLOW: u32 = 1 << 1;
pub const SPI_FRAME_CONTROL: u32 = 0x1000D;

// ── SDPCM / CDC / IOCTL definitions ────────────────────────────────────

pub const SDPCM_HEADER_LEN: usize = 12;
pub const CDC_HEADER_LEN: usize = 16;

pub const CHANNEL_CONTROL: u8 = 0;
pub const CHANNEL_EVENT: u8 = 1;
pub const CHANNEL_DATA: u8 = 2;

pub const SDPCM_GET: u32 = 0;
pub const SDPCM_SET: u32 = 2;

// TODO: sort IOCTL_CMD constants by numeric value
pub const IOCTL_CMD_UP: u32 = 2;
pub const IOCTL_CMD_DOWN: u32 = 3;
pub const IOCTL_CMD_SET_SSID: u32 = 26;
pub const IOCTL_CMD_SET_CHANNEL: u32 = 30;
pub const IOCTL_CMD_DISASSOC: u32 = 52;
pub const IOCTL_CMD_GET_ANTDIV: u32 = 63;
pub const IOCTL_CMD_SET_ANTDIV: u32 = 64;
pub const IOCTL_CMD_SET_INFRA: u32 = 20;
pub const IOCTL_CMD_SET_AUTH: u32 = 22;
pub const IOCTL_CMD_SET_WSEC: u32 = 134;
pub const IOCTL_CMD_SET_WPA_AUTH: u32 = 165;
pub const IOCTL_CMD_SET_WSEC_PMK: u32 = 268;
pub const IOCTL_CMD_SET_VAR: u32 = 263;
pub const IOCTL_CMD_GET_VAR: u32 = 262;

// WPA2-PSK security constants
pub const WSEC_AES: u32 = 4;
pub const WPA2_AUTH_PSK: u32 = 0x80;
pub const WSEC_PASSPHRASE: u16 = 1;

// Wi-Fi event types (big-endian in event frames)
pub const EVENT_SET_SSID: u32 = 0;
pub const EVENT_AUTH: u32 = 3;
pub const EVENT_DEAUTH_IND: u32 = 6;
pub const EVENT_DISASSOC_IND: u32 = 12;
pub const EVENT_LINK: u32 = 16;
pub const EVENT_PSK_SUP: u32 = 46;
pub const EVENT_ESCAN_RESULT: u32 = 69;

// ── BDC (Broadcom Dongle Control) header for data frames ────────────────

pub const BDC_HEADER_LEN: usize = 4;
pub const BDC_VERSION_2: u8 = 2 << 4; // 0x20 — SDK and Embassy both use v2 for TX

// ── CYW43 GPIO (for LED control via IOCTL) ─────────────────────────────

pub const CYW43_GPIO_LED: u8 = 0;
pub const CYW43_GPIO_COUNT: u8 = 3;
