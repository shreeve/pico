# Architecture — How pico Works

This document walks through the entire stack, from radio waves to
JavaScript execution, using an encrypted MQTT connection as the
narrative thread. Every layer described here is custom — no lwIP,
no RTOS, no vendor SDK.

## The Full Path

When you type `mqtts 172.20.10.5` in the telnet shell, here is
everything that happens on a $6 Raspberry Pi Pico W running at
125 MHz with 264 KB of RAM:

### 1. Shell parses the command

The telnet shell (`net/shell.zig`) runs over TCP port 23 with
readline-lite support — cursor movement, command history, Ctrl keys.
It negotiates character-at-a-time mode with the telnet client on
connect (IAC WILL ECHO, SUPPRESS-GO-AHEAD).

`mqtts 172.20.10.5` is parsed, the IP is extracted, and the shell
calls `mqtt.connectBrokerTls()` with the broker IP, port 8883,
client ID "pico", server name, and a pinned RSA public key.

### 2. TLS session initializes

`src/tls/tls.zig` sets up BearSSL for TLS 1.2:

- **Entropy**: 4096 ROSC jitter bits + 64 timer samples, conditioned
  through SHA-256, seed an HMAC-DRBG (`tls/entropy.zig`). The RP2040
  has no hardware RNG — this is the standard approach.
- **Trust**: The broker's RSA public key is pinned via BearSSL's
  `x509_knownkey` — no CA chain, no certificate parsing. The server's
  key either matches or the handshake fails.
- **Cipher**: `ECDHE_RSA_WITH_AES_128_GCM_SHA256` — forward secrecy
  via ephemeral Elliptic Curve Diffie-Hellman, RSA signatures, AES-128
  in Galois/Counter Mode. All in software on a Cortex-M0+.

### 3. TCP handshake (SYN → SYN-ACK → ACK)

The custom TCP/IP stack (`net/tcpip.zig`) opens a connection:

```
Pico → SYN (seq=ISN, MSS=1460) → Broker
Pico ← SYN-ACK ← Broker
Pico → ACK → Broker
```

ISN generation uses a 4-tuple + boot-secret + monotonic counter +
lowbias32 mixer. The stack is uIP-inspired: stop-and-wait, one
unacked segment per connection, app-driven retransmission via
`AppVTable.produce_tx()` callbacks.

The TCP segment travels through:
- `net/ipv4.zig` — IPv4 header, checksum, routing
- `net/arp.zig` — resolve gateway MAC (8-entry cache, 5-min TTL)
- `cyw43/netif/` — Ethernet frame with BDC header
- `cyw43/transport/` — SDPCM/gSPI at 31 MHz via PIO state machine
- **CYW43439** — 802.11 radio, WPA2-PSK encryption, over the air

### 4. TLS handshake

Once TCP is connected, BearSSL's SSL engine drives the handshake
through the TLS session adapter:

```
Pico → ClientHello (cipher suites, client random)
Pico ← ServerHello + Certificate + ServerKeyExchange + ServerHelloDone
Pico:   verify server key matches pinned RSA key
Pico → ClientKeyExchange (ECDHE public point) + ChangeCipherSpec + Finished
Pico ← ChangeCipherSpec + Finished
```

**Everything after this point is encrypted with AES-128-GCM.**

The TLS adapter (`tls/tls.zig`) bridges BearSSL's engine model to
the TCP stack's AppVTable pattern. The key design constraint: TLS
records are stateful — sequence numbers advance, so ciphertext
cannot be regenerated for TCP retransmission. A ciphertext retention
ring buffer holds encrypted bytes until TCP ACKs them.

### 5. MQTT CONNECT

Inside the encrypted TLS channel, the MQTT 3.1.1 client sends:

```
CONNECT (client_id="pico", keepalive=60s, clean_session=1)
```

The broker responds with CONNACK (return code 0 = accepted).

### 6. Auto-subscribe

On CONNACK, the client subscribes to `pico/#` — a wildcard that
catches all topics under the `pico/` namespace:

| Topic | Handler |
|-------|---------|
| `pico/js` | Execute payload as JavaScript via MQuickJS |
| `pico/led` | Direct LED control: on, off, toggle, blink |
| `pico/*` | Dispatch to `mqtt.on("message", fn)` JS callback |

### 7. Superloop keeps it alive

The cooperative main loop runs continuously:

```zig
while (true) {
    runtime.poll();    // JS timers, deferred callbacks
    pollUart();        // UART commands (reboot, wifi)
    wifi.poll();       // CYW43 service loop
    mqtt.poll();       // MQTT keepalive (PINGREQ every 60s)
    led.poll();        // Managed LED blink timer
    netif.poll(now);   // TCP retransmit, TIME-WAIT, output processing
    watchdog.feed();   // 8-second watchdog
    asm("wfe");        // Wait for event (low power until next interrupt)
}
```

No threads, no RTOS, no preemption. Each subsystem does bounded
work per iteration. The 10ms periodic timer interrupt wakes the
core from `wfe`.

## What Happens When You Publish to `pico/js`

From your Mac:
```bash
mosquitto_pub -t "pico/js" -m 'console.log("hello from the cloud")'
```

The journey:

