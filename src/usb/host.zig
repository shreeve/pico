// ============================================================================
// USB Host Driver for RP2040
//
// Ported from PicoUSB (Steve Shreeve's C implementation) to bare-metal Zig.
// Architecture follows picousb closely: pipes, task queue, stepped enumeration.
//
// Flow: ISR → task queue → poll() → callbacks/enumeration
// ============================================================================

const reg = @import("regs.zig");
const desc = @import("descriptors.zig");
const hal = @import("../platform/hal.zig");
const console = @import("../bindings/console.zig");

// ── Configuration ──────────────────────────────────────────────────────

pub const MAX_DEVICES = 2; // dev0 + 1 user device
pub const MAX_PIPES = 16; // ctrl + 15
pub const MAX_CTRL_BUF = 320;

// ── Speed ──────────────────────────────────────────────────────────────

pub const Speed = enum(u2) {
    disconnected = 0,
    low = 1,
    full = 2,
};

// ── Device state ───────────────────────────────────────────────────────

pub const DeviceState = enum(u8) {
    disconnected,
    allocated,
    detected,
    addressed,
    enumerated,
    configured,
    ready,
    suspended,
};

pub const Device = struct {
    dev_addr: u8 = 0,
    state: DeviceState = .disconnected,
    speed: Speed = .disconnected,
    maxsize0: u16 = 0,

    class: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,

    vid: u16 = 0,
    pid: u16 = 0,
    version: u16 = 0,
    i_manufacturer: u8 = 0,
    i_product: u8 = 0,
    i_serial: u8 = 0,

    pub fn reset(self: *Device) void {
        self.* = .{};
    }
};

// ── Pipe (matches picousb's pipe_t) ────────────────────────────────────

pub const PipeStatus = enum(u8) {
    unconfigured,
    configured,
    started,
    finished,
};

pub const TransferResult = struct {
    dev_addr: u8 = 0,
    ep_num: u8 = 0,
    dir_in: bool = false,
    user_buf: [*]u8 = undefined,
    len: u16 = 0,
    status: u8 = 0,
};

pub const Callback = *const fn (*anyopaque) void;
pub const TransferCallback = *const fn (?*anyopaque, *const TransferResult) void;

pub const Pipe = struct {
    dev_addr: u8 = 0,
    ep_num: u4 = 0,
    ep_in: bool = false,
    transfer_type: u8 = 0,
    interval: u16 = 0,
    maxsize: u16 = 0,

    buf_addr: u32 = 0, // DPSRAM buffer address
    user_buf: [*]u8 = undefined,

    ecr_addr: u32 = 0, // endpoint control register address (DPSRAM)
    bcr_addr: u32 = 0, // buffer control register address (DPSRAM)

    status: PipeStatus = .unconfigured,
    setup: bool = false,
    data_pid: u1 = 0,
    bytes_left: u16 = 0,
    bytes_done: u16 = 0,

    cb: ?Callback = null,
    cb_arg: ?*anyopaque = null,
    xfer_cb: ?TransferCallback = null,
    xfer_ctx: ?*anyopaque = null,

    pub fn resetState(self: *Pipe) void {
        self.status = .finished;
        self.setup = false;
        self.bytes_left = 0;
        self.bytes_done = 0;
    }

    pub fn clear(self: *Pipe) void {
        self.* = .{};
    }
};

// ── Task queue (ISR → main loop, matches picousb) ──────────────────────

pub const TaskType = enum(u8) {
    callback,
    connect,
    transfer,
};

pub const ConnectInfo = struct {
    speed: Speed = .disconnected,
};

pub const TransferInfo = struct {
    status: u8 = 0,
    dev_addr: u8 = 0,
    ep_num: u8 = 0,
    user_buf: ?[*]u8 = null,
    len: u16 = 0,
};

pub const Task = struct {
    task_type: TaskType = .callback,
    guid: u32 = 0,

    connect: ConnectInfo = .{},
    transfer: TransferInfo = .{},

    cb: ?Callback = null,
    cb_arg: ?*anyopaque = null,
    xfer_cb: ?TransferCallback = null,
    xfer_ctx: ?*anyopaque = null,
};

const TASK_QUEUE_SIZE = 64;
var task_queue: [TASK_QUEUE_SIZE]Task = [_]Task{.{}} ** TASK_QUEUE_SIZE;
var tq_head: usize = 0;
var tq_tail: usize = 0;
var tq_count: usize = 0;
var next_guid: u32 = 1;

fn taskEnqueue(task: Task) void {
    if (tq_count >= TASK_QUEUE_SIZE) return; // full, drop
    var t = task;
    t.guid = next_guid;
    next_guid +%= 1;
    task_queue[tq_tail] = t;
    tq_tail = (tq_tail + 1) % TASK_QUEUE_SIZE;
    tq_count += 1;
}

