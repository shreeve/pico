# Current Issues

## Resolved (previously tracked)

1. **~~Provisioning mode after successful WiFi join~~** — Fixed.
   `main.zig` now calls `wifi.init()` which boots CYW43 and joins via
   build-time credentials. No spurious provisioning mode entry.

2. **~~wifi.connect() was a facade~~** — Fixed.
   `bindings/wifi.zig` `connect()` now calls `cyw43.device.joinWpa2()`
   and starts DHCP. The JS-facing API matches the hardware path.

3. **~~Naming confusion between firmware and host tool~~** — Accepted.
   `README.md` covers the firmware, `PICO.md` covers the host tool
   vision. Both use the working name "pico." This is fine for now.

## Open Issues

1. **TCP handshake not yet validated on hardware.** The TCP state machine
   in `net/tcpip.zig` compiles and is wired into the IPv4 dispatcher, but
   no TCP connection has been established on real hardware yet.

2. **MQTT not yet tested with a real broker.** The MQTT client in
   `bindings/mqtt.zig` implements AppVTable and builds correct MQTT
   packets, but has not been tested against Mosquitto or any broker.

3. **Flash KV write not implemented.** `bindings/storage.zig` can read
   from flash via XIP but cannot write. Writing requires a RAM-resident
   flash driver that disables interrupts during erase/program cycles.

4. **Script push listener registered but not tested.** `net/script_push.zig`
   registers a TCP listener on port 9001, but no client has connected.

5. **OTA update mechanism not implemented.** Flash layout is OTA-ready
   (768 KB staging area) but no bootloader, image verification, or
   download path exists yet.

6. **No TLS.** BearSSL is the recommended library but not yet integrated.
   Required for MQTT over TLS (port 8883) and HTTPS for OTA downloads.