1. **Mac** → Mosquitto broker (localhost TLS on port 8883)
2. **Broker** → TCP segment to Pico's IP over WiFi
3. **CYW43** radio receives the 802.11 frame
4. **PIO SPI** at 31 MHz transfers it to RP2040 SRAM
5. **gSPI/SDPCM** unpacks the Ethernet frame
6. **IPv4** validates checksum, routes to TCP
7. **TCP** validates sequence/checksum, delivers payload to TLS
8. **BearSSL** decrypts AES-128-GCM, verifies GHASH tag
9. **TLS adapter** feeds decrypted record to MQTT client
10. **MQTT** parses PUBLISH, extracts topic `pico/js` and payload
11. **Topic dispatch** recognizes `pico/js` → calls `engine.eval()`
12. **MQuickJS** executes `console.log("hello from the cloud")`
13. **console.log** writes to UART via `putc`
14. **picocom** displays: `hello from the cloud`

All of this on 125 MHz, 264 KB RAM, no OS, in about 2 milliseconds
for the application-layer processing (TLS decrypt + MQTT parse + JS
eval). The network latency dominates.

## Layer Diagram

```
┌──────────────────────────────────────────┐
│           User Scripts (JS)              │
│  console.log · mqtt.on · led.blink       │
├──────────────────────────────────────────┤
│         MQuickJS Runtime (C)             │
│  18K lines · 80 KB flash · 64 KB heap   │
├──────────────────────────────────────────┤
│       pico Runtime (Zig)                 │
│  superloop · timers · scheduler          │
├──────────────────────────────────────────┤
│         Bindings (Zig → JS)              │
│  led · mqtt · wifi · gpio · timers       │
│  console · storage · usb · uart          │
├──────────────────────────────────────────┤
│    TLS 1.2 (BearSSL, ~68 KB flash)      │
│  ECDHE_RSA · AES-128-GCM · SHA-256      │
│  ROSC entropy · HMAC-DRBG · key pinning │
├──────────────────────────────────────────┤
│       Net Stack (Zig, ~7 KB RAM)         │
│  TCP · IPv4 · ICMP · ARP · DHCP · MQTT  │
├──────────────────────────────────────────┤
│     CYW43439 WiFi Driver (Zig)           │
│  PIO SPI · gSPI · SDPCM · WPA2-PSK      │
├──────────────────────────────────────────┤
│         RP2040 HAL (Zig)                 │
│  clocks · UART · GPIO · timer · ROM      │
├──────────────────────────────────────────┤
│             Hardware                     │
│  Cortex-M0+ @ 125 MHz · 264 KB SRAM     │
│  2 MB Flash · CYW43439 radio             │
└──────────────────────────────────────────┘
```

## Memory Budget (RP2040)

| Component | Flash | SRAM |
|-----------|-------|------|
| Firmware total | ~466 KB | — |
| CYW43 WiFi firmware blob | ~231 KB | — |
| MQuickJS engine | ~80 KB | 64-96 KB heap |
| BearSSL (when TLS active) | ~68 KB | ~12 KB/session |
| TCP/IP stack | ~15 KB | ~7 KB |
| Application code + bindings | ~72 KB | ~4 KB |
| Runtime stack | — | 8 KB |
| **Available in 768 KB partition** | **~302 KB free** | **~140 KB free** |

## Key Design Decisions

**No RTOS.** A cooperative superloop is simpler, deterministic, and
uses less RAM than any RTOS. Every subsystem is polled in a fixed
order. No mutexes, no priority inversion, no stack-per-thread overhead.

**No lwIP.** The custom TCP/IP stack is ~15 KB of flash and ~7 KB of
RAM. lwIP would be 50-100 KB flash and 30+ KB RAM for the same
functionality. The custom stack also integrates cleanly with the
app-driven retransmission model.

**App-driven retransmission.** The TCP stack stores no payload. When
a segment needs retransmitting, it calls the app's `produce_tx()`
callback to regenerate the data. This eliminates per-connection
send buffers. For TLS, where records can't be regenerated, the TLS
adapter maintains its own ciphertext retention buffer.

**BearSSL over alternatives.** BearSSL is designed for embedded: no
dynamic allocation, constant-time crypto, ~68 KB flash. It compiles
to empty translation units on non-matching platforms (x86 code
vanishes on ARM). mbedTLS would be 150+ KB flash.

**Known-key trust over PKI.** For a fixed LAN broker, pinning the
server's RSA public key is simpler, smaller, and more secure than
CA chain validation. No certificate parsing, no expiry checks, no
revocation lists. The tradeoff: key rotation requires firmware update.

**MQuickJS over alternatives.** Fabrice Bellard's micro engine runs
full ES2023 in 80 KB flash and 64 KB heap. JerryScript is larger.
Espruino is tied to its own hardware. KalumaJS is closest in spirit
but less mature. MQuickJS gives real JavaScript on real constraints.

## What's Proven on Hardware

All of the following have been validated on a real Pico W:

- WiFi scan, join, DHCP, ARP, ICMP ping
- TCP handshake, bidirectional data, MSS negotiation, clean teardown
- Telnet shell with readline (cursor, history, Ctrl keys)
- MQTT plaintext (port 1883) — publish, subscribe, receive
- MQTT over TLS 1.2 (port 8883) — encrypted bidirectional pub/sub
- Remote JavaScript execution over encrypted MQTT (`pico/js`)
- LED control over MQTT (`pico/led`) with managed blink timer
- JavaScript eval over telnet (`eval 2+2` returns `4`)
- USB Host with FTDI driver + ASTM medical protocol parser
