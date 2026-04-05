// ============================================================================
// USB Host Driver for RP2040 — EPX-only mode
//
// Ported from Steve Shreeve's PicoUSB C implementation to bare-metal Zig.
// All transfers go through the single software endpoint (EPX) for maximum
// control and simplicity.  Hardware interrupt polling endpoints are not used.
//
// Architecture:
//   ISR → event queue → event loop → callbacks (Zig or JS)
// ============================================================================

const std = @import("std");
const reg = @import("regs.zig");
const desc = @import("descriptors.zig");
const hal = @import("../platform/hal.zig");
const console = @import("../services/console.zig");

// ── Configuration ──────────────────────────────────────────────────────

pub const MAX_DEVICES = 3; // dev0 + 2 user devices
pub const MAX_ENDPOINTS = 7; // EP0 per device + extras
pub const MAX_PACKET_SIZE = 64;
pub const CTRL_BUF_SIZE = 255;

// ── Speed ──────────────────────────────────────────────────────────────

pub const Speed = enum(u2) {
    disconnected = 0,
    low = 1,
    full = 2,
};

// ── Device state ───────────────────────────────────────────────────────

pub const DeviceState = enum {
    disconnected,
    allocated,
    enumerating,
    addressed,
    active,
    suspended,
};

pub const Device = struct {
    state: DeviceState = .disconnected,
    speed: Speed = .disconnected,
    class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    vid: u16 = 0,
    pid: u16 = 0,
    version: u16 = 0,
    max_packet_size0: u8 = 8,
    i_manufacturer: u8 = 0,
    i_product: u8 = 0,
    i_serial: u8 = 0,

    pub fn reset(self: *Device) void {
        self.* = .{};
    }
};

// ── Endpoint ───────────────────────────────────────────────────────────

pub const TransferCallback = *const fn (*Endpoint, []const u8) void;

pub const Endpoint = struct {
    dev_addr: u8 = 0,
    ep_addr: u8 = 0,
    ep_type: u8 = 0, // control/bulk/interrupt/isochronous
    maxsize: u16 = 8,
    interval: u16 = 0, // polling interval in ms (0 = not polled)
    data_pid: u1 = 0, // toggle DATA0/DATA1
    configured: bool = false,
    active: bool = false,
    setup: bool = false,

    // Transfer state
    user_buf: [*]u8 = undefined,
    bytes_left: u16 = 0,
    bytes_done: u16 = 0,
    cb: ?TransferCallback = null,

    pub inline fn isIn(self: *const Endpoint) bool {
        return self.ep_addr & desc.DIR_IN != 0;
    }

    pub inline fn num(self: *const Endpoint) u4 {
        return @intCast(self.ep_addr & 0x0F);
    }

    pub fn clear(self: *Endpoint) void {
        self.active = false;
        self.setup = false;
        self.data_pid = 0;
        self.user_buf = undefined;
        self.bytes_left = 0;
        self.bytes_done = 0;
    }
};

// ── State ──────────────────────────────────────────────────────────────

var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;
var endpoints: [MAX_ENDPOINTS]Endpoint = [_]Endpoint{.{}} ** MAX_ENDPOINTS;
var ctrl_buf: [CTRL_BUF_SIZE]u8 = undefined;
var initialized: bool = false;

// The shared EPX endpoint (index 0)
fn epx() *Endpoint {
    return &endpoints[0];
}

fn dev0() *Device {
    return &devices[0];
}

// ── Event queue (ISR → main loop) ──────────────────────────────────────

pub const EventKind = enum(u8) {
    connect,
    disconnect,
    transfer_complete,
    stall,
    error_timeout,
    error_data_seq,
};

pub const Event = struct {
    kind: EventKind,
    ep_idx: u8 = 0,
    transfer_len: u16 = 0,
    speed: Speed = .disconnected,
};

const EVENT_QUEUE_SIZE = 16;
var event_queue: [EVENT_QUEUE_SIZE]Event = undefined;
var eq_head: usize = 0;
var eq_tail: usize = 0;

