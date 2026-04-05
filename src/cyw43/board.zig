// Board abstraction for CYW43 WiFi driver.
//
// Each board (Pico W, Pico 2 W) provides pin definitions and board-specific
// operations. The CYW43 driver calls through this interface so that board
// details stay out of the protocol/transport layers.

const hal = @import("../platform/hal.zig");
const rp2040 = hal.platform;

pub const BoardOps = struct {
    wl_on: u5,
    wl_cs: u5,
    wl_clk: u5,
    wl_data: u5,

    pub fn initPins(self: *const BoardOps) void {
        // WL_DATA: output, drive LOW — must be low when WL_ON goes high
        // (selects SPI mode on CYW43, per datasheet)
        rp2040.gpioInit(self.wl_data, true);
        rp2040.gpioSet(self.wl_data, false);

        // WL_ON: output, drive low initially (chip held in reset)
        rp2040.gpioInit(self.wl_on, true);
        rp2040.gpioSet(self.wl_on, false);

        // WL_CS: output, drive high (deselected)
        rp2040.gpioInit(self.wl_cs, true);
        rp2040.gpioSet(self.wl_cs, true);

        // WL_CLK: output, drive low
        rp2040.gpioInit(self.wl_clk, true);
        rp2040.gpioSet(self.wl_clk, false);
    }

    pub fn resetChip(self: *const BoardOps) void {
        rp2040.gpioSet(self.wl_on, false);
        hal.delayMs(20);
        rp2040.gpioSet(self.wl_on, true); // DATA is LOW → SPI mode selected
        hal.delayMs(250); // SDK uses 250ms
    }

    pub fn csAssert(self: *const BoardOps) void {
        rp2040.gpioSet(self.wl_cs, false);
    }

    pub fn csDeassert(self: *const BoardOps) void {
        rp2040.gpioSet(self.wl_cs, true);
    }
};

// Pico W: CYW43439 connected via PIO SPI on dedicated GPIOs
pub const pico_w = BoardOps{
    .wl_on = 23,
    .wl_cs = 25,
    .wl_clk = 29,
    .wl_data = 24,
};

// Pico 2 W: same pin mapping as Pico W
pub const pico2_w = BoardOps{
    .wl_on = 23,
    .wl_cs = 25,
    .wl_clk = 29,
    .wl_data = 24,
};
