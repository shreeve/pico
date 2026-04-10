# Wi-Fi and Networking Notes

Practical implementation notes, current status, and near-term roadmap for the
CYW43439 Wi-Fi and networking stack on Pico W / Pico 2 W.

## Current state (April 10, 2026)

The networking stack has been significantly expanded:

### Proven on hardware
- PIO SPI / gSPI transport at 31 MHz
- firmware upload + NVRAM token + HT clock boot
- SDPCM/CDC IOCTL control plane
- CLM upload and onboard LED control
- Wi-Fi scan discovering nearby SSIDs and hidden networks
- WPA2-PSK join with retry/cooldown handling
- raw Ethernet TX/RX through the CYW43 data channel
- DHCP client bound at `10.0.0.27` without lwIP
- ARP responder + client cache (8-entry, 5-min TTL)
- DHCP lease-renewal logic

### New in this build
- **IPv4 layer** (`src/net/ipv4.zig`) — generic IP RX demux (ICMP/UDP/TCP), header checksum validation, fragment rejection, destination check, outbound TX with routing
- **ICMP echo reply** (`src/net/icmp.zig`) — device can be pinged from the LAN
- **ARP client/cache** (`src/net/arp.zig`) — outbound ARP requests, 8-entry cache with LRU eviction, gateway MAC resolution, gratuitous ARP on DHCP bind
- **TCP/IP stack** (`src/net/tcpip.zig`) — comptime-composed NetStack with multi-connection TCP, app-driven retransmit via AppVTable, work-flag output processing
- **TLS integration point** (`src/net/tls.zig`) — placeholder for BearSSL, honest error returns
- **MQTT 3.1.1 client** (`src/bindings/mqtt.zig`) — CONNECT, PUBLISH, SUBSCRIBE, PINGREQ via AppVTable, QoS 0
- **Flash KV storage** (`src/bindings/storage.zig`) — append-log format, read-only via XIP
- **Watchdog** (`src/runtime/watchdog.zig`) — 8-second timeout, crash counter, safe-mode detection
- **Periodic timer tick** — 10ms ALARM0-based interrupt enabling `wfe` idle in the main loop
- **Truthful `wifi.connect()`** — now actually calls `cyw43.joinWpa2()` and starts DHCP
- **OTA-ready flash layout** — firmware (768 KB) + staging (768 KB) + scripts (256 KB) + config (192 KB) + metadata (64 KB)

## Architecture

```
Air ↔ CYW43 ↔ PIO SPI ↔ gSPI ↔ SDPCM/BDC ↔ Ethernet
                                                 ↓
                                          ┌──────┴───────┐
                                          │  ethertype   │
                                          ├──────────────┤
                                     0x0806│         0x0800│
                                          ↓              ↓
                                        ARP           IPv4
                                   (reply+cache)   (demux+route)
                                                  ┌────┼────┐
                                               ICMP  UDP   TCP
                                              (echo) (DHCP) (state machine)
                                                            ↓
                                                      ┌─────┴─────┐
                                                    MQTT      protocol.zig
                                                  (broker)    (script push)
```

## Flash layout (RP2040, 2 MB)

```
0x10000000  BOOT2          256 bytes
0x10000100  Firmware       ~768 KB (code + CYW43 FW + MQuickJS)
0x100C0000  OTA Staging    ~768 KB (downloaded update image)
0x10180000  Scripts        256 KB  (active + rollback)
0x101C0000  Config/KV      192 KB  (append-log KV store)
0x101F0000  OTA Metadata   64 KB   (version, hash, commit flag)
```

## Reference boot log

```text
[cyw43] SPI OK
[cyw43] ALP clock OK
[cyw43] verify OK
[cyw43] HT clock OK — firmware running
[cyw43] F2 ready
[cyw43] MAC=28:cd:c1:10:3e:1b
[cyw43] CLM loaded
[cyw43] LED blink OK
[cyw43] WiFi UP
[scan] 8 networks found:
  -38 dBm  c6:50:9c:9e:fc:69  Shreeve
  ...
[join] associated!
[dhcp] offer 10.0.0.27 from 10.0.0.1
[dhcp] bound 10.0.0.27 gw 10.0.0.1 mask 255.255.255.0
[wifi] IP=10.0.0.27
```

## What is next

1. **Validate on hardware**: ARP client, ICMP echo, TCP handshake
2. **Integrate BearSSL** for client TLS (MQTT over TLS port 8883, HTTPS for OTA)
3. **Test MQTT end-to-end** with a real broker (Mosquitto)
4. **Wire `protocol.zig`** into the event loop for script push over TCP
5. **Implement flash write driver** (RAM-resident, for KV storage.set() and OTA)
6. **Build OTA bootloader** (immutable, verifies SHA-256, copies staging to active)
7. **Production security**: signed updates, authenticated script upload, JS sandboxing

## Scope boundary

This document is for:
- current networking milestone status
- what is proven on hardware
- what is next in the stack

Low-level CYW43 transport and bus details live in `CYW43.md`.
The host-side CLI tool vision lives in `PICO.md`.
