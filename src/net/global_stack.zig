// Network interface — global stack instance and integration bridge.
//
// Provides the singleton NetStack instance and functions that the
// existing protocol modules (ipv4.zig, arp.zig, ethernet.zig) can
// call to update stats, access the RX ring, and route TCP segments
// through the new stack architecture.

const stack_mod = @import("tcpip.zig");
pub const Stack = stack_mod.NetStack(.{});

var instance: Stack = Stack.init();

pub fn get() *Stack {
    return &instance;
}

pub fn tick() void {
    instance.tick();
    instance.tcpPollTimers();
    instance.tcpPollOutput();
}
