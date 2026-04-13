// Global network stack singleton.
//
// Single shared NetStack instance for the entire firmware. All protocol
// modules (ipv4.zig, arp.zig, tcpip.zig, ethernet.zig) access this to
// update stats, route TCP segments, and manage connections.
//
// Design rationale:
//   - RP2040 single-core target with cooperative scheduling
//   - one network interface (CYW43 WiFi)
//   - avoids threading a large state struct through every call chain
//
// Lifecycle:
//   - initialized at program load (module-scope var with .init())
//   - valid immediately — no explicit init() call required
//   - IPv4 config set by DHCP (or future static config) via setIpv4()
//   - tick(now_ms) must be called from main loop for timer processing
//
// Constraints:
//   - not thread-safe (single-core cooperative only)
//   - must not be accessed from ISR context
//   - all callers must run in the main cooperative loop

const tcpip = @import("tcpip.zig");
pub const Stack = tcpip.NetStack(.{});

var instance: Stack = Stack.init();

/// Return a mutable pointer to the singleton stack.
pub fn stack() *Stack {
    return &instance;
}

pub fn tick(now_ms: u32) void {
    instance.tick(now_ms);
}