fn enqueueEvent(ev: Event) void {
    const next = (eq_tail + 1) % EVENT_QUEUE_SIZE;
    if (next == eq_head) return; // full, drop event
    event_queue[eq_tail] = ev;
    eq_tail = next;
}

fn dequeueEvent() ?Event {
    if (eq_head == eq_tail) return null;
    const ev = event_queue[eq_head];
    eq_head = (eq_head + 1) % EVENT_QUEUE_SIZE;
    return ev;
}

// ── User callbacks ─────────────────────────────────────────────────────

pub const ConnectCallback = *const fn (Speed) void;
pub const DisconnectCallback = *const fn () void;
pub const TransferDoneCallback = *const fn (*Endpoint, u16) void;

var on_connect: ?ConnectCallback = null;
var on_disconnect: ?DisconnectCallback = null;
var on_transfer_done: ?TransferDoneCallback = null;

pub fn setConnectCallback(cb: ConnectCallback) void {
    on_connect = cb;
}
pub fn setDisconnectCallback(cb: DisconnectCallback) void {
    on_disconnect = cb;
}
pub fn setTransferDoneCallback(cb: TransferDoneCallback) void {
    on_transfer_done = cb;
}

// ── NVIC (Cortex-M0+ interrupt controller) ─────────────────────────────

const NVIC_ISER: u32 = 0xE000_E100; // Interrupt Set-Enable
const NVIC_ICER: u32 = 0xE000_E180; // Interrupt Clear-Enable
const NVIC_ICPR: u32 = 0xE000_E280; // Interrupt Clear-Pending
const USBCTRL_IRQ: u5 = 5;

fn nvicEnableIrq(irq: u5) void {
    hal.regWrite(NVIC_ISER, @as(u32, 1) << irq);
}

fn nvicDisableIrq(irq: u5) void {
    hal.regWrite(NVIC_ICER, @as(u32, 1) << irq);
}

fn nvicClearPending(irq: u5) void {
    hal.regWrite(NVIC_ICPR, @as(u32, 1) << irq);
}

// ── Init ───────────────────────────────────────────────────────────────

pub fn init() void {
    console.puts("[usb] host init\n");

    // Ensure NVIC USB IRQ is disabled before touching USB hardware
    nvicDisableIrq(USBCTRL_IRQ);
    nvicClearPending(USBCTRL_IRQ);

    // Reset the USB controller
    const RESETS_USBCTRL: u32 = 1 << 24;
    hal.regSet(hal.platform.RESETS_BASE, RESETS_USBCTRL);
    hal.regClr(hal.platform.RESETS_BASE, RESETS_USBCTRL);
    while ((hal.regRead(hal.platform.RESETS_BASE + 0x08) & RESETS_USBCTRL) == 0) {}

    // Clear all state
    reg.dpMemset(reg.DPSRAM_BASE, 0, 4096);

    // Clear USB registers — disable interrupts first, then clear all status
    reg.write(reg.INTE, 0);
    reg.write(reg.MAIN_CTRL, 0);
    reg.write(reg.SIE_CTRL, 0);
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF); // W1C: clear all status
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF); // W1C: clear all buffer status

    // Configure as USB host
    reg.write(reg.USB_MUXING, reg.MUXING_TO_PHY | reg.MUXING_SOFTCON);
    reg.write(reg.USB_PWR, reg.PWR_VBUS_DETECT | reg.PWR_VBUS_DETECT_OVERRIDE_EN);
    reg.write(reg.MAIN_CTRL, reg.MAIN_CTRL_CONTROLLER_EN | reg.MAIN_CTRL_HOST_NDEVICE);
    reg.write(reg.SIE_CTRL, reg.SIE_CTRL_HOST_BASE);

    // Clear device and endpoint state
    for (&devices) |*d| d.reset();
    for (&endpoints) |*ep| ep.* = .{};

    // Configure EPX for control transfers (default 8-byte maxsize)
    setupEpx(8);

    // Clear any pending status one more time after configuration
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);

    // Enable USB interrupt sources (peripheral-level)
    reg.write(reg.INTE, reg.INT_HOST_CONN_DIS | reg.INT_STALL | reg.INT_BUFF_STATUS | reg.INT_TRANS_COMPLETE | reg.INT_HOST_RESUME | reg.INT_ERROR_DATA_SEQ | reg.INT_ERROR_RX_TIMEOUT);

    // Clear NVIC pending (in case INTS went high briefly) and enable
    nvicClearPending(USBCTRL_IRQ);
    nvicEnableIrq(USBCTRL_IRQ);

    initialized = true;
    console.puts("[usb] host ready\n");
}

