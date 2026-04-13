# Wi-Fi and Networking Notes

Practical implementation notes, current status, and near-term roadmap for the
CYW43439 Wi-Fi and networking stack on Pico W / Pico 2 W.

## Current state (April 13, 2026)

### Proven on hardware
- PIO SPI / gSPI transport at 31 MHz
- Firmware upload + NVRAM token + HT clock boot
- SDPCM/CDC IOCTL control plane
- CLM upload and onboard LED control
- Wi-Fi scan discovering nearby SSIDs and hidden networks
- WPA2-PSK join with retry/cooldown handling
- Raw Ethernet TX/RX through the CYW43 data channel
- DHCP client bound on the LAN without lwIP
- ARP responder + client cache (8-entry, 5-min TTL)
- IPv4 layer with generic demux (ICMP/UDP/TCP)
- ICMP echo reply — device responds to ping
- **TCP** — full handshake, bidirectional data, MSS negotiation, clean teardown
- **Telnet shell** on port 23 — readline-lite with cursor movement, 4-entry history
- **MQTT plaintext** (port 1883) — CONNECT, PUBLISH, SUBSCRIBE, PINGREQ with Mosquitto
- **MQTT over TLS 1.2** (port 8883) — BearSSL handshake, encrypted bidirectional pub/sub

### Implemented but not yet validated on hardware
- Script push protocol (`src/net/script_push.zig`) — TCP listener on port 9001
- Flash KV storage (`src/bindings/storage.zig`) — append-log read via XIP
- OTA-ready flash layout — firmware (768 KB) + staging (768 KB) + scripts (256 KB) + config (192 KB) + metadata (64 KB)

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
                                              (echo) (DHCP) (NetStack)
                                                            ↓
                                                      ┌─────┴─────┐
                                                    MQTT      script_push
                                                  (broker)    (port 9001)
```

## TCP/IP stack design

The stack in `src/net/tcpip.zig` is a comptime-parameterized `NetStack(Config)`:

- **App-driven retransmission**: stack stores no payload data. Applications
  implement `AppVTable` with `produce_tx()` to regenerate data on retransmit.
- **Stop-and-wait**: one unacked segment per connection, no sliding window.
- **Multi-connection**: fixed array of N connections (default 4) + listener table.
- **Work flags**: per-connection `ack_due`, `tx_ready`, `retx_due`, `close_due`.
- **Fixed receive window**: configurable at compile time (`rcv_wnd`, default 2048); no per-connection receive buffer — app consumes data via `on_recv` callback.
- **21 observability counters**: ip_rx, ip_bad_checksum, arp_hits/misses, tcp_retx, tcp_bad_checksum, tcp_rst_tx, etc.
- **RX checksum verification**: incoming TCP segments validated before processing.
- **RST generation**: unmatched segments receive RST per RFC 793.
- **Zero dynamic allocation**: all buffers are static, compile-time sized.

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
[cyw43] MAC=d8:3a:dd:2d:84:62
[cyw43] CLM loaded
[cyw43] LED blink OK
[cyw43] WiFi UP
[scan] 11 networks found:
  -44 dBm  c6:50:9c:9e:fc:69  Shreeve
  ...
[join] associated!
[dhcp] offer 10.0.0.39 from 10.0.0.1
[dhcp] bound 10.0.0.39 gw 10.0.0.1 mask 255.255.255.0
[wifi] IP=10.0.0.39
[boot] WiFi IP=10.0.0.39
```

## What is next

1. ~~Validate TCP handshake~~ — **DONE** (telnet shell on port 23)
2. ~~Test MQTT end-to-end~~ — **DONE** (plaintext + TLS, bidirectional pub/sub)
3. ~~Validate TLS on hardware~~ — **DONE** (BearSSL ECDHE_RSA_WITH_AES_128_GCM_SHA256)
4. **Hook MQTT into JS runtime** — `mqtt.on("message", fn)` callback
5. **Implement flash write driver** (RAM-resident, for KV storage.set() and OTA)
6. **Build OTA bootloader** (immutable, verifies SHA-256, copies staging to active)
7. **Production security**: signed updates, authenticated script upload, JS sandboxing

## TLS architecture

```
                    ┌─────────────────┐
                    │   MQTT client   │
                    │ (plaintext API) │
                    └────────┬────────┘
                             │ tls.send() / on_recv callback
                    ┌────────┴────────┐
                    │   TLS Session   │
                    │  (bearssl.zig)  │
                    │                 │
                    │ ┌─────────────┐ │
                    │ │ BearSSL SSL │ │
                    │ │   engine    │ │
                    │ └─────────────┘ │
                    │ ┌─────────────┐ │
                    │ │  ciphertext │ │
                    │ │  TX retain  │ │
                    │ └─────────────┘ │
                    └────────┬────────┘
                             │ AppVTable (produce_tx / on_recv)
                    ┌────────┴────────┐
                    │   TCP NetStack  │
                    └─────────────────┘
```

BearSSL buffers: 6KB RX + 2KB TX I/O, ~12KB total per session.
Cipher suite: ECDHE_RSA_WITH_AES_128_GCM_SHA256 (TLS 1.2 only).
Trust model: x509 known-key (pin broker's RSA public key).
Entropy: ROSC jitter + timer LSBs → SHA-256 → HMAC-DRBG.

## Scope boundary

This document is for:
- current networking milestone status
- what is proven on hardware
- what is next in the stack

Low-level CYW43 transport and bus details live in `docs/CYW43.md`.
The host-side CLI tool vision lives in `PICO.md`.
