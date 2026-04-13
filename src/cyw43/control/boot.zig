const board = @import("../board.zig");
const bus = @import("../transport/bus.zig");
const regs = @import("../regs.zig");
const types = @import("../types.zig");
const ioctl = @import("ioctl.zig");
const dhcp = @import("../../net/dhcp.zig");
const hal = @import("../../platform/hal.zig");
const fmt = @import("../../lib/fmt.zig");
const netif = @import("../../net/stack.zig");

pub const Context = struct {
    state: *types.State,
    brd: *const board.BoardOps,
    chip_id: *u32,
    mac_addr: *[6]u8,
    fw_blob: []const u8,
    nvram_blob: []const u8,
    clm_blob: []const u8,

    puts: *const fn ([]const u8) void,
    putDec: *const fn (u32) void,
    putHex32: *const fn (u32) void,

    do_ioctl: *const fn (u32, u32, u8, []u8) anyerror!void,
    led_set: *const fn (bool) anyerror!void,
    start_scan: *const fn () anyerror!void,
    print_scan_results: *const fn () void,
    join_wpa2: *const fn ([]const u8, []const u8) anyerror!void,
    poll_device: *const fn () ioctl.PollResult,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    upload_blob: *const fn (u32, []const u8) void,
    verify_blob: *const fn (u32, []const u8) bool,
    disable_core: *const fn (u32) void,
    reset_core: *const fn (u32) void,
    clm_load: *const fn () anyerror!void,
    rx_buf: *[2048 / 4]u32,
    wifi_ssid: []const u8,
    wifi_pass: []const u8,
};

pub fn probe(ctx: *Context) types.Error!void {
    ctx.state.* = .resetting;

    ctx.brd.initPins();
    ctx.brd.resetChip();

    bus.init(ctx.brd);
    bus.initBus() catch {
        ctx.puts("[cyw43] SPI bus FAILED\n");
        ctx.state.* = .err;
        return types.Error.SpiBusNotReady;
    };
    ctx.puts("[cyw43] SPI OK\n");
    ctx.state.* = .bus_ready;

    bus.writeReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_CHIP_CLOCK_CSR, @as(u8, @truncate(regs.ALP_AVAIL_REQ)));

    var timeout: u32 = 0;
    while (timeout < 500) : (timeout += 1) {
        const csr = bus.readReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_CHIP_CLOCK_CSR);
        if (csr & @as(u8, @truncate(regs.ALP_AVAIL | regs.HT_AVAIL)) != 0) break;
        hal.delayMs(1);
    }
    if (timeout >= 500) {
        ctx.puts("[cyw43] ALP clock timeout\n");
        ctx.state.* = .err;
        return types.Error.ClockTimeout;
    }
    ctx.puts("[cyw43] ALP clock OK\n");

    bus.writeReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_CHIP_CLOCK_CSR, 0);

    const id_raw = bus.bpRead32(regs.CHIPCOMMON_CHIPID);
    ctx.puts("[cyw43] id=");
    ctx.putHex32(id_raw);
    ctx.puts("\n");

    ctx.chip_id.* = id_raw & 0xFFFF;
    if (ctx.chip_id.* != regs.CHIP_ID_CYW43439) {
        ctx.puts("[cyw43] chip ID mismatch!\n");
        ctx.state.* = .err;
        return types.Error.ChipIdMismatch;
    }
}