fn taskDequeue() ?Task {
    if (tq_count == 0) return null;
    const t = task_queue[tq_head];
    tq_head = (tq_head + 1) % TASK_QUEUE_SIZE;
    tq_count -= 1;
    return t;
}

fn queueCallback(cb: Callback, arg: *anyopaque) void {
    taskEnqueue(.{
        .task_type = .callback,
        .cb = cb,
        .cb_arg = arg,
    });
}

// ── State ──────────────────────────────────────────────────────────────

var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;
pub var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;
var ctrl_buf: [MAX_CTRL_BUF]u8 align(4) = undefined;
var initialized: bool = false;
var epx_owner: ?*Pipe = null; // tracks which pipe currently owns EPX for bulk transfers

fn dev0() *Device {
    return &devices[0];
}

fn ctrl() *Pipe {
    return &pipes[0];
}

fn getDevice(addr: u8) *Device {
    return &devices[addr];
}

fn nextDevice() *Device {
    for (devices[1..], 1..) |*d, i| {
        if (d.state == .disconnected) {
            d.state = .allocated;
            d.dev_addr = @intCast(i);
            return d;
        }
    }
    @panic("No free devices remaining");
}

fn clearDevice(addr: u8) void {
    devices[addr].reset();
}

fn clearAllDevices() void {
    for (&devices) |*d| d.reset();
}

fn clearAllPipes() void {
    for (&pipes) |*p| p.clear();
}

// ── NVIC ───────────────────────────────────────────────────────────────

const NVIC_ISER: u32 = 0xE000_E100;
const NVIC_ICER: u32 = 0xE000_E180;
const NVIC_ICPR: u32 = 0xE000_E280;
const USBCTRL_IRQ: u5 = 5;

fn nvicEnable() void {
    hal.regWrite(NVIC_ISER, @as(u32, 1) << USBCTRL_IRQ);
}

fn nvicDisable() void {
    hal.regWrite(NVIC_ICER, @as(u32, 1) << USBCTRL_IRQ);
}

fn nvicClearPending() void {
    hal.regWrite(NVIC_ICPR, @as(u32, 1) << USBCTRL_IRQ);
}

// ── Pipe setup ─────────────────────────────────────────────────────────

fn setupPipe(pp: *Pipe, phe: u8, epd_addr: u8, epd_attrs: u8, epd_maxsize: u16, epd_interval: u8, user_buf: [*]u8) void {
    const saved_dev_addr = pp.dev_addr;

    pp.* = .{
        .dev_addr = saved_dev_addr,
        .ep_num = @intCast(epd_addr & 0x0F),
        .ep_in = (epd_addr & 0x80) != 0,
        .transfer_type = epd_attrs & 0x03,
        .interval = epd_interval,
        .maxsize = epd_maxsize,
        .user_buf = user_buf,
    };

    if (phe == 0) {
        pp.ecr_addr = reg.EPX_CTRL;
        pp.bcr_addr = reg.EPX_BUF_CTRL;
        pp.buf_addr = reg.EPX_DATA;
    } else {
        const i: u32 = @as(u32, phe) - 1;
        pp.ecr_addr = reg.intEpCtrl(@intCast(i));
        pp.bcr_addr = reg.intEpBufCtrl(@intCast(i));
        pp.buf_addr = reg.EPX_DATA + (i + 2) * 64;
    }

    // Clear BCR with settling time
    reg.dpWrite(pp.bcr_addr, 0);
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");

    // Setup ECR
    const buf_type: u32 = if (phe != 0)
        (reg.EP_CTRL_INT_PER_BUFFER)
    else
        (reg.EP_CTRL_DOUBLE_BUFFERED | reg.EP_CTRL_INT_PER_DOUBLE_BUFFER);

    const ecr = reg.EP_CTRL_ENABLE | buf_type | (@as(u32, pp.transfer_type) << reg.EP_CTRL_BUFFER_TYPE_LSB) | (@as(u32, @max(pp.interval, 1) - 1) << reg.EP_CTRL_HOST_INT_INTERVAL_LSB) | (pp.buf_addr & 0xFC0);
    reg.dpWrite(pp.ecr_addr, ecr);

    pp.data_pid = 0;

    // Piccolo Xpress quirk: starts with DATA1 (same as picousb)
    if (pp.dev_addr != 0) {
        const dev = getDevice(pp.dev_addr);
        if (dev.vid == 0x0403 and dev.pid == 0xCD18) {
            pp.data_pid = 1;
        }
    }

    pp.status = .configured;
}

