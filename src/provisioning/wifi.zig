/// Wi-Fi provisioning — AP mode captive portal.
/// When no Wi-Fi credentials are stored, the device creates a soft AP
/// and serves a simple web page where the user enters SSID + password.
const console = @import("../services/console.zig");
const config = @import("../config/config.zig");

pub const AP_SSID = "pico-setup";
pub const AP_CHANNEL: u8 = 6;

var provisioning_active: bool = false;

pub fn start() void {
    console.puts("[provision] starting AP: ");
    console.puts(AP_SSID);
    console.puts("\n");
    provisioning_active = true;
    // TODO: start CYW43 AP mode
    // TODO: start DHCP server
    // TODO: start HTTP server on port 80
}

pub fn poll() void {
    if (!provisioning_active) return;
    // TODO: serve captive portal, handle form submissions
}

pub fn isActive() bool {
    return provisioning_active;
}

pub fn stop() void {
    provisioning_active = false;
    console.puts("[provision] stopped\n");
}