pub fn deinit() void {
    nvicDisableIrq(USBCTRL_IRQ);
    reg.write(reg.INTE, 0);
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);
    nvicClearPending(USBCTRL_IRQ);
    reg.write(reg.MAIN_CTRL, 0);
    initialized = false;
}

fn setupEpx(maxsize: u16) void {
    const ep = epx();
    ep.* = .{
        .dev_addr = 0,
        .ep_addr = 0,
        .ep_type = desc.TRANSFER_CONTROL,
        .maxsize = maxsize,
        .interval = 0,
        .configured = true,
        .user_buf = &ctrl_buf,
    };

    // ECR: enable, control type, data buffer at EPX_DATA offset
    const data_offset = reg.EPX_DATA & 0x0FFF;
    const ecr = reg.EP_CTRL_ENABLE | reg.EP_CTRL_DOUBLE_BUFFERED | reg.EP_CTRL_INT_PER_DOUBLE_BUFFER | (@as(u32, desc.TRANSFER_CONTROL) << reg.EP_CTRL_BUFFER_TYPE_LSB) | data_offset;
    reg.dpWrite(reg.EPX_CTRL, ecr);
}

// ── Endpoint management ────────────────────────────────────────────────

pub fn findEndpoint(dev_addr: u8, ep_addr: u8) ?*Endpoint {
    const want_ep0 = (ep_addr & ~@as(u8, desc.DIR_IN)) == 0;
    if (dev_addr == 0 and want_ep0) return epx();

    for (endpoints[1..]) |*ep| {
        if (!ep.configured or ep.dev_addr != dev_addr) continue;
        if (want_ep0 and (ep.ep_addr & ~@as(u8, desc.DIR_IN)) == 0) return ep;
        if (ep.ep_addr == ep_addr) return ep;
    }
    return null;
}

pub fn allocEndpoint(dev_addr: u8, ep_desc: *const desc.EndpointDescriptor) ?*Endpoint {
    for (endpoints[1..]) |*ep| {
        if (!ep.configured) {
            ep.* = .{
                .dev_addr = dev_addr,
                .ep_addr = ep_desc.bEndpointAddress,
                .ep_type = ep_desc.bmAttributes & desc.TRANSFER_TYPE_MASK,
                .maxsize = ep_desc.wMaxPacketSize,
                .interval = ep_desc.bInterval,
                .configured = true,
                .user_buf = &ctrl_buf,
            };
            return ep;
        }
    }
    return null;
}

pub fn allocEp0(dev_addr: u8, maxsize: u8) ?*Endpoint {
    for (endpoints[1..]) |*ep| {
        if (!ep.configured) {
            ep.* = .{
                .dev_addr = dev_addr,
                .ep_addr = 0,
                .ep_type = desc.TRANSFER_CONTROL,
                .maxsize = maxsize,
                .configured = true,
                .user_buf = &ctrl_buf,
            };
            return ep;
        }
    }
    return null;
}

// ── Device management ──────────────────────────────────────────────────

pub fn getDevice(addr: u8) ?*Device {
    if (addr < MAX_DEVICES) return &devices[addr];
    return null;
}