fn setupCtrl() void {
    setupPipe(ctrl(), 0, 0, desc.TRANSFER_CONTROL, 0, 0, &ctrl_buf);
}

fn getPipe(dev_addr: u8, ep_num: u8) *Pipe {
    for (&pipes) |*pp| {
        if (pp.status != .unconfigured) {
            if (pp.dev_addr == dev_addr and pp.ep_num == @as(u4, @intCast(ep_num & 0x0F)))
                return pp;
        }
    }
    @panic("No configured pipe for this endpoint");
}

fn nextPipe(dev_addr: u8, epd: *const desc.EndpointDescriptor, user_buf: ?[*]u8) *Pipe {
    if ((epd.bEndpointAddress & 0x0F) == 0) @panic("EP0 cannot be requested");
    for (pipes[1..], 1..) |*pp, i| {
        if (pp.status == .unconfigured) {
            pp.dev_addr = dev_addr;
            setupPipe(pp, @intCast(i), epd.bEndpointAddress, epd.bmAttributes, epd.wMaxPacketSize, epd.bInterval, user_buf orelse &ctrl_buf);
            return pp;
        }
    }
    @panic("No free pipes remaining");
}

// ── Buffer management ──────────────────────────────────────────────────

fn startBuffer(pp: *Pipe, buf_id: u1) u16 {
    const is_in = pp.ep_in;
    const has_more = pp.bytes_left > pp.maxsize;
    const pid = pp.data_pid;
    const len: u16 = @min(pp.bytes_left, pp.maxsize);

    var bcr: u16 = 0;
    if (!is_in) bcr |= @as(u16, @truncate(reg.BUF_CTRL_FULL));
    if (!has_more) bcr |= @as(u16, @truncate(reg.BUF_CTRL_LAST));
    if (pid == 1) bcr |= @as(u16, @truncate(reg.BUF_CTRL_DATA1_PID));
    bcr |= len;

    pp.data_pid = pid ^ 1;

    // OUT: copy from user buffer to DPSRAM
    if (!is_in and len > 0) {
        const dst = pp.buf_addr + @as(u32, buf_id) * 64;
        reg.dpMemcpy(dst, pp.user_buf + pp.bytes_done, len);
        pp.bytes_done += len;
    }

    pp.bytes_left -= len;
    return bcr;
}

fn finishBuffer(pp: *Pipe, buf_id: u1, bcr: u32) u16 {
    const is_in = pp.ep_in;
    const len: u16 = @intCast(bcr & reg.BUF_CTRL_LEN_MASK);

    // IN: copy from DPSRAM to user buffer
    if (is_in and len > 0) {
        const src = pp.buf_addr + @as(u32, buf_id) * 64;
        reg.dpMemcpyFrom(pp.user_buf + pp.bytes_done, src, len);
        pp.bytes_done += len;
    }

    if (len < pp.maxsize)
        pp.bytes_left = 0;

    return len;
}

// ── Transactions ───────────────────────────────────────────────────────

fn startTransactionCb(arg: *anyopaque) void {
    const pp: *Pipe = @ptrCast(@alignCast(arg));
    startTransaction(pp);
}

fn startTransaction(pp: *Pipe) void {
    var hold: u32 = startBuffer(pp, 0);
    var fire: u32 = reg.BUF_CTRL_AVAIL;

    // Double/single buffer mode for epx
    if (pp.ecr_addr == ctrl().ecr_addr) {
        if (hold & reg.BUF_CTRL_LAST != 0) {
            // Single buffer
            var ecr = reg.dpRead(pp.ecr_addr);
            ecr &= ~(reg.EP_CTRL_DOUBLE_BUFFERED | reg.EP_CTRL_INT_PER_DOUBLE_BUFFER);
            ecr |= reg.EP_CTRL_INT_PER_BUFFER;
            reg.dpWrite(pp.ecr_addr, ecr);
        } else {
            // Double buffer
            hold |= @as(u32, startBuffer(pp, 1)) << 16;
            var ecr = reg.dpRead(pp.ecr_addr);
            ecr &= ~reg.EP_CTRL_INT_PER_BUFFER;
            ecr |= reg.EP_CTRL_DOUBLE_BUFFERED | reg.EP_CTRL_INT_PER_DOUBLE_BUFFER;
            reg.dpWrite(pp.ecr_addr, ecr);
            fire |= fire << 16;
        }
    }

    // Write BCR with settling nops
    reg.dpWrite(pp.bcr_addr, hold);
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");
    asm volatile ("nop");

    // Fire
    reg.dpWrite(pp.bcr_addr, hold | fire);
}

