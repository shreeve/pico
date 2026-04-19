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

1. **~~TCP handshake not yet validated on hardware.~~** — Fixed.
   Telnet shell on port 23 proves full TCP lifecycle. MQTT uses TCP
   for both plaintext and TLS connections.

2. **~~MQTT not yet tested with a real broker.~~** — Fixed.
   Bidirectional pub/sub validated with Mosquitto on both plaintext
   (port 1883) and TLS (port 8883).

3. **Flash KV write not implemented.** `bindings/storage.zig` can read
   from flash via XIP but cannot write. Writing requires a RAM-resident
   flash driver that disables interrupts during erase/program cycles.

4. **Script push listener registered but not tested.** `net/script_push.zig`
   registers a TCP listener on port 9001, but no client has connected.

5. **OTA update mechanism not implemented.** Flash layout is OTA-ready
   (768 KB staging area) but no bootloader, image verification, or
   download path exists yet.

6. **~~No TLS.~~** — Fixed.
   BearSSL integrated and validated on hardware. TLS 1.2 with
   ECDHE_RSA_WITH_AES_128_GCM_SHA256, known-key trust (RSA key pinning).

7. **WPA3/mixed-mode AP incompatibility.** CYW43 WPA2-PSK 4-way handshake
   gets consistent DEAUTH type=6 from APs running WPA3 or WPA2/WPA3
   transition mode. Workaround: set router to WPA2-PSK only, or use a
   simple AP like iPhone hotspot. May need CYW43 SAE support to fix.

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

## Nanoruby integration (Phase A)

15. **`.nrb` serializer does not recurse into `child_funcs` or
    serialize `float_pool`.** In `src/ruby/nanoruby/vm/nrb.zig` (now
    at format v2 after commit M6 in UPSTREAM.md), `serialize` writes
    a single `IrFunc` with its `syms` + `string_literals` tables but
    NOT `child_funcs` or `float_pool`. Ruby blocks (`loop do … end`,
    `5.times { }`, `each { }`) compile to child functions and float
    literals populate `float_pool`; neither roundtrips through v2.
    Phase A scripts use `while true` and no floats. Phase B fix:
    extend serialize/deserialize to walk `child_funcs` recursively
    and serialize `float_pool`; bump format version to 3. Upstream
    feature request for nanoruby, not a pico-local fix.

16. **~~`Loader.deserialize(data, &func)` only initializes 5 fields.~~**
    Partially resolved by M6 (.nrb format v2 now populates `syms` and
    `string_literals` too). Still unset by deserialize: `child_funcs`,
    `float_pool`, `param_spec`, `name_sym`, `source_line`,
    `captured_mask`. Pico's `runBootScript` zero-initialises the 5
    no-default fields and relies on struct defaults (`&.{}` / `0`)
    for the rest. When issue #15 is fixed, the remaining fields will
    be populated from the wire format.

17. **Native-method error raising depends on `pending_native_error`
    being checked by the VM.** `bindings_adapter.zig` returns
    `vm.raise(VmError.ArgumentError)` on bad args. This sets
    `vm.pending_native_error` and returns `Value.undef`. The VM's
    `invokeNative` path (per the comment at `vm/vm.zig` line ~165)
    checks this field and promotes it into an `ExecResult.err`.
    Error propagation path exists by code inspection; not yet
    validated by an end-to-end script/hardware repro. To exercise:
    write a test script that calls `led_blink(-1)` or
    `sleep_ms("abc")` and confirm the firmware prints a matching
    `[nanoruby] boot script error: ArgumentError/TypeError/...` line
    instead of crashing silently.