pub fn nextDevAddr() ?u8 {
    for (1..MAX_DEVICES) |i| {
        if (devices[i].state == .disconnected) {
            devices[i].state = .allocated;
            return @intCast(i);
        }
    }
    return null;
}

// ── Buffer management (EPX-only) ───────────────────────────────────────

fn readBuffer(ep: *Endpoint, buf_id: u1, bcr: u32) u16 {
    const is_in = ep.isIn();
    const is_full = bcr & reg.BUF_CTRL_FULL != 0;
    const len: u16 = @intCast(bcr & reg.BUF_CTRL_LEN_MASK);

    // Sanity: IN buffers should be full, OUT buffers should be empty
    _ = is_full;

    // Copy inbound data from DPSRAM to user buffer
    if (is_in and len > 0) {
        const src = reg.epxDataBuf(buf_id);
        reg.dpMemcpyFrom(ep.user_buf + ep.bytes_done, src, len);
        ep.bytes_done += len;
    }

    // Short packet means transfer is done
    if (len < ep.maxsize) {
        ep.bytes_left = 0;
    }

    return len;
}

fn prepBuffer(ep: *Endpoint, buf_id: u1) u16 {
    const is_in = ep.isIn();
    const has_more = ep.bytes_left > ep.maxsize;
    const pid = ep.data_pid;
    const len: u16 = @min(ep.maxsize, ep.bytes_left);

    var bcr: u16 = 0;
    if (!is_in) bcr |= @as(u16, @truncate(reg.BUF_CTRL_FULL)); // OUT = full
    if (!has_more) bcr |= @as(u16, @truncate(reg.BUF_CTRL_LAST)); // last packet
    if (pid == 1) bcr |= @as(u16, @truncate(reg.BUF_CTRL_DATA1_PID));
    bcr |= @as(u16, @truncate(reg.BUF_CTRL_AVAIL));
    bcr |= len;

    // Toggle PID
    ep.data_pid = pid ^ 1;

    // Copy outbound data from user buffer to DPSRAM
    if (!is_in and len > 0) {
        const dst = reg.epxDataBuf(buf_id);
        reg.dpMemcpy(dst, ep.user_buf + ep.bytes_done, len);
        ep.bytes_done += len;
    }

    ep.bytes_left -= len;
    return bcr;
}

fn sendBuffers(ep: *Endpoint) void {
    var ecr = reg.dpRead(reg.EPX_CTRL);
    var bcr: u32 = prepBuffer(ep, 0);

    // Double buffer if there's more data after this packet
    if (bcr & reg.BUF_CTRL_LAST == 0) {
        ecr |= reg.EP_CTRL_DOUBLE_BUFFERED;
        bcr |= @as(u32, prepBuffer(ep, 1)) << 16;
    } else {
        ecr &= ~reg.EP_CTRL_DOUBLE_BUFFERED;
    }

    // Write BCR first (masked), then ECR, then unmask BCR
    reg.dpWrite(reg.EPX_BUF_CTRL, bcr & reg.UNAVAILABLE_MASK);
    reg.dpWrite(reg.EPX_CTRL, ecr);
    asm volatile ("nop");
    asm volatile ("nop");
    reg.dpWrite(reg.EPX_BUF_CTRL, bcr);
}

fn handleBuffers(ep: *Endpoint) void {
    if (!ep.active) return;

    const ecr = reg.dpRead(reg.EPX_CTRL);
    var bcr = reg.dpRead(reg.EPX_BUF_CTRL);

    if (ecr & reg.EP_CTRL_DOUBLE_BUFFERED != 0) {
        if (readBuffer(ep, 0, bcr) == ep.maxsize)
            _ = readBuffer(ep, 1, bcr >> 16);
    } else {
        // RP2040-E4 workaround
        const bch = reg.read(reg.BUFF_CPU_SHOULD_HANDLE);
        if (bch & 1 != 0) bcr >>= 16;
        _ = readBuffer(ep, 0, bcr);
    }

    // Send next buffers if there's more data
    if (ep.bytes_left > 0) sendBuffers(ep);
}