fn finishTransaction(pp: *Pipe) void {
    const ecr = reg.dpRead(pp.ecr_addr);
    const bcr = reg.dpRead(pp.bcr_addr);

    if (ecr & reg.EP_CTRL_DOUBLE_BUFFERED != 0) {
        if (finishBuffer(pp, 0, bcr) == pp.maxsize)
            _ = finishBuffer(pp, 1, bcr >> 16);
    } else {
        const bch = reg.read(reg.BUFF_CPU_SHOULD_HANDLE);
        var tmp = bcr;
        if (bch & 1 != 0) tmp >>= 16;
        _ = finishBuffer(pp, 0, tmp);
    }
}

// ── Transfers ──────────────────────────────────────────────────────────

fn startTransfer(pp: *Pipe) void {
    pp.status = .started;

    const dar: u32 = @as(u32, pp.ep_num) << 16 | pp.dev_addr;
    var sie: u32 = reg.SIE_CTRL_HOST_BASE;

    // Shared epx needs per-transfer SIE setup
    if (pp.ecr_addr == ctrl().ecr_addr) {
        const is_in = pp.ep_in;
        const is_setup_start = pp.setup and pp.bytes_done == 0;

        if (is_in) {
            sie |= reg.SIE_CTRL_RECEIVE_DATA;
        } else {
            sie |= reg.SIE_CTRL_SEND_DATA;
        }
        if (is_setup_start) {
            sie |= reg.SIE_CTRL_SEND_SETUP;
        }
    }

    reg.write(reg.ADDR_ENDP, dar);
    reg.write(reg.SIE_CTRL, sie);

    startTransaction(pp);

    // Fire
    reg.write(reg.SIE_CTRL, sie | reg.SIE_CTRL_START_TRANS);
}

fn finishTransfer(pp: *Pipe) void {
    const task = Task{
        .task_type = .transfer,
        .transfer = .{
            .status = 0,
            .dev_addr = pp.dev_addr,
            .ep_num = pp.ep_num,
            .user_buf = pp.user_buf,
            .len = pp.bytes_done,
        },
        .cb = pp.cb,
        .cb_arg = pp.cb_arg,
        .xfer_cb = pp.xfer_cb,
        .xfer_ctx = pp.xfer_ctx,
    };

    pp.resetState();

    // Control transfer callbacks are one-shot
    if (pp.ep_num == 0 and pp.cb != null) {
        pp.cb = null;
        pp.cb_arg = null;
    }

    taskEnqueue(task);
}

pub fn transferZlp(arg: *anyopaque) void {
    const pp: *Pipe = @ptrCast(@alignCast(arg));

    pp.bytes_left = 0;

    // ZLP for control transfers flips direction and uses DATA1
    if (pp.transfer_type == 0) {
        pp.ep_in = !pp.ep_in;
        pp.data_pid = 1;
    }

    startTransfer(pp);
}

fn awaitTransfer(pp: *Pipe) void {
    while (pp.status != .finished) {
        processTask();
    }
}

pub fn controlTransfer(dev: *Device, setup: *const desc.SetupPacket) void {
    const pp = ctrl();
    epx_owner = null;

    // Copy setup packet to DPSRAM
    const src: [*]const u8 = @ptrCast(setup);
    reg.dpMemcpy(reg.SETUP_PACKET, src, 8);

    pp.dev_addr = dev.dev_addr;
    pp.ep_num = 0;
    pp.ep_in = (setup.bmRequestType & desc.DIR_IN) != 0;
    pp.maxsize = if (dev.maxsize0 > 0) dev.maxsize0 else 8;
    pp.setup = true;
    pp.data_pid = 1; // SETUP uses DATA0, next packet DATA1
    pp.user_buf = &ctrl_buf;
    pp.bytes_left = setup.wLength;
    pp.bytes_done = 0;

    // No data phase → flip direction
    if (pp.bytes_left == 0) pp.ep_in = !pp.ep_in;

    startTransfer(pp);
}

pub fn command(dev: *Device, bmRequestType: u8, bRequest: u8, wValue: u16, wIndex: u16, wLength: u16) void {
    controlTransfer(dev, &.{
        .bmRequestType = bmRequestType,
        .bRequest = bRequest,
        .wValue = wValue,
        .wIndex = wIndex,
        .wLength = wLength,
    });
    awaitTransfer(ctrl());
}

pub fn bulkTransfer(pp: *Pipe, ptr: [*]u8, len: u16) void {
    pp.user_buf = ptr;
    pp.bytes_left = len;
    pp.bytes_done = 0;
    routeThroughEpx(pp);
    startTransfer(pp);
}

pub fn bulkTransferAsync(pp: *Pipe, ptr: [*]u8, len: u16, cb: TransferCallback, ctx: ?*anyopaque) void {
    pp.xfer_cb = cb;
    pp.xfer_ctx = ctx;
    pp.user_buf = ptr;
    pp.bytes_left = len;
    pp.bytes_done = 0;
    routeThroughEpx(pp);
    startTransfer(pp);
}