pub fn boot(ctx: *Context) types.Error!void {
    if (ctx.state.* != .bus_ready) return types.Error.SpiBusNotReady;

    ctx.disable_core(regs.WLAN_BASE);
    ctx.disable_core(regs.SOCSRAM_BASE);
    ctx.reset_core(regs.SOCSRAM_BASE);
    bus.bpWrite32(regs.SOCSRAM_BANKX_INDEX, 0x03);
    bus.bpWrite32(regs.SOCSRAM_BANKX_PDA, 0);

    ctx.state.* = .firmware_loading;
    ctx.puts("[cyw43] uploading firmware (");
    ctx.putDec(@intCast(ctx.fw_blob.len));
    ctx.puts(" bytes)...\n");
    ctx.upload_blob(regs.ATCM_RAM_BASE, ctx.fw_blob);
    _ = ctx.verify_blob(regs.ATCM_RAM_BASE, ctx.fw_blob);

    const nvram_len_padded: u32 = @intCast((ctx.nvram_blob.len + 3) & ~@as(usize, 3));
    const nvram_addr = regs.RAM_SIZE_CYW43439 - 4 - nvram_len_padded;
    ctx.puts("[cyw43] uploading NVRAM (");
    ctx.putDec(@intCast(ctx.nvram_blob.len));
    ctx.puts(" bytes, padded ");
    ctx.putDec(nvram_len_padded);
    ctx.puts(") at ");
    ctx.putHex32(nvram_addr);
    ctx.puts("\n");

    ctx.upload_blob(nvram_addr, ctx.nvram_blob);
    const nvram_sz_words = nvram_len_padded / 4;
    const nvram_token = ((~nvram_sz_words & 0xFFFF) << 16) | (nvram_sz_words & 0xFFFF);
    bus.bpWrite32(regs.RAM_SIZE_CYW43439 - 4, nvram_token);
    ctx.state.* = .firmware_ready;

    const fw_w0 = bus.bpRead32(regs.ATCM_RAM_BASE);
    const fw_mid = bus.bpRead32(regs.ATCM_RAM_BASE + 0x10000);
    const token_rb = bus.bpRead32(regs.RAM_SIZE_CYW43439 - 4);
    ctx.puts("[cyw43] ram[0]=");
    ctx.putHex32(fw_w0);
    ctx.puts(" ram[64K]=");
    ctx.putHex32(fw_mid);
    ctx.puts(" token=");
    ctx.putHex32(token_rb);
    ctx.puts("\n");

    ctx.puts("[cyw43] resetting WLAN core...\n");
    ctx.reset_core(regs.WLAN_BASE);

    const wlan_wrap = regs.WLAN_BASE + regs.WRAPPER_OFFSET;
    const ioctrl_after = bus.bpRead32(wlan_wrap + regs.AI_IOCTRL_OFFSET);
    const resetctrl_after = bus.bpRead32(wlan_wrap + regs.AI_RESETCTRL_OFFSET);
    ctx.puts("[cyw43] WLAN ioctrl=");
    ctx.putHex32(ioctrl_after);
    ctx.puts(" resetctrl=");
    ctx.putHex32(resetctrl_after);
    ctx.puts("\n");

    var timeout: u32 = 0;
    var last_csr: u8 = 0;
    while (timeout < 2000) : (timeout += 1) {
        last_csr = bus.readReg8(regs.FUNC_BACKPLANE, regs.BACKPLANE_CHIP_CLOCK_CSR);
        if (last_csr & @as(u8, @truncate(regs.HT_AVAIL)) != 0) break;
        hal.delayMs(1);
    }
    if (timeout >= 2000) {
        ctx.puts("[cyw43] HT timeout csr=");
        ctx.putHex32(last_csr);
        ctx.puts("\n");
        ctx.state.* = .err;
        return types.Error.ClockTimeout;
    }
    ctx.puts("[cyw43] HT clock OK — firmware running\n");

    timeout = 0;
    while (timeout < 1000) : (timeout += 1) {
        const f2_status = bus.readStatus();
        if ((f2_status & regs.STATUS_F2_RX_READY) != 0) break;
        hal.delayMs(1);
    }
    if (timeout >= 1000) ctx.puts("[cyw43] F2 not ready\n") else ctx.puts("[cyw43] F2 ready\n");

    ctx.state.* = .core_init;

    var mac_iobuf: [32]u8 = undefined;
    @memcpy(mac_iobuf[0..15], "cur_etheraddr\x00\x00");
    ctx.do_ioctl(regs.SDPCM_GET, regs.IOCTL_CMD_GET_VAR, 0, mac_iobuf[0..15]) catch {
        ctx.puts("[cyw43] MAC read failed\n");
    };
    @memcpy(ctx.mac_addr, mac_iobuf[0..6]);
    ctx.puts("[cyw43] MAC=");
    const hex = "0123456789abcdef";
    for (ctx.mac_addr.*, 0..) |b, i| {
        if (i > 0) @import("../../platform/hal.zig").platform.uartWrite(@import("../../platform/hal.zig").platform.UART0_BASE, ':');
        @import("../../platform/hal.zig").platform.uartWrite(@import("../../platform/hal.zig").platform.UART0_BASE, hex[b >> 4]);
        @import("../../platform/hal.zig").platform.uartWrite(@import("../../platform/hal.zig").platform.UART0_BASE, hex[b & 0xF]);
    }
    ctx.puts("\n");

    ctx.state.* = .clm_loading;
    ctx.clm_load() catch {
        ctx.puts("[cyw43] CLM upload failed\n");
        ctx.state.* = .err;
        return types.Error.IoctlTimeout;
    };
    ctx.puts("[cyw43] CLM loaded\n");

    ctx.led_set(true) catch {};
    hal.delayMs(250);
    ctx.led_set(false) catch {};
    ctx.puts("[cyw43] LED blink OK\n");

    var zero4 = [_]u8{ 0, 0, 0, 0 };
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_DOWN, 0, &zero4) catch {};

    var country_buf: [8 + 12]u8 = [_]u8{0} ** 20;
    @memcpy(country_buf[0..8], "country\x00");
    country_buf[8] = 'X';
    country_buf[9] = 'X';
    country_buf[12] = 'X';
    country_buf[13] = 'X';
    country_buf[16] = 0xFF;
    country_buf[17] = 0xFF;
    country_buf[18] = 0xFF;
    country_buf[19] = 0xFF;
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, &country_buf) catch {
        ctx.puts("[cyw43] country set failed\n");
    };

    ctx.do_ioctl(regs.SDPCM_SET, 0x56, 0, &zero4) catch {};
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_UP, 0, &zero4) catch {
        ctx.puts("[cyw43] WLC_UP failed\n");
        ctx.state.* = .err;
        return types.Error.IoctlTimeout;
    };
    ctx.puts("[cyw43] WiFi UP\n");

    var evtmask_buf: [8 + 24]u8 = [_]u8{0} ** 32;
    @memcpy(evtmask_buf[0..11], "event_msgs\x00");
    @memset(evtmask_buf[11..32], 0xFF);
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, &evtmask_buf) catch {
        ctx.puts("[cyw43] event_msgs failed\n");
    };

    var txglom_buf: [8 + 6 + 4]u8 = [_]u8{0} ** 18;
    @memcpy(txglom_buf[0..11], "bus:txglom\x00");
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, txglom_buf[0..15]) catch {};

    var apsta_buf: [8 + 4]u8 = [_]u8{0} ** 12;
    @memcpy(apsta_buf[0..6], "apsta\x00");
    apsta_buf[6] = 1;
    ctx.do_ioctl(regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, &apsta_buf) catch {};

    @import("scan.zig").reset();
    ctx.start_scan() catch {
        ctx.puts("[cyw43] scan start failed\n");
    };

    var scan_timeout: u32 = 0;
    while (scan_timeout < 5000) : (scan_timeout += 1) {
        while (true) {
            const result = ctx.poll_device();
            if (result == .none) break;
            if (result == .event) ctx.handle_event(@as([*]const u8, @ptrCast(ctx.rx_buf)));
        }
        hal.delayMs(1);
    }
    ctx.print_scan_results();

    ctx.state.* = .wifi_idle;

    if (ctx.wifi_ssid.len > 0 and ctx.wifi_pass.len > 0) {
        const delays = [_]u32{ 0, 2000, 5000 };
        var joined = false;
        for (delays) |delay| {
            if (delay > 0) {
                ctx.puts("[wifi] retrying in ");
                ctx.putDec(delay / 1000);
                ctx.puts("s...\n");
                hal.delayMs(delay);
            }
            ctx.join_wpa2(ctx.wifi_ssid, ctx.wifi_pass) catch continue;
            joined = true;
            break;
        }
        if (!joined) {
            ctx.puts("[wifi] join failed after retries\n");
            return;
        }

        ctx.puts("[dhcp] starting...\n");
        dhcp.start();

        var dhcp_timeout: u32 = 0;
        var retries: u8 = 0;
        while (dhcp_timeout < 10000) : (dhcp_timeout += 1) {
            const result = ctx.poll_device();
            if (result == .event) ctx.handle_event(@as([*]const u8, @ptrCast(ctx.rx_buf)));
            if (result == .data) ctx.handle_data();
            if (dhcp.dhcp_state == .bound or dhcp.dhcp_state == .failed) break;

            if (dhcp_timeout > 0 and dhcp_timeout % 3000 == 0 and dhcp.dhcp_state == .discovering and retries < 3) {
                retries += 1;
                ctx.puts("[dhcp] retransmit discover\n");
                dhcp.retransmit();
            }
            hal.delayMs(1);
        }

        if (dhcp.dhcp_state == .bound) {
            ctx.puts("[wifi] IP=");
            fmt.putIp(netif.stack().local_ip);
            ctx.puts("\n");
        } else {
            ctx.puts("[dhcp] failed to obtain IP\n");
        }
    }
}

pub fn init(ctx: *Context) types.Error!void {
    try probe(ctx);
    try boot(ctx);
}