// ── Transfers ──────────────────────────────────────────────────────────

pub fn transfer(ep: *Endpoint) void {
    var is_in = ep.isIn();
    const is_setup = ep.setup and ep.bytes_done == 0;

    // No data phase → flip direction (status stage)
    if (ep.bytes_left == 0) {
        is_in = !is_in;
        ep.ep_addr ^= desc.DIR_IN;
    }

    // Build the device address register value
    const dar: u32 = @as(u32, ep.dev_addr) | (@as(u32, ep.num()) << reg.ADDR_ENDP_ENDPOINT_LSB);

    // Build SIE_CTRL
    var scr: u32 = reg.SIE_CTRL_HOST_BASE;
    if (is_setup) scr |= reg.SIE_CTRL_SEND_SETUP;
    if (is_in) {
        scr |= reg.SIE_CTRL_RECEIVE_DATA;
    } else {
        scr |= reg.SIE_CTRL_SEND_DATA;
    }
    scr |= reg.SIE_CTRL_START_TRANS;

    ep.active = true;

    // Program the hardware (order matters)
    reg.write(reg.ADDR_ENDP, dar);
    reg.write(reg.SIE_CTRL, scr & ~reg.SIE_CTRL_START_TRANS);
    sendBuffers(ep);
    reg.write(reg.SIE_CTRL, scr);
}

pub fn transferZlp(ep: *Endpoint) void {
    ep.data_pid = 1;
    transfer(ep);
}

pub fn controlTransfer(ep: *Endpoint, setup: *const desc.SetupPacket) void {
    // Write the setup packet to DPSRAM
    const src: [*]const u8 = @ptrCast(setup);
    reg.dpMemcpy(reg.SETUP_PACKET, src, 8);

    ep.setup = true;
    ep.data_pid = 1;
    ep.ep_addr = if (setup.bmRequestType & desc.DIR_IN != 0) desc.DIR_IN else 0;
    ep.bytes_left = setup.wLength;
    ep.bytes_done = 0;
    transfer(ep);
}

// ── High-level transfer helpers ────────────────────────────────────────

pub fn getDescriptor(ep: *Endpoint, dtype: u8, index: u8, len: u8) void {
    controlTransfer(ep, &.{
        .bmRequestType = desc.DIR_IN | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_GET_DESCRIPTOR,
        .wValue = desc.makeU16(dtype, index),
        .wIndex = 0,
        .wLength = len,
    });
}

pub fn setAddress(ep: *Endpoint, addr: u8) void {
    controlTransfer(ep, &.{
        .bmRequestType = desc.DIR_OUT | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_SET_ADDRESS,
        .wValue = addr,
        .wIndex = 0,
        .wLength = 0,
    });
}

pub fn setConfiguration(ep: *Endpoint, config: u16) void {
    controlTransfer(ep, &.{
        .bmRequestType = desc.DIR_OUT | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_SET_CONFIGURATION,
        .wValue = config,
        .wIndex = 0,
        .wLength = 0,
    });
}

pub fn getStringDescriptor(ep: *Endpoint, index: u8) void {
    controlTransfer(ep, &.{
        .bmRequestType = desc.DIR_IN | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_GET_DESCRIPTOR,
        .wValue = desc.makeU16(desc.DT_STRING, index),
        .wIndex = 0,
        .wLength = CTRL_BUF_SIZE,
    });
}

// ── Bulk transfers (EPX-only) ──────────────────────────────────────────

pub fn bulkIn(ep: *Endpoint, buf: [*]u8, len: u16) void {
    ep.ep_addr |= desc.DIR_IN;
    ep.user_buf = buf;
    ep.bytes_left = len;
    ep.bytes_done = 0;
    ep.setup = false;
    transfer(ep);
}

