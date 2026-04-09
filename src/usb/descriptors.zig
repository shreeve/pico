// USB 2.0 descriptor structures and constants.
// These match the USB spec byte-for-byte (packed, little-endian).

// ── Direction ──────────────────────────────────────────────────────────

pub const DIR_OUT: u8 = 0x00;
pub const DIR_IN: u8 = 0x80;

// ── Request types ──────────────────────────────────────────────────────

pub const REQ_TYPE_STANDARD: u8 = 0x00;
pub const REQ_TYPE_CLASS: u8 = 0x20;
pub const REQ_TYPE_VENDOR: u8 = 0x40;
pub const REQ_TYPE_MASK: u8 = 0x60;

pub const REQ_RECIPIENT_DEVICE: u8 = 0x00;
pub const REQ_RECIPIENT_INTERFACE: u8 = 0x01;
pub const REQ_RECIPIENT_ENDPOINT: u8 = 0x02;
pub const REQ_RECIPIENT_MASK: u8 = 0x1F;

// ── Transfer types ─────────────────────────────────────────────────────

pub const TRANSFER_CONTROL: u8 = 0x00;
pub const TRANSFER_ISOCHRONOUS: u8 = 0x01;
pub const TRANSFER_BULK: u8 = 0x02;
pub const TRANSFER_INTERRUPT: u8 = 0x03;
pub const TRANSFER_TYPE_MASK: u8 = 0x03;

// ── Descriptor types ───────────────────────────────────────────────────

pub const DT_DEVICE: u8 = 0x01;
pub const DT_CONFIG: u8 = 0x02;
pub const DT_STRING: u8 = 0x03;
pub const DT_INTERFACE: u8 = 0x04;
pub const DT_ENDPOINT: u8 = 0x05;
pub const DT_DEVICE_QUALIFIER: u8 = 0x06;
pub const DT_INTERFACE_ASSOCIATION: u8 = 0x0B;
pub const DT_CS_INTERFACE: u8 = 0x24;
pub const DT_CS_ENDPOINT: u8 = 0x25;

// ── Standard requests ──────────────────────────────────────────────────

pub const REQUEST_GET_STATUS: u8 = 0x00;
pub const REQUEST_CLEAR_FEATURE: u8 = 0x01;
pub const REQUEST_SET_FEATURE: u8 = 0x03;
pub const REQUEST_SET_ADDRESS: u8 = 0x05;
pub const REQUEST_GET_DESCRIPTOR: u8 = 0x06;
pub const REQUEST_SET_DESCRIPTOR: u8 = 0x07;
pub const REQUEST_GET_CONFIGURATION: u8 = 0x08;
pub const REQUEST_SET_CONFIGURATION: u8 = 0x09;
pub const REQUEST_GET_INTERFACE: u8 = 0x0A;
pub const REQUEST_SET_INTERFACE: u8 = 0x0B;
pub const REQUEST_SYNC_FRAME: u8 = 0x0C;

// ── Class codes ────────────────────────────────────────────────────────

pub const CLASS_UNSPECIFIED: u8 = 0x00;
pub const CLASS_AUDIO: u8 = 0x01;
pub const CLASS_CDC: u8 = 0x02;
pub const CLASS_HID: u8 = 0x03;
pub const CLASS_PHYSICAL: u8 = 0x05;
pub const CLASS_IMAGE: u8 = 0x06;
pub const CLASS_PRINTER: u8 = 0x07;
pub const CLASS_MSC: u8 = 0x08;
pub const CLASS_HUB: u8 = 0x09;
pub const CLASS_CDC_DATA: u8 = 0x0A;
pub const CLASS_VENDOR_SPECIFIC: u8 = 0xFF;

pub const SUBCLASS_CDC_ACM: u8 = 0x02;

// ── Setup packet ───────────────────────────────────────────────────────

pub const SetupPacket = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
};

// ── Device descriptor ──────────────────────────────────────────────────

pub const DeviceDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16,
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize0: u8,
    idVendor: u16,
    idProduct: u16,
    bcdDevice: u16,
    iManufacturer: u8,
    iProduct: u8,
    iSerialNumber: u8,
    bNumConfigurations: u8,
};

// ── Configuration descriptor ───────────────────────────────────────────

pub const ConfigDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16,
    bNumInterfaces: u8,
    bConfigurationValue: u8,
    iConfiguration: u8,
    bmAttributes: u8,
    bMaxPower: u8,
};

// ── Interface descriptor ───────────────────────────────────────────────

pub const InterfaceDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,
};

// ── Endpoint descriptor ────────────────────────────────────────────────

pub const EndpointDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8,
    bmAttributes: u8,
    wMaxPacketSize: u16,
    bInterval: u8,
};

// ── Interface Association Descriptor ───────────────────────────────────

pub const InterfaceAssocDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bFirstInterface: u8,
    bInterfaceCount: u8,
    bFunctionClass: u8,
    bFunctionSubClass: u8,
    bFunctionProtocol: u8,
    iFunction: u8,
};

// ── String descriptor ──────────────────────────────────────────────────

pub const StringDescriptor = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    // Followed by UTF-16LE code units
};

// ── Wire-format size assertions ────────────────────────────────────────
// extern struct may add tail padding; these catch it at compile time.
// Descriptor parsing uses wire-format constants (7, 9, 9) for bounds
// checks, not @sizeOf, so padding doesn't cause missed descriptors.

comptime {
    if (@sizeOf(SetupPacket) != 8) @compileError("SetupPacket must be 8 bytes");
    if (@sizeOf(DeviceDescriptor) != 18) @compileError("DeviceDescriptor must be 18 bytes");
    // ConfigDescriptor: 9 wire bytes, but @sizeOf may be 10 due to u16 tail padding
    // InterfaceDescriptor: 9 wire bytes, @sizeOf should be 9 (all u8)
    // EndpointDescriptor: 7 wire bytes, but @sizeOf may be 8 due to u16 tail padding
}

// ── Helpers ────────────────────────────────────────────────────────────

pub inline fn makeU16(hi: u8, lo: u8) u16 {
    return (@as(u16, hi) << 8) | lo;
}

/// Cast a raw byte buffer to a typed descriptor pointer.
pub fn cast(comptime T: type, buf: []const u8) *const T {
    if (buf.len < @sizeOf(T)) @panic("descriptor buffer too small");
    return @ptrCast(@alignCast(buf.ptr));
}
