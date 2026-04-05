const regs = @import("../regs.zig");
const bus = @import("../transport/bus.zig");
const hal = @import("../../platform/hal.zig");

pub const Error = error{IoctlTimeout};
pub const PollResult = enum { control, event, data, none };

pub const Context = struct {
    ioctl_id: *u16,
    sdpcm_tx_seq: *u8,
    sdpcm_last_credit: *u8,
    rx_buf: *[2048 / 4]u32,
};

fn nextIoctlId(ctx: *Context) u16 {
    const id = ctx.ioctl_id.*;
    ctx.ioctl_id.* +%= 1;
    return id;
}

pub fn readLE16(src: []const u8) u16 {
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

pub fn readLE32(src: []const u8) u32 {
    return @as(u32, src[0]) | (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) | (@as(u32, src[3]) << 24);
}

pub fn writeLE16(dst: *[2]u8, val: u16) void {
    dst[0] = @truncate(val);
    dst[1] = @truncate(val >> 8);
}

pub fn writeLE32(dst: *[4]u8, val: u32) void {
    dst[0] = @truncate(val);
    dst[1] = @truncate(val >> 8);
    dst[2] = @truncate(val >> 16);
    dst[3] = @truncate(val >> 24);
}

pub fn buildIoctlFrame(ctx: *Context, buf: []u8, kind: u32, cmd: u32, iface: u8, data: []const u8) u16 {
    const total_len = regs.SDPCM_HEADER_LEN + regs.CDC_HEADER_LEN + data.len;
    const id = nextIoctlId(ctx);

    writeLE16(@ptrCast(buf[0..2]), @intCast(total_len));
    writeLE16(@ptrCast(buf[2..4]), @intCast(total_len ^ 0xFFFF));
    buf[4] = ctx.sdpcm_tx_seq.*;
    ctx.sdpcm_tx_seq.* +%= 1;
    buf[5] = regs.CHANNEL_CONTROL;
    buf[6] = 0;
    buf[7] = @intCast(regs.SDPCM_HEADER_LEN);
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 0;
    buf[11] = 0;

    const cdc_off = regs.SDPCM_HEADER_LEN;
    writeLE32(@ptrCast(buf[cdc_off..][0..4]), cmd);
    writeLE32(@ptrCast(buf[cdc_off + 4 ..][0..4]), @intCast(data.len));
    const flags: u32 = (@as(u32, id) << 16) | (@as(u32, iface) << 12) | kind;
    writeLE32(@ptrCast(buf[cdc_off + 8 ..][0..4]), flags);
    writeLE32(@ptrCast(buf[cdc_off + 12 ..][0..4]), 0);

    const payload_off = regs.SDPCM_HEADER_LEN + regs.CDC_HEADER_LEN;
    if (data.len > 0) {
        @memcpy(buf[payload_off..][0..data.len], data);
    }

    return id;
}

pub fn pollDevice(ctx: *Context) PollResult {
    const irq = bus.readReg32(regs.FUNC_BUS, regs.SPI_INTERRUPT_REGISTER);
    if (irq != 0) {
        bus.writeReg32(regs.FUNC_BUS, regs.SPI_INTERRUPT_REGISTER, irq);
    }

    const status = bus.readStatus();
    const pkt_len = (status & regs.STATUS_F2_PKT_LEN_MASK) >> regs.STATUS_F2_PKT_LEN_SHIFT;
    if (pkt_len == 0 or pkt_len > ctx.rx_buf.len * 4) return .none;

    bus.wlanRead(ctx.rx_buf, pkt_len);

    const rx_bytes = @as([*]const u8, @ptrCast(ctx.rx_buf));
    const size = readLE16(rx_bytes[0..2]);
    const size_com = readLE16(rx_bytes[2..4]);
    if ((size ^ size_com) != 0xFFFF) return .none;

    if ((rx_bytes[5] & 0x0F) < 3) {
        ctx.sdpcm_last_credit.* = rx_bytes[9];
    }

    const channel = rx_bytes[5] & 0x0F;
    return switch (channel) {
        regs.CHANNEL_CONTROL => .control,
        regs.CHANNEL_EVENT => .event,
        regs.CHANNEL_DATA => .data,
        else => .none,
    };
}

pub fn hasCredit(ctx: *Context) bool {
    return ((ctx.sdpcm_last_credit.* -% ctx.sdpcm_tx_seq.*) & 0xFF) != 0;
}

pub fn doIoctl(
    ctx: *Context,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    kind: u32,
    cmd: u32,
    iface: u8,
    payload: []u8,
) Error!void {
    var tx_buf: [2048]u8 = undefined;

    var credit_wait: u32 = 0;
    while (!hasCredit(ctx) and credit_wait < 1000) : (credit_wait += 1) {
        const cw_result = pollDevice(ctx);
        if (cw_result == .event) {
            handle_event(@as([*]const u8, @ptrCast(ctx.rx_buf)));
        }
        hal.delayMs(1);
    }
    if (!hasCredit(ctx)) return Error.IoctlTimeout;

    const total_len = regs.SDPCM_HEADER_LEN + regs.CDC_HEADER_LEN + payload.len;
    const sent_id = buildIoctlFrame(ctx, &tx_buf, kind, cmd, iface, payload);

    const padded = (total_len + 63) & ~@as(usize, 63);
    @memset(tx_buf[total_len..padded], 0);

    bus.wlanWrite(tx_buf[0..padded]);

    var timeout: u32 = 0;
    while (timeout < 1000) : (timeout += 1) {
        while (true) {
            const result = pollDevice(ctx);
            if (result == .none) break;
            if (result == .control) {
                const rx_bytes = @as([*]const u8, @ptrCast(ctx.rx_buf));
                const hdr_len = rx_bytes[7];
                const cdc_flags = readLE32(rx_bytes[hdr_len + 8 ..][0..4]);
                const resp_id: u16 = @truncate(cdc_flags >> 16);
                if (resp_id == sent_id) {
                    const resp_data_off = hdr_len + regs.CDC_HEADER_LEN;
                    const resp_len = @min(payload.len, readLE32(rx_bytes[hdr_len + 4 ..][0..4]) & 0xFFFF);
                    if (resp_len > 0) {
                        @memcpy(payload[0..resp_len], rx_bytes[resp_data_off..][0..resp_len]);
                    }
                    return;
                }
            }
            if (result == .event) {
                handle_event(@as([*]const u8, @ptrCast(ctx.rx_buf)));
            }
            if (result == .data) {
                handle_data();
            }
        }
        hal.delayMs(1);
    }
    return Error.IoctlTimeout;
}

pub fn setIoctlU32(
    ctx: *Context,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    cmd: u32,
    iface: u8,
    value: u32,
) Error!void {
    var buf: [4]u8 = undefined;
    writeLE32(@ptrCast(&buf), value);
    try doIoctl(ctx, handle_event, handle_data, regs.SDPCM_SET, cmd, iface, &buf);
}

pub fn setIovar(
    ctx: *Context,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    name: []const u8,
    data: []const u8,
) Error!void {
    var buf: [128]u8 = [_]u8{0} ** 128;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const payload_off = name.len + 1;
    @memcpy(buf[payload_off..][0..data.len], data);
    try doIoctl(ctx, handle_event, handle_data, regs.SDPCM_SET, regs.IOCTL_CMD_SET_VAR, 0, buf[0 .. payload_off + data.len]);
}

pub fn setIovarU32(
    ctx: *Context,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    name: []const u8,
    value: u32,
) Error!void {
    var val_buf: [4]u8 = undefined;
    writeLE32(@ptrCast(&val_buf), value);
    try setIovar(ctx, handle_event, handle_data, name, &val_buf);
}

pub fn setBsscfgIovarU32(
    ctx: *Context,
    handle_event: *const fn ([*]const u8) void,
    handle_data: *const fn () void,
    name: []const u8,
    iface: u32,
    value: u32,
) Error!void {
    var payload: [8]u8 = undefined;
    writeLE32(@ptrCast(payload[0..4]), iface);
    writeLE32(@ptrCast(payload[4..8]), value);
    try setIovar(ctx, handle_event, handle_data, name, &payload);
}