fn routeThroughEpx(pp: *Pipe) void {
    pp.ecr_addr = reg.EPX_CTRL;
    pp.bcr_addr = reg.EPX_BUF_CTRL;
    pp.buf_addr = reg.EPX_DATA;
    epx_owner = pp;
}

// ── Descriptors ────────────────────────────────────────────────────────

fn getDescriptor(dev: *Device, dtype: u8, len: u8) void {
    controlTransfer(dev, &.{
        .bmRequestType = desc.DIR_IN | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_GET_DESCRIPTOR,
        .wValue = desc.makeU16(dtype, 0),
        .wIndex = 0,
        .wLength = len,
    });
}

fn getDeviceDescriptor(dev: *Device) void {
    var len: u8 = @sizeOf(desc.DeviceDescriptor);
    if (dev.maxsize0 == 0) {
        dev.maxsize0 = 8; // Default per USB 2.0 spec
        len = 8;
    }
    getDescriptor(dev, desc.DT_DEVICE, len);
}

fn getConfigDescriptor(dev: *Device, len: u8) void {
    getDescriptor(dev, desc.DT_CONFIG, len);
}

fn loadDeviceDescriptor(dev: *Device) void {
    const d = desc.cast(desc.DeviceDescriptor, &ctrl_buf);
    dev.class = d.bDeviceClass;
    dev.subclass = d.bDeviceSubClass;
    dev.protocol = d.bDeviceProtocol;
    dev.vid = d.idVendor;
    dev.pid = d.idProduct;
    dev.version = d.bcdDevice;
    dev.i_manufacturer = d.iManufacturer;
    dev.i_product = d.iProduct;
    dev.i_serial = d.iSerialNumber;
}

fn setDeviceAddress(dev: *Device) void {
    controlTransfer(dev0(), &.{
        .bmRequestType = desc.DIR_OUT | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_SET_ADDRESS,
        .wValue = dev.dev_addr,
        .wIndex = 0,
        .wLength = 0,
    });
}

fn setConfiguration(dev: *Device, cfg: u16) void {
    controlTransfer(dev, &.{
        .bmRequestType = desc.DIR_OUT | desc.REQ_TYPE_STANDARD | desc.REQ_RECIPIENT_DEVICE,
        .bRequest = desc.REQUEST_SET_CONFIGURATION,
        .wValue = cfg,
        .wIndex = 0,
        .wLength = 0,
    });
}

fn showDeviceInfo(dev: *Device) void {
    console.puts("[usb] VID=0x");
    printHex16(dev.vid);
    console.puts(" PID=0x");
    printHex16(dev.pid);
    console.puts(" class=");
    printU8(dev.class);
    console.puts("\n");
}

// ── Enumeration state machine ──────────────────────────────────────────

const EnumStep = enum(u8) {
    start,
    get_maxsize,
    set_address,
    get_device,
    get_config_short,
    get_config_full,
    set_config,
    finish,
};

var enum_step: EnumStep = .start;
var enum_new_addr: u8 = 0;

fn resetEnumState() void {
    enum_step = .start;
    enum_new_addr = 0;
}

fn enumerate(arg: *anyopaque) void {
    const dev: *Device = @ptrCast(@alignCast(arg));

    if (dev.maxsize0 == 0)
        enum_step = .start;

    switch (enum_step) {
        .start => {
            console.puts("[usb] enumeration started\n");
            enum_step = .get_maxsize;
            getDeviceDescriptor(dev);
        },

        .get_maxsize => {
            enum_step = .set_address;
            // Extract maxsize from partial device descriptor
            const d = desc.cast(desc.DeviceDescriptor, &ctrl_buf);
            const new_dev = nextDevice();
            new_dev.state = dev0().state;
            new_dev.speed = dev0().speed;
            new_dev.maxsize0 = d.bMaxPacketSize0;
            enum_new_addr = new_dev.dev_addr;

            console.puts("[usb] SET_ADDRESS -> ");
            printU8(enum_new_addr);
            console.puts("\n");
            setDeviceAddress(new_dev);
        },

        .set_address => {
            enum_step = .get_device;
            const new_dev = getDevice(enum_new_addr);
            new_dev.state = .addressed;
            clearDevice(0);

            console.puts("[usb] GET_DEVICE_DESCRIPTOR (full)\n");
            getDeviceDescriptor(new_dev);
        },

        .get_device => {
            enum_step = .get_config_short;
            loadDeviceDescriptor(dev);
            showDeviceInfo(dev);

            console.puts("[usb] GET_CONFIG_DESCRIPTOR (short)\n");
            getConfigDescriptor(dev, 9);
        },

        .get_config_short => {
            enum_step = .get_config_full;
            const cd = desc.cast(desc.ConfigDescriptor, &ctrl_buf);
            const total_len = cd.wTotalLength;
            if (total_len > MAX_CTRL_BUF)
                @panic("Configuration descriptor too large");

            console.puts("[usb] GET_CONFIG_DESCRIPTOR (full, ");
            printU16(total_len);
            console.puts(" bytes)\n");
            getConfigDescriptor(dev, @intCast(total_len));
        },

        .get_config_full => {
            enum_step = .set_config;
            enumerateDescriptors(dev);
            dev.state = .enumerated;

            console.puts("[usb] SET_CONFIGURATION\n");
            setConfiguration(dev, 1);
        },

        .set_config => {
            enum_step = .finish;
            dev.state = .configured;
            console.puts("[usb] device configured!\n");
            showDeviceInfo(dev);
            onDeviceConfigured(dev);
        },

        .finish => {},
    }
}

