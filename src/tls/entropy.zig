// Boot-time entropy collection for TLS on RP2040.
//
// RP2040 has no hardware RNG, but the Ring Oscillator (ROSC) provides
// jittery bits at its RANDOMBIT register. We oversample heavily and
// condition through SHA-256 to produce a seed for BearSSL's HMAC-DRBG.
//
// Security model:
//   - ROSC bit samples are biased but contain real physical entropy
//   - Timer LSBs add timing jitter from XOSC/ROSC frequency mismatch
//   - SHA-256 conditioning removes bias and compresses to 256-bit seed
//   - HMAC-DRBG expands the seed for TLS usage
//
// This is the standard approach for RP2040 TLS implementations.

const hal = @import("../platform/hal.zig");
const ssl = @import("bearssl.zig");

const ROSC_BASE: u32 = 0x4006_0000;
const ROSC_RANDOMBIT: u32 = ROSC_BASE + 0x1C;
const TIMER_TIMELR: u32 = 0x4005_4000 + 0x0C;

/// Read one random bit from the ROSC RANDOMBIT register.
fn roscBit() u1 {
    return @truncate(hal.regRead(ROSC_RANDOMBIT));
}

/// Read a byte by sampling 8 ROSC bits (each involves independent jitter).
fn roscByte() u8 {
    var b: u8 = 0;
    for (0..8) |_| {
        b = (b << 1) | @as(u8, roscBit());
    }
    return b;
}

/// Read the low 32 bits of the hardware microsecond timer.
fn timerLow() u32 {
    return hal.regRead(TIMER_TIMELR);
}

/// Collect entropy and seed a BearSSL HMAC-DRBG context.
/// Should be called once at boot, after clocks are running.
pub fn seedDrbg(drbg: *ssl.HmacDrbgContext) void {
    var sha_ctx: ssl.Sha256Context = undefined;
    ssl.sha256Init(&sha_ctx);

    // Phase 1: ~512 ROSC bytes (4096 bit samples)
    for (0..512) |_| {
        const b = [1]u8{roscByte()};
        ssl.sha256Update(&sha_ctx, &b);
    }

    // Phase 2: timer jitter — 64 samples of timer LSBs interleaved
    // with ROSC reads. The XOSC↔ROSC frequency mismatch creates
    // additional entropy in the timer LSBs.
    for (0..64) |_| {
        const t = timerLow();
        const tb = [4]u8{
            @truncate(t),
            @truncate(t >> 8),
            @truncate(t >> 16),
            @truncate(t >> 24),
        };
        ssl.sha256Update(&sha_ctx, &tb);
        const r = [1]u8{roscByte()};
        ssl.sha256Update(&sha_ctx, &r);
    }

    // Finalize: 32-byte seed
    var seed: [32]u8 = undefined;
    ssl.sha256Out(&sha_ctx, &seed);

    // Seed HMAC-DRBG
    ssl.hmacDrbgInit(drbg, &seed);

    // Wipe seed from stack
    @memset(&seed, 0);
}

/// Re-seed an existing DRBG with fresh ROSC entropy.
/// Call periodically (e.g. every few minutes) for long-running sessions.
pub fn reseedDrbg(drbg: *ssl.HmacDrbgContext) void {
    var sha_ctx: ssl.Sha256Context = undefined;
    ssl.sha256Init(&sha_ctx);

    for (0..128) |_| {
        const b = [1]u8{roscByte()};
        ssl.sha256Update(&sha_ctx, &b);
    }

    var fresh: [32]u8 = undefined;
    ssl.sha256Out(&sha_ctx, &fresh);
    ssl.hmacDrbgUpdate(drbg, &fresh);
    @memset(&fresh, 0);
}
