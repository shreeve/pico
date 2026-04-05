// usb_enumerate.js — enumerate a USB device entirely from JavaScript
//
// This does what your C enumerate() state machine does, but as a
// readable sequential script.  Push this to the Pico and plug in
// a USB device to watch it enumerate.

usb.init();

console.log("Waiting for USB device...");

usb.on("connect", function(speed) {
    var speedName = speed === 1 ? "low" : "full";
    console.log("Device connected (" + speedName + " speed)");

    // Step 1: Get first 8 bytes of device descriptor to learn max packet size
    console.log("GET_DESCRIPTOR (device, 8 bytes)");
    var dd8 = usb.controlIn(0, 0x80, 0x06, 0x0100, 0, 8);
    var maxPacketSize = dd8.charCodeAt(7);
    console.log("  max packet size: " + maxPacketSize);

    // Step 2: Allocate a new address and set it
    var addr = usb.nextAddress();
    usb.allocEp0(addr, maxPacketSize);
    console.log("SET_ADDRESS -> " + addr);
    usb.controlOut(0, 0x00, 0x05, addr, 0);

    // Step 3: Get full device descriptor (18 bytes) from new address
    console.log("GET_DESCRIPTOR (device, 18 bytes)");
    var dd = usb.controlIn(addr, 0x80, 0x06, 0x0100, 0, 18);
    var vid = dd.charCodeAt(8)  | (dd.charCodeAt(9)  << 8);
    var pid = dd.charCodeAt(10) | (dd.charCodeAt(11) << 8);
    console.log("  VID: 0x" + vid.toString(16));
    console.log("  PID: 0x" + pid.toString(16));
    console.log("  class: " + dd.charCodeAt(4));
    console.log("  subclass: " + dd.charCodeAt(5));
    console.log("  protocol: " + dd.charCodeAt(6));

    // Step 4: Get short config descriptor (9 bytes) to learn total length
    console.log("GET_DESCRIPTOR (config, 9 bytes)");
    var cd9 = usb.controlIn(addr, 0x80, 0x06, 0x0200, 0, 9);
    var totalLen = cd9.charCodeAt(2) | (cd9.charCodeAt(3) << 8);
    var numInterfaces = cd9.charCodeAt(4);
    console.log("  total length: " + totalLen);
    console.log("  interfaces: " + numInterfaces);

    // Step 5: Get full config descriptor
    console.log("GET_DESCRIPTOR (config, " + totalLen + " bytes)");
    var cd = usb.controlIn(addr, 0x80, 0x06, 0x0200, 0, totalLen);

    // Parse interfaces
    var offset = cd9.charCodeAt(0); // skip config descriptor itself
    while (offset < totalLen) {
        var descLen  = cd.charCodeAt(offset);
        var descType = cd.charCodeAt(offset + 1);

        if (descType === 4) { // interface descriptor
            var ifNum    = cd.charCodeAt(offset + 2);
            var ifClass  = cd.charCodeAt(offset + 5);
            var ifSub    = cd.charCodeAt(offset + 6);
            var ifProto  = cd.charCodeAt(offset + 7);
            console.log("  interface " + ifNum +
                        ": class=" + ifClass +
                        " sub=" + ifSub +
                        " proto=" + ifProto);
        } else if (descType === 5) { // endpoint descriptor
            var epAddr = cd.charCodeAt(offset + 2);
            var epAttr = cd.charCodeAt(offset + 3);
            var epSize = cd.charCodeAt(offset + 4) | (cd.charCodeAt(offset + 5) << 8);
            var epDir  = (epAddr & 0x80) ? "IN" : "OUT";
            var epNum  = epAddr & 0x0F;
            var epType = ["control", "iso", "bulk", "interrupt"][epAttr & 3];
            console.log("    EP" + epNum + " " + epDir +
                        " " + epType +
                        " maxsize=" + epSize);
        }

        offset += descLen;
    }

    // Step 6: Set configuration
    console.log("SET_CONFIGURATION -> 1");
    usb.controlOut(addr, 0x00, 0x09, 1, 0);

    console.log("Device enumerated!");
    console.log("Ready for class driver operations.");
});

usb.on("disconnect", function() {
    console.log("Device disconnected");
});