fn enumerateDescriptors(dev: *Device) void {
    var cur: usize = 0;
    const cd = desc.cast(desc.ConfigDescriptor, &ctrl_buf);
    const end: usize = cd.wTotalLength;

    while (cur + 2 <= end) {
        const dlen: usize = ctrl_buf[cur];
        const dtype = ctrl_buf[cur + 1];

        if (dlen == 0) break;
        if (cur + dlen > end) break;

        switch (dtype) {
            desc.DT_CONFIG => {
                console.puts("[usb]   config descriptor\n");
            },
            desc.DT_INTERFACE => {
                if (dlen >= 9) {
                    const ifd = desc.cast(desc.InterfaceDescriptor, ctrl_buf[cur..]);
                    console.puts("[usb]   interface ");
                    printU8(ifd.bInterfaceNumber);
                    console.puts(" class=0x");
                    printHex8(ifd.bInterfaceClass);
                    console.puts(" sub=0x");
                    printHex8(ifd.bInterfaceSubClass);
                    console.puts("\n");
                }
            },
            desc.DT_ENDPOINT => {
                if (dlen >= 7) {
                    // Parse from raw bytes to avoid alignment faults
                    // (endpoint descriptors can start at odd offsets)
                    const ep_addr = ctrl_buf[cur + 2];
                    const ep_attrs = ctrl_buf[cur + 3];
                    const ep_maxsize = @as(u16, ctrl_buf[cur + 4]) | (@as(u16, ctrl_buf[cur + 5]) << 8);
                    const ep_interval = ctrl_buf[cur + 6];

                    console.puts("[usb]   endpoint EP");
                    printU8(ep_addr & 0x0F);
                    if (ep_addr & 0x80 != 0) {
                        console.puts(" IN");
                    } else {
                        console.puts(" OUT");
                    }
                    console.puts(" maxsize=");
                    printU16(ep_maxsize);
                    console.puts("\n");

                    const epd_aligned = desc.EndpointDescriptor{
                        .bLength = ctrl_buf[cur],
                        .bDescriptorType = ctrl_buf[cur + 1],
                        .bEndpointAddress = ep_addr,
                        .bmAttributes = ep_attrs,
                        .wMaxPacketSize = ep_maxsize,
                        .bInterval = ep_interval,
                    };
                    _ = nextPipe(dev.dev_addr, &epd_aligned, null);
                }
            },
            else => {},
        }

        cur += dlen;
    }
}

// ── Device callbacks ───────────────────────────────────────────────────

fn onDeviceConfigured(dev: *Device) void {
    console.puts("[usb] device ");
    printU8(dev.dev_addr);
    console.puts(" ready (VID=0x");
    printHex16(dev.vid);
    console.puts(" PID=0x");
    printHex16(dev.pid);
    console.puts(")\n");
    dev.state = .ready;

    const ftdi = @import("ftdi.zig");
    ftdi.ftdiSetup(dev);
}

// ── Bus reset ──────────────────────────────────────────────────────────