18. **Ruby-mode service progress depends on cooperative yields.**
    During Ruby VM execution, the only firmware progress guarantees
    come from `sleep_ms` (or any future explicit yield primitive)
    calling `superloopTickOnce()`, plus IRQ-driven subsystems that do
    not enter the VM. A tight Ruby loop without `sleep_ms` starves:
    - `reboot` UART shell (unresponsive)
    - `watchdog.feed()` (MCU resets after 8 s — once the watchdog is
      actually armed, which it is not yet in the Ruby path — see the
      TODO below)
    - `led.poll()` (blink-state machine stops advancing)
    - Phase B WiFi/MQTT/netif pumps (will stall once added)

    This is a core runtime contract, not just "deferred feature work."
    Documented in `src/ruby/runtime.zig`'s header block; should also
    be surfaced to script authors in a user-facing doc in Phase B.

    ~~TODO: the Ruby path does not yet call `watchdog.init(8000)`.~~
    Resolved: `main_ruby.zig` now arms `watchdog.init(8000)` plus
    `watchdog.clearCrashCount()` between `rp2040.initPeriodicTick()`
    and `rb_runtime.runBootScript()`, mirroring the JS path. The 8 s
    timeout applies to Ruby scripts that fail to yield cooperatively
    — the designed enforcement mechanism for this contract.

20. **~~Sustained allocation eventually dies with TypeError (~84 iters
    on blinky_3.rb).~~** Fixed in M7 (see UPSTREAM.md). The up-front
    high-water-mark check in `vm/vm.zig::allocHeapObj` defeated the
    GC tombstone-reclamation mechanism: once `obj_registry_count`
    ever reached `MAX_OBJ_REGISTRY = 256`, every subsequent
    allocation failed without invoking GC. The bug manifested in
    blinky_3.rb (`puts "blink " + count.to_s`) because each iteration
    allocates two heap Strings; ~84 iterations saturated the HWM and
    `Integer#to_s`'s `orelse Value.nil` path then propagated nil into
    `String#+` → TypeError.

    Fix: factor the allocation into a `tryAllocHeapObj` helper that
    funnels through `registerObj` (which already walks for tombstones),
    and call it twice in `allocHeapObj`: once directly, once after
    `gc()`. Now both failure modes (heap-bytes-full OR registry-full)
    trigger a GC retry via the same code path. Hardware verification
    required to close this out fully.

19. **`reboot` UART shell is duplicated between JS and Ruby paths.**
    The JS build's `src/main.zig::pollUart` handles `reboot` and
    `wifi` commands from the main superloop. The Ruby build's
    `src/ruby/runtime.zig::pollUart` (called from
    `superloopTickOnce`) handles only `reboot`. Duplication is a
    maintainability wart created by the byte-identity gate on
    `main.zig`: any change to the JS-side shell will need to be
    mirrored (or diverge) in the Ruby side. Low-priority cleanup —
    likely addressed when the byte-identity gate is eventually
    relaxed, or when a shared `src/bindings/uart_shell.zig` helper is
    extracted such that both entry points call it.

## Toolchain / upstream (Zig 0.16.0)

13. **Aro translate-c miscompiles BearSSL inline helpers under 0.16.**
    `@cImport({ @cInclude("bearssl.h"); })` produces Zig code that 0.16
    refuses to compile for `br_multihash_setimpl` / `br_multihash_getimpl`
    (see https://github.com/ziglang/translate-c/issues/66 for the class).
    Workaround: `src/tls/bearssl_c.zig` holds pre-translated bindings with
    the two helpers hand-rewritten. `@cImport` is no longer on the compile
    path. See that file's header for regeneration procedure.

14. **Zig 0.16 rejects `ctx.*.array_field[idx]` through a `[*c]` pointer.**
    Indexing an array field reached via `[*c]` auto-deref types the whole
    expression as the array rather than the element, producing
    `expected type '[N]T', found 'T'` on assignment. Reproducible with a
    trivial extern-struct repro; looks like a 0.16 type-resolution regression.
    Workaround in `src/tls/bearssl_c.zig`: bind the field to a properly-typed
    pointer first (`const p: *[N]T = &ctx.*.field; p[idx] = x;`). Filing
    upstream as a follow-up.
