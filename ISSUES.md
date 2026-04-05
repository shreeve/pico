# Current Issues

This file captures the current critical and important issues identified
after the source-tree reorganization and naming cleanup.

## Findings

1. **`src/main.zig` still enters provisioning mode even after the CYW43 path has already joined Wi-Fi and obtained DHCP.**  
   The runtime currently decides whether to start provisioning from flash
   config only, not from actual network state. In practice, logs show a
   successful join and DHCP lease, then `"[boot] no wifi config —
   provisioning mode"` anyway. That means the boot flow is still
   semantically wrong even though the refactor preserved behavior.

   ```zig
   // src/main.zig
   wifi.init();
   if (config.isConfigured()) {
       if (config.wifiSsid()) |ssid| {
           const pass = config.wifiPass() orelse "";
           _ = wifi.connect(ssid, pass);
       }
   } else {
       puts("[boot] no wifi config — provisioning mode\n");
       provisioning.start();
   }
   ```

2. **`src/services/wifi.zig` remains a misleading abstraction over the real CYW43 state.**  
   The service never updates `state` to `connected`, never populates
   `ip_buf`, and `connect()` only records strings locally. So the
   JS-facing Wi-Fi API is still logically disconnected from the proven
   hardware path. The README is now more honest, but this mismatch should
   be cleaned up before building more on top of it.

   ```zig
   // src/services/wifi.zig
   pub fn init() void {
       state = .disconnected;
       console.puts("[wifi] init: CYW43 driver\n");

       cyw43.init(.pico_w) catch {
           console.puts("[wifi] CYW43 init failed\n");
           state = .failed;
           return;
       };

       cyw43_ready = true;
       console.puts("[wifi] CYW43 ready\n");
   }

   pub fn connect(ssid: []const u8, password: []const u8) bool {
       _ = password;
       console.puts("[wifi] connecting to: ");
       console.puts(ssid);
       console.puts("\n");
       @memcpy(ssid_buf[0..ssid.len], ssid);
       ssid_len = ssid.len;
       state = .connecting;
       return true;
   }
   ```

3. **Using `pico` for both the firmware/runtime and the host-side tool is still a conceptual regression in clarity.**  
   The tree and code are cleaner, but the naming model is less clean.
   `README.md` is about the firmware, `PICO.md` is about the host tool,
   and `AGENTS.md` has to explain the distinction manually. That is
   workable, but not elegant. Long-term, either the firmware/runtime or
   the host-side tool should get a distinct name.

## Assessment

Yes, the reorganization is a **genuine improvement**.

The biggest gains are real:

- `src/cyw43/core.zig` is no longer a monolith in practice
- the tree now has meaningful subsystem boundaries:
  - `cyw43/transport`
  - `cyw43/control`
  - `cyw43/protocol`
  - `cyw43/netif`
  - `net/`
- tests moved out of `src/`
- `libc/`, `ext/`, `tests/`, `support.zig`, `flash.zig`, and
  `provisioning/wifi.zig` all make the tree read more intentionally
- the refactor held through repeated hardware validation:
  - boot
  - join `Shreeve:innovation`
  - DHCP lease `10.0.0.27`

The refactor improved the codebase in a real way. It is not merely
different.

## Immediate Next Changes

1. Fix `src/main.zig` so provisioning does not start after a successful
   build-time join / DHCP path.
2. Decide whether `src/services/wifi.zig` should become a real state
   bridge to CYW43 or stay an explicitly stubbed JS façade for now.
3. Reconsider the host-tool naming if `pico` is also the firmware/runtime
   name.