fn busReset() void {
    console.puts("[usb] bus reset...\n");

    // Disable NVIC USB IRQ during bus reset to prevent spurious connect/disconnect
    nvicDisable();

    // Mask HOST_CONN_DIS during reset
    var inte = reg.read(reg.INTE);
    inte &= ~reg.INT_HOST_CONN_DIS;
    reg.write(reg.INTE, inte);

    // Assert SE0 (bus reset)
    reg.set(reg.SIE_CTRL, reg.SIE_CTRL_RESET_BUS);

    // 50ms bus reset per USB spec
    hal.delayMs(50);

    // Deassert bus reset
    reg.clr(reg.SIE_CTRL, reg.SIE_CTRL_RESET_BUS);

    // Recovery time after bus reset
    hal.delayMs(10);

    // Clear all SIE_STATUS and BUFF_STATUS (W1C: write 1s to clear)
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);

    // Flush task queue
    tq_head = 0;
    tq_tail = 0;
    tq_count = 0;

    // Re-enable HOST_CONN_DIS interrupt
    inte = reg.read(reg.INTE);
    inte |= reg.INT_HOST_CONN_DIS;
    reg.write(reg.INTE, inte);

    // Clear NVIC pending and re-enable
    nvicClearPending();
    nvicEnable();

    console.puts("[usb] bus reset complete\n");
}

// ── ISR ────────────────────────────────────────────────────────────────

pub fn isr() void {
    var ints = reg.read(reg.INTS);

    // Connection / disconnection
    if (ints & reg.INT_HOST_CONN_DIS != 0) {
        ints &= ~reg.INT_HOST_CONN_DIS;

        // Capture speed BEFORE clearing (W1C erases speed bits)
        const speed_bits = (reg.read(reg.SIE_STATUS) & reg.SIE_STATUS_SPEED_BITS) >> reg.SIE_STATUS_SPEED_LSB;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_SPEED_BITS);

        const speed: Speed = @enumFromInt(@as(u2, @truncate(speed_bits)));
        if (speed != .disconnected) {
            taskEnqueue(.{
                .task_type = .connect,
                .connect = .{ .speed = speed },
                .cb = &enumerate,
                .cb_arg = @ptrCast(dev0()),
            });
        } else {
            const ftdi = @import("ftdi.zig");
            ftdi.resetState();
            clearDevice(0);
            clearAllPipes();
            setupCtrl();
            resetEnumState();
        }
    }

    // Stall
    if (ints & reg.INT_STALL != 0) {
        ints &= ~reg.INT_STALL;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_STALL_REC);
        console.puts("[usb] ISR: stall\n");
    }

    // Buffer ready
    if (ints & reg.INT_BUFF_STATUS != 0) {
        ints &= ~reg.INT_BUFF_STATUS;

        var bits = reg.read(reg.BUFF_STATUS);
        var mask: u32 = 0b11;

        var pipe_idx: u8 = 0;
        while (pipe_idx < MAX_PIPES and bits != 0) : ({
            pipe_idx += 1;
            mask <<= 2;
        }) {
            if (bits & mask != 0) {
                bits &= ~mask;
                reg.write(reg.BUFF_STATUS, mask);

                const pp = if (pipe_idx == 0 and epx_owner != null) epx_owner.? else &pipes[pipe_idx];
                finishTransaction(pp);

                if (pp.bytes_left > 0) {
                    queueCallback(&startTransactionCb, @ptrCast(pp));
                } else {
                    finishTransfer(pp);
                }
            }
        }
    }

    // Transfer complete
    if (ints & reg.INT_TRANS_COMPLETE != 0) {
        ints &= ~reg.INT_TRANS_COMPLETE;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_TRANS_COMPLETE);
    }

    // Receive timeout
    if (ints & reg.INT_ERROR_RX_TIMEOUT != 0) {
        ints &= ~reg.INT_ERROR_RX_TIMEOUT;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_RX_TIMEOUT);
    }

    // Data sequence error
    if (ints & reg.INT_ERROR_DATA_SEQ != 0) {
        ints &= ~reg.INT_ERROR_DATA_SEQ;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_DATA_SEQ_ERROR);
    }

    // Device resume
    if (ints & reg.INT_HOST_RESUME != 0) {
        ints &= ~reg.INT_HOST_RESUME;
        reg.write(reg.SIE_STATUS, reg.SIE_STATUS_RESUME);
    }
}

// ── Task processing (called from superloop) ─────────────────────────────

fn processTask() void {
    if (taskDequeue()) |task| {
        switch (task.task_type) {
            .callback => {},

            .connect => {
                const ftdi = @import("ftdi.zig");
                ftdi.resetState();
                clearDevice(0);
                clearAllPipes();
                setupCtrl();
                resetEnumState();
                const d = dev0();
                d.state = .detected;
                d.speed = task.connect.speed;

                const label: []const u8 = switch (task.connect.speed) {
                    .low => "low",
                    .full => "full",
                    .disconnected => "???",
                };
                console.puts("[usb] device connected (");
                console.puts(label);
                console.puts(" speed)\n");

                // Bus reset after connect
                busReset();
            },

            .transfer => {
                const dev = getDevice(task.transfer.dev_addr);
                const pp = getPipe(task.transfer.dev_addr, task.transfer.ep_num);

                if (@intFromEnum(dev.state) < @intFromEnum(DeviceState.configured)) {
                    if (task.transfer.len > 0) {
                        transferZlp(@ptrCast(pp));
                    } else {
                        enumerate(@ptrCast(dev));
                    }
                } else if (task.xfer_cb) |xcb| {
                    const result = TransferResult{
                        .dev_addr = task.transfer.dev_addr,
                        .ep_num = task.transfer.ep_num,
                        .dir_in = pp.ep_in,
                        .user_buf = task.transfer.user_buf orelse undefined,
                        .len = task.transfer.len,
                        .status = task.transfer.status,
                    };
                    xcb(task.xfer_ctx, &result);
                }
            },
        }

        // Invoke optional legacy callback (used by enumeration connect path)
        if (task.cb) |cb| {
            cb(task.cb_arg orelse @ptrCast(dev0()));
        }
    }
}

