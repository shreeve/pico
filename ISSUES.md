# Current Issues

## Resolved

1. **~~Provisioning mode after successful WiFi join~~** — Fixed.
   `main.zig` now calls `wifi.init()` which boots CYW43 and joins via
   build-time credentials. No spurious provisioning mode entry.

2. **~~wifi.connect() was a facade~~** — Fixed.
   `bindings/wifi.zig` `connect()` now calls `cyw43.device.joinWpa2()`
   and starts DHCP. The JS-facing API matches the hardware path.

3. **~~Naming confusion between firmware and host tool~~** — Accepted.
   `README.md` covers the firmware, `PICO.md` covers the host tool
   vision. Both use the working name "pico." This is fine for now.

4. **~~TCP stack: passive-open retransmit timer never armed~~** — Fixed.
   `onListenSyn()` now sets `retx_deadline = self.ticks + 25`. Previously
   defaulted to 0, causing SYN-ACK blast every tick on inbound accept.

5. **~~TCP stack: receive buffer leaked window to zero~~** — Fixed.
   Removed `rx_buf`/`rx_len` from Connection. Receive window is now a
   fixed comptime value (`cfg.rcv_wnd = 2048`). App receives data solely
   via `on_recv` callback.

6. **~~TCP stack: FIN-only retransmission missing~~** — Fixed.
   `retransmit()` now has a dedicated `else if (ptx.fin)` branch for
   FIN-only segments, and data+FIN retransmit preserves the FIN flag.

7. **~~TCP stack: ACKs accepted without validation~~** — Fixed.
   `processAck()` now validates ACK range via `ackAcceptable()` before
   advancing `snd_una`. Only advances when `seqGt(ack_num, snd_una)`.

8. **~~TCP stack: FIN accepted without sequence check~~** — Fixed.
   All states now validate segment sequence via `seqAcceptable()` before
   processing payload or FIN. Data/FIN require `seq == rcv_nxt`.

9. **~~TCP stack: FIN state transitions wrong~~** — Fixed.
   `fin_wait_1` now correctly enters `.closing` on peer FIN before our
   FIN is ACKed, and `.fin_wait_2` only when our FIN is ACKed.
   `.last_ack` only closes when `ack_num == snd_nxt`. `.closing` is now
   reachable and correctly transitions to `.time_wait`.

10. **~~TCP stack: no checksum verification on RX~~** — Fixed.
    Added `tcpChecksumValid()` using pseudo-header. Called in `tcpInput()`
    before any segment processing. New `tcp_bad_checksum` stat counter.

11. **~~TCP stack: no RST for unmatched segments~~** — Fixed.
    Added `sendResetForUnmatched()` per RFC 793. ACK segments get
    RST with SEQ=ACK; non-ACK get RST|ACK with ACK=SEQ+seglen.
    Incoming RST segments are never answered with RST.

12. **~~TCP stack: duplicate SYN in syn_rcvd ignored~~** — Fixed.
    `.syn_rcvd` now detects duplicate SYN (same sequence as original)
    and resends SYN-ACK. Prevents handshake stall when SYN-ACK is lost.

13. **~~TCP stack: stats double-counted~~** — Fixed.
    Removed spurious `tcp_tx += 1` from `processAck()`. Added
    `tcp_rst_tx` counter for outbound RST tracking.

## Open Issues

1. **TCP handshake not yet validated on hardware.** The TCP state machine
   in `net/tcpip.zig` has been hardened (sequence validation, ACK checks,
   proper FIN state transitions, checksum verification, RST generation)
   but no TCP connection has been established on real hardware yet.

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

7. **~~ARP-pending silently drops first TCP segment~~** — Fixed.
   `emitSegment()` now returns `EmitResult` (`.sent` or `.arp_pending`).
   Connections with `arp_pending = true` are retried each poll cycle via
   `retryArpPending()` in `tcpPollOutput()`.

8. **~~No TCP zero-window probes / persist timer~~** — Fixed.
   When `remote_window == 0` and data is pending, a persist timer arms
   (250ms initial, exponential backoff to 5s). On fire, a 1-byte window
   probe is sent via `produce_tx(.probe)`. Cleared when window reopens.

9. **~~No MSS option in SYN/SYN-ACK~~** — Fixed.
   `emitSegment()` appends a 4-byte MSS option (kind=2, len=4) on SYN
   segments, advertising `min(mtu - 40, 1460)`. TCP header is 24 bytes
   for SYN/SYN-ACK, 20 bytes otherwise.

10. **~~ISN generation is weak~~** — Fixed.
    `generateIsn()` now mixes local/remote IP, ports, time, boot-secret,
    and a per-call counter through a compact 32-bit finalizer (lowbias32).
    Not cryptographic, but far less predictable than a linear counter.

11. **~~No simultaneous open support~~** — Fixed.
    SYN without ACK in `.syn_sent` now transitions to `.syn_rcvd` and
    sends SYN-ACK per RFC 793 Section 3.4. The existing `.syn_rcvd` ACK
    handler completes the handshake.

12. **~~TIME-WAIT duration is 3 seconds~~** — Fixed.
    Now configurable via `Config.tcp_timewait_ms` (default 30 seconds).
    Timer is driven by elapsed wall-clock milliseconds, not loop iterations.
    Elapsed is clamped to 10s max to avoid instant draining after stalls.