pub fn bulkOut(ep: *Endpoint, buf: [*]const u8, len: u16) void {
    ep.ep_addr &= ~desc.DIR_IN;
    ep.user_buf = @constCast(buf);
    ep.bytes_left = len;
    ep.bytes_done = 0;
    ep.setup = false;
    transfer(ep);
}

// ── ISR ────────────────────────────────────────────────────────────────

pub fn isr() void {
    var ints = reg.read(reg.INTS);

    // Connection / disconnection
    if (ints & reg.INT_HOST_CONN_DIS != 0) {
        ints &= ~reg.INT_HOST_CONN_DIS;
        const speed_bits = (reg.read(reg.SIE_STATUS) & reg.SIE_STATUS_SPEED_BITS) >> reg.SIE_STATUS_SPEED_LSB;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_SPEED_BITS);

        const speed: Speed = @enumFromInt(@as(u2, @truncate(speed_bits)));
        if (speed != .disconnected) {
            enqueueEvent(.{ .kind = .connect, .speed = speed });
        } else {
            enqueueEvent(.{ .kind = .disconnect });
        }
    }

    // Stall
    if (ints & reg.INT_STALL != 0) {
        ints &= ~reg.INT_STALL;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_STALL_REC);
        enqueueEvent(.{ .kind = .stall });
    }

    // Buffer ready
    if (ints & reg.INT_BUFF_STATUS != 0) {
        ints &= ~reg.INT_BUFF_STATUS;
        const ep = epx();
        handleBuffers(ep);
        reg.write(reg.BUFF_STATUS, 0xFFFFFFFF); // clear all
    }

    // Transfer complete
    if (ints & reg.INT_TRANS_COMPLETE != 0) {
        ints &= ~reg.INT_TRANS_COMPLETE;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_TRANS_COMPLETE);

        const ep = epx();
        if (ep.active) {
            const len = ep.bytes_done;
            ep.clear();
            enqueueEvent(.{ .kind = .transfer_complete, .transfer_len = len });
        }
    }

    // Receive timeout
    if (ints & reg.INT_ERROR_RX_TIMEOUT != 0) {
        ints &= ~reg.INT_ERROR_RX_TIMEOUT;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_RX_TIMEOUT);
        enqueueEvent(.{ .kind = .error_timeout });
    }

    // Data sequence error
    if (ints & reg.INT_ERROR_DATA_SEQ != 0) {
        ints &= ~reg.INT_ERROR_DATA_SEQ;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_DATA_SEQ_ERROR);
        enqueueEvent(.{ .kind = .error_data_seq });
    }

    // Device resume
    if (ints & reg.INT_HOST_RESUME != 0) {
        ints &= ~reg.INT_HOST_RESUME;
        reg.clr(reg.SIE_STATUS, reg.SIE_STATUS_RESUME);
    }
}

// ── Event processing (called from event loop) ──────────────────────────

pub fn poll() void {
    while (dequeueEvent()) |ev| {
        switch (ev.kind) {
            .connect => {
                console.puts("[usb] device connected\n");
                dev0().state = .enumerating;
                dev0().speed = ev.speed;
                if (on_connect) |cb| cb(ev.speed);
            },
            .disconnect => {
                console.puts("[usb] device disconnected\n");
                for (&devices) |*d| d.reset();
                for (&endpoints) |*ep| ep.* = .{};
                setupEpx(8);
                if (on_disconnect) |cb| cb();
            },
            .transfer_complete => {
                if (on_transfer_done) |cb| cb(epx(), ev.transfer_len);
            },
            .stall => {
                console.puts("[usb] stall detected\n");
            },
            .error_timeout => {
                console.puts("[usb] rx timeout\n");
            },
            .error_data_seq => {
                console.puts("[usb] data sequence error\n");
            },
        }
    }
}

// ── Public accessors ───────────────────────────────────────────────────

pub fn getEpx() *Endpoint {
    return epx();
}

pub fn getCtrlBuf() []u8 {
    return &ctrl_buf;
}

pub fn isReady() bool {
    return initialized;
}