// ── Init ───────────────────────────────────────────────────────────────

pub fn init() void {
    console.puts("[usb] host init\n");

    nvicDisable();
    nvicClearPending();

    // Reset USB controller
    const RESETS_USBCTRL: u32 = 1 << 24;
    hal.regSet(hal.platform.RESETS_BASE, RESETS_USBCTRL);
    hal.regClr(hal.platform.RESETS_BASE, RESETS_USBCTRL);
    while ((hal.regRead(hal.platform.RESETS_BASE + 0x08) & RESETS_USBCTRL) == 0) {}

    // Clear DPSRAM
    reg.dpMemset(reg.DPSRAM_BASE, 0, 4096);

    // Disable everything first
    reg.write(reg.INTE, 0);
    reg.write(reg.MAIN_CTRL, 0);
    reg.write(reg.SIE_CTRL, 0);
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);

    // Configure as USB host
    reg.write(reg.USB_MUXING, reg.MUXING_TO_PHY | reg.MUXING_SOFTCON);
    reg.write(reg.USB_PWR, reg.PWR_HOST_MODE);
    reg.write(reg.MAIN_CTRL, reg.MAIN_CTRL_CONTROLLER_EN | reg.MAIN_CTRL_HOST_NDEVICE);
    reg.write(reg.SIE_CTRL, reg.SIE_CTRL_HOST_BASE);

    // Clear state
    clearAllDevices();
    clearAllPipes();
    setupCtrl();

    // Clear status one more time
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);

    // Flush task queue BEFORE enabling interrupts (prevents ISR/main race)
    tq_head = 0;
    tq_tail = 0;
    tq_count = 0;

    // Enable interrupts
    reg.write(reg.INTE, reg.INT_HOST_CONN_DIS | reg.INT_STALL | reg.INT_BUFF_STATUS | reg.INT_TRANS_COMPLETE | reg.INT_HOST_RESUME | reg.INT_ERROR_DATA_SEQ | reg.INT_ERROR_RX_TIMEOUT);

    nvicClearPending();
    nvicEnable();

    initialized = true;
    console.puts("[usb] host ready — waiting for device\n");
}

pub fn deinit() void {
    nvicDisable();
    reg.write(reg.INTE, 0);
    reg.write(reg.SIE_STATUS, 0xFFFFFFFF);
    reg.write(reg.BUFF_STATUS, 0xFFFFFFFF);
    nvicClearPending();
    reg.write(reg.MAIN_CTRL, 0);
    initialized = false;
}

// ── Poll (called from superloop) ────────────────────────────────────────

pub fn poll() void {
    processTask();
}

// ── Public accessors ───────────────────────────────────────────────────

pub fn getCtrl() *Pipe {
    return ctrl();
}

pub fn getCtrlBuf() []u8 {
    return &ctrl_buf;
}

pub fn isReady() bool {
    return initialized;
}

pub fn getDev0() *Device {
    return dev0();
}

// ── Formatting helpers ─────────────────────────────────────────────────

fn printU8(val: u8) void {
    var buf: [3]u8 = undefined;
    var n: u8 = val;
    var i: usize = buf.len;
    if (n == 0) {
        console.putc('0');
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = (n % 10) + '0';
        n /= 10;
    }
    console.puts(buf[i..]);
}

fn printU16(val: u16) void {
    var buf: [5]u8 = undefined;
    var n: u16 = val;
    var i: usize = buf.len;
    if (n == 0) {
        console.putc('0');
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast(n % 10 + '0');
        n /= 10;
    }
    console.puts(buf[i..]);
}

fn printHex8(val: u8) void {
    const hex = "0123456789ABCDEF";
    console.putc(hex[val >> 4]);
    console.putc(hex[val & 0x0F]);
}

fn printHex16(val: u16) void {
    printHex8(@intCast(val >> 8));
    printHex8(@intCast(val & 0xFF));
}
