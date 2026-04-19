// Pre-translated BearSSL C bindings for Zig 0.16.0.
//
// PROVENANCE
// ----------
// This file was produced by `@cImport({ @cInclude("bearssl.h"); })` running
// under Zig 0.16.0 with the firmware build's `-nostdinc`, `-ffreestanding`,
// and `-DBR_*=0` flags (see build.zig `bearssl_flags`). The file lives under
// source control rather than being regenerated on every build so that:
//   1. We are not exposed to Aro translate-c regressions from build to build.
//   2. The two hand-patched inline helpers below (see MANUAL EDITS) stay
//      correct; a regeneration would silently reintroduce the Aro bug.
//
// MANUAL EDITS
// ------------
// Only `br_multihash_setimpl` and `br_multihash_getimpl` were hand-rewritten.
// Their C source (ext/bearssl/inc/bearssl_hash.h) is trivially:
//     ctx->impl[id - 1] = impl;
// and
//     return ctx->impl[id - 1];
// but two independent 0.16 issues meant the straight Aro translation did not
// compile:
//   (a) Aro's `@bitCast(@as(isize, @intCast(id - 1)))` 1-arg bitcast relies on
//       result-location type inference that 0.16's reworked type resolution no
//       longer performs in array-subscript contexts. See
//       https://github.com/ziglang/translate-c/issues/66 for the bug class.
//   (b) Even with a clean hand rewrite `const idx: usize = @intCast(id - 1);
//       ctx.*.impl[idx] = impl;`, 0.16 refuses with
//       `expected type '[6]T', found 'T'` — i.e. it types the field-array
//       subscript expression as the whole array rather than an element. This
//       looks like a compiler regression, reproducible only when indexing
//       an array field reached through a `[*c]` pointer auto-deref.
// The workaround that compiles: bind the field to a properly-typed pointer
// first, then index through it:
//     const impls: *[6][*c]const br_hash_class = &ctx.*.impl;
//     impls[idx] = hash_impl;
//
// REGENERATION
// ------------
// If you need to regenerate this file (e.g. BearSSL headers changed):
//   1. Temporarily switch `src/tls/bearssl.zig` back to `@cImport`.
//   2. `zig build` — the generated `cimport.zig` lands under `.zig-cache/`.
//   3. Copy it to `src/tls/bearssl_c.zig` and reapply:
//      - this header comment
//      - the hand-rewritten `br_multihash_setimpl` / `br_multihash_getimpl`
//   4. Restore bearssl.zig to `@import("bearssl_c.zig")`.
//   5. Rebuild.

const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const ptrdiff_t = c_int;
pub extern fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
pub extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
pub extern fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque;
pub extern fn memcmp(s1: ?*const anyopaque, s2: ?*const anyopaque, n: usize) c_int;
pub extern fn strlen(s: [*c]const u8) usize;
pub extern fn strcmp(s1: [*c]const u8, s2: [*c]const u8) c_int;
pub extern fn strncmp(s1: [*c]const u8, s2: [*c]const u8, n: usize) c_int;
pub extern fn strcpy(dest: [*c]u8, src: [*c]const u8) [*c]u8;
pub extern fn strncpy(dest: [*c]u8, src: [*c]const u8, n: usize) [*c]u8;
pub extern fn strcat(dest: [*c]u8, src: [*c]const u8) [*c]u8;
pub extern fn strchr(s: [*c]const u8, c: c_int) [*c]u8;
pub extern fn strrchr(s: [*c]const u8, c: c_int) [*c]u8;
pub extern fn strstr(haystack: [*c]const u8, needle: [*c]const u8) [*c]u8;
pub const br_hash_class = struct_br_hash_class_;
pub const struct_br_hash_class_ = extern struct {
    context_size: usize = 0,
    desc: u32 = 0,
    init: ?*const fn (ctx: [*c][*c]const br_hash_class) callconv(.c) void = null,
    update: ?*const fn (ctx: [*c][*c]const br_hash_class, data: ?*const anyopaque, len: usize) callconv(.c) void = null,
    out: ?*const fn (ctx: [*c]const [*c]const br_hash_class, dst: ?*anyopaque) callconv(.c) void = null,
    state: ?*const fn (ctx: [*c]const [*c]const br_hash_class, dst: ?*anyopaque) callconv(.c) u64 = null,
    set_state: ?*const fn (ctx: [*c][*c]const br_hash_class, stb: ?*const anyopaque, count: u64) callconv(.c) void = null,
    pub const br_rsa_i15_oaep_decrypt = __root.br_rsa_i15_oaep_decrypt;
    pub const br_rsa_i31_oaep_decrypt = __root.br_rsa_i31_oaep_decrypt;
    pub const br_rsa_i32_oaep_decrypt = __root.br_rsa_i32_oaep_decrypt;
    pub const br_rsa_i62_oaep_decrypt = __root.br_rsa_i62_oaep_decrypt;
    pub const decrypt = __root.br_rsa_i15_oaep_decrypt;
};
pub extern const br_md5_vtable: br_hash_class;
pub const br_md5_context = extern struct {
    vtable: [*c]const br_hash_class = null,
    buf: [64]u8 = @import("std").mem.zeroes([64]u8),
    count: u64 = 0,
    val: [4]u32 = @import("std").mem.zeroes([4]u32),
    pub const br_md5_init = __root.br_md5_init;
    pub const br_md5_update = __root.br_md5_update;
    pub const br_md5_out = __root.br_md5_out;
    pub const br_md5_state = __root.br_md5_state;
    pub const br_md5_set_state = __root.br_md5_set_state;
    pub const init = __root.br_md5_init;
    pub const update = __root.br_md5_update;
    pub const out = __root.br_md5_out;
    pub const state = __root.br_md5_state;
};
pub extern fn br_md5_init(ctx: [*c]br_md5_context) void;
pub extern fn br_md5_update(ctx: [*c]br_md5_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_md5_out(ctx: [*c]const br_md5_context, out: ?*anyopaque) void;
pub extern fn br_md5_state(ctx: [*c]const br_md5_context, out: ?*anyopaque) u64;
pub extern fn br_md5_set_state(ctx: [*c]br_md5_context, stb: ?*const anyopaque, count: u64) void;
pub extern const br_sha1_vtable: br_hash_class;
pub const br_sha1_context = extern struct {
    vtable: [*c]const br_hash_class = null,
    buf: [64]u8 = @import("std").mem.zeroes([64]u8),
    count: u64 = 0,
    val: [5]u32 = @import("std").mem.zeroes([5]u32),
    pub const br_sha1_init = __root.br_sha1_init;
    pub const br_sha1_update = __root.br_sha1_update;
    pub const br_sha1_out = __root.br_sha1_out;
    pub const br_sha1_state = __root.br_sha1_state;
    pub const br_sha1_set_state = __root.br_sha1_set_state;
    pub const init = __root.br_sha1_init;
    pub const update = __root.br_sha1_update;
    pub const out = __root.br_sha1_out;
    pub const state = __root.br_sha1_state;
};
pub extern fn br_sha1_init(ctx: [*c]br_sha1_context) void;
pub extern fn br_sha1_update(ctx: [*c]br_sha1_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_sha1_out(ctx: [*c]const br_sha1_context, out: ?*anyopaque) void;
pub extern fn br_sha1_state(ctx: [*c]const br_sha1_context, out: ?*anyopaque) u64;
pub extern fn br_sha1_set_state(ctx: [*c]br_sha1_context, stb: ?*const anyopaque, count: u64) void;
pub extern const br_sha224_vtable: br_hash_class;
pub const br_sha224_context = extern struct {
    vtable: [*c]const br_hash_class = null,
    buf: [64]u8 = @import("std").mem.zeroes([64]u8),
    count: u64 = 0,
    val: [8]u32 = @import("std").mem.zeroes([8]u32),
    pub const br_sha224_init = __root.br_sha224_init;
    pub const br_sha224_update = __root.br_sha224_update;
    pub const br_sha224_out = __root.br_sha224_out;
    pub const br_sha224_state = __root.br_sha224_state;
    pub const br_sha224_set_state = __root.br_sha224_set_state;
    pub const br_sha256_init = __root.br_sha256_init;
    pub const br_sha256_out = __root.br_sha256_out;
    pub const init = __root.br_sha224_init;
    pub const update = __root.br_sha224_update;
    pub const out = __root.br_sha224_out;
    pub const state = __root.br_sha224_state;
};
pub extern fn br_sha224_init(ctx: [*c]br_sha224_context) void;
pub extern fn br_sha224_update(ctx: [*c]br_sha224_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_sha224_out(ctx: [*c]const br_sha224_context, out: ?*anyopaque) void;
pub extern fn br_sha224_state(ctx: [*c]const br_sha224_context, out: ?*anyopaque) u64;
pub extern fn br_sha224_set_state(ctx: [*c]br_sha224_context, stb: ?*const anyopaque, count: u64) void;
pub extern const br_sha256_vtable: br_hash_class;
pub const br_sha256_context = br_sha224_context;
pub extern fn br_sha256_init(ctx: [*c]br_sha256_context) void;
pub extern fn br_sha256_out(ctx: [*c]const br_sha256_context, out: ?*anyopaque) void;
pub extern const br_sha384_vtable: br_hash_class;
pub const br_sha384_context = extern struct {
    vtable: [*c]const br_hash_class = null,
    buf: [128]u8 = @import("std").mem.zeroes([128]u8),
    count: u64 = 0,
    val: [8]u64 = @import("std").mem.zeroes([8]u64),
    pub const br_sha384_init = __root.br_sha384_init;
    pub const br_sha384_update = __root.br_sha384_update;
    pub const br_sha384_out = __root.br_sha384_out;
    pub const br_sha384_state = __root.br_sha384_state;
    pub const br_sha384_set_state = __root.br_sha384_set_state;
    pub const br_sha512_init = __root.br_sha512_init;
    pub const br_sha512_out = __root.br_sha512_out;
    pub const init = __root.br_sha384_init;
    pub const update = __root.br_sha384_update;
    pub const out = __root.br_sha384_out;
    pub const state = __root.br_sha384_state;
};
pub extern fn br_sha384_init(ctx: [*c]br_sha384_context) void;
pub extern fn br_sha384_update(ctx: [*c]br_sha384_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_sha384_out(ctx: [*c]const br_sha384_context, out: ?*anyopaque) void;
pub extern fn br_sha384_state(ctx: [*c]const br_sha384_context, out: ?*anyopaque) u64;
pub extern fn br_sha384_set_state(ctx: [*c]br_sha384_context, stb: ?*const anyopaque, count: u64) void;
pub extern const br_sha512_vtable: br_hash_class;
pub const br_sha512_context = br_sha384_context;
pub extern fn br_sha512_init(ctx: [*c]br_sha512_context) void;
pub extern fn br_sha512_out(ctx: [*c]const br_sha512_context, out: ?*anyopaque) void;
pub extern const br_md5sha1_vtable: br_hash_class;
pub const br_md5sha1_context = extern struct {
    vtable: [*c]const br_hash_class = null,
    buf: [64]u8 = @import("std").mem.zeroes([64]u8),
    count: u64 = 0,
    val_md5: [4]u32 = @import("std").mem.zeroes([4]u32),
    val_sha1: [5]u32 = @import("std").mem.zeroes([5]u32),
    pub const br_md5sha1_init = __root.br_md5sha1_init;
    pub const br_md5sha1_update = __root.br_md5sha1_update;
    pub const br_md5sha1_out = __root.br_md5sha1_out;
    pub const br_md5sha1_state = __root.br_md5sha1_state;
    pub const br_md5sha1_set_state = __root.br_md5sha1_set_state;
    pub const init = __root.br_md5sha1_init;
    pub const update = __root.br_md5sha1_update;
    pub const out = __root.br_md5sha1_out;
    pub const state = __root.br_md5sha1_state;
};
pub extern fn br_md5sha1_init(ctx: [*c]br_md5sha1_context) void;
pub extern fn br_md5sha1_update(ctx: [*c]br_md5sha1_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_md5sha1_out(ctx: [*c]const br_md5sha1_context, out: ?*anyopaque) void;
pub extern fn br_md5sha1_state(ctx: [*c]const br_md5sha1_context, out: ?*anyopaque) u64;
pub extern fn br_md5sha1_set_state(ctx: [*c]br_md5sha1_context, stb: ?*const anyopaque, count: u64) void;
pub const br_hash_compat_context = extern union {
    vtable: [*c]const br_hash_class,
    md5: br_md5_context,
    sha1: br_sha1_context,
    sha224: br_sha224_context,
    sha256: br_sha256_context,
    sha384: br_sha384_context,
    sha512: br_sha512_context,
    md5sha1: br_md5sha1_context,
};
pub const br_multihash_context = extern struct {
    buf: [128]u8 = @import("std").mem.zeroes([128]u8),
    count: u64 = 0,
    val_32: [25]u32 = @import("std").mem.zeroes([25]u32),
    val_64: [16]u64 = @import("std").mem.zeroes([16]u64),
    impl: [6][*c]const br_hash_class = @import("std").mem.zeroes([6][*c]const br_hash_class),
    pub const br_multihash_zero = __root.br_multihash_zero;
    pub const br_multihash_setimpl = __root.br_multihash_setimpl;
    pub const br_multihash_getimpl = __root.br_multihash_getimpl;
    pub const br_multihash_init = __root.br_multihash_init;
    pub const br_multihash_update = __root.br_multihash_update;
    pub const br_multihash_out = __root.br_multihash_out;
    pub const zero = __root.br_multihash_zero;
    pub const setimpl = __root.br_multihash_setimpl;
    pub const getimpl = __root.br_multihash_getimpl;
    pub const init = __root.br_multihash_init;
    pub const update = __root.br_multihash_update;
    pub const out = __root.br_multihash_out;
};
pub extern fn br_multihash_zero(ctx: [*c]br_multihash_context) void;
// ── HAND-PATCHED (see top-of-file "MANUAL EDITS") ──
// Do not regenerate these two functions from Aro; the Aro output and the
// obvious hand rewrite both fail to compile under 0.16. See header for detail.
pub fn br_multihash_setimpl(ctx: [*c]br_multihash_context, id: c_int, hash_impl: [*c]const br_hash_class) callconv(.c) void {
    const idx: usize = @intCast(id - 1);
    const impls: *[6][*c]const br_hash_class = &ctx.*.impl;
    impls[idx] = hash_impl;
}
pub fn br_multihash_getimpl(ctx: [*c]const br_multihash_context, id: c_int) callconv(.c) [*c]const br_hash_class {
    const idx: usize = @intCast(id - 1);
    const impls: *const [6][*c]const br_hash_class = &ctx.*.impl;
    return impls[idx];
}
// ── /HAND-PATCHED ──
pub extern fn br_multihash_init(ctx: [*c]br_multihash_context) void;
pub extern fn br_multihash_update(ctx: [*c]br_multihash_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_multihash_out(ctx: [*c]const br_multihash_context, id: c_int, dst: ?*anyopaque) usize;
pub const br_ghash = ?*const fn (y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) callconv(.c) void;
pub extern fn br_ghash_ctmul(y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ghash_ctmul32(y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ghash_ctmul64(y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ghash_pclmul(y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ghash_pclmul_get() br_ghash;
pub extern fn br_ghash_pwr8(y: ?*anyopaque, h: ?*const anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ghash_pwr8_get() br_ghash;
pub const br_hmac_key_context = extern struct {
    dig_vtable: [*c]const br_hash_class = null,
    ksi: [64]u8 = @import("std").mem.zeroes([64]u8),
    kso: [64]u8 = @import("std").mem.zeroes([64]u8),
    pub const br_hmac_key_init = __root.br_hmac_key_init;
    pub const br_hmac_key_get_digest = __root.br_hmac_key_get_digest;
    pub const init = __root.br_hmac_key_init;
    pub const digest = __root.br_hmac_key_get_digest;
};
pub extern fn br_hmac_key_init(kc: [*c]br_hmac_key_context, digest_vtable: [*c]const br_hash_class, key: ?*const anyopaque, key_len: usize) void;
pub fn br_hmac_key_get_digest(arg_kc: [*c]const br_hmac_key_context) callconv(.c) [*c]const br_hash_class {
    var kc = arg_kc;
    _ = &kc;
    return kc.*.dig_vtable;
}
pub const br_hmac_context = extern struct {
    dig: br_hash_compat_context = @import("std").mem.zeroes(br_hash_compat_context),
    kso: [64]u8 = @import("std").mem.zeroes([64]u8),
    out_len: usize = 0,
    pub const br_hmac_init = __root.br_hmac_init;
    pub const br_hmac_size = __root.br_hmac_size;
    pub const br_hmac_get_digest = __root.br_hmac_get_digest;
    pub const br_hmac_update = __root.br_hmac_update;
    pub const br_hmac_out = __root.br_hmac_out;
    pub const br_hmac_outCT = __root.br_hmac_outCT;
    pub const init = __root.br_hmac_init;
    pub const size = __root.br_hmac_size;
    pub const digest = __root.br_hmac_get_digest;
    pub const update = __root.br_hmac_update;
    pub const out = __root.br_hmac_out;
    pub const outCT = __root.br_hmac_outCT;
};
pub extern fn br_hmac_init(ctx: [*c]br_hmac_context, kc: [*c]const br_hmac_key_context, out_len: usize) void;
pub fn br_hmac_size(arg_ctx: [*c]br_hmac_context) callconv(.c) usize {
    var ctx = arg_ctx;
    _ = &ctx;
    return ctx.*.out_len;
}
pub fn br_hmac_get_digest(arg_hc: [*c]const br_hmac_context) callconv(.c) [*c]const br_hash_class {
    var hc = arg_hc;
    _ = &hc;
    return hc.*.dig.vtable;
}
pub extern fn br_hmac_update(ctx: [*c]br_hmac_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_hmac_out(ctx: [*c]const br_hmac_context, out: ?*anyopaque) usize;
pub extern fn br_hmac_outCT(ctx: [*c]const br_hmac_context, data: ?*const anyopaque, len: usize, min_len: usize, max_len: usize, out: ?*anyopaque) usize;
const union_unnamed_1 = extern union {
    hmac_ctx: br_hmac_context,
    prk_ctx: br_hmac_key_context,
};
pub const br_hkdf_context = extern struct {
    u: union_unnamed_1 = @import("std").mem.zeroes(union_unnamed_1),
    buf: [64]u8 = @import("std").mem.zeroes([64]u8),
    ptr: usize = 0,
    dig_len: usize = 0,
    chunk_num: c_uint = 0,
    pub const br_hkdf_init = __root.br_hkdf_init;
    pub const br_hkdf_inject = __root.br_hkdf_inject;
    pub const br_hkdf_flip = __root.br_hkdf_flip;
    pub const br_hkdf_produce = __root.br_hkdf_produce;
    pub const init = __root.br_hkdf_init;
    pub const inject = __root.br_hkdf_inject;
    pub const flip = __root.br_hkdf_flip;
    pub const produce = __root.br_hkdf_produce;
};
pub extern fn br_hkdf_init(hc: [*c]br_hkdf_context, digest_vtable: [*c]const br_hash_class, salt: ?*const anyopaque, salt_len: usize) void;
pub extern const br_hkdf_no_salt: u8;
pub extern fn br_hkdf_inject(hc: [*c]br_hkdf_context, ikm: ?*const anyopaque, ikm_len: usize) void;
pub extern fn br_hkdf_flip(hc: [*c]br_hkdf_context) void;
pub extern fn br_hkdf_produce(hc: [*c]br_hkdf_context, info: ?*const anyopaque, info_len: usize, out: ?*anyopaque, out_len: usize) usize;
pub const br_shake_context = extern struct {
    dbuf: [200]u8 = @import("std").mem.zeroes([200]u8),
    dptr: usize = 0,
    rate: usize = 0,
    A: [25]u64 = @import("std").mem.zeroes([25]u64),
    pub const br_shake_init = __root.br_shake_init;
    pub const br_shake_inject = __root.br_shake_inject;
    pub const br_shake_flip = __root.br_shake_flip;
    pub const br_shake_produce = __root.br_shake_produce;
    pub const init = __root.br_shake_init;
    pub const inject = __root.br_shake_inject;
    pub const flip = __root.br_shake_flip;
    pub const produce = __root.br_shake_produce;
};
pub extern fn br_shake_init(sc: [*c]br_shake_context, security_level: c_int) void;
pub extern fn br_shake_inject(sc: [*c]br_shake_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_shake_flip(hc: [*c]br_shake_context) void;
pub extern fn br_shake_produce(sc: [*c]br_shake_context, out: ?*anyopaque, len: usize) void;
pub const br_block_cbcenc_class = struct_br_block_cbcenc_class_;
pub const struct_br_block_cbcenc_class_ = extern struct {
    context_size: usize = 0,
    block_size: c_uint = 0,
    log_block_size: c_uint = 0,
    init: ?*const fn (ctx: [*c][*c]const br_block_cbcenc_class, key: ?*const anyopaque, key_len: usize) callconv(.c) void = null,
    run: ?*const fn (ctx: [*c]const [*c]const br_block_cbcenc_class, iv: ?*anyopaque, data: ?*anyopaque, len: usize) callconv(.c) void = null,
};
pub const br_block_cbcdec_class = struct_br_block_cbcdec_class_;
pub const struct_br_block_cbcdec_class_ = extern struct {
    context_size: usize = 0,
    block_size: c_uint = 0,
    log_block_size: c_uint = 0,
    init: ?*const fn (ctx: [*c][*c]const br_block_cbcdec_class, key: ?*const anyopaque, key_len: usize) callconv(.c) void = null,
    run: ?*const fn (ctx: [*c]const [*c]const br_block_cbcdec_class, iv: ?*anyopaque, data: ?*anyopaque, len: usize) callconv(.c) void = null,
};
pub const br_block_ctr_class = struct_br_block_ctr_class_;
pub const struct_br_block_ctr_class_ = extern struct {
    context_size: usize = 0,
    block_size: c_uint = 0,
    log_block_size: c_uint = 0,
    init: ?*const fn (ctx: [*c][*c]const br_block_ctr_class, key: ?*const anyopaque, key_len: usize) callconv(.c) void = null,
    run: ?*const fn (ctx: [*c]const [*c]const br_block_ctr_class, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) callconv(.c) u32 = null,
};
pub const br_block_ctrcbc_class = struct_br_block_ctrcbc_class_;
pub const struct_br_block_ctrcbc_class_ = extern struct {
    context_size: usize = 0,
    block_size: c_uint = 0,
    log_block_size: c_uint = 0,
    init: ?*const fn (ctx: [*c][*c]const br_block_ctrcbc_class, key: ?*const anyopaque, key_len: usize) callconv(.c) void = null,
    encrypt: ?*const fn (ctx: [*c]const [*c]const br_block_ctrcbc_class, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) callconv(.c) void = null,
    decrypt: ?*const fn (ctx: [*c]const [*c]const br_block_ctrcbc_class, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) callconv(.c) void = null,
    ctr: ?*const fn (ctx: [*c]const [*c]const br_block_ctrcbc_class, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) callconv(.c) void = null,
    mac: ?*const fn (ctx: [*c]const [*c]const br_block_ctrcbc_class, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) callconv(.c) void = null,
};
pub const br_aes_big_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_big_cbcenc_init = __root.br_aes_big_cbcenc_init;
    pub const br_aes_big_cbcenc_run = __root.br_aes_big_cbcenc_run;
    pub const init = __root.br_aes_big_cbcenc_init;
    pub const run = __root.br_aes_big_cbcenc_run;
};
pub const br_aes_big_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_big_cbcdec_init = __root.br_aes_big_cbcdec_init;
    pub const br_aes_big_cbcdec_run = __root.br_aes_big_cbcdec_run;
    pub const init = __root.br_aes_big_cbcdec_init;
    pub const run = __root.br_aes_big_cbcdec_run;
};
pub const br_aes_big_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_big_ctr_init = __root.br_aes_big_ctr_init;
    pub const br_aes_big_ctr_run = __root.br_aes_big_ctr_run;
    pub const init = __root.br_aes_big_ctr_init;
    pub const run = __root.br_aes_big_ctr_run;
};
pub const br_aes_big_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_big_ctrcbc_init = __root.br_aes_big_ctrcbc_init;
    pub const br_aes_big_ctrcbc_encrypt = __root.br_aes_big_ctrcbc_encrypt;
    pub const br_aes_big_ctrcbc_decrypt = __root.br_aes_big_ctrcbc_decrypt;
    pub const br_aes_big_ctrcbc_ctr = __root.br_aes_big_ctrcbc_ctr;
    pub const br_aes_big_ctrcbc_mac = __root.br_aes_big_ctrcbc_mac;
    pub const init = __root.br_aes_big_ctrcbc_init;
    pub const encrypt = __root.br_aes_big_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_big_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_big_ctrcbc_ctr;
    pub const mac = __root.br_aes_big_ctrcbc_mac;
};
pub extern const br_aes_big_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_big_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_big_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_big_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_big_cbcenc_init(ctx: [*c]br_aes_big_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_big_cbcdec_init(ctx: [*c]br_aes_big_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_big_ctr_init(ctx: [*c]br_aes_big_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_big_ctrcbc_init(ctx: [*c]br_aes_big_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_big_cbcenc_run(ctx: [*c]const br_aes_big_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_big_cbcdec_run(ctx: [*c]const br_aes_big_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_big_ctr_run(ctx: [*c]const br_aes_big_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_big_ctrcbc_encrypt(ctx: [*c]const br_aes_big_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_big_ctrcbc_decrypt(ctx: [*c]const br_aes_big_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_big_ctrcbc_ctr(ctx: [*c]const br_aes_big_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_big_ctrcbc_mac(ctx: [*c]const br_aes_big_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
pub const br_aes_small_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_small_cbcenc_init = __root.br_aes_small_cbcenc_init;
    pub const br_aes_small_cbcenc_run = __root.br_aes_small_cbcenc_run;
    pub const init = __root.br_aes_small_cbcenc_init;
    pub const run = __root.br_aes_small_cbcenc_run;
};
pub const br_aes_small_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_small_cbcdec_init = __root.br_aes_small_cbcdec_init;
    pub const br_aes_small_cbcdec_run = __root.br_aes_small_cbcdec_run;
    pub const init = __root.br_aes_small_cbcdec_init;
    pub const run = __root.br_aes_small_cbcdec_run;
};
pub const br_aes_small_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_small_ctr_init = __root.br_aes_small_ctr_init;
    pub const br_aes_small_ctr_run = __root.br_aes_small_ctr_run;
    pub const init = __root.br_aes_small_ctr_init;
    pub const run = __root.br_aes_small_ctr_run;
};
pub const br_aes_small_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_small_ctrcbc_init = __root.br_aes_small_ctrcbc_init;
    pub const br_aes_small_ctrcbc_encrypt = __root.br_aes_small_ctrcbc_encrypt;
    pub const br_aes_small_ctrcbc_decrypt = __root.br_aes_small_ctrcbc_decrypt;
    pub const br_aes_small_ctrcbc_ctr = __root.br_aes_small_ctrcbc_ctr;
    pub const br_aes_small_ctrcbc_mac = __root.br_aes_small_ctrcbc_mac;
    pub const init = __root.br_aes_small_ctrcbc_init;
    pub const encrypt = __root.br_aes_small_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_small_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_small_ctrcbc_ctr;
    pub const mac = __root.br_aes_small_ctrcbc_mac;
};
pub extern const br_aes_small_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_small_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_small_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_small_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_small_cbcenc_init(ctx: [*c]br_aes_small_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_small_cbcdec_init(ctx: [*c]br_aes_small_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_small_ctr_init(ctx: [*c]br_aes_small_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_small_ctrcbc_init(ctx: [*c]br_aes_small_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_small_cbcenc_run(ctx: [*c]const br_aes_small_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_small_cbcdec_run(ctx: [*c]const br_aes_small_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_small_ctr_run(ctx: [*c]const br_aes_small_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_small_ctrcbc_encrypt(ctx: [*c]const br_aes_small_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_small_ctrcbc_decrypt(ctx: [*c]const br_aes_small_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_small_ctrcbc_ctr(ctx: [*c]const br_aes_small_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_small_ctrcbc_mac(ctx: [*c]const br_aes_small_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
pub const br_aes_ct_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_ct_cbcenc_init = __root.br_aes_ct_cbcenc_init;
    pub const br_aes_ct_cbcenc_run = __root.br_aes_ct_cbcenc_run;
    pub const init = __root.br_aes_ct_cbcenc_init;
    pub const run = __root.br_aes_ct_cbcenc_run;
};
pub const br_aes_ct_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_ct_cbcdec_init = __root.br_aes_ct_cbcdec_init;
    pub const br_aes_ct_cbcdec_run = __root.br_aes_ct_cbcdec_run;
    pub const init = __root.br_aes_ct_cbcdec_init;
    pub const run = __root.br_aes_ct_cbcdec_run;
};
pub const br_aes_ct_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_ct_ctr_init = __root.br_aes_ct_ctr_init;
    pub const br_aes_ct_ctr_run = __root.br_aes_ct_ctr_run;
    pub const init = __root.br_aes_ct_ctr_init;
    pub const run = __root.br_aes_ct_ctr_run;
};
pub const br_aes_ct_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: [60]u32 = @import("std").mem.zeroes([60]u32),
    num_rounds: c_uint = 0,
    pub const br_aes_ct_ctrcbc_init = __root.br_aes_ct_ctrcbc_init;
    pub const br_aes_ct_ctrcbc_encrypt = __root.br_aes_ct_ctrcbc_encrypt;
    pub const br_aes_ct_ctrcbc_decrypt = __root.br_aes_ct_ctrcbc_decrypt;
    pub const br_aes_ct_ctrcbc_ctr = __root.br_aes_ct_ctrcbc_ctr;
    pub const br_aes_ct_ctrcbc_mac = __root.br_aes_ct_ctrcbc_mac;
    pub const init = __root.br_aes_ct_ctrcbc_init;
    pub const encrypt = __root.br_aes_ct_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_ct_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_ct_ctrcbc_ctr;
    pub const mac = __root.br_aes_ct_ctrcbc_mac;
};
pub extern const br_aes_ct_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_ct_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_ct_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_ct_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_ct_cbcenc_init(ctx: [*c]br_aes_ct_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct_cbcdec_init(ctx: [*c]br_aes_ct_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctr_init(ctx: [*c]br_aes_ct_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctrcbc_init(ctx: [*c]br_aes_ct_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct_cbcenc_run(ctx: [*c]const br_aes_ct_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct_cbcdec_run(ctx: [*c]const br_aes_ct_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctr_run(ctx: [*c]const br_aes_ct_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_ct_ctrcbc_encrypt(ctx: [*c]const br_aes_ct_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctrcbc_decrypt(ctx: [*c]const br_aes_ct_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctrcbc_ctr(ctx: [*c]const br_aes_ct_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct_ctrcbc_mac(ctx: [*c]const br_aes_ct_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
pub const br_aes_ct64_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [30]u64 = @import("std").mem.zeroes([30]u64),
    num_rounds: c_uint = 0,
    pub const br_aes_ct64_cbcenc_init = __root.br_aes_ct64_cbcenc_init;
    pub const br_aes_ct64_cbcenc_run = __root.br_aes_ct64_cbcenc_run;
    pub const init = __root.br_aes_ct64_cbcenc_init;
    pub const run = __root.br_aes_ct64_cbcenc_run;
};
pub const br_aes_ct64_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [30]u64 = @import("std").mem.zeroes([30]u64),
    num_rounds: c_uint = 0,
    pub const br_aes_ct64_cbcdec_init = __root.br_aes_ct64_cbcdec_init;
    pub const br_aes_ct64_cbcdec_run = __root.br_aes_ct64_cbcdec_run;
    pub const init = __root.br_aes_ct64_cbcdec_init;
    pub const run = __root.br_aes_ct64_cbcdec_run;
};
pub const br_aes_ct64_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: [30]u64 = @import("std").mem.zeroes([30]u64),
    num_rounds: c_uint = 0,
    pub const br_aes_ct64_ctr_init = __root.br_aes_ct64_ctr_init;
    pub const br_aes_ct64_ctr_run = __root.br_aes_ct64_ctr_run;
    pub const init = __root.br_aes_ct64_ctr_init;
    pub const run = __root.br_aes_ct64_ctr_run;
};
pub const br_aes_ct64_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: [30]u64 = @import("std").mem.zeroes([30]u64),
    num_rounds: c_uint = 0,
    pub const br_aes_ct64_ctrcbc_init = __root.br_aes_ct64_ctrcbc_init;
    pub const br_aes_ct64_ctrcbc_encrypt = __root.br_aes_ct64_ctrcbc_encrypt;
    pub const br_aes_ct64_ctrcbc_decrypt = __root.br_aes_ct64_ctrcbc_decrypt;
    pub const br_aes_ct64_ctrcbc_ctr = __root.br_aes_ct64_ctrcbc_ctr;
    pub const br_aes_ct64_ctrcbc_mac = __root.br_aes_ct64_ctrcbc_mac;
    pub const init = __root.br_aes_ct64_ctrcbc_init;
    pub const encrypt = __root.br_aes_ct64_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_ct64_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_ct64_ctrcbc_ctr;
    pub const mac = __root.br_aes_ct64_ctrcbc_mac;
};
pub extern const br_aes_ct64_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_ct64_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_ct64_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_ct64_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_ct64_cbcenc_init(ctx: [*c]br_aes_ct64_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct64_cbcdec_init(ctx: [*c]br_aes_ct64_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctr_init(ctx: [*c]br_aes_ct64_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctrcbc_init(ctx: [*c]br_aes_ct64_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_ct64_cbcenc_run(ctx: [*c]const br_aes_ct64_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct64_cbcdec_run(ctx: [*c]const br_aes_ct64_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctr_run(ctx: [*c]const br_aes_ct64_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_ct64_ctrcbc_encrypt(ctx: [*c]const br_aes_ct64_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctrcbc_decrypt(ctx: [*c]const br_aes_ct64_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctrcbc_ctr(ctx: [*c]const br_aes_ct64_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_ct64_ctrcbc_mac(ctx: [*c]const br_aes_ct64_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
const union_unnamed_2 = extern union {
    skni: [240]u8,
};
pub const br_aes_x86ni_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: union_unnamed_2 = @import("std").mem.zeroes(union_unnamed_2),
    num_rounds: c_uint = 0,
    pub const br_aes_x86ni_cbcenc_init = __root.br_aes_x86ni_cbcenc_init;
    pub const br_aes_x86ni_cbcenc_run = __root.br_aes_x86ni_cbcenc_run;
    pub const init = __root.br_aes_x86ni_cbcenc_init;
    pub const run = __root.br_aes_x86ni_cbcenc_run;
};
const union_unnamed_3 = extern union {
    skni: [240]u8,
};
pub const br_aes_x86ni_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: union_unnamed_3 = @import("std").mem.zeroes(union_unnamed_3),
    num_rounds: c_uint = 0,
    pub const br_aes_x86ni_cbcdec_init = __root.br_aes_x86ni_cbcdec_init;
    pub const br_aes_x86ni_cbcdec_run = __root.br_aes_x86ni_cbcdec_run;
    pub const init = __root.br_aes_x86ni_cbcdec_init;
    pub const run = __root.br_aes_x86ni_cbcdec_run;
};
const union_unnamed_4 = extern union {
    skni: [240]u8,
};
pub const br_aes_x86ni_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: union_unnamed_4 = @import("std").mem.zeroes(union_unnamed_4),
    num_rounds: c_uint = 0,
    pub const br_aes_x86ni_ctr_init = __root.br_aes_x86ni_ctr_init;
    pub const br_aes_x86ni_ctr_run = __root.br_aes_x86ni_ctr_run;
    pub const init = __root.br_aes_x86ni_ctr_init;
    pub const run = __root.br_aes_x86ni_ctr_run;
};
const union_unnamed_5 = extern union {
    skni: [240]u8,
};
pub const br_aes_x86ni_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: union_unnamed_5 = @import("std").mem.zeroes(union_unnamed_5),
    num_rounds: c_uint = 0,
    pub const br_aes_x86ni_ctrcbc_init = __root.br_aes_x86ni_ctrcbc_init;
    pub const br_aes_x86ni_ctrcbc_encrypt = __root.br_aes_x86ni_ctrcbc_encrypt;
    pub const br_aes_x86ni_ctrcbc_decrypt = __root.br_aes_x86ni_ctrcbc_decrypt;
    pub const br_aes_x86ni_ctrcbc_ctr = __root.br_aes_x86ni_ctrcbc_ctr;
    pub const br_aes_x86ni_ctrcbc_mac = __root.br_aes_x86ni_ctrcbc_mac;
    pub const init = __root.br_aes_x86ni_ctrcbc_init;
    pub const encrypt = __root.br_aes_x86ni_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_x86ni_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_x86ni_ctrcbc_ctr;
    pub const mac = __root.br_aes_x86ni_ctrcbc_mac;
};
pub extern const br_aes_x86ni_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_x86ni_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_x86ni_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_x86ni_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_x86ni_cbcenc_init(ctx: [*c]br_aes_x86ni_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_cbcdec_init(ctx: [*c]br_aes_x86ni_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctr_init(ctx: [*c]br_aes_x86ni_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctrcbc_init(ctx: [*c]br_aes_x86ni_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_cbcenc_run(ctx: [*c]const br_aes_x86ni_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_cbcdec_run(ctx: [*c]const br_aes_x86ni_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctr_run(ctx: [*c]const br_aes_x86ni_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_x86ni_ctrcbc_encrypt(ctx: [*c]const br_aes_x86ni_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctrcbc_decrypt(ctx: [*c]const br_aes_x86ni_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctrcbc_ctr(ctx: [*c]const br_aes_x86ni_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_ctrcbc_mac(ctx: [*c]const br_aes_x86ni_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_x86ni_cbcenc_get_vtable() [*c]const br_block_cbcenc_class;
pub extern fn br_aes_x86ni_cbcdec_get_vtable() [*c]const br_block_cbcdec_class;
pub extern fn br_aes_x86ni_ctr_get_vtable() [*c]const br_block_ctr_class;
pub extern fn br_aes_x86ni_ctrcbc_get_vtable() [*c]const br_block_ctrcbc_class;
const union_unnamed_6 = extern union {
    skni: [240]u8,
};
pub const br_aes_pwr8_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: union_unnamed_6 = @import("std").mem.zeroes(union_unnamed_6),
    num_rounds: c_uint = 0,
    pub const br_aes_pwr8_cbcenc_init = __root.br_aes_pwr8_cbcenc_init;
    pub const br_aes_pwr8_cbcenc_run = __root.br_aes_pwr8_cbcenc_run;
    pub const init = __root.br_aes_pwr8_cbcenc_init;
    pub const run = __root.br_aes_pwr8_cbcenc_run;
};
const union_unnamed_7 = extern union {
    skni: [240]u8,
};
pub const br_aes_pwr8_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: union_unnamed_7 = @import("std").mem.zeroes(union_unnamed_7),
    num_rounds: c_uint = 0,
    pub const br_aes_pwr8_cbcdec_init = __root.br_aes_pwr8_cbcdec_init;
    pub const br_aes_pwr8_cbcdec_run = __root.br_aes_pwr8_cbcdec_run;
    pub const init = __root.br_aes_pwr8_cbcdec_init;
    pub const run = __root.br_aes_pwr8_cbcdec_run;
};
const union_unnamed_8 = extern union {
    skni: [240]u8,
};
pub const br_aes_pwr8_ctr_keys = extern struct {
    vtable: [*c]const br_block_ctr_class = null,
    skey: union_unnamed_8 = @import("std").mem.zeroes(union_unnamed_8),
    num_rounds: c_uint = 0,
    pub const br_aes_pwr8_ctr_init = __root.br_aes_pwr8_ctr_init;
    pub const br_aes_pwr8_ctr_run = __root.br_aes_pwr8_ctr_run;
    pub const init = __root.br_aes_pwr8_ctr_init;
    pub const run = __root.br_aes_pwr8_ctr_run;
};
const union_unnamed_9 = extern union {
    skni: [240]u8,
};
pub const br_aes_pwr8_ctrcbc_keys = extern struct {
    vtable: [*c]const br_block_ctrcbc_class = null,
    skey: union_unnamed_9 = @import("std").mem.zeroes(union_unnamed_9),
    num_rounds: c_uint = 0,
    pub const br_aes_pwr8_ctrcbc_init = __root.br_aes_pwr8_ctrcbc_init;
    pub const br_aes_pwr8_ctrcbc_encrypt = __root.br_aes_pwr8_ctrcbc_encrypt;
    pub const br_aes_pwr8_ctrcbc_decrypt = __root.br_aes_pwr8_ctrcbc_decrypt;
    pub const br_aes_pwr8_ctrcbc_ctr = __root.br_aes_pwr8_ctrcbc_ctr;
    pub const br_aes_pwr8_ctrcbc_mac = __root.br_aes_pwr8_ctrcbc_mac;
    pub const init = __root.br_aes_pwr8_ctrcbc_init;
    pub const encrypt = __root.br_aes_pwr8_ctrcbc_encrypt;
    pub const decrypt = __root.br_aes_pwr8_ctrcbc_decrypt;
    pub const ctr = __root.br_aes_pwr8_ctrcbc_ctr;
    pub const mac = __root.br_aes_pwr8_ctrcbc_mac;
};
pub extern const br_aes_pwr8_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_aes_pwr8_cbcdec_vtable: br_block_cbcdec_class;
pub extern const br_aes_pwr8_ctr_vtable: br_block_ctr_class;
pub extern const br_aes_pwr8_ctrcbc_vtable: br_block_ctrcbc_class;
pub extern fn br_aes_pwr8_cbcenc_init(ctx: [*c]br_aes_pwr8_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_cbcdec_init(ctx: [*c]br_aes_pwr8_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctr_init(ctx: [*c]br_aes_pwr8_ctr_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctrcbc_init(ctx: [*c]br_aes_pwr8_ctrcbc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_cbcenc_run(ctx: [*c]const br_aes_pwr8_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_cbcdec_run(ctx: [*c]const br_aes_pwr8_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctr_run(ctx: [*c]const br_aes_pwr8_ctr_keys, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_aes_pwr8_ctrcbc_encrypt(ctx: [*c]const br_aes_pwr8_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctrcbc_decrypt(ctx: [*c]const br_aes_pwr8_ctrcbc_keys, ctr: ?*anyopaque, cbcmac: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctrcbc_ctr(ctx: [*c]const br_aes_pwr8_ctrcbc_keys, ctr: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_ctrcbc_mac(ctx: [*c]const br_aes_pwr8_ctrcbc_keys, cbcmac: ?*anyopaque, data: ?*const anyopaque, len: usize) void;
pub extern fn br_aes_pwr8_cbcenc_get_vtable() [*c]const br_block_cbcenc_class;
pub extern fn br_aes_pwr8_cbcdec_get_vtable() [*c]const br_block_cbcdec_class;
pub extern fn br_aes_pwr8_ctr_get_vtable() [*c]const br_block_ctr_class;
pub extern fn br_aes_pwr8_ctrcbc_get_vtable() [*c]const br_block_ctrcbc_class;
pub const br_aes_gen_cbcenc_keys = extern union {
    vtable: [*c]const br_block_cbcenc_class,
    c_big: br_aes_big_cbcenc_keys,
    c_small: br_aes_small_cbcenc_keys,
    c_ct: br_aes_ct_cbcenc_keys,
    c_ct64: br_aes_ct64_cbcenc_keys,
    c_x86ni: br_aes_x86ni_cbcenc_keys,
    c_pwr8: br_aes_pwr8_cbcenc_keys,
};
pub const br_aes_gen_cbcdec_keys = extern union {
    vtable: [*c]const br_block_cbcdec_class,
    c_big: br_aes_big_cbcdec_keys,
    c_small: br_aes_small_cbcdec_keys,
    c_ct: br_aes_ct_cbcdec_keys,
    c_ct64: br_aes_ct64_cbcdec_keys,
    c_x86ni: br_aes_x86ni_cbcdec_keys,
    c_pwr8: br_aes_pwr8_cbcdec_keys,
};
pub const br_aes_gen_ctr_keys = extern union {
    vtable: [*c]const br_block_ctr_class,
    c_big: br_aes_big_ctr_keys,
    c_small: br_aes_small_ctr_keys,
    c_ct: br_aes_ct_ctr_keys,
    c_ct64: br_aes_ct64_ctr_keys,
    c_x86ni: br_aes_x86ni_ctr_keys,
    c_pwr8: br_aes_pwr8_ctr_keys,
};
pub const br_aes_gen_ctrcbc_keys = extern union {
    vtable: [*c]const br_block_ctrcbc_class,
    c_big: br_aes_big_ctrcbc_keys,
    c_small: br_aes_small_ctrcbc_keys,
    c_ct: br_aes_ct_ctrcbc_keys,
    c_ct64: br_aes_ct64_ctrcbc_keys,
    c_x86ni: br_aes_x86ni_ctrcbc_keys,
    c_pwr8: br_aes_pwr8_ctrcbc_keys,
};
pub const br_des_tab_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [96]u32 = @import("std").mem.zeroes([96]u32),
    num_rounds: c_uint = 0,
    pub const br_des_tab_cbcenc_init = __root.br_des_tab_cbcenc_init;
    pub const br_des_tab_cbcenc_run = __root.br_des_tab_cbcenc_run;
    pub const init = __root.br_des_tab_cbcenc_init;
    pub const run = __root.br_des_tab_cbcenc_run;
};
pub const br_des_tab_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [96]u32 = @import("std").mem.zeroes([96]u32),
    num_rounds: c_uint = 0,
    pub const br_des_tab_cbcdec_init = __root.br_des_tab_cbcdec_init;
    pub const br_des_tab_cbcdec_run = __root.br_des_tab_cbcdec_run;
    pub const init = __root.br_des_tab_cbcdec_init;
    pub const run = __root.br_des_tab_cbcdec_run;
};
pub extern const br_des_tab_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_des_tab_cbcdec_vtable: br_block_cbcdec_class;
pub extern fn br_des_tab_cbcenc_init(ctx: [*c]br_des_tab_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_des_tab_cbcdec_init(ctx: [*c]br_des_tab_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_des_tab_cbcenc_run(ctx: [*c]const br_des_tab_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_des_tab_cbcdec_run(ctx: [*c]const br_des_tab_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub const br_des_ct_cbcenc_keys = extern struct {
    vtable: [*c]const br_block_cbcenc_class = null,
    skey: [96]u32 = @import("std").mem.zeroes([96]u32),
    num_rounds: c_uint = 0,
    pub const br_des_ct_cbcenc_init = __root.br_des_ct_cbcenc_init;
    pub const br_des_ct_cbcenc_run = __root.br_des_ct_cbcenc_run;
    pub const init = __root.br_des_ct_cbcenc_init;
    pub const run = __root.br_des_ct_cbcenc_run;
};
pub const br_des_ct_cbcdec_keys = extern struct {
    vtable: [*c]const br_block_cbcdec_class = null,
    skey: [96]u32 = @import("std").mem.zeroes([96]u32),
    num_rounds: c_uint = 0,
    pub const br_des_ct_cbcdec_init = __root.br_des_ct_cbcdec_init;
    pub const br_des_ct_cbcdec_run = __root.br_des_ct_cbcdec_run;
    pub const init = __root.br_des_ct_cbcdec_init;
    pub const run = __root.br_des_ct_cbcdec_run;
};
pub extern const br_des_ct_cbcenc_vtable: br_block_cbcenc_class;
pub extern const br_des_ct_cbcdec_vtable: br_block_cbcdec_class;
pub extern fn br_des_ct_cbcenc_init(ctx: [*c]br_des_ct_cbcenc_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_des_ct_cbcdec_init(ctx: [*c]br_des_ct_cbcdec_keys, key: ?*const anyopaque, len: usize) void;
pub extern fn br_des_ct_cbcenc_run(ctx: [*c]const br_des_ct_cbcenc_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub extern fn br_des_ct_cbcdec_run(ctx: [*c]const br_des_ct_cbcdec_keys, iv: ?*anyopaque, data: ?*anyopaque, len: usize) void;
pub const br_des_gen_cbcenc_keys = extern union {
    vtable: [*c]const br_block_cbcenc_class,
    tab: br_des_tab_cbcenc_keys,
    ct: br_des_ct_cbcenc_keys,
};
pub const br_des_gen_cbcdec_keys = extern union {
    vtable: [*c]const br_block_cbcdec_class,
    c_tab: br_des_tab_cbcdec_keys,
    c_ct: br_des_ct_cbcdec_keys,
};
pub const br_chacha20_run = ?*const fn (key: ?*const anyopaque, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) callconv(.c) u32;
pub extern fn br_chacha20_ct_run(key: ?*const anyopaque, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_chacha20_sse2_run(key: ?*const anyopaque, iv: ?*const anyopaque, cc: u32, data: ?*anyopaque, len: usize) u32;
pub extern fn br_chacha20_sse2_get() br_chacha20_run;
pub const br_poly1305_run = ?*const fn (key: ?*const anyopaque, iv: ?*const anyopaque, data: ?*anyopaque, len: usize, aad: ?*const anyopaque, aad_len: usize, tag: ?*anyopaque, ichacha: br_chacha20_run, encrypt: c_int) callconv(.c) void;
pub extern fn br_poly1305_ctmul_run(key: ?*const anyopaque, iv: ?*const anyopaque, data: ?*anyopaque, len: usize, aad: ?*const anyopaque, aad_len: usize, tag: ?*anyopaque, ichacha: br_chacha20_run, encrypt: c_int) void;
pub extern fn br_poly1305_ctmul32_run(key: ?*const anyopaque, iv: ?*const anyopaque, data: ?*anyopaque, len: usize, aad: ?*const anyopaque, aad_len: usize, tag: ?*anyopaque, ichacha: br_chacha20_run, encrypt: c_int) void;
pub extern fn br_poly1305_i15_run(key: ?*const anyopaque, iv: ?*const anyopaque, data: ?*anyopaque, len: usize, aad: ?*const anyopaque, aad_len: usize, tag: ?*anyopaque, ichacha: br_chacha20_run, encrypt: c_int) void;
pub extern fn br_poly1305_ctmulq_run(key: ?*const anyopaque, iv: ?*const anyopaque, data: ?*anyopaque, len: usize, aad: ?*const anyopaque, aad_len: usize, tag: ?*anyopaque, ichacha: br_chacha20_run, encrypt: c_int) void;
pub extern fn br_poly1305_ctmulq_get() br_poly1305_run;
pub const br_prng_class = struct_br_prng_class_;
pub const struct_br_prng_class_ = extern struct {
    context_size: usize = 0,
    init: ?*const fn (ctx: [*c][*c]const br_prng_class, params: ?*const anyopaque, seed: ?*const anyopaque, seed_len: usize) callconv(.c) void = null,
    generate: ?*const fn (ctx: [*c][*c]const br_prng_class, out: ?*anyopaque, len: usize) callconv(.c) void = null,
    update: ?*const fn (ctx: [*c][*c]const br_prng_class, seed: ?*const anyopaque, seed_len: usize) callconv(.c) void = null,
};
pub const br_hmac_drbg_context = extern struct {
    vtable: [*c]const br_prng_class = null,
    K: [64]u8 = @import("std").mem.zeroes([64]u8),
    V: [64]u8 = @import("std").mem.zeroes([64]u8),
    digest_class: [*c]const br_hash_class = null,
    pub const br_hmac_drbg_init = __root.br_hmac_drbg_init;
    pub const br_hmac_drbg_generate = __root.br_hmac_drbg_generate;
    pub const br_hmac_drbg_update = __root.br_hmac_drbg_update;
    pub const br_hmac_drbg_get_hash = __root.br_hmac_drbg_get_hash;
    pub const init = __root.br_hmac_drbg_init;
    pub const generate = __root.br_hmac_drbg_generate;
    pub const update = __root.br_hmac_drbg_update;
    pub const hash = __root.br_hmac_drbg_get_hash;
};
pub extern const br_hmac_drbg_vtable: br_prng_class;
pub extern fn br_hmac_drbg_init(ctx: [*c]br_hmac_drbg_context, digest_class: [*c]const br_hash_class, seed: ?*const anyopaque, seed_len: usize) void;
pub extern fn br_hmac_drbg_generate(ctx: [*c]br_hmac_drbg_context, out: ?*anyopaque, len: usize) void;
pub extern fn br_hmac_drbg_update(ctx: [*c]br_hmac_drbg_context, seed: ?*const anyopaque, seed_len: usize) void;
pub fn br_hmac_drbg_get_hash(arg_ctx: [*c]const br_hmac_drbg_context) callconv(.c) [*c]const br_hash_class {
    var ctx = arg_ctx;
    _ = &ctx;
    return ctx.*.digest_class;
}
pub const br_prng_seeder = ?*const fn (ctx: [*c][*c]const br_prng_class) callconv(.c) c_int;
pub extern fn br_prng_seeder_system(name: [*c][*c]const u8) br_prng_seeder;
pub const br_aesctr_drbg_context = extern struct {
    vtable: [*c]const br_prng_class = null,
    sk: br_aes_gen_ctr_keys = @import("std").mem.zeroes(br_aes_gen_ctr_keys),
    cc: u32 = 0,
    pub const br_aesctr_drbg_init = __root.br_aesctr_drbg_init;
    pub const br_aesctr_drbg_generate = __root.br_aesctr_drbg_generate;
    pub const br_aesctr_drbg_update = __root.br_aesctr_drbg_update;
    pub const init = __root.br_aesctr_drbg_init;
    pub const generate = __root.br_aesctr_drbg_generate;
    pub const update = __root.br_aesctr_drbg_update;
};
pub extern const br_aesctr_drbg_vtable: br_prng_class;
pub extern fn br_aesctr_drbg_init(ctx: [*c]br_aesctr_drbg_context, aesctr: [*c]const br_block_ctr_class, seed: ?*const anyopaque, seed_len: usize) void;
pub extern fn br_aesctr_drbg_generate(ctx: [*c]br_aesctr_drbg_context, out: ?*anyopaque, len: usize) void;
pub extern fn br_aesctr_drbg_update(ctx: [*c]br_aesctr_drbg_context, seed: ?*const anyopaque, seed_len: usize) void;
pub const br_tls_prf_seed_chunk = extern struct {
    data: ?*const anyopaque = null,
    len: usize = 0,
};
pub extern fn br_tls10_prf(dst: ?*anyopaque, len: usize, secret: ?*const anyopaque, secret_len: usize, label: [*c]const u8, seed_num: usize, seed: [*c]const br_tls_prf_seed_chunk) void;
pub extern fn br_tls12_sha256_prf(dst: ?*anyopaque, len: usize, secret: ?*const anyopaque, secret_len: usize, label: [*c]const u8, seed_num: usize, seed: [*c]const br_tls_prf_seed_chunk) void;
pub extern fn br_tls12_sha384_prf(dst: ?*anyopaque, len: usize, secret: ?*const anyopaque, secret_len: usize, label: [*c]const u8, seed_num: usize, seed: [*c]const br_tls_prf_seed_chunk) void;
pub const br_tls_prf_impl = ?*const fn (dst: ?*anyopaque, len: usize, secret: ?*const anyopaque, secret_len: usize, label: [*c]const u8, seed_num: usize, seed: [*c]const br_tls_prf_seed_chunk) callconv(.c) void;
pub const br_aead_class = struct_br_aead_class_;
pub const struct_br_aead_class_ = extern struct {
    tag_size: usize = 0,
    reset: ?*const fn (cc: [*c][*c]const br_aead_class, iv: ?*const anyopaque, len: usize) callconv(.c) void = null,
    aad_inject: ?*const fn (cc: [*c][*c]const br_aead_class, data: ?*const anyopaque, len: usize) callconv(.c) void = null,
    flip: ?*const fn (cc: [*c][*c]const br_aead_class) callconv(.c) void = null,
    run: ?*const fn (cc: [*c][*c]const br_aead_class, encrypt: c_int, data: ?*anyopaque, len: usize) callconv(.c) void = null,
    get_tag: ?*const fn (cc: [*c][*c]const br_aead_class, tag: ?*anyopaque) callconv(.c) void = null,
    check_tag: ?*const fn (cc: [*c][*c]const br_aead_class, tag: ?*const anyopaque) callconv(.c) u32 = null,
    get_tag_trunc: ?*const fn (cc: [*c][*c]const br_aead_class, tag: ?*anyopaque, len: usize) callconv(.c) void = null,
    check_tag_trunc: ?*const fn (cc: [*c][*c]const br_aead_class, tag: ?*const anyopaque, len: usize) callconv(.c) u32 = null,
};
pub const br_gcm_context = extern struct {
    vtable: [*c]const br_aead_class = null,
    bctx: [*c][*c]const br_block_ctr_class = null,
    gh: br_ghash = null,
    h: [16]u8 = @import("std").mem.zeroes([16]u8),
    j0_1: [12]u8 = @import("std").mem.zeroes([12]u8),
    buf: [16]u8 = @import("std").mem.zeroes([16]u8),
    y: [16]u8 = @import("std").mem.zeroes([16]u8),
    j0_2: u32 = 0,
    jc: u32 = 0,
    count_aad: u64 = 0,
    count_ctr: u64 = 0,
    pub const br_gcm_init = __root.br_gcm_init;
    pub const br_gcm_reset = __root.br_gcm_reset;
    pub const br_gcm_aad_inject = __root.br_gcm_aad_inject;
    pub const br_gcm_flip = __root.br_gcm_flip;
    pub const br_gcm_run = __root.br_gcm_run;
    pub const br_gcm_get_tag = __root.br_gcm_get_tag;
    pub const br_gcm_check_tag = __root.br_gcm_check_tag;
    pub const br_gcm_get_tag_trunc = __root.br_gcm_get_tag_trunc;
    pub const br_gcm_check_tag_trunc = __root.br_gcm_check_tag_trunc;
    pub const init = __root.br_gcm_init;
    pub const reset = __root.br_gcm_reset;
    pub const inject = __root.br_gcm_aad_inject;
    pub const flip = __root.br_gcm_flip;
    pub const run = __root.br_gcm_run;
    pub const tag = __root.br_gcm_get_tag;
    pub const trunc = __root.br_gcm_get_tag_trunc;
};
pub extern fn br_gcm_init(ctx: [*c]br_gcm_context, bctx: [*c][*c]const br_block_ctr_class, gh: br_ghash) void;
pub extern fn br_gcm_reset(ctx: [*c]br_gcm_context, iv: ?*const anyopaque, len: usize) void;
pub extern fn br_gcm_aad_inject(ctx: [*c]br_gcm_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_gcm_flip(ctx: [*c]br_gcm_context) void;
pub extern fn br_gcm_run(ctx: [*c]br_gcm_context, encrypt: c_int, data: ?*anyopaque, len: usize) void;
pub extern fn br_gcm_get_tag(ctx: [*c]br_gcm_context, tag: ?*anyopaque) void;
pub extern fn br_gcm_check_tag(ctx: [*c]br_gcm_context, tag: ?*const anyopaque) u32;
pub extern fn br_gcm_get_tag_trunc(ctx: [*c]br_gcm_context, tag: ?*anyopaque, len: usize) void;
pub extern fn br_gcm_check_tag_trunc(ctx: [*c]br_gcm_context, tag: ?*const anyopaque, len: usize) u32;
pub extern const br_gcm_vtable: br_aead_class;
pub const br_eax_context = extern struct {
    vtable: [*c]const br_aead_class = null,
    bctx: [*c][*c]const br_block_ctrcbc_class = null,
    L2: [16]u8 = @import("std").mem.zeroes([16]u8),
    L4: [16]u8 = @import("std").mem.zeroes([16]u8),
    nonce: [16]u8 = @import("std").mem.zeroes([16]u8),
    head: [16]u8 = @import("std").mem.zeroes([16]u8),
    ctr: [16]u8 = @import("std").mem.zeroes([16]u8),
    cbcmac: [16]u8 = @import("std").mem.zeroes([16]u8),
    buf: [16]u8 = @import("std").mem.zeroes([16]u8),
    ptr: usize = 0,
    pub const br_eax_init = __root.br_eax_init;
    pub const br_eax_capture = __root.br_eax_capture;
    pub const br_eax_reset = __root.br_eax_reset;
    pub const br_eax_reset_pre_aad = __root.br_eax_reset_pre_aad;
    pub const br_eax_reset_post_aad = __root.br_eax_reset_post_aad;
    pub const br_eax_aad_inject = __root.br_eax_aad_inject;
    pub const br_eax_flip = __root.br_eax_flip;
    pub const br_eax_get_aad_mac = __root.br_eax_get_aad_mac;
    pub const br_eax_run = __root.br_eax_run;
    pub const br_eax_get_tag = __root.br_eax_get_tag;
    pub const br_eax_check_tag = __root.br_eax_check_tag;
    pub const br_eax_get_tag_trunc = __root.br_eax_get_tag_trunc;
    pub const br_eax_check_tag_trunc = __root.br_eax_check_tag_trunc;
    pub const init = __root.br_eax_init;
    pub const capture = __root.br_eax_capture;
    pub const reset = __root.br_eax_reset;
    pub const aad = __root.br_eax_reset_pre_aad;
    pub const inject = __root.br_eax_aad_inject;
    pub const flip = __root.br_eax_flip;
    pub const mac = __root.br_eax_get_aad_mac;
    pub const run = __root.br_eax_run;
    pub const tag = __root.br_eax_get_tag;
    pub const trunc = __root.br_eax_get_tag_trunc;
};
pub const br_eax_state = extern struct {
    st: [3][16]u8 = @import("std").mem.zeroes([3][16]u8),
};
pub extern fn br_eax_init(ctx: [*c]br_eax_context, bctx: [*c][*c]const br_block_ctrcbc_class) void;
pub extern fn br_eax_capture(ctx: [*c]const br_eax_context, st: [*c]br_eax_state) void;
pub extern fn br_eax_reset(ctx: [*c]br_eax_context, nonce: ?*const anyopaque, len: usize) void;
pub extern fn br_eax_reset_pre_aad(ctx: [*c]br_eax_context, st: [*c]const br_eax_state, nonce: ?*const anyopaque, len: usize) void;
pub extern fn br_eax_reset_post_aad(ctx: [*c]br_eax_context, st: [*c]const br_eax_state, nonce: ?*const anyopaque, len: usize) void;
pub extern fn br_eax_aad_inject(ctx: [*c]br_eax_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_eax_flip(ctx: [*c]br_eax_context) void;
pub fn br_eax_get_aad_mac(arg_ctx: [*c]const br_eax_context, arg_st: [*c]br_eax_state) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var st = arg_st;
    _ = &st;
    _ = memcpy(@ptrCast(@alignCast(@as([*c]u8, @ptrCast(@alignCast(&st.*.st[@as(c_int, 1)]))))), @ptrCast(@alignCast(@as([*c]u8, @ptrCast(@alignCast(&ctx.*.head))))), @sizeOf(@TypeOf(ctx.*.head)));
}
pub extern fn br_eax_run(ctx: [*c]br_eax_context, encrypt: c_int, data: ?*anyopaque, len: usize) void;
pub extern fn br_eax_get_tag(ctx: [*c]br_eax_context, tag: ?*anyopaque) void;
pub extern fn br_eax_check_tag(ctx: [*c]br_eax_context, tag: ?*const anyopaque) u32;
pub extern fn br_eax_get_tag_trunc(ctx: [*c]br_eax_context, tag: ?*anyopaque, len: usize) void;
pub extern fn br_eax_check_tag_trunc(ctx: [*c]br_eax_context, tag: ?*const anyopaque, len: usize) u32;
pub extern const br_eax_vtable: br_aead_class;
pub const br_ccm_context = extern struct {
    bctx: [*c][*c]const br_block_ctrcbc_class = null,
    ctr: [16]u8 = @import("std").mem.zeroes([16]u8),
    cbcmac: [16]u8 = @import("std").mem.zeroes([16]u8),
    tagmask: [16]u8 = @import("std").mem.zeroes([16]u8),
    buf: [16]u8 = @import("std").mem.zeroes([16]u8),
    ptr: usize = 0,
    tag_len: usize = 0,
    pub const br_ccm_init = __root.br_ccm_init;
    pub const br_ccm_reset = __root.br_ccm_reset;
    pub const br_ccm_aad_inject = __root.br_ccm_aad_inject;
    pub const br_ccm_flip = __root.br_ccm_flip;
    pub const br_ccm_run = __root.br_ccm_run;
    pub const br_ccm_get_tag = __root.br_ccm_get_tag;
    pub const br_ccm_check_tag = __root.br_ccm_check_tag;
    pub const init = __root.br_ccm_init;
    pub const reset = __root.br_ccm_reset;
    pub const inject = __root.br_ccm_aad_inject;
    pub const flip = __root.br_ccm_flip;
    pub const run = __root.br_ccm_run;
    pub const tag = __root.br_ccm_get_tag;
};
pub extern fn br_ccm_init(ctx: [*c]br_ccm_context, bctx: [*c][*c]const br_block_ctrcbc_class) void;
pub extern fn br_ccm_reset(ctx: [*c]br_ccm_context, nonce: ?*const anyopaque, nonce_len: usize, aad_len: u64, data_len: u64, tag_len: usize) c_int;
pub extern fn br_ccm_aad_inject(ctx: [*c]br_ccm_context, data: ?*const anyopaque, len: usize) void;
pub extern fn br_ccm_flip(ctx: [*c]br_ccm_context) void;
pub extern fn br_ccm_run(ctx: [*c]br_ccm_context, encrypt: c_int, data: ?*anyopaque, len: usize) void;
pub extern fn br_ccm_get_tag(ctx: [*c]br_ccm_context, tag: ?*anyopaque) usize;
pub extern fn br_ccm_check_tag(ctx: [*c]br_ccm_context, tag: ?*const anyopaque) u32;
pub const br_rsa_public_key = extern struct {
    n: [*c]u8 = null,
    nlen: usize = 0,
    e: [*c]u8 = null,
    elen: usize = 0,
};
pub const br_rsa_private_key = extern struct {
    n_bitlen: u32 = 0,
    p: [*c]u8 = null,
    plen: usize = 0,
    q: [*c]u8 = null,
    qlen: usize = 0,
    dp: [*c]u8 = null,
    dplen: usize = 0,
    dq: [*c]u8 = null,
    dqlen: usize = 0,
    iq: [*c]u8 = null,
    iqlen: usize = 0,
    pub const br_rsa_i15_compute_pubexp = __root.br_rsa_i15_compute_pubexp;
    pub const br_rsa_i31_compute_pubexp = __root.br_rsa_i31_compute_pubexp;
    pub const pubexp = __root.br_rsa_i15_compute_pubexp;
};
pub const br_rsa_public = ?*const fn (x: [*c]u8, xlen: usize, pk: [*c]const br_rsa_public_key) callconv(.c) u32;
pub const br_rsa_pkcs1_vrfy = ?*const fn (x: [*c]const u8, xlen: usize, hash_oid: [*c]const u8, hash_len: usize, pk: [*c]const br_rsa_public_key, hash_out: [*c]u8) callconv(.c) u32;
pub const br_rsa_pss_vrfy = ?*const fn (x: [*c]const u8, xlen: usize, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash: ?*const anyopaque, salt_len: usize, pk: [*c]const br_rsa_public_key) callconv(.c) u32;
pub const br_rsa_oaep_encrypt = ?*const fn (rnd: [*c][*c]const br_prng_class, dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, pk: [*c]const br_rsa_public_key, dst: ?*anyopaque, dst_max_len: usize, src: ?*const anyopaque, src_len: usize) callconv(.c) usize;
pub const br_rsa_private = ?*const fn (x: [*c]u8, sk: [*c]const br_rsa_private_key) callconv(.c) u32;
pub const br_rsa_pkcs1_sign = ?*const fn (hash_oid: [*c]const u8, hash: [*c]const u8, hash_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) callconv(.c) u32;
pub const br_rsa_pss_sign = ?*const fn (rng: [*c][*c]const br_prng_class, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash_value: [*c]const u8, salt_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) callconv(.c) u32;
pub const br_rsa_oaep_decrypt = ?*const fn (dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, sk: [*c]const br_rsa_private_key, data: ?*anyopaque, len: [*c]usize) callconv(.c) u32;
pub extern fn br_rsa_i32_public(x: [*c]u8, xlen: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i32_pkcs1_vrfy(x: [*c]const u8, xlen: usize, hash_oid: [*c]const u8, hash_len: usize, pk: [*c]const br_rsa_public_key, hash_out: [*c]u8) u32;
pub extern fn br_rsa_i32_pss_vrfy(x: [*c]const u8, xlen: usize, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash: ?*const anyopaque, salt_len: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i32_private(x: [*c]u8, sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_i32_pkcs1_sign(hash_oid: [*c]const u8, hash: [*c]const u8, hash_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i32_pss_sign(rng: [*c][*c]const br_prng_class, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash_value: [*c]const u8, salt_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i31_public(x: [*c]u8, xlen: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i31_pkcs1_vrfy(x: [*c]const u8, xlen: usize, hash_oid: [*c]const u8, hash_len: usize, pk: [*c]const br_rsa_public_key, hash_out: [*c]u8) u32;
pub extern fn br_rsa_i31_pss_vrfy(x: [*c]const u8, xlen: usize, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash: ?*const anyopaque, salt_len: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i31_private(x: [*c]u8, sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_i31_pkcs1_sign(hash_oid: [*c]const u8, hash: [*c]const u8, hash_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i31_pss_sign(rng: [*c][*c]const br_prng_class, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash_value: [*c]const u8, salt_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i62_public(x: [*c]u8, xlen: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i62_pkcs1_vrfy(x: [*c]const u8, xlen: usize, hash_oid: [*c]const u8, hash_len: usize, pk: [*c]const br_rsa_public_key, hash_out: [*c]u8) u32;
pub extern fn br_rsa_i62_pss_vrfy(x: [*c]const u8, xlen: usize, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash: ?*const anyopaque, salt_len: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i62_private(x: [*c]u8, sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_i62_pkcs1_sign(hash_oid: [*c]const u8, hash: [*c]const u8, hash_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i62_pss_sign(rng: [*c][*c]const br_prng_class, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash_value: [*c]const u8, salt_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i62_public_get() br_rsa_public;
pub extern fn br_rsa_i62_pkcs1_vrfy_get() br_rsa_pkcs1_vrfy;
pub extern fn br_rsa_i62_pss_vrfy_get() br_rsa_pss_vrfy;
pub extern fn br_rsa_i62_private_get() br_rsa_private;
pub extern fn br_rsa_i62_pkcs1_sign_get() br_rsa_pkcs1_sign;
pub extern fn br_rsa_i62_pss_sign_get() br_rsa_pss_sign;
pub extern fn br_rsa_i62_oaep_encrypt_get() br_rsa_oaep_encrypt;
pub extern fn br_rsa_i62_oaep_decrypt_get() br_rsa_oaep_decrypt;
pub extern fn br_rsa_i15_public(x: [*c]u8, xlen: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i15_pkcs1_vrfy(x: [*c]const u8, xlen: usize, hash_oid: [*c]const u8, hash_len: usize, pk: [*c]const br_rsa_public_key, hash_out: [*c]u8) u32;
pub extern fn br_rsa_i15_pss_vrfy(x: [*c]const u8, xlen: usize, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash: ?*const anyopaque, salt_len: usize, pk: [*c]const br_rsa_public_key) u32;
pub extern fn br_rsa_i15_private(x: [*c]u8, sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_i15_pkcs1_sign(hash_oid: [*c]const u8, hash: [*c]const u8, hash_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_i15_pss_sign(rng: [*c][*c]const br_prng_class, hf_data: [*c]const br_hash_class, hf_mgf1: [*c]const br_hash_class, hash_value: [*c]const u8, salt_len: usize, sk: [*c]const br_rsa_private_key, x: [*c]u8) u32;
pub extern fn br_rsa_public_get_default() br_rsa_public;
pub extern fn br_rsa_private_get_default() br_rsa_private;
pub extern fn br_rsa_pkcs1_vrfy_get_default() br_rsa_pkcs1_vrfy;
pub extern fn br_rsa_pss_vrfy_get_default() br_rsa_pss_vrfy;
pub extern fn br_rsa_pkcs1_sign_get_default() br_rsa_pkcs1_sign;
pub extern fn br_rsa_pss_sign_get_default() br_rsa_pss_sign;
pub extern fn br_rsa_oaep_encrypt_get_default() br_rsa_oaep_encrypt;
pub extern fn br_rsa_oaep_decrypt_get_default() br_rsa_oaep_decrypt;
pub extern fn br_rsa_ssl_decrypt(core: br_rsa_private, sk: [*c]const br_rsa_private_key, data: [*c]u8, len: usize) u32;
pub extern fn br_rsa_i15_oaep_encrypt(rnd: [*c][*c]const br_prng_class, dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, pk: [*c]const br_rsa_public_key, dst: ?*anyopaque, dst_max_len: usize, src: ?*const anyopaque, src_len: usize) usize;
pub extern fn br_rsa_i15_oaep_decrypt(dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, sk: [*c]const br_rsa_private_key, data: ?*anyopaque, len: [*c]usize) u32;
pub extern fn br_rsa_i31_oaep_encrypt(rnd: [*c][*c]const br_prng_class, dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, pk: [*c]const br_rsa_public_key, dst: ?*anyopaque, dst_max_len: usize, src: ?*const anyopaque, src_len: usize) usize;
pub extern fn br_rsa_i31_oaep_decrypt(dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, sk: [*c]const br_rsa_private_key, data: ?*anyopaque, len: [*c]usize) u32;
pub extern fn br_rsa_i32_oaep_encrypt(rnd: [*c][*c]const br_prng_class, dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, pk: [*c]const br_rsa_public_key, dst: ?*anyopaque, dst_max_len: usize, src: ?*const anyopaque, src_len: usize) usize;
pub extern fn br_rsa_i32_oaep_decrypt(dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, sk: [*c]const br_rsa_private_key, data: ?*anyopaque, len: [*c]usize) u32;
pub extern fn br_rsa_i62_oaep_encrypt(rnd: [*c][*c]const br_prng_class, dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, pk: [*c]const br_rsa_public_key, dst: ?*anyopaque, dst_max_len: usize, src: ?*const anyopaque, src_len: usize) usize;
pub extern fn br_rsa_i62_oaep_decrypt(dig: [*c]const br_hash_class, label: ?*const anyopaque, label_len: usize, sk: [*c]const br_rsa_private_key, data: ?*anyopaque, len: [*c]usize) u32;
pub const br_rsa_keygen = ?*const fn (rng_ctx: [*c][*c]const br_prng_class, sk: [*c]br_rsa_private_key, kbuf_priv: ?*anyopaque, pk: [*c]br_rsa_public_key, kbuf_pub: ?*anyopaque, size: c_uint, pubexp: u32) callconv(.c) u32;
pub extern fn br_rsa_i15_keygen(rng_ctx: [*c][*c]const br_prng_class, sk: [*c]br_rsa_private_key, kbuf_priv: ?*anyopaque, pk: [*c]br_rsa_public_key, kbuf_pub: ?*anyopaque, size: c_uint, pubexp: u32) u32;
pub extern fn br_rsa_i31_keygen(rng_ctx: [*c][*c]const br_prng_class, sk: [*c]br_rsa_private_key, kbuf_priv: ?*anyopaque, pk: [*c]br_rsa_public_key, kbuf_pub: ?*anyopaque, size: c_uint, pubexp: u32) u32;
pub extern fn br_rsa_i62_keygen(rng_ctx: [*c][*c]const br_prng_class, sk: [*c]br_rsa_private_key, kbuf_priv: ?*anyopaque, pk: [*c]br_rsa_public_key, kbuf_pub: ?*anyopaque, size: c_uint, pubexp: u32) u32;
pub extern fn br_rsa_i62_keygen_get() br_rsa_keygen;
pub extern fn br_rsa_keygen_get_default() br_rsa_keygen;
pub const br_rsa_compute_modulus = ?*const fn (n: ?*anyopaque, sk: [*c]const br_rsa_private_key) callconv(.c) usize;
pub extern fn br_rsa_i15_compute_modulus(n: ?*anyopaque, sk: [*c]const br_rsa_private_key) usize;
pub extern fn br_rsa_i31_compute_modulus(n: ?*anyopaque, sk: [*c]const br_rsa_private_key) usize;
pub extern fn br_rsa_compute_modulus_get_default() br_rsa_compute_modulus;
pub const br_rsa_compute_pubexp = ?*const fn (sk: [*c]const br_rsa_private_key) callconv(.c) u32;
pub extern fn br_rsa_i15_compute_pubexp(sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_i31_compute_pubexp(sk: [*c]const br_rsa_private_key) u32;
pub extern fn br_rsa_compute_pubexp_get_default() br_rsa_compute_pubexp;
pub const br_rsa_compute_privexp = ?*const fn (d: ?*anyopaque, sk: [*c]const br_rsa_private_key, pubexp: u32) callconv(.c) usize;
pub extern fn br_rsa_i15_compute_privexp(d: ?*anyopaque, sk: [*c]const br_rsa_private_key, pubexp: u32) usize;
pub extern fn br_rsa_i31_compute_privexp(d: ?*anyopaque, sk: [*c]const br_rsa_private_key, pubexp: u32) usize;
pub extern fn br_rsa_compute_privexp_get_default() br_rsa_compute_privexp;
pub const br_ec_public_key = extern struct {
    curve: c_int = 0,
    q: [*c]u8 = null,
    qlen: usize = 0,
};
pub const br_ec_private_key = extern struct {
    curve: c_int = 0,
    x: [*c]u8 = null,
    xlen: usize = 0,
};
pub const br_ec_impl = extern struct {
    supported_curves: u32 = 0,
    generator: ?*const fn (curve: c_int, len: [*c]usize) callconv(.c) [*c]const u8 = null,
    order: ?*const fn (curve: c_int, len: [*c]usize) callconv(.c) [*c]const u8 = null,
    xoff: ?*const fn (curve: c_int, len: [*c]usize) callconv(.c) usize = null,
    mul: ?*const fn (G: [*c]u8, Glen: usize, x: [*c]const u8, xlen: usize, curve: c_int) callconv(.c) u32 = null,
    mulgen: ?*const fn (R: [*c]u8, x: [*c]const u8, xlen: usize, curve: c_int) callconv(.c) usize = null,
    muladd: ?*const fn (A: [*c]u8, B: [*c]const u8, len: usize, x: [*c]const u8, xlen: usize, y: [*c]const u8, ylen: usize, curve: c_int) callconv(.c) u32 = null,
    pub const br_ecdsa_i31_sign_asn1 = __root.br_ecdsa_i31_sign_asn1;
    pub const br_ecdsa_i31_sign_raw = __root.br_ecdsa_i31_sign_raw;
    pub const br_ecdsa_i31_vrfy_asn1 = __root.br_ecdsa_i31_vrfy_asn1;
    pub const br_ecdsa_i31_vrfy_raw = __root.br_ecdsa_i31_vrfy_raw;
    pub const br_ecdsa_i15_sign_asn1 = __root.br_ecdsa_i15_sign_asn1;
    pub const br_ecdsa_i15_sign_raw = __root.br_ecdsa_i15_sign_raw;
    pub const br_ecdsa_i15_vrfy_asn1 = __root.br_ecdsa_i15_vrfy_asn1;
    pub const br_ecdsa_i15_vrfy_raw = __root.br_ecdsa_i15_vrfy_raw;
    pub const br_ec_compute_pub = __root.br_ec_compute_pub;
    pub const asn1 = __root.br_ecdsa_i31_sign_asn1;
    pub const raw = __root.br_ecdsa_i31_sign_raw;
    pub const @"pub" = __root.br_ec_compute_pub;
};
pub extern const br_ec_prime_i31: br_ec_impl;
pub extern const br_ec_prime_i15: br_ec_impl;
pub extern const br_ec_p256_m15: br_ec_impl;
pub extern const br_ec_p256_m31: br_ec_impl;
pub extern const br_ec_p256_m62: br_ec_impl;
pub extern fn br_ec_p256_m62_get() [*c]const br_ec_impl;
pub extern const br_ec_p256_m64: br_ec_impl;
pub extern fn br_ec_p256_m64_get() [*c]const br_ec_impl;
pub extern const br_ec_c25519_i15: br_ec_impl;
pub extern const br_ec_c25519_i31: br_ec_impl;
pub extern const br_ec_c25519_m15: br_ec_impl;
pub extern const br_ec_c25519_m31: br_ec_impl;
pub extern const br_ec_c25519_m62: br_ec_impl;
pub extern fn br_ec_c25519_m62_get() [*c]const br_ec_impl;
pub extern const br_ec_c25519_m64: br_ec_impl;
pub extern fn br_ec_c25519_m64_get() [*c]const br_ec_impl;
pub extern const br_ec_all_m15: br_ec_impl;
pub extern const br_ec_all_m31: br_ec_impl;
pub extern fn br_ec_get_default() [*c]const br_ec_impl;
pub extern fn br_ecdsa_raw_to_asn1(sig: ?*anyopaque, sig_len: usize) usize;
pub extern fn br_ecdsa_asn1_to_raw(sig: ?*anyopaque, sig_len: usize) usize;
pub const br_ecdsa_sign = ?*const fn (impl: [*c]const br_ec_impl, hf: [*c]const br_hash_class, hash_value: ?*const anyopaque, sk: [*c]const br_ec_private_key, sig: ?*anyopaque) callconv(.c) usize;
pub const br_ecdsa_vrfy = ?*const fn (impl: [*c]const br_ec_impl, hash: ?*const anyopaque, hash_len: usize, pk: [*c]const br_ec_public_key, sig: ?*const anyopaque, sig_len: usize) callconv(.c) u32;
pub extern fn br_ecdsa_i31_sign_asn1(impl: [*c]const br_ec_impl, hf: [*c]const br_hash_class, hash_value: ?*const anyopaque, sk: [*c]const br_ec_private_key, sig: ?*anyopaque) usize;
pub extern fn br_ecdsa_i31_sign_raw(impl: [*c]const br_ec_impl, hf: [*c]const br_hash_class, hash_value: ?*const anyopaque, sk: [*c]const br_ec_private_key, sig: ?*anyopaque) usize;
pub extern fn br_ecdsa_i31_vrfy_asn1(impl: [*c]const br_ec_impl, hash: ?*const anyopaque, hash_len: usize, pk: [*c]const br_ec_public_key, sig: ?*const anyopaque, sig_len: usize) u32;
pub extern fn br_ecdsa_i31_vrfy_raw(impl: [*c]const br_ec_impl, hash: ?*const anyopaque, hash_len: usize, pk: [*c]const br_ec_public_key, sig: ?*const anyopaque, sig_len: usize) u32;
pub extern fn br_ecdsa_i15_sign_asn1(impl: [*c]const br_ec_impl, hf: [*c]const br_hash_class, hash_value: ?*const anyopaque, sk: [*c]const br_ec_private_key, sig: ?*anyopaque) usize;
pub extern fn br_ecdsa_i15_sign_raw(impl: [*c]const br_ec_impl, hf: [*c]const br_hash_class, hash_value: ?*const anyopaque, sk: [*c]const br_ec_private_key, sig: ?*anyopaque) usize;
pub extern fn br_ecdsa_i15_vrfy_asn1(impl: [*c]const br_ec_impl, hash: ?*const anyopaque, hash_len: usize, pk: [*c]const br_ec_public_key, sig: ?*const anyopaque, sig_len: usize) u32;
pub extern fn br_ecdsa_i15_vrfy_raw(impl: [*c]const br_ec_impl, hash: ?*const anyopaque, hash_len: usize, pk: [*c]const br_ec_public_key, sig: ?*const anyopaque, sig_len: usize) u32;
pub extern fn br_ecdsa_sign_asn1_get_default() br_ecdsa_sign;
pub extern fn br_ecdsa_sign_raw_get_default() br_ecdsa_sign;
pub extern fn br_ecdsa_vrfy_asn1_get_default() br_ecdsa_vrfy;
pub extern fn br_ecdsa_vrfy_raw_get_default() br_ecdsa_vrfy;
pub extern fn br_ec_keygen(rng_ctx: [*c][*c]const br_prng_class, impl: [*c]const br_ec_impl, sk: [*c]br_ec_private_key, kbuf: ?*anyopaque, curve: c_int) usize;
pub extern fn br_ec_compute_pub(impl: [*c]const br_ec_impl, pk: [*c]br_ec_public_key, kbuf: ?*anyopaque, sk: [*c]const br_ec_private_key) usize;
const union_unnamed_10 = extern union {
    rsa: br_rsa_public_key,
    ec: br_ec_public_key,
};
pub const br_x509_pkey = extern struct {
    key_type: u8 = 0,
    key: union_unnamed_10 = @import("std").mem.zeroes(union_unnamed_10),
};
pub const br_x500_name = extern struct {
    data: [*c]u8 = null,
    len: usize = 0,
};
pub const br_x509_trust_anchor = extern struct {
    dn: br_x500_name = @import("std").mem.zeroes(br_x500_name),
    flags: c_uint = 0,
    pkey: br_x509_pkey = @import("std").mem.zeroes(br_x509_pkey),
};
pub const br_x509_class = struct_br_x509_class_;
pub const struct_br_x509_class_ = extern struct {
    context_size: usize = 0,
    start_chain: ?*const fn (ctx: [*c][*c]const br_x509_class, server_name: [*c]const u8) callconv(.c) void = null,
    start_cert: ?*const fn (ctx: [*c][*c]const br_x509_class, length: u32) callconv(.c) void = null,
    append: ?*const fn (ctx: [*c][*c]const br_x509_class, buf: [*c]const u8, len: usize) callconv(.c) void = null,
    end_cert: ?*const fn (ctx: [*c][*c]const br_x509_class) callconv(.c) void = null,
    end_chain: ?*const fn (ctx: [*c][*c]const br_x509_class) callconv(.c) c_uint = null,
    get_pkey: ?*const fn (ctx: [*c]const [*c]const br_x509_class, usages: [*c]c_uint) callconv(.c) [*c]const br_x509_pkey = null,
};
pub const br_x509_knownkey_context = extern struct {
    vtable: [*c]const br_x509_class = null,
    pkey: br_x509_pkey = @import("std").mem.zeroes(br_x509_pkey),
    usages: c_uint = 0,
    pub const br_x509_knownkey_init_rsa = __root.br_x509_knownkey_init_rsa;
    pub const br_x509_knownkey_init_ec = __root.br_x509_knownkey_init_ec;
    pub const rsa = __root.br_x509_knownkey_init_rsa;
    pub const ec = __root.br_x509_knownkey_init_ec;
};
pub extern const br_x509_knownkey_vtable: br_x509_class;
pub extern fn br_x509_knownkey_init_rsa(ctx: [*c]br_x509_knownkey_context, pk: [*c]const br_rsa_public_key, usages: c_uint) void;
pub extern fn br_x509_knownkey_init_ec(ctx: [*c]br_x509_knownkey_context, pk: [*c]const br_ec_public_key, usages: c_uint) void;
pub const br_name_element = extern struct {
    oid: [*c]const u8 = null,
    buf: [*c]u8 = null,
    len: usize = 0,
    status: c_int = 0,
};
pub const br_x509_time_check = ?*const fn (tctx: ?*anyopaque, not_before_days: u32, not_before_seconds: u32, not_after_days: u32, not_after_seconds: u32) callconv(.c) c_int;
const struct_unnamed_11 = extern struct {
    dp: [*c]u32 = null,
    rp: [*c]u32 = null,
    ip: [*c]const u8 = null,
};
pub const br_x509_minimal_context = extern struct {
    vtable: [*c]const br_x509_class = null,
    pkey: br_x509_pkey = @import("std").mem.zeroes(br_x509_pkey),
    cpu: struct_unnamed_11 = @import("std").mem.zeroes(struct_unnamed_11),
    dp_stack: [31]u32 = @import("std").mem.zeroes([31]u32),
    rp_stack: [31]u32 = @import("std").mem.zeroes([31]u32),
    err: c_int = 0,
    server_name: [*c]const u8 = null,
    key_usages: u8 = 0,
    days: u32 = 0,
    seconds: u32 = 0,
    cert_length: u32 = 0,
    num_certs: u32 = 0,
    hbuf: [*c]const u8 = null,
    hlen: usize = 0,
    pad: [256]u8 = @import("std").mem.zeroes([256]u8),
    ee_pkey_data: [520]u8 = @import("std").mem.zeroes([520]u8),
    pkey_data: [520]u8 = @import("std").mem.zeroes([520]u8),
    cert_signer_key_type: u8 = 0,
    cert_sig_hash_oid: u16 = 0,
    cert_sig_hash_len: u8 = 0,
    cert_sig: [512]u8 = @import("std").mem.zeroes([512]u8),
    cert_sig_len: u16 = 0,
    min_rsa_size: i16 = 0,
    trust_anchors: [*c]const br_x509_trust_anchor = null,
    trust_anchors_num: usize = 0,
    do_mhash: u8 = 0,
    mhash: br_multihash_context = @import("std").mem.zeroes(br_multihash_context),
    tbs_hash: [64]u8 = @import("std").mem.zeroes([64]u8),
    do_dn_hash: u8 = 0,
    dn_hash_impl: [*c]const br_hash_class = null,
    dn_hash: br_hash_compat_context = @import("std").mem.zeroes(br_hash_compat_context),
    current_dn_hash: [64]u8 = @import("std").mem.zeroes([64]u8),
    next_dn_hash: [64]u8 = @import("std").mem.zeroes([64]u8),
    saved_dn_hash: [64]u8 = @import("std").mem.zeroes([64]u8),
    name_elts: [*c]br_name_element = null,
    num_name_elts: usize = 0,
    itime_ctx: ?*anyopaque = null,
    itime: br_x509_time_check = null,
    irsa: br_rsa_pkcs1_vrfy = null,
    iecdsa: br_ecdsa_vrfy = null,
    iec: [*c]const br_ec_impl = null,
    pub const br_x509_minimal_init = __root.br_x509_minimal_init;
    pub const br_x509_minimal_set_hash = __root.br_x509_minimal_set_hash;
    pub const br_x509_minimal_set_rsa = __root.br_x509_minimal_set_rsa;
    pub const br_x509_minimal_set_ecdsa = __root.br_x509_minimal_set_ecdsa;
    pub const br_x509_minimal_init_full = __root.br_x509_minimal_init_full;
    pub const br_x509_minimal_set_time = __root.br_x509_minimal_set_time;
    pub const br_x509_minimal_set_time_callback = __root.br_x509_minimal_set_time_callback;
    pub const br_x509_minimal_set_minrsa = __root.br_x509_minimal_set_minrsa;
    pub const br_x509_minimal_set_name_elements = __root.br_x509_minimal_set_name_elements;
    pub const init = __root.br_x509_minimal_init;
    pub const hash = __root.br_x509_minimal_set_hash;
    pub const rsa = __root.br_x509_minimal_set_rsa;
    pub const ecdsa = __root.br_x509_minimal_set_ecdsa;
    pub const full = __root.br_x509_minimal_init_full;
    pub const time = __root.br_x509_minimal_set_time;
    pub const callback = __root.br_x509_minimal_set_time_callback;
    pub const minrsa = __root.br_x509_minimal_set_minrsa;
    pub const elements = __root.br_x509_minimal_set_name_elements;
};
pub extern const br_x509_minimal_vtable: br_x509_class;
pub extern fn br_x509_minimal_init(ctx: [*c]br_x509_minimal_context, dn_hash_impl: [*c]const br_hash_class, trust_anchors: [*c]const br_x509_trust_anchor, trust_anchors_num: usize) void;
pub fn br_x509_minimal_set_hash(arg_ctx: [*c]br_x509_minimal_context, arg_id: c_int, arg_impl: [*c]const br_hash_class) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var id = arg_id;
    _ = &id;
    var impl = arg_impl;
    _ = &impl;
    br_multihash_setimpl(&ctx.*.mhash, id, impl);
}
pub fn br_x509_minimal_set_rsa(arg_ctx: [*c]br_x509_minimal_context, arg_irsa: br_rsa_pkcs1_vrfy) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var irsa = arg_irsa;
    _ = &irsa;
    ctx.*.irsa = irsa;
}
pub fn br_x509_minimal_set_ecdsa(arg_ctx: [*c]br_x509_minimal_context, arg_iec: [*c]const br_ec_impl, arg_iecdsa: br_ecdsa_vrfy) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var iec = arg_iec;
    _ = &iec;
    var iecdsa = arg_iecdsa;
    _ = &iecdsa;
    ctx.*.iecdsa = iecdsa;
    ctx.*.iec = iec;
}
pub extern fn br_x509_minimal_init_full(ctx: [*c]br_x509_minimal_context, trust_anchors: [*c]const br_x509_trust_anchor, trust_anchors_num: usize) void;
pub fn br_x509_minimal_set_time(arg_ctx: [*c]br_x509_minimal_context, arg_days: u32, arg_seconds: u32) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var days = arg_days;
    _ = &days;
    var seconds = arg_seconds;
    _ = &seconds;
    ctx.*.days = days;
    ctx.*.seconds = seconds;
    ctx.*.itime = null;
}
pub fn br_x509_minimal_set_time_callback(arg_ctx: [*c]br_x509_minimal_context, arg_itime_ctx: ?*anyopaque, arg_itime: br_x509_time_check) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var itime_ctx = arg_itime_ctx;
    _ = &itime_ctx;
    var itime = arg_itime;
    _ = &itime;
    ctx.*.itime_ctx = itime_ctx;
    ctx.*.itime = itime;
}
pub fn br_x509_minimal_set_minrsa(arg_ctx: [*c]br_x509_minimal_context, arg_byte_length: c_int) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var byte_length = arg_byte_length;
    _ = &byte_length;
    ctx.*.min_rsa_size = @truncate(byte_length - @as(c_int, 128));
}
pub fn br_x509_minimal_set_name_elements(arg_ctx: [*c]br_x509_minimal_context, arg_elts: [*c]br_name_element, arg_num_elts: usize) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var elts = arg_elts;
    _ = &elts;
    var num_elts = arg_num_elts;
    _ = &num_elts;
    ctx.*.name_elts = elts;
    ctx.*.num_name_elts = num_elts;
}
const struct_unnamed_12 = extern struct {
    dp: [*c]u32 = null,
    rp: [*c]u32 = null,
    ip: [*c]const u8 = null,
};
pub const br_x509_decoder_context = extern struct {
    pkey: br_x509_pkey = @import("std").mem.zeroes(br_x509_pkey),
    cpu: struct_unnamed_12 = @import("std").mem.zeroes(struct_unnamed_12),
    dp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    rp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    err: c_int = 0,
    pad: [256]u8 = @import("std").mem.zeroes([256]u8),
    decoded: u8 = 0,
    notbefore_days: u32 = 0,
    notbefore_seconds: u32 = 0,
    notafter_days: u32 = 0,
    notafter_seconds: u32 = 0,
    isCA: u8 = 0,
    copy_dn: u8 = 0,
    append_dn_ctx: ?*anyopaque = null,
    append_dn: ?*const fn (ctx: ?*anyopaque, buf: ?*const anyopaque, len: usize) callconv(.c) void = null,
    hbuf: [*c]const u8 = null,
    hlen: usize = 0,
    pkey_data: [520]u8 = @import("std").mem.zeroes([520]u8),
    signer_key_type: u8 = 0,
    signer_hash_id: u8 = 0,
    pub const br_x509_decoder_init = __root.br_x509_decoder_init;
    pub const br_x509_decoder_push = __root.br_x509_decoder_push;
    pub const br_x509_decoder_get_pkey = __root.br_x509_decoder_get_pkey;
    pub const br_x509_decoder_last_error = __root.br_x509_decoder_last_error;
    pub const br_x509_decoder_isCA = __root.br_x509_decoder_isCA;
    pub const br_x509_decoder_get_signer_key_type = __root.br_x509_decoder_get_signer_key_type;
    pub const br_x509_decoder_get_signer_hash_id = __root.br_x509_decoder_get_signer_hash_id;
    pub const init = __root.br_x509_decoder_init;
    pub const push = __root.br_x509_decoder_push;
    pub const @"error" = __root.br_x509_decoder_last_error;
    pub const @"type" = __root.br_x509_decoder_get_signer_key_type;
    pub const id = __root.br_x509_decoder_get_signer_hash_id;
};
pub extern fn br_x509_decoder_init(ctx: [*c]br_x509_decoder_context, append_dn: ?*const fn (ctx: ?*anyopaque, buf: ?*const anyopaque, len: usize) callconv(.c) void, append_dn_ctx: ?*anyopaque) void;
pub extern fn br_x509_decoder_push(ctx: [*c]br_x509_decoder_context, data: ?*const anyopaque, len: usize) void;
pub fn br_x509_decoder_get_pkey(arg_ctx: [*c]br_x509_decoder_context) callconv(.c) [*c]br_x509_pkey {
    var ctx = arg_ctx;
    _ = &ctx;
    if ((@as(c_int, ctx.*.decoded) != 0) and (ctx.*.err == @as(c_int, 0))) {
        return &ctx.*.pkey;
    } else {
        return null;
    }
}
pub fn br_x509_decoder_last_error(arg_ctx: [*c]br_x509_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    if (ctx.*.err != @as(c_int, 0)) {
        return ctx.*.err;
    }
    if (!(@as(c_int, ctx.*.decoded) != 0)) {
        return BR_ERR_X509_TRUNCATED;
    }
    return 0;
}
pub fn br_x509_decoder_isCA(arg_ctx: [*c]br_x509_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    return ctx.*.isCA;
}
pub fn br_x509_decoder_get_signer_key_type(arg_ctx: [*c]br_x509_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    return ctx.*.signer_key_type;
}
pub fn br_x509_decoder_get_signer_hash_id(arg_ctx: [*c]br_x509_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    return ctx.*.signer_hash_id;
}
pub const br_x509_certificate = extern struct {
    data: [*c]u8 = null,
    data_len: usize = 0,
};
const union_unnamed_13 = extern union {
    rsa: br_rsa_private_key,
    ec: br_ec_private_key,
};
const struct_unnamed_14 = extern struct {
    dp: [*c]u32 = null,
    rp: [*c]u32 = null,
    ip: [*c]const u8 = null,
};
pub const br_skey_decoder_context = extern struct {
    key: union_unnamed_13 = @import("std").mem.zeroes(union_unnamed_13),
    cpu: struct_unnamed_14 = @import("std").mem.zeroes(struct_unnamed_14),
    dp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    rp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    err: c_int = 0,
    hbuf: [*c]const u8 = null,
    hlen: usize = 0,
    pad: [256]u8 = @import("std").mem.zeroes([256]u8),
    key_type: u8 = 0,
    key_data: [1536]u8 = @import("std").mem.zeroes([1536]u8),
    pub const br_skey_decoder_init = __root.br_skey_decoder_init;
    pub const br_skey_decoder_push = __root.br_skey_decoder_push;
    pub const br_skey_decoder_last_error = __root.br_skey_decoder_last_error;
    pub const br_skey_decoder_key_type = __root.br_skey_decoder_key_type;
    pub const br_skey_decoder_get_rsa = __root.br_skey_decoder_get_rsa;
    pub const br_skey_decoder_get_ec = __root.br_skey_decoder_get_ec;
    pub const init = __root.br_skey_decoder_init;
    pub const push = __root.br_skey_decoder_push;
    pub const @"error" = __root.br_skey_decoder_last_error;
    pub const @"type" = __root.br_skey_decoder_key_type;
    pub const rsa = __root.br_skey_decoder_get_rsa;
    pub const ec = __root.br_skey_decoder_get_ec;
};
pub extern fn br_skey_decoder_init(ctx: [*c]br_skey_decoder_context) void;
pub extern fn br_skey_decoder_push(ctx: [*c]br_skey_decoder_context, data: ?*const anyopaque, len: usize) void;
pub fn br_skey_decoder_last_error(arg_ctx: [*c]const br_skey_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    if (ctx.*.err != @as(c_int, 0)) {
        return ctx.*.err;
    }
    if (@as(c_int, ctx.*.key_type) == @as(c_int, 0)) {
        return BR_ERR_X509_TRUNCATED;
    }
    return 0;
}
pub fn br_skey_decoder_key_type(arg_ctx: [*c]const br_skey_decoder_context) callconv(.c) c_int {
    var ctx = arg_ctx;
    _ = &ctx;
    if (ctx.*.err == @as(c_int, 0)) {
        return ctx.*.key_type;
    } else {
        return 0;
    }
}
pub fn br_skey_decoder_get_rsa(arg_ctx: [*c]const br_skey_decoder_context) callconv(.c) [*c]const br_rsa_private_key {
    var ctx = arg_ctx;
    _ = &ctx;
    if ((ctx.*.err == @as(c_int, 0)) and (@as(c_int, ctx.*.key_type) == BR_KEYTYPE_RSA)) {
        return &ctx.*.key.rsa;
    } else {
        return null;
    }
}
pub fn br_skey_decoder_get_ec(arg_ctx: [*c]const br_skey_decoder_context) callconv(.c) [*c]const br_ec_private_key {
    var ctx = arg_ctx;
    _ = &ctx;
    if ((ctx.*.err == @as(c_int, 0)) and (@as(c_int, ctx.*.key_type) == BR_KEYTYPE_EC)) {
        return &ctx.*.key.ec;
    } else {
        return null;
    }
}
pub extern fn br_encode_rsa_raw_der(dest: ?*anyopaque, sk: [*c]const br_rsa_private_key, pk: [*c]const br_rsa_public_key, d: ?*const anyopaque, dlen: usize) usize;
pub extern fn br_encode_rsa_pkcs8_der(dest: ?*anyopaque, sk: [*c]const br_rsa_private_key, pk: [*c]const br_rsa_public_key, d: ?*const anyopaque, dlen: usize) usize;
pub extern fn br_encode_ec_raw_der(dest: ?*anyopaque, sk: [*c]const br_ec_private_key, pk: [*c]const br_ec_public_key) usize;
pub extern fn br_encode_ec_pkcs8_der(dest: ?*anyopaque, sk: [*c]const br_ec_private_key, pk: [*c]const br_ec_public_key) usize;
pub const br_sslrec_in_class = struct_br_sslrec_in_class_;
pub const struct_br_sslrec_in_class_ = extern struct {
    context_size: usize = 0,
    check_length: ?*const fn (ctx: [*c]const [*c]const br_sslrec_in_class, record_len: usize) callconv(.c) c_int = null,
    decrypt: ?*const fn (ctx: [*c][*c]const br_sslrec_in_class, record_type: c_int, version: c_uint, payload: ?*anyopaque, len: [*c]usize) callconv(.c) [*c]u8 = null,
};
pub const br_sslrec_out_class = struct_br_sslrec_out_class_;
pub const struct_br_sslrec_out_class_ = extern struct {
    context_size: usize = 0,
    max_plaintext: ?*const fn (ctx: [*c]const [*c]const br_sslrec_out_class, start: [*c]usize, end: [*c]usize) callconv(.c) void = null,
    encrypt: ?*const fn (ctx: [*c][*c]const br_sslrec_out_class, record_type: c_int, version: c_uint, plaintext: ?*anyopaque, len: [*c]usize) callconv(.c) [*c]u8 = null,
};
pub const br_sslrec_out_clear_context = extern struct {
    vtable: [*c]const br_sslrec_out_class = null,
};
pub extern const br_sslrec_out_clear_vtable: br_sslrec_out_class;
pub const br_sslrec_in_cbc_class = struct_br_sslrec_in_cbc_class_;
pub const struct_br_sslrec_in_cbc_class_ = extern struct {
    inner: br_sslrec_in_class = @import("std").mem.zeroes(br_sslrec_in_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_in_cbc_class, bc_impl: [*c]const br_block_cbcdec_class, bc_key: ?*const anyopaque, bc_key_len: usize, dig_impl: [*c]const br_hash_class, mac_key: ?*const anyopaque, mac_key_len: usize, mac_out_len: usize, iv: ?*const anyopaque) callconv(.c) void = null,
};
pub const br_sslrec_out_cbc_class = struct_br_sslrec_out_cbc_class_;
pub const struct_br_sslrec_out_cbc_class_ = extern struct {
    inner: br_sslrec_out_class = @import("std").mem.zeroes(br_sslrec_out_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_out_cbc_class, bc_impl: [*c]const br_block_cbcenc_class, bc_key: ?*const anyopaque, bc_key_len: usize, dig_impl: [*c]const br_hash_class, mac_key: ?*const anyopaque, mac_key_len: usize, mac_out_len: usize, iv: ?*const anyopaque) callconv(.c) void = null,
};
const union_unnamed_15 = extern union {
    vtable: [*c]const br_block_cbcdec_class,
    aes: br_aes_gen_cbcdec_keys,
    des: br_des_gen_cbcdec_keys,
};
pub const br_sslrec_in_cbc_context = extern struct {
    vtable: [*c]const br_sslrec_in_cbc_class = null,
    seq: u64 = 0,
    bc: union_unnamed_15 = @import("std").mem.zeroes(union_unnamed_15),
    mac: br_hmac_key_context = @import("std").mem.zeroes(br_hmac_key_context),
    mac_len: usize = 0,
    iv: [16]u8 = @import("std").mem.zeroes([16]u8),
    explicit_IV: c_int = 0,
};
pub extern const br_sslrec_in_cbc_vtable: br_sslrec_in_cbc_class;
const union_unnamed_16 = extern union {
    vtable: [*c]const br_block_cbcenc_class,
    aes: br_aes_gen_cbcenc_keys,
    des: br_des_gen_cbcenc_keys,
};
pub const br_sslrec_out_cbc_context = extern struct {
    vtable: [*c]const br_sslrec_out_cbc_class = null,
    seq: u64 = 0,
    bc: union_unnamed_16 = @import("std").mem.zeroes(union_unnamed_16),
    mac: br_hmac_key_context = @import("std").mem.zeroes(br_hmac_key_context),
    mac_len: usize = 0,
    iv: [16]u8 = @import("std").mem.zeroes([16]u8),
    explicit_IV: c_int = 0,
};
pub extern const br_sslrec_out_cbc_vtable: br_sslrec_out_cbc_class;
pub const br_sslrec_in_gcm_class = struct_br_sslrec_in_gcm_class_;
pub const struct_br_sslrec_in_gcm_class_ = extern struct {
    inner: br_sslrec_in_class = @import("std").mem.zeroes(br_sslrec_in_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_in_gcm_class, bc_impl: [*c]const br_block_ctr_class, key: ?*const anyopaque, key_len: usize, gh_impl: br_ghash, iv: ?*const anyopaque) callconv(.c) void = null,
};
pub const br_sslrec_out_gcm_class = struct_br_sslrec_out_gcm_class_;
pub const struct_br_sslrec_out_gcm_class_ = extern struct {
    inner: br_sslrec_out_class = @import("std").mem.zeroes(br_sslrec_out_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_out_gcm_class, bc_impl: [*c]const br_block_ctr_class, key: ?*const anyopaque, key_len: usize, gh_impl: br_ghash, iv: ?*const anyopaque) callconv(.c) void = null,
};
const union_unnamed_17 = extern union {
    gen: ?*const anyopaque,
    in: [*c]const br_sslrec_in_gcm_class,
    out: [*c]const br_sslrec_out_gcm_class,
};
const union_unnamed_18 = extern union {
    vtable: [*c]const br_block_ctr_class,
    aes: br_aes_gen_ctr_keys,
};
pub const br_sslrec_gcm_context = extern struct {
    vtable: union_unnamed_17 = @import("std").mem.zeroes(union_unnamed_17),
    seq: u64 = 0,
    bc: union_unnamed_18 = @import("std").mem.zeroes(union_unnamed_18),
    gh: br_ghash = null,
    iv: [4]u8 = @import("std").mem.zeroes([4]u8),
    h: [16]u8 = @import("std").mem.zeroes([16]u8),
};
pub extern const br_sslrec_in_gcm_vtable: br_sslrec_in_gcm_class;
pub extern const br_sslrec_out_gcm_vtable: br_sslrec_out_gcm_class;
pub const br_sslrec_in_chapol_class = struct_br_sslrec_in_chapol_class_;
pub const struct_br_sslrec_in_chapol_class_ = extern struct {
    inner: br_sslrec_in_class = @import("std").mem.zeroes(br_sslrec_in_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_in_chapol_class, ichacha: br_chacha20_run, ipoly: br_poly1305_run, key: ?*const anyopaque, iv: ?*const anyopaque) callconv(.c) void = null,
};
pub const br_sslrec_out_chapol_class = struct_br_sslrec_out_chapol_class_;
pub const struct_br_sslrec_out_chapol_class_ = extern struct {
    inner: br_sslrec_out_class = @import("std").mem.zeroes(br_sslrec_out_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_out_chapol_class, ichacha: br_chacha20_run, ipoly: br_poly1305_run, key: ?*const anyopaque, iv: ?*const anyopaque) callconv(.c) void = null,
};
const union_unnamed_19 = extern union {
    gen: ?*const anyopaque,
    in: [*c]const br_sslrec_in_chapol_class,
    out: [*c]const br_sslrec_out_chapol_class,
};
pub const br_sslrec_chapol_context = extern struct {
    vtable: union_unnamed_19 = @import("std").mem.zeroes(union_unnamed_19),
    seq: u64 = 0,
    key: [32]u8 = @import("std").mem.zeroes([32]u8),
    iv: [12]u8 = @import("std").mem.zeroes([12]u8),
    ichacha: br_chacha20_run = null,
    ipoly: br_poly1305_run = null,
};
pub extern const br_sslrec_in_chapol_vtable: br_sslrec_in_chapol_class;
pub extern const br_sslrec_out_chapol_vtable: br_sslrec_out_chapol_class;
pub const br_sslrec_in_ccm_class = struct_br_sslrec_in_ccm_class_;
pub const struct_br_sslrec_in_ccm_class_ = extern struct {
    inner: br_sslrec_in_class = @import("std").mem.zeroes(br_sslrec_in_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_in_ccm_class, bc_impl: [*c]const br_block_ctrcbc_class, key: ?*const anyopaque, key_len: usize, iv: ?*const anyopaque, tag_len: usize) callconv(.c) void = null,
};
pub const br_sslrec_out_ccm_class = struct_br_sslrec_out_ccm_class_;
pub const struct_br_sslrec_out_ccm_class_ = extern struct {
    inner: br_sslrec_out_class = @import("std").mem.zeroes(br_sslrec_out_class),
    init: ?*const fn (ctx: [*c][*c]const br_sslrec_out_ccm_class, bc_impl: [*c]const br_block_ctrcbc_class, key: ?*const anyopaque, key_len: usize, iv: ?*const anyopaque, tag_len: usize) callconv(.c) void = null,
};
const union_unnamed_20 = extern union {
    gen: ?*const anyopaque,
    in: [*c]const br_sslrec_in_ccm_class,
    out: [*c]const br_sslrec_out_ccm_class,
};
const union_unnamed_21 = extern union {
    vtable: [*c]const br_block_ctrcbc_class,
    aes: br_aes_gen_ctrcbc_keys,
};
pub const br_sslrec_ccm_context = extern struct {
    vtable: union_unnamed_20 = @import("std").mem.zeroes(union_unnamed_20),
    seq: u64 = 0,
    bc: union_unnamed_21 = @import("std").mem.zeroes(union_unnamed_21),
    iv: [4]u8 = @import("std").mem.zeroes([4]u8),
    tag_len: usize = 0,
};
pub extern const br_sslrec_in_ccm_vtable: br_sslrec_in_ccm_class;
pub extern const br_sslrec_out_ccm_vtable: br_sslrec_out_ccm_class;
pub const br_ssl_session_parameters = extern struct {
    session_id: [32]u8 = @import("std").mem.zeroes([32]u8),
    session_id_len: u8 = 0,
    version: u16 = 0,
    cipher_suite: u16 = 0,
    master_secret: [48]u8 = @import("std").mem.zeroes([48]u8),
};
const union_unnamed_22 = extern union {
    vtable: [*c]const br_sslrec_in_class,
    cbc: br_sslrec_in_cbc_context,
    gcm: br_sslrec_gcm_context,
    chapol: br_sslrec_chapol_context,
    ccm: br_sslrec_ccm_context,
};
const union_unnamed_23 = extern union {
    vtable: [*c]const br_sslrec_out_class,
    clear: br_sslrec_out_clear_context,
    cbc: br_sslrec_out_cbc_context,
    gcm: br_sslrec_gcm_context,
    chapol: br_sslrec_chapol_context,
    ccm: br_sslrec_ccm_context,
};
const struct_unnamed_24 = extern struct {
    dp: [*c]u32 = null,
    rp: [*c]u32 = null,
    ip: [*c]const u8 = null,
};
pub const br_ssl_engine_context = extern struct {
    err: c_int = 0,
    ibuf: [*c]u8 = null,
    obuf: [*c]u8 = null,
    ibuf_len: usize = 0,
    obuf_len: usize = 0,
    max_frag_len: u16 = 0,
    log_max_frag_len: u8 = 0,
    peer_log_max_frag_len: u8 = 0,
    ixa: usize = 0,
    ixb: usize = 0,
    ixc: usize = 0,
    oxa: usize = 0,
    oxb: usize = 0,
    oxc: usize = 0,
    iomode: u8 = 0,
    incrypt: u8 = 0,
    shutdown_recv: u8 = 0,
    record_type_in: u8 = 0,
    record_type_out: u8 = 0,
    version_in: u16 = 0,
    version_out: u16 = 0,
    in: union_unnamed_22 = @import("std").mem.zeroes(union_unnamed_22),
    out: union_unnamed_23 = @import("std").mem.zeroes(union_unnamed_23),
    application_data: u8 = 0,
    rng: br_hmac_drbg_context = @import("std").mem.zeroes(br_hmac_drbg_context),
    rng_init_done: c_int = 0,
    rng_os_rand_done: c_int = 0,
    version_min: u16 = 0,
    version_max: u16 = 0,
    suites_buf: [48]u16 = @import("std").mem.zeroes([48]u16),
    suites_num: u8 = 0,
    server_name: [256]u8 = @import("std").mem.zeroes([256]u8),
    client_random: [32]u8 = @import("std").mem.zeroes([32]u8),
    server_random: [32]u8 = @import("std").mem.zeroes([32]u8),
    session: br_ssl_session_parameters = @import("std").mem.zeroes(br_ssl_session_parameters),
    ecdhe_curve: u8 = 0,
    ecdhe_point: [133]u8 = @import("std").mem.zeroes([133]u8),
    ecdhe_point_len: u8 = 0,
    reneg: u8 = 0,
    saved_finished: [24]u8 = @import("std").mem.zeroes([24]u8),
    flags: u32 = 0,
    cpu: struct_unnamed_24 = @import("std").mem.zeroes(struct_unnamed_24),
    dp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    rp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    pad: [512]u8 = @import("std").mem.zeroes([512]u8),
    hbuf_in: [*c]u8 = null,
    hbuf_out: [*c]u8 = null,
    saved_hbuf_out: [*c]u8 = null,
    hlen_in: usize = 0,
    hlen_out: usize = 0,
    hsrun: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    action: u8 = 0,
    alert: u8 = 0,
    close_received: u8 = 0,
    mhash: br_multihash_context = @import("std").mem.zeroes(br_multihash_context),
    x509ctx: [*c][*c]const br_x509_class = null,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
    cert_cur: [*c]const u8 = null,
    cert_len: usize = 0,
    protocol_names: [*c][*c]const u8 = null,
    protocol_names_num: u16 = 0,
    selected_protocol: u16 = 0,
    prf10: br_tls_prf_impl = null,
    prf_sha256: br_tls_prf_impl = null,
    prf_sha384: br_tls_prf_impl = null,
    iaes_cbcenc: [*c]const br_block_cbcenc_class = null,
    iaes_cbcdec: [*c]const br_block_cbcdec_class = null,
    iaes_ctr: [*c]const br_block_ctr_class = null,
    iaes_ctrcbc: [*c]const br_block_ctrcbc_class = null,
    ides_cbcenc: [*c]const br_block_cbcenc_class = null,
    ides_cbcdec: [*c]const br_block_cbcdec_class = null,
    ighash: br_ghash = null,
    ichacha: br_chacha20_run = null,
    ipoly: br_poly1305_run = null,
    icbc_in: [*c]const br_sslrec_in_cbc_class = null,
    icbc_out: [*c]const br_sslrec_out_cbc_class = null,
    igcm_in: [*c]const br_sslrec_in_gcm_class = null,
    igcm_out: [*c]const br_sslrec_out_gcm_class = null,
    ichapol_in: [*c]const br_sslrec_in_chapol_class = null,
    ichapol_out: [*c]const br_sslrec_out_chapol_class = null,
    iccm_in: [*c]const br_sslrec_in_ccm_class = null,
    iccm_out: [*c]const br_sslrec_out_ccm_class = null,
    iec: [*c]const br_ec_impl = null,
    irsavrfy: br_rsa_pkcs1_vrfy = null,
    iecdsa: br_ecdsa_vrfy = null,
    pub const br_ssl_engine_get_flags = __root.br_ssl_engine_get_flags;
    pub const br_ssl_engine_set_all_flags = __root.br_ssl_engine_set_all_flags;
    pub const br_ssl_engine_add_flags = __root.br_ssl_engine_add_flags;
    pub const br_ssl_engine_remove_flags = __root.br_ssl_engine_remove_flags;
    pub const br_ssl_engine_set_versions = __root.br_ssl_engine_set_versions;
    pub const br_ssl_engine_set_suites = __root.br_ssl_engine_set_suites;
    pub const br_ssl_engine_set_x509 = __root.br_ssl_engine_set_x509;
    pub const br_ssl_engine_set_protocol_names = __root.br_ssl_engine_set_protocol_names;
    pub const br_ssl_engine_get_selected_protocol = __root.br_ssl_engine_get_selected_protocol;
    pub const br_ssl_engine_set_hash = __root.br_ssl_engine_set_hash;
    pub const br_ssl_engine_get_hash = __root.br_ssl_engine_get_hash;
    pub const br_ssl_engine_set_prf10 = __root.br_ssl_engine_set_prf10;
    pub const br_ssl_engine_set_prf_sha256 = __root.br_ssl_engine_set_prf_sha256;
    pub const br_ssl_engine_set_prf_sha384 = __root.br_ssl_engine_set_prf_sha384;
    pub const br_ssl_engine_set_aes_cbc = __root.br_ssl_engine_set_aes_cbc;
    pub const br_ssl_engine_set_default_aes_cbc = __root.br_ssl_engine_set_default_aes_cbc;
    pub const br_ssl_engine_set_aes_ctr = __root.br_ssl_engine_set_aes_ctr;
    pub const br_ssl_engine_set_default_aes_gcm = __root.br_ssl_engine_set_default_aes_gcm;
    pub const br_ssl_engine_set_des_cbc = __root.br_ssl_engine_set_des_cbc;
    pub const br_ssl_engine_set_default_des_cbc = __root.br_ssl_engine_set_default_des_cbc;
    pub const br_ssl_engine_set_ghash = __root.br_ssl_engine_set_ghash;
    pub const br_ssl_engine_set_chacha20 = __root.br_ssl_engine_set_chacha20;
    pub const br_ssl_engine_set_poly1305 = __root.br_ssl_engine_set_poly1305;
    pub const br_ssl_engine_set_default_chapol = __root.br_ssl_engine_set_default_chapol;
    pub const br_ssl_engine_set_aes_ctrcbc = __root.br_ssl_engine_set_aes_ctrcbc;
    pub const br_ssl_engine_set_default_aes_ccm = __root.br_ssl_engine_set_default_aes_ccm;
    pub const br_ssl_engine_set_cbc = __root.br_ssl_engine_set_cbc;
    pub const br_ssl_engine_set_gcm = __root.br_ssl_engine_set_gcm;
    pub const br_ssl_engine_set_ccm = __root.br_ssl_engine_set_ccm;
    pub const br_ssl_engine_set_chapol = __root.br_ssl_engine_set_chapol;
    pub const br_ssl_engine_set_ec = __root.br_ssl_engine_set_ec;
    pub const br_ssl_engine_set_default_ec = __root.br_ssl_engine_set_default_ec;
    pub const br_ssl_engine_get_ec = __root.br_ssl_engine_get_ec;
    pub const br_ssl_engine_set_rsavrfy = __root.br_ssl_engine_set_rsavrfy;
    pub const br_ssl_engine_set_default_rsavrfy = __root.br_ssl_engine_set_default_rsavrfy;
    pub const br_ssl_engine_get_rsavrfy = __root.br_ssl_engine_get_rsavrfy;
    pub const br_ssl_engine_set_ecdsa = __root.br_ssl_engine_set_ecdsa;
    pub const br_ssl_engine_set_default_ecdsa = __root.br_ssl_engine_set_default_ecdsa;
    pub const br_ssl_engine_get_ecdsa = __root.br_ssl_engine_get_ecdsa;
    pub const br_ssl_engine_set_buffer = __root.br_ssl_engine_set_buffer;
    pub const br_ssl_engine_set_buffers_bidi = __root.br_ssl_engine_set_buffers_bidi;
    pub const br_ssl_engine_inject_entropy = __root.br_ssl_engine_inject_entropy;
    pub const br_ssl_engine_get_server_name = __root.br_ssl_engine_get_server_name;
    pub const br_ssl_engine_get_version = __root.br_ssl_engine_get_version;
    pub const br_ssl_engine_get_session_parameters = __root.br_ssl_engine_get_session_parameters;
    pub const br_ssl_engine_set_session_parameters = __root.br_ssl_engine_set_session_parameters;
    pub const br_ssl_engine_get_ecdhe_curve = __root.br_ssl_engine_get_ecdhe_curve;
    pub const br_ssl_engine_current_state = __root.br_ssl_engine_current_state;
    pub const br_ssl_engine_last_error = __root.br_ssl_engine_last_error;
    pub const br_ssl_engine_sendapp_buf = __root.br_ssl_engine_sendapp_buf;
    pub const br_ssl_engine_sendapp_ack = __root.br_ssl_engine_sendapp_ack;
    pub const br_ssl_engine_recvapp_buf = __root.br_ssl_engine_recvapp_buf;
    pub const br_ssl_engine_recvapp_ack = __root.br_ssl_engine_recvapp_ack;
    pub const br_ssl_engine_sendrec_buf = __root.br_ssl_engine_sendrec_buf;
    pub const br_ssl_engine_sendrec_ack = __root.br_ssl_engine_sendrec_ack;
    pub const br_ssl_engine_recvrec_buf = __root.br_ssl_engine_recvrec_buf;
    pub const br_ssl_engine_recvrec_ack = __root.br_ssl_engine_recvrec_ack;
    pub const br_ssl_engine_flush = __root.br_ssl_engine_flush;
    pub const br_ssl_engine_close = __root.br_ssl_engine_close;
    pub const br_ssl_engine_renegotiate = __root.br_ssl_engine_renegotiate;
    pub const br_ssl_key_export = __root.br_ssl_key_export;
    pub const versions = __root.br_ssl_engine_set_versions;
    pub const suites = __root.br_ssl_engine_set_suites;
    pub const x509 = __root.br_ssl_engine_set_x509;
    pub const names = __root.br_ssl_engine_set_protocol_names;
    pub const protocol = __root.br_ssl_engine_get_selected_protocol;
    pub const hash = __root.br_ssl_engine_set_hash;
    pub const sha256 = __root.br_ssl_engine_set_prf_sha256;
    pub const sha384 = __root.br_ssl_engine_set_prf_sha384;
    pub const cbc = __root.br_ssl_engine_set_aes_cbc;
    pub const ctr = __root.br_ssl_engine_set_aes_ctr;
    pub const gcm = __root.br_ssl_engine_set_default_aes_gcm;
    pub const ghash = __root.br_ssl_engine_set_ghash;
    pub const chacha20 = __root.br_ssl_engine_set_chacha20;
    pub const poly1305 = __root.br_ssl_engine_set_poly1305;
    pub const chapol = __root.br_ssl_engine_set_default_chapol;
    pub const ctrcbc = __root.br_ssl_engine_set_aes_ctrcbc;
    pub const ccm = __root.br_ssl_engine_set_default_aes_ccm;
    pub const ec = __root.br_ssl_engine_set_ec;
    pub const rsavrfy = __root.br_ssl_engine_set_rsavrfy;
    pub const ecdsa = __root.br_ssl_engine_set_ecdsa;
    pub const buffer = __root.br_ssl_engine_set_buffer;
    pub const bidi = __root.br_ssl_engine_set_buffers_bidi;
    pub const entropy = __root.br_ssl_engine_inject_entropy;
    pub const name = __root.br_ssl_engine_get_server_name;
    pub const version = __root.br_ssl_engine_get_version;
    pub const parameters = __root.br_ssl_engine_get_session_parameters;
    pub const curve = __root.br_ssl_engine_get_ecdhe_curve;
    pub const state = __root.br_ssl_engine_current_state;
    pub const @"error" = __root.br_ssl_engine_last_error;
    pub const buf = __root.br_ssl_engine_sendapp_buf;
    pub const ack = __root.br_ssl_engine_sendapp_ack;
    pub const flush = __root.br_ssl_engine_flush;
    pub const close = __root.br_ssl_engine_close;
    pub const renegotiate = __root.br_ssl_engine_renegotiate;
    pub const @"export" = __root.br_ssl_key_export;
};
pub fn br_ssl_engine_get_flags(arg_cc: [*c]br_ssl_engine_context) callconv(.c) u32 {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.flags;
}
pub fn br_ssl_engine_set_all_flags(arg_cc: [*c]br_ssl_engine_context, arg_flags: u32) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var flags = arg_flags;
    _ = &flags;
    cc.*.flags = flags;
}
pub fn br_ssl_engine_add_flags(arg_cc: [*c]br_ssl_engine_context, arg_flags: u32) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var flags = arg_flags;
    _ = &flags;
    cc.*.flags |= flags;
}
pub fn br_ssl_engine_remove_flags(arg_cc: [*c]br_ssl_engine_context, arg_flags: u32) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var flags = arg_flags;
    _ = &flags;
    cc.*.flags &= ~flags;
}
pub fn br_ssl_engine_set_versions(arg_cc: [*c]br_ssl_engine_context, arg_version_min: c_uint, arg_version_max: c_uint) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var version_min = arg_version_min;
    _ = &version_min;
    var version_max = arg_version_max;
    _ = &version_max;
    cc.*.version_min = @truncate(version_min);
    cc.*.version_max = @truncate(version_max);
}
pub extern fn br_ssl_engine_set_suites(cc: [*c]br_ssl_engine_context, suites: [*c]const u16, suites_num: usize) void;
pub fn br_ssl_engine_set_x509(arg_cc: [*c]br_ssl_engine_context, arg_x509ctx: [*c][*c]const br_x509_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var x509ctx = arg_x509ctx;
    _ = &x509ctx;
    cc.*.x509ctx = x509ctx;
}
pub fn br_ssl_engine_set_protocol_names(arg_ctx: [*c]br_ssl_engine_context, arg_names: [*c][*c]const u8, arg_num: usize) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var names = arg_names;
    _ = &names;
    var num = arg_num;
    _ = &num;
    ctx.*.protocol_names = names;
    ctx.*.protocol_names_num = @truncate(num);
}
pub fn br_ssl_engine_get_selected_protocol(arg_ctx: [*c]br_ssl_engine_context) callconv(.c) [*c]const u8 {
    var ctx = arg_ctx;
    _ = &ctx;
    var k: c_uint = undefined;
    _ = &k;
    k = ctx.*.selected_protocol;
    return @ptrCast(@alignCast(if ((k == @as(c_uint, 0)) or (k == @as(c_uint, 65535))) @as(?*const anyopaque, @ptrCast(@alignCast(@as(?*anyopaque, null)))) else @as(?*const anyopaque, @ptrCast(@alignCast(ctx.*.protocol_names[k -% @as(c_uint, 1)])))));
}
pub fn br_ssl_engine_set_hash(arg_ctx: [*c]br_ssl_engine_context, arg_id: c_int, arg_impl: [*c]const br_hash_class) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var id = arg_id;
    _ = &id;
    var impl = arg_impl;
    _ = &impl;
    br_multihash_setimpl(&ctx.*.mhash, id, impl);
}
pub fn br_ssl_engine_get_hash(arg_ctx: [*c]br_ssl_engine_context, arg_id: c_int) callconv(.c) [*c]const br_hash_class {
    var ctx = arg_ctx;
    _ = &ctx;
    var id = arg_id;
    _ = &id;
    return br_multihash_getimpl(&ctx.*.mhash, id);
}
pub fn br_ssl_engine_set_prf10(arg_cc: [*c]br_ssl_engine_context, arg_impl: br_tls_prf_impl) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.prf10 = impl;
}
pub fn br_ssl_engine_set_prf_sha256(arg_cc: [*c]br_ssl_engine_context, arg_impl: br_tls_prf_impl) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.prf_sha256 = impl;
}
pub fn br_ssl_engine_set_prf_sha384(arg_cc: [*c]br_ssl_engine_context, arg_impl: br_tls_prf_impl) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.prf_sha384 = impl;
}
pub fn br_ssl_engine_set_aes_cbc(arg_cc: [*c]br_ssl_engine_context, arg_impl_enc: [*c]const br_block_cbcenc_class, arg_impl_dec: [*c]const br_block_cbcdec_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_enc = arg_impl_enc;
    _ = &impl_enc;
    var impl_dec = arg_impl_dec;
    _ = &impl_dec;
    cc.*.iaes_cbcenc = impl_enc;
    cc.*.iaes_cbcdec = impl_dec;
}
pub extern fn br_ssl_engine_set_default_aes_cbc(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_set_aes_ctr(arg_cc: [*c]br_ssl_engine_context, arg_impl: [*c]const br_block_ctr_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.iaes_ctr = impl;
}
pub extern fn br_ssl_engine_set_default_aes_gcm(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_set_des_cbc(arg_cc: [*c]br_ssl_engine_context, arg_impl_enc: [*c]const br_block_cbcenc_class, arg_impl_dec: [*c]const br_block_cbcdec_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_enc = arg_impl_enc;
    _ = &impl_enc;
    var impl_dec = arg_impl_dec;
    _ = &impl_dec;
    cc.*.ides_cbcenc = impl_enc;
    cc.*.ides_cbcdec = impl_dec;
}
pub extern fn br_ssl_engine_set_default_des_cbc(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_set_ghash(arg_cc: [*c]br_ssl_engine_context, arg_impl: br_ghash) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.ighash = impl;
}
pub fn br_ssl_engine_set_chacha20(arg_cc: [*c]br_ssl_engine_context, arg_ichacha: br_chacha20_run) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var ichacha = arg_ichacha;
    _ = &ichacha;
    cc.*.ichacha = ichacha;
}
pub fn br_ssl_engine_set_poly1305(arg_cc: [*c]br_ssl_engine_context, arg_ipoly: br_poly1305_run) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var ipoly = arg_ipoly;
    _ = &ipoly;
    cc.*.ipoly = ipoly;
}
pub extern fn br_ssl_engine_set_default_chapol(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_set_aes_ctrcbc(arg_cc: [*c]br_ssl_engine_context, arg_impl: [*c]const br_block_ctrcbc_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl = arg_impl;
    _ = &impl;
    cc.*.iaes_ctrcbc = impl;
}
pub extern fn br_ssl_engine_set_default_aes_ccm(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_set_cbc(arg_cc: [*c]br_ssl_engine_context, arg_impl_in: [*c]const br_sslrec_in_cbc_class, arg_impl_out: [*c]const br_sslrec_out_cbc_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_in = arg_impl_in;
    _ = &impl_in;
    var impl_out = arg_impl_out;
    _ = &impl_out;
    cc.*.icbc_in = impl_in;
    cc.*.icbc_out = impl_out;
}
pub fn br_ssl_engine_set_gcm(arg_cc: [*c]br_ssl_engine_context, arg_impl_in: [*c]const br_sslrec_in_gcm_class, arg_impl_out: [*c]const br_sslrec_out_gcm_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_in = arg_impl_in;
    _ = &impl_in;
    var impl_out = arg_impl_out;
    _ = &impl_out;
    cc.*.igcm_in = impl_in;
    cc.*.igcm_out = impl_out;
}
pub fn br_ssl_engine_set_ccm(arg_cc: [*c]br_ssl_engine_context, arg_impl_in: [*c]const br_sslrec_in_ccm_class, arg_impl_out: [*c]const br_sslrec_out_ccm_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_in = arg_impl_in;
    _ = &impl_in;
    var impl_out = arg_impl_out;
    _ = &impl_out;
    cc.*.iccm_in = impl_in;
    cc.*.iccm_out = impl_out;
}
pub fn br_ssl_engine_set_chapol(arg_cc: [*c]br_ssl_engine_context, arg_impl_in: [*c]const br_sslrec_in_chapol_class, arg_impl_out: [*c]const br_sslrec_out_chapol_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var impl_in = arg_impl_in;
    _ = &impl_in;
    var impl_out = arg_impl_out;
    _ = &impl_out;
    cc.*.ichapol_in = impl_in;
    cc.*.ichapol_out = impl_out;
}
pub fn br_ssl_engine_set_ec(arg_cc: [*c]br_ssl_engine_context, arg_iec: [*c]const br_ec_impl) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var iec = arg_iec;
    _ = &iec;
    cc.*.iec = iec;
}
pub extern fn br_ssl_engine_set_default_ec(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_get_ec(arg_cc: [*c]br_ssl_engine_context) callconv(.c) [*c]const br_ec_impl {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.iec;
}
pub fn br_ssl_engine_set_rsavrfy(arg_cc: [*c]br_ssl_engine_context, arg_irsavrfy: br_rsa_pkcs1_vrfy) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var irsavrfy = arg_irsavrfy;
    _ = &irsavrfy;
    cc.*.irsavrfy = irsavrfy;
}
pub extern fn br_ssl_engine_set_default_rsavrfy(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_get_rsavrfy(arg_cc: [*c]br_ssl_engine_context) callconv(.c) br_rsa_pkcs1_vrfy {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.irsavrfy;
}
pub fn br_ssl_engine_set_ecdsa(arg_cc: [*c]br_ssl_engine_context, arg_iecdsa: br_ecdsa_vrfy) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var iecdsa = arg_iecdsa;
    _ = &iecdsa;
    cc.*.iecdsa = iecdsa;
}
pub extern fn br_ssl_engine_set_default_ecdsa(cc: [*c]br_ssl_engine_context) void;
pub fn br_ssl_engine_get_ecdsa(arg_cc: [*c]br_ssl_engine_context) callconv(.c) br_ecdsa_vrfy {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.iecdsa;
}
pub extern fn br_ssl_engine_set_buffer(cc: [*c]br_ssl_engine_context, iobuf: ?*anyopaque, iobuf_len: usize, bidi: c_int) void;
pub extern fn br_ssl_engine_set_buffers_bidi(cc: [*c]br_ssl_engine_context, ibuf: ?*anyopaque, ibuf_len: usize, obuf: ?*anyopaque, obuf_len: usize) void;
pub extern fn br_ssl_engine_inject_entropy(cc: [*c]br_ssl_engine_context, data: ?*const anyopaque, len: usize) void;
pub fn br_ssl_engine_get_server_name(arg_cc: [*c]const br_ssl_engine_context) callconv(.c) [*c]const u8 {
    var cc = arg_cc;
    _ = &cc;
    return @ptrCast(@alignCast(&cc.*.server_name));
}
pub fn br_ssl_engine_get_version(arg_cc: [*c]const br_ssl_engine_context) callconv(.c) c_uint {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.session.version;
}
pub fn br_ssl_engine_get_session_parameters(arg_cc: [*c]const br_ssl_engine_context, arg_pp: [*c]br_ssl_session_parameters) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var pp = arg_pp;
    _ = &pp;
    _ = memcpy(@ptrCast(@alignCast(pp)), @ptrCast(@alignCast(&cc.*.session)), @sizeOf(@TypeOf(pp.*)));
}
pub fn br_ssl_engine_set_session_parameters(arg_cc: [*c]br_ssl_engine_context, arg_pp: [*c]const br_ssl_session_parameters) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var pp = arg_pp;
    _ = &pp;
    _ = memcpy(@ptrCast(@alignCast(&cc.*.session)), @ptrCast(@alignCast(pp)), @sizeOf(@TypeOf(pp.*)));
}
pub fn br_ssl_engine_get_ecdhe_curve(arg_cc: [*c]br_ssl_engine_context) callconv(.c) c_int {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.ecdhe_curve;
}
pub extern fn br_ssl_engine_current_state(cc: [*c]const br_ssl_engine_context) c_uint;
pub fn br_ssl_engine_last_error(arg_cc: [*c]const br_ssl_engine_context) callconv(.c) c_int {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.err;
}
pub extern fn br_ssl_engine_sendapp_buf(cc: [*c]const br_ssl_engine_context, len: [*c]usize) [*c]u8;
pub extern fn br_ssl_engine_sendapp_ack(cc: [*c]br_ssl_engine_context, len: usize) void;
pub extern fn br_ssl_engine_recvapp_buf(cc: [*c]const br_ssl_engine_context, len: [*c]usize) [*c]u8;
pub extern fn br_ssl_engine_recvapp_ack(cc: [*c]br_ssl_engine_context, len: usize) void;
pub extern fn br_ssl_engine_sendrec_buf(cc: [*c]const br_ssl_engine_context, len: [*c]usize) [*c]u8;
pub extern fn br_ssl_engine_sendrec_ack(cc: [*c]br_ssl_engine_context, len: usize) void;
pub extern fn br_ssl_engine_recvrec_buf(cc: [*c]const br_ssl_engine_context, len: [*c]usize) [*c]u8;
pub extern fn br_ssl_engine_recvrec_ack(cc: [*c]br_ssl_engine_context, len: usize) void;
pub extern fn br_ssl_engine_flush(cc: [*c]br_ssl_engine_context, force: c_int) void;
pub extern fn br_ssl_engine_close(cc: [*c]br_ssl_engine_context) void;
pub extern fn br_ssl_engine_renegotiate(cc: [*c]br_ssl_engine_context) c_int;
pub extern fn br_ssl_key_export(cc: [*c]br_ssl_engine_context, dst: ?*anyopaque, len: usize, label: [*c]const u8, context: ?*const anyopaque, context_len: usize) c_int;
pub const br_ssl_client_context = struct_br_ssl_client_context_;
pub const struct_br_ssl_client_certificate_class_ = extern struct {
    context_size: usize = 0,
    start_name_list: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class) callconv(.c) void = null,
    start_name: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class, len: usize) callconv(.c) void = null,
    append_name: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class, data: [*c]const u8, len: usize) callconv(.c) void = null,
    end_name: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class) callconv(.c) void = null,
    end_name_list: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class) callconv(.c) void = null,
    choose: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class, cc: [*c]const br_ssl_client_context, auth_types: u32, choices: [*c]br_ssl_client_certificate) callconv(.c) void = null,
    do_keyx: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class, data: [*c]u8, len: [*c]usize) callconv(.c) u32 = null,
    do_sign: ?*const fn (pctx: [*c][*c]const br_ssl_client_certificate_class, hash_id: c_int, hv_len: usize, data: [*c]u8, len: usize) callconv(.c) usize = null,
};
pub const br_ssl_client_certificate_class = struct_br_ssl_client_certificate_class_;
const union_unnamed_25 = extern union {
    vtable: [*c]const br_ssl_client_certificate_class,
    single_rsa: br_ssl_client_certificate_rsa_context,
    single_ec: br_ssl_client_certificate_ec_context,
};
pub const struct_br_ssl_client_context_ = extern struct {
    eng: br_ssl_engine_context = @import("std").mem.zeroes(br_ssl_engine_context),
    min_clienthello_len: u16 = 0,
    hashes: u32 = 0,
    server_curve: c_int = 0,
    client_auth_vtable: [*c][*c]const br_ssl_client_certificate_class = null,
    auth_type: u8 = 0,
    hash_id: u8 = 0,
    client_auth: union_unnamed_25 = @import("std").mem.zeroes(union_unnamed_25),
    irsapub: br_rsa_public = null,
    pub const br_ssl_client_get_server_hashes = __root.br_ssl_client_get_server_hashes;
    pub const br_ssl_client_get_server_curve = __root.br_ssl_client_get_server_curve;
    pub const br_ssl_client_init_full = __root.br_ssl_client_init_full;
    pub const br_ssl_client_zero = __root.br_ssl_client_zero;
    pub const br_ssl_client_set_client_certificate = __root.br_ssl_client_set_client_certificate;
    pub const br_ssl_client_set_rsapub = __root.br_ssl_client_set_rsapub;
    pub const br_ssl_client_set_default_rsapub = __root.br_ssl_client_set_default_rsapub;
    pub const br_ssl_client_set_min_clienthello_len = __root.br_ssl_client_set_min_clienthello_len;
    pub const br_ssl_client_reset = __root.br_ssl_client_reset;
    pub const br_ssl_client_forget_session = __root.br_ssl_client_forget_session;
    pub const br_ssl_client_set_single_rsa = __root.br_ssl_client_set_single_rsa;
    pub const br_ssl_client_set_single_ec = __root.br_ssl_client_set_single_ec;
    pub const curve = __root.br_ssl_client_get_server_curve;
    pub const full = __root.br_ssl_client_init_full;
    pub const zero = __root.br_ssl_client_zero;
    pub const certificate = __root.br_ssl_client_set_client_certificate;
    pub const rsapub = __root.br_ssl_client_set_rsapub;
    pub const len = __root.br_ssl_client_set_min_clienthello_len;
    pub const reset = __root.br_ssl_client_reset;
    pub const session = __root.br_ssl_client_forget_session;
    pub const rsa = __root.br_ssl_client_set_single_rsa;
    pub const ec = __root.br_ssl_client_set_single_ec;
};
pub const br_ssl_client_certificate = extern struct {
    auth_type: c_int = 0,
    hash_id: c_int = 0,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
};
pub const br_ssl_client_certificate_rsa_context = extern struct {
    vtable: [*c]const br_ssl_client_certificate_class = null,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
    sk: [*c]const br_rsa_private_key = null,
    irsasign: br_rsa_pkcs1_sign = null,
};
pub const br_ssl_client_certificate_ec_context = extern struct {
    vtable: [*c]const br_ssl_client_certificate_class = null,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
    sk: [*c]const br_ec_private_key = null,
    allowed_usages: c_uint = 0,
    issuer_key_type: c_uint = 0,
    mhash: [*c]const br_multihash_context = null,
    iec: [*c]const br_ec_impl = null,
    iecdsa: br_ecdsa_sign = null,
};
pub fn br_ssl_client_get_server_hashes(arg_cc: [*c]const br_ssl_client_context) callconv(.c) u32 {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.hashes;
}
pub fn br_ssl_client_get_server_curve(arg_cc: [*c]const br_ssl_client_context) callconv(.c) c_int {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.server_curve;
}
pub extern fn br_ssl_client_init_full(cc: [*c]br_ssl_client_context, xc: [*c]br_x509_minimal_context, trust_anchors: [*c]const br_x509_trust_anchor, trust_anchors_num: usize) void;
pub extern fn br_ssl_client_zero(cc: [*c]br_ssl_client_context) void;
pub fn br_ssl_client_set_client_certificate(arg_cc: [*c]br_ssl_client_context, arg_pctx: [*c][*c]const br_ssl_client_certificate_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var pctx = arg_pctx;
    _ = &pctx;
    cc.*.client_auth_vtable = pctx;
}
pub fn br_ssl_client_set_rsapub(arg_cc: [*c]br_ssl_client_context, arg_irsapub: br_rsa_public) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var irsapub = arg_irsapub;
    _ = &irsapub;
    cc.*.irsapub = irsapub;
}
pub extern fn br_ssl_client_set_default_rsapub(cc: [*c]br_ssl_client_context) void;
pub fn br_ssl_client_set_min_clienthello_len(arg_cc: [*c]br_ssl_client_context, arg_len: u16) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var len = arg_len;
    _ = &len;
    cc.*.min_clienthello_len = len;
}
pub extern fn br_ssl_client_reset(cc: [*c]br_ssl_client_context, server_name: [*c]const u8, resume_session: c_int) c_int;
pub fn br_ssl_client_forget_session(arg_cc: [*c]br_ssl_client_context) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    cc.*.eng.session.session_id_len = 0;
}
pub extern fn br_ssl_client_set_single_rsa(cc: [*c]br_ssl_client_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key, irsasign: br_rsa_pkcs1_sign) void;
pub extern fn br_ssl_client_set_single_ec(cc: [*c]br_ssl_client_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key, allowed_usages: c_uint, cert_issuer_key_type: c_uint, iec: [*c]const br_ec_impl, iecdsa: br_ecdsa_sign) void;
pub const br_suite_translated = [2]u16;
pub const br_ssl_server_context = struct_br_ssl_server_context_;
pub const struct_br_ssl_session_cache_class_ = extern struct {
    context_size: usize = 0,
    save: ?*const fn (ctx: [*c][*c]const br_ssl_session_cache_class, server_ctx: [*c]br_ssl_server_context, params: [*c]const br_ssl_session_parameters) callconv(.c) void = null,
    load: ?*const fn (ctx: [*c][*c]const br_ssl_session_cache_class, server_ctx: [*c]br_ssl_server_context, params: [*c]br_ssl_session_parameters) callconv(.c) c_int = null,
};
pub const br_ssl_session_cache_class = struct_br_ssl_session_cache_class_;
pub const struct_br_ssl_server_policy_class_ = extern struct {
    context_size: usize = 0,
    choose: ?*const fn (pctx: [*c][*c]const br_ssl_server_policy_class, cc: [*c]const br_ssl_server_context, choices: [*c]br_ssl_server_choices) callconv(.c) c_int = null,
    do_keyx: ?*const fn (pctx: [*c][*c]const br_ssl_server_policy_class, data: [*c]u8, len: [*c]usize) callconv(.c) u32 = null,
    do_sign: ?*const fn (pctx: [*c][*c]const br_ssl_server_policy_class, algo_id: c_uint, data: [*c]u8, hv_len: usize, len: usize) callconv(.c) usize = null,
};
pub const br_ssl_server_policy_class = struct_br_ssl_server_policy_class_;
const union_unnamed_26 = extern union {
    vtable: [*c]const br_ssl_server_policy_class,
    single_rsa: br_ssl_server_policy_rsa_context,
    single_ec: br_ssl_server_policy_ec_context,
};
pub const struct_br_ssl_server_context_ = extern struct {
    eng: br_ssl_engine_context = @import("std").mem.zeroes(br_ssl_engine_context),
    client_max_version: u16 = 0,
    cache_vtable: [*c][*c]const br_ssl_session_cache_class = null,
    client_suites: [48]br_suite_translated = @import("std").mem.zeroes([48]br_suite_translated),
    client_suites_num: u8 = 0,
    hashes: u32 = 0,
    curves: u32 = 0,
    policy_vtable: [*c][*c]const br_ssl_server_policy_class = null,
    sign_hash_id: u16 = 0,
    chain_handler: union_unnamed_26 = @import("std").mem.zeroes(union_unnamed_26),
    ecdhe_key: [70]u8 = @import("std").mem.zeroes([70]u8),
    ecdhe_key_len: usize = 0,
    ta_names: [*c]const br_x500_name = null,
    tas: [*c]const br_x509_trust_anchor = null,
    num_tas: usize = 0,
    cur_dn_index: usize = 0,
    cur_dn: [*c]const u8 = null,
    cur_dn_len: usize = 0,
    hash_CV: [64]u8 = @import("std").mem.zeroes([64]u8),
    hash_CV_len: usize = 0,
    hash_CV_id: c_int = 0,
    pub const br_ssl_server_init_full_rsa = __root.br_ssl_server_init_full_rsa;
    pub const br_ssl_server_init_full_ec = __root.br_ssl_server_init_full_ec;
    pub const br_ssl_server_init_minr2g = __root.br_ssl_server_init_minr2g;
    pub const br_ssl_server_init_mine2g = __root.br_ssl_server_init_mine2g;
    pub const br_ssl_server_init_minf2g = __root.br_ssl_server_init_minf2g;
    pub const br_ssl_server_init_minu2g = __root.br_ssl_server_init_minu2g;
    pub const br_ssl_server_init_minv2g = __root.br_ssl_server_init_minv2g;
    pub const br_ssl_server_init_mine2c = __root.br_ssl_server_init_mine2c;
    pub const br_ssl_server_init_minf2c = __root.br_ssl_server_init_minf2c;
    pub const br_ssl_server_get_client_suites = __root.br_ssl_server_get_client_suites;
    pub const br_ssl_server_get_client_hashes = __root.br_ssl_server_get_client_hashes;
    pub const br_ssl_server_get_client_curves = __root.br_ssl_server_get_client_curves;
    pub const br_ssl_server_zero = __root.br_ssl_server_zero;
    pub const br_ssl_server_set_policy = __root.br_ssl_server_set_policy;
    pub const br_ssl_server_set_single_rsa = __root.br_ssl_server_set_single_rsa;
    pub const br_ssl_server_set_single_ec = __root.br_ssl_server_set_single_ec;
    pub const br_ssl_server_set_trust_anchor_names = __root.br_ssl_server_set_trust_anchor_names;
    pub const br_ssl_server_set_trust_anchor_names_alt = __root.br_ssl_server_set_trust_anchor_names_alt;
    pub const br_ssl_server_set_cache = __root.br_ssl_server_set_cache;
    pub const br_ssl_server_reset = __root.br_ssl_server_reset;
    pub const rsa = __root.br_ssl_server_init_full_rsa;
    pub const ec = __root.br_ssl_server_init_full_ec;
    pub const minr2g = __root.br_ssl_server_init_minr2g;
    pub const mine2g = __root.br_ssl_server_init_mine2g;
    pub const minf2g = __root.br_ssl_server_init_minf2g;
    pub const minu2g = __root.br_ssl_server_init_minu2g;
    pub const minv2g = __root.br_ssl_server_init_minv2g;
    pub const mine2c = __root.br_ssl_server_init_mine2c;
    pub const minf2c = __root.br_ssl_server_init_minf2c;
    pub const suites = __root.br_ssl_server_get_client_suites;
    pub const zero = __root.br_ssl_server_zero;
    pub const policy = __root.br_ssl_server_set_policy;
    pub const names = __root.br_ssl_server_set_trust_anchor_names;
    pub const alt = __root.br_ssl_server_set_trust_anchor_names_alt;
    pub const cache = __root.br_ssl_server_set_cache;
    pub const reset = __root.br_ssl_server_reset;
};
pub const br_ssl_server_choices = extern struct {
    cipher_suite: u16 = 0,
    algo_id: c_uint = 0,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
};
pub const br_ssl_server_policy_rsa_context = extern struct {
    vtable: [*c]const br_ssl_server_policy_class = null,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
    sk: [*c]const br_rsa_private_key = null,
    allowed_usages: c_uint = 0,
    irsacore: br_rsa_private = null,
    irsasign: br_rsa_pkcs1_sign = null,
};
pub const br_ssl_server_policy_ec_context = extern struct {
    vtable: [*c]const br_ssl_server_policy_class = null,
    chain: [*c]const br_x509_certificate = null,
    chain_len: usize = 0,
    sk: [*c]const br_ec_private_key = null,
    allowed_usages: c_uint = 0,
    cert_issuer_key_type: c_uint = 0,
    mhash: [*c]const br_multihash_context = null,
    iec: [*c]const br_ec_impl = null,
    iecdsa: br_ecdsa_sign = null,
};
pub const br_ssl_session_cache_lru = extern struct {
    vtable: [*c]const br_ssl_session_cache_class = null,
    store: [*c]u8 = null,
    store_len: usize = 0,
    store_ptr: usize = 0,
    index_key: [32]u8 = @import("std").mem.zeroes([32]u8),
    hash: [*c]const br_hash_class = null,
    init_done: c_int = 0,
    head: u32 = 0,
    tail: u32 = 0,
    root: u32 = 0,
    pub const br_ssl_session_cache_lru_init = __root.br_ssl_session_cache_lru_init;
    pub const br_ssl_session_cache_lru_forget = __root.br_ssl_session_cache_lru_forget;
    pub const init = __root.br_ssl_session_cache_lru_init;
    pub const forget = __root.br_ssl_session_cache_lru_forget;
};
pub extern fn br_ssl_session_cache_lru_init(cc: [*c]br_ssl_session_cache_lru, store: [*c]u8, store_len: usize) void;
pub extern fn br_ssl_session_cache_lru_forget(cc: [*c]br_ssl_session_cache_lru, id: [*c]const u8) void;
pub extern fn br_ssl_server_init_full_rsa(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key) void;
pub extern fn br_ssl_server_init_full_ec(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, cert_issuer_key_type: c_uint, sk: [*c]const br_ec_private_key) void;
pub extern fn br_ssl_server_init_minr2g(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key) void;
pub extern fn br_ssl_server_init_mine2g(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key) void;
pub extern fn br_ssl_server_init_minf2g(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key) void;
pub extern fn br_ssl_server_init_minu2g(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key) void;
pub extern fn br_ssl_server_init_minv2g(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key) void;
pub extern fn br_ssl_server_init_mine2c(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key) void;
pub extern fn br_ssl_server_init_minf2c(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key) void;
pub fn br_ssl_server_get_client_suites(arg_cc: [*c]const br_ssl_server_context, arg_num: [*c]usize) callconv(.c) [*c]const br_suite_translated {
    var cc = arg_cc;
    _ = &cc;
    var num = arg_num;
    _ = &num;
    num.* = cc.*.client_suites_num;
    return @ptrCast(@alignCast(&cc.*.client_suites));
}
pub fn br_ssl_server_get_client_hashes(arg_cc: [*c]const br_ssl_server_context) callconv(.c) u32 {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.hashes;
}
pub fn br_ssl_server_get_client_curves(arg_cc: [*c]const br_ssl_server_context) callconv(.c) u32 {
    var cc = arg_cc;
    _ = &cc;
    return cc.*.curves;
}
pub extern fn br_ssl_server_zero(cc: [*c]br_ssl_server_context) void;
pub fn br_ssl_server_set_policy(arg_cc: [*c]br_ssl_server_context, arg_pctx: [*c][*c]const br_ssl_server_policy_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var pctx = arg_pctx;
    _ = &pctx;
    cc.*.policy_vtable = pctx;
}
pub extern fn br_ssl_server_set_single_rsa(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_rsa_private_key, allowed_usages: c_uint, irsacore: br_rsa_private, irsasign: br_rsa_pkcs1_sign) void;
pub extern fn br_ssl_server_set_single_ec(cc: [*c]br_ssl_server_context, chain: [*c]const br_x509_certificate, chain_len: usize, sk: [*c]const br_ec_private_key, allowed_usages: c_uint, cert_issuer_key_type: c_uint, iec: [*c]const br_ec_impl, iecdsa: br_ecdsa_sign) void;
pub fn br_ssl_server_set_trust_anchor_names(arg_cc: [*c]br_ssl_server_context, arg_ta_names: [*c]const br_x500_name, arg_num: usize) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var ta_names = arg_ta_names;
    _ = &ta_names;
    var num = arg_num;
    _ = &num;
    cc.*.ta_names = ta_names;
    cc.*.tas = null;
    cc.*.num_tas = num;
}
pub fn br_ssl_server_set_trust_anchor_names_alt(arg_cc: [*c]br_ssl_server_context, arg_tas: [*c]const br_x509_trust_anchor, arg_num: usize) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var tas = arg_tas;
    _ = &tas;
    var num = arg_num;
    _ = &num;
    cc.*.ta_names = null;
    cc.*.tas = tas;
    cc.*.num_tas = num;
}
pub fn br_ssl_server_set_cache(arg_cc: [*c]br_ssl_server_context, arg_vtable: [*c][*c]const br_ssl_session_cache_class) callconv(.c) void {
    var cc = arg_cc;
    _ = &cc;
    var vtable = arg_vtable;
    _ = &vtable;
    cc.*.cache_vtable = vtable;
}
pub extern fn br_ssl_server_reset(cc: [*c]br_ssl_server_context) c_int;
pub const br_sslio_context = extern struct {
    engine: [*c]br_ssl_engine_context = null,
    low_read: ?*const fn (read_context: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) c_int = null,
    read_context: ?*anyopaque = null,
    low_write: ?*const fn (write_context: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) c_int = null,
    write_context: ?*anyopaque = null,
    pub const br_sslio_init = __root.br_sslio_init;
    pub const br_sslio_read = __root.br_sslio_read;
    pub const br_sslio_read_all = __root.br_sslio_read_all;
    pub const br_sslio_write = __root.br_sslio_write;
    pub const br_sslio_write_all = __root.br_sslio_write_all;
    pub const br_sslio_flush = __root.br_sslio_flush;
    pub const br_sslio_close = __root.br_sslio_close;
    pub const init = __root.br_sslio_init;
    pub const read = __root.br_sslio_read;
    pub const all = __root.br_sslio_read_all;
    pub const write = __root.br_sslio_write;
    pub const flush = __root.br_sslio_flush;
    pub const close = __root.br_sslio_close;
};
pub extern fn br_sslio_init(ctx: [*c]br_sslio_context, engine: [*c]br_ssl_engine_context, low_read: ?*const fn (read_context: ?*anyopaque, data: [*c]u8, len: usize) callconv(.c) c_int, read_context: ?*anyopaque, low_write: ?*const fn (write_context: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) c_int, write_context: ?*anyopaque) void;
pub extern fn br_sslio_read(cc: [*c]br_sslio_context, dst: ?*anyopaque, len: usize) c_int;
pub extern fn br_sslio_read_all(cc: [*c]br_sslio_context, dst: ?*anyopaque, len: usize) c_int;
pub extern fn br_sslio_write(cc: [*c]br_sslio_context, src: ?*const anyopaque, len: usize) c_int;
pub extern fn br_sslio_write_all(cc: [*c]br_sslio_context, src: ?*const anyopaque, len: usize) c_int;
pub extern fn br_sslio_flush(cc: [*c]br_sslio_context) c_int;
pub extern fn br_sslio_close(cc: [*c]br_sslio_context) c_int;
const struct_unnamed_27 = extern struct {
    dp: [*c]u32 = null,
    rp: [*c]u32 = null,
    ip: [*c]const u8 = null,
};
pub const br_pem_decoder_context = extern struct {
    cpu: struct_unnamed_27 = @import("std").mem.zeroes(struct_unnamed_27),
    dp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    rp_stack: [32]u32 = @import("std").mem.zeroes([32]u32),
    err: c_int = 0,
    hbuf: [*c]const u8 = null,
    hlen: usize = 0,
    dest: ?*const fn (dest_ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void = null,
    dest_ctx: ?*anyopaque = null,
    event: u8 = 0,
    name: [128]u8 = @import("std").mem.zeroes([128]u8),
    buf: [255]u8 = @import("std").mem.zeroes([255]u8),
    ptr: usize = 0,
    pub const br_pem_decoder_init = __root.br_pem_decoder_init;
    pub const br_pem_decoder_push = __root.br_pem_decoder_push;
    pub const br_pem_decoder_setdest = __root.br_pem_decoder_setdest;
    pub const br_pem_decoder_event = __root.br_pem_decoder_event;
    pub const br_pem_decoder_name = __root.br_pem_decoder_name;
    pub const init = __root.br_pem_decoder_init;
    pub const push = __root.br_pem_decoder_push;
    pub const setdest = __root.br_pem_decoder_setdest;
};
pub extern fn br_pem_decoder_init(ctx: [*c]br_pem_decoder_context) void;
pub extern fn br_pem_decoder_push(ctx: [*c]br_pem_decoder_context, data: ?*const anyopaque, len: usize) usize;
pub fn br_pem_decoder_setdest(arg_ctx: [*c]br_pem_decoder_context, arg_dest: ?*const fn (dest_ctx: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void, arg_dest_ctx: ?*anyopaque) callconv(.c) void {
    var ctx = arg_ctx;
    _ = &ctx;
    var dest = arg_dest;
    _ = &dest;
    var dest_ctx = arg_dest_ctx;
    _ = &dest_ctx;
    ctx.*.dest = dest;
    ctx.*.dest_ctx = dest_ctx;
}
pub extern fn br_pem_decoder_event(ctx: [*c]br_pem_decoder_context) c_int;
pub fn br_pem_decoder_name(arg_ctx: [*c]br_pem_decoder_context) callconv(.c) [*c]const u8 {
    var ctx = arg_ctx;
    _ = &ctx;
    return @ptrCast(@alignCast(&ctx.*.name));
}
pub extern fn br_pem_encode(dest: ?*anyopaque, data: ?*const anyopaque, len: usize, banner: [*c]const u8, flags: c_uint) usize;
pub const br_config_option = extern struct {
    name: [*c]const u8 = null,
    value: c_long = 0,
};
pub extern fn br_get_config() [*c]const br_config_option;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 0);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 4);
pub const __GNUC_MINOR__ = @as(c_int, 2);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 1);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_CLANG__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const __OPTIMIZE__ = @as(c_int, 1);
pub const __OPTIMIZE_SIZE__ = @as(c_int, 1);
pub const __arm__ = @as(c_int, 1);
pub const __arm = @as(c_int, 1);
pub const __thumb__ = @as(c_int, 1);
pub const _ILP32 = @as(c_int, 1);
pub const __ILP32__ = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ELF__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __CHAR_UNSIGNED__ = @as(c_int, 1);
pub const __WCHAR_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = @as(c_long, 2147483647);
pub const __LONG_WIDTH__ = @as(c_int, 32);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 32);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 32);
pub const __INTMAX_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __SIZE_WIDTH__ = @as(c_int, 32);
pub const __UINTMAX_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 32);
pub const __INTPTR_MAX__ = @as(c_long, 2147483647);
pub const __INTPTR_WIDTH__ = @as(c_int, 32);
pub const __UINTPTR_MAX__ = @as(c_ulong, 4294967295);
pub const __UINTPTR_WIDTH__ = @as(c_int, 32);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 4);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 4);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 4);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 4);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 4);
pub const __SIZEOF_WINT_T__ = @as(c_int, 4);
pub const __INTPTR_TYPE__ = c_long;
pub const __UINTPTR_TYPE__ = c_ulong;
pub const __INTMAX_TYPE__ = c_longlong;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`"); // <builtin>:98:9
pub const __INTMAX_C = __helpers.L_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulonglong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`"); // <builtin>:101:9
pub const __UINTMAX_C = __helpers.UL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_int;
pub const __SIZE_TYPE__ = c_uint;
pub const __WCHAR_TYPE__ = c_uint;
pub const __WINT_TYPE__ = c_int;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_longlong;
pub const __INT64_FMTd__ = "lld";
pub const __INT64_FMTi__ = "lli";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`"); // <builtin>:127:9
pub const __INT64_C = __helpers.LL_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`"); // <builtin>:152:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulonglong;
pub const __UINT64_FMTo__ = "llo";
pub const __UINT64_FMTu__ = "llu";
pub const __UINT64_FMTx__ = "llx";
pub const __UINT64_FMTX__ = "llX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`"); // <builtin>:161:9
pub const __UINT64_C = __helpers.ULL_SUFFIX;
pub const __UINT64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __INT64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_longlong;
pub const __INT_LEAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "lld";
pub const INT_LEAST64_FMTi__ = "lli";
pub const __UINT_LEAST64_TYPE__ = c_ulonglong;
pub const __UINT_LEAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_LEAST64_FMTo__ = "llo";
pub const UINT_LEAST64_FMTu__ = "llu";
pub const UINT_LEAST64_FMTx__ = "llx";
pub const UINT_LEAST64_FMTX__ = "llX";
pub const __INT_FAST64_TYPE__ = c_longlong;
pub const __INT_FAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "lld";
pub const INT_FAST64_FMTi__ = "lli";
pub const __UINT_FAST64_TYPE__ = c_ulonglong;
pub const __UINT_FAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_FAST64_FMTo__ = "llo";
pub const UINT_FAST64_FMTu__ = "llu";
pub const UINT_FAST64_FMTx__ = "llx";
pub const UINT_FAST64_FMTX__ = "llX";
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 4.9406564584124654e-324);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 15);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 2.2204460492503131e-16);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 53);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __LDBL_MAX_EXP__ = @as(c_int, 1024);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.7976931348623157e+308);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __LDBL_MIN__ = @as(c_longdouble, 2.2250738585072014e-308);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const NDEBUG = @as(c_int, 1);
pub const BR_BEARSSL_H__ = "";
pub const _RIP_STDDEF_H = "";
pub const NULL = __helpers.cast(?*anyopaque, @as(c_int, 0));
pub const offsetof = @compileError("unable to translate macro: undefined identifier `__builtin_offsetof`"); // /Users/shreeve/Data/Code/pico/src/libc/stddef.h:12:9
pub const _RIP_STDINT_H = "";
pub const INT8_MIN = -@as(c_int, 128);
pub const INT8_MAX = @as(c_int, 127);
pub const INT16_MIN = -__helpers.promoteIntLiteral(c_int, 32768, .decimal);
pub const INT16_MAX = @as(c_int, 32767);
pub const INT32_MIN = -__helpers.promoteIntLiteral(c_int, 2147483647, .decimal) - @as(c_int, 1);
pub const INT32_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const INT64_MIN = -@as(c_longlong, 9223372036854775807) - @as(c_int, 1);
pub const INT64_MAX = @as(c_longlong, 9223372036854775807);
pub const UINT8_MAX = @as(c_uint, 255);
pub const UINT16_MAX = @as(c_uint, 65535);
pub const UINT32_MAX = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT64_MAX = @as(c_ulonglong, 18446744073709551615);
pub const INTPTR_MAX = __INTPTR_MAX__;
pub const UINTPTR_MAX = __UINTPTR_MAX__;
pub const SIZE_MAX = __SIZE_MAX__;
pub const INT64_C = __helpers.LL_SUFFIX;
pub const UINT64_C = __helpers.ULL_SUFFIX;
pub const BR_BEARSSL_HASH_H__ = "";
pub const _RIP_STRING_H = "";
pub inline fn BR_HASHDESC_ID(id: anytype) @TypeOf(__helpers.cast(u32, id) << BR_HASHDESC_ID_OFF) {
    _ = &id;
    return __helpers.cast(u32, id) << BR_HASHDESC_ID_OFF;
}
pub const BR_HASHDESC_ID_OFF = @as(c_int, 0);
pub const BR_HASHDESC_ID_MASK = @as(c_int, 0xFF);
pub inline fn BR_HASHDESC_OUT(size: anytype) @TypeOf(__helpers.cast(u32, size) << BR_HASHDESC_OUT_OFF) {
    _ = &size;
    return __helpers.cast(u32, size) << BR_HASHDESC_OUT_OFF;
}
pub const BR_HASHDESC_OUT_OFF = @as(c_int, 8);
pub const BR_HASHDESC_OUT_MASK = @as(c_int, 0x7F);
pub inline fn BR_HASHDESC_STATE(size: anytype) @TypeOf(__helpers.cast(u32, size) << BR_HASHDESC_STATE_OFF) {
    _ = &size;
    return __helpers.cast(u32, size) << BR_HASHDESC_STATE_OFF;
}
pub const BR_HASHDESC_STATE_OFF = @as(c_int, 15);
pub const BR_HASHDESC_STATE_MASK = @as(c_int, 0xFF);
pub inline fn BR_HASHDESC_LBLEN(ls: anytype) @TypeOf(__helpers.cast(u32, ls) << BR_HASHDESC_LBLEN_OFF) {
    _ = &ls;
    return __helpers.cast(u32, ls) << BR_HASHDESC_LBLEN_OFF;
}
pub const BR_HASHDESC_LBLEN_OFF = @as(c_int, 23);
pub const BR_HASHDESC_LBLEN_MASK = @as(c_int, 0x0F);
pub const BR_HASHDESC_MD_PADDING = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 28);
pub const BR_HASHDESC_MD_PADDING_128 = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 29);
pub const BR_HASHDESC_MD_PADDING_BE = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 30);
pub const br_md5_ID = @as(c_int, 1);
pub const br_md5_SIZE = @as(c_int, 16);
pub const br_sha1_ID = @as(c_int, 2);
pub const br_sha1_SIZE = @as(c_int, 20);
pub const br_sha224_ID = @as(c_int, 3);
pub const br_sha224_SIZE = @as(c_int, 28);
pub const br_sha256_ID = @as(c_int, 4);
pub const br_sha256_SIZE = @as(c_int, 32);
pub const br_sha256_update = br_sha224_update;
pub const br_sha256_state = br_sha224_state;
pub const br_sha256_set_state = br_sha224_set_state;
pub const br_sha384_ID = @as(c_int, 5);
pub const br_sha384_SIZE = @as(c_int, 48);
pub const br_sha512_ID = @as(c_int, 6);
pub const br_sha512_SIZE = @as(c_int, 64);
pub const br_sha512_update = br_sha384_update;
pub const br_sha512_state = br_sha384_state;
pub const br_sha512_set_state = br_sha384_set_state;
pub const br_md5sha1_ID = @as(c_int, 0);
pub const br_md5sha1_SIZE = @as(c_int, 36);
pub const BR_BEARSSL_HMAC_H__ = "";
pub const BR_BEARSSL_KDF_H__ = "";
pub const BR_HKDF_NO_SALT = &br_hkdf_no_salt;
pub const BR_BEARSSL_RAND_H__ = "";
pub const BR_BEARSSL_BLOCK_H__ = "";
pub const br_aes_big_BLOCK_SIZE = @as(c_int, 16);
pub const br_aes_small_BLOCK_SIZE = @as(c_int, 16);
pub const br_aes_ct_BLOCK_SIZE = @as(c_int, 16);
pub const br_aes_ct64_BLOCK_SIZE = @as(c_int, 16);
pub const br_aes_x86ni_BLOCK_SIZE = @as(c_int, 16);
pub const br_aes_pwr8_BLOCK_SIZE = @as(c_int, 16);
pub const br_des_tab_BLOCK_SIZE = @as(c_int, 8);
pub const br_des_ct_BLOCK_SIZE = @as(c_int, 8);
pub const BR_BEARSSL_PRF_H__ = "";
pub const BR_BEARSSL_AEAD_H__ = "";
pub const BR_BEARSSL_RSA_H__ = "";
pub const BR_HASH_OID_SHA1 = @compileError("unable to translate C expr: unexpected token 'const'"); // /Users/shreeve/Data/Code/pico/ext/bearssl/inc/bearssl_rsa.h:488:9
pub const BR_HASH_OID_SHA224 = @compileError("unable to translate C expr: unexpected token 'const'"); // /Users/shreeve/Data/Code/pico/ext/bearssl/inc/bearssl_rsa.h:494:9
pub const BR_HASH_OID_SHA256 = @compileError("unable to translate C expr: unexpected token 'const'"); // /Users/shreeve/Data/Code/pico/ext/bearssl/inc/bearssl_rsa.h:500:9
pub const BR_HASH_OID_SHA384 = @compileError("unable to translate C expr: unexpected token 'const'"); // /Users/shreeve/Data/Code/pico/ext/bearssl/inc/bearssl_rsa.h:506:9
pub const BR_HASH_OID_SHA512 = @compileError("unable to translate C expr: unexpected token 'const'"); // /Users/shreeve/Data/Code/pico/ext/bearssl/inc/bearssl_rsa.h:512:9
pub inline fn BR_RSA_KBUF_PRIV_SIZE(size: anytype) @TypeOf(@as(c_int, 5) * ((size + @as(c_int, 15)) >> @as(c_int, 4))) {
    _ = &size;
    return @as(c_int, 5) * ((size + @as(c_int, 15)) >> @as(c_int, 4));
}
pub inline fn BR_RSA_KBUF_PUB_SIZE(size: anytype) @TypeOf(@as(c_int, 4) + ((size + @as(c_int, 7)) >> @as(c_int, 3))) {
    _ = &size;
    return @as(c_int, 4) + ((size + @as(c_int, 7)) >> @as(c_int, 3));
}
pub const BR_BEARSSL_EC_H__ = "";
pub const BR_EC_sect163k1 = @as(c_int, 1);
pub const BR_EC_sect163r1 = @as(c_int, 2);
pub const BR_EC_sect163r2 = @as(c_int, 3);
pub const BR_EC_sect193r1 = @as(c_int, 4);
pub const BR_EC_sect193r2 = @as(c_int, 5);
pub const BR_EC_sect233k1 = @as(c_int, 6);
pub const BR_EC_sect233r1 = @as(c_int, 7);
pub const BR_EC_sect239k1 = @as(c_int, 8);
pub const BR_EC_sect283k1 = @as(c_int, 9);
pub const BR_EC_sect283r1 = @as(c_int, 10);
pub const BR_EC_sect409k1 = @as(c_int, 11);
pub const BR_EC_sect409r1 = @as(c_int, 12);
pub const BR_EC_sect571k1 = @as(c_int, 13);
pub const BR_EC_sect571r1 = @as(c_int, 14);
pub const BR_EC_secp160k1 = @as(c_int, 15);
pub const BR_EC_secp160r1 = @as(c_int, 16);
pub const BR_EC_secp160r2 = @as(c_int, 17);
pub const BR_EC_secp192k1 = @as(c_int, 18);
pub const BR_EC_secp192r1 = @as(c_int, 19);
pub const BR_EC_secp224k1 = @as(c_int, 20);
pub const BR_EC_secp224r1 = @as(c_int, 21);
pub const BR_EC_secp256k1 = @as(c_int, 22);
pub const BR_EC_secp256r1 = @as(c_int, 23);
pub const BR_EC_secp384r1 = @as(c_int, 24);
pub const BR_EC_secp521r1 = @as(c_int, 25);
pub const BR_EC_brainpoolP256r1 = @as(c_int, 26);
pub const BR_EC_brainpoolP384r1 = @as(c_int, 27);
pub const BR_EC_brainpoolP512r1 = @as(c_int, 28);
pub const BR_EC_curve25519 = @as(c_int, 29);
pub const BR_EC_curve448 = @as(c_int, 30);
pub const BR_EC_KBUF_PRIV_MAX_SIZE = @as(c_int, 72);
pub const BR_EC_KBUF_PUB_MAX_SIZE = @as(c_int, 145);
pub const BR_BEARSSL_SSL_H__ = "";
pub const BR_BEARSSL_X509_H__ = "";
pub const BR_ERR_X509_OK = @as(c_int, 32);
pub const BR_ERR_X509_INVALID_VALUE = @as(c_int, 33);
pub const BR_ERR_X509_TRUNCATED = @as(c_int, 34);
pub const BR_ERR_X509_EMPTY_CHAIN = @as(c_int, 35);
pub const BR_ERR_X509_INNER_TRUNC = @as(c_int, 36);
pub const BR_ERR_X509_BAD_TAG_CLASS = @as(c_int, 37);
pub const BR_ERR_X509_BAD_TAG_VALUE = @as(c_int, 38);
pub const BR_ERR_X509_INDEFINITE_LENGTH = @as(c_int, 39);
pub const BR_ERR_X509_EXTRA_ELEMENT = @as(c_int, 40);
pub const BR_ERR_X509_UNEXPECTED = @as(c_int, 41);
pub const BR_ERR_X509_NOT_CONSTRUCTED = @as(c_int, 42);
pub const BR_ERR_X509_NOT_PRIMITIVE = @as(c_int, 43);
pub const BR_ERR_X509_PARTIAL_BYTE = @as(c_int, 44);
pub const BR_ERR_X509_BAD_BOOLEAN = @as(c_int, 45);
pub const BR_ERR_X509_OVERFLOW = @as(c_int, 46);
pub const BR_ERR_X509_BAD_DN = @as(c_int, 47);
pub const BR_ERR_X509_BAD_TIME = @as(c_int, 48);
pub const BR_ERR_X509_UNSUPPORTED = @as(c_int, 49);
pub const BR_ERR_X509_LIMIT_EXCEEDED = @as(c_int, 50);
pub const BR_ERR_X509_WRONG_KEY_TYPE = @as(c_int, 51);
pub const BR_ERR_X509_BAD_SIGNATURE = @as(c_int, 52);
pub const BR_ERR_X509_TIME_UNKNOWN = @as(c_int, 53);
pub const BR_ERR_X509_EXPIRED = @as(c_int, 54);
pub const BR_ERR_X509_DN_MISMATCH = @as(c_int, 55);
pub const BR_ERR_X509_BAD_SERVER_NAME = @as(c_int, 56);
pub const BR_ERR_X509_CRITICAL_EXTENSION = @as(c_int, 57);
pub const BR_ERR_X509_NOT_CA = @as(c_int, 58);
pub const BR_ERR_X509_FORBIDDEN_KEY_USAGE = @as(c_int, 59);
pub const BR_ERR_X509_WEAK_PUBLIC_KEY = @as(c_int, 60);
pub const BR_ERR_X509_NOT_TRUSTED = @as(c_int, 62);
pub const BR_X509_TA_CA = @as(c_int, 0x0001);
pub const BR_KEYTYPE_RSA = @as(c_int, 1);
pub const BR_KEYTYPE_EC = @as(c_int, 2);
pub const BR_KEYTYPE_KEYX = @as(c_int, 0x10);
pub const BR_KEYTYPE_SIGN = @as(c_int, 0x20);
pub const BR_X509_BUFSIZE_KEY = @as(c_int, 520);
pub const BR_X509_BUFSIZE_SIG = @as(c_int, 512);
pub const BR_ENCODE_PEM_RSA_RAW = "RSA PRIVATE KEY";
pub const BR_ENCODE_PEM_EC_RAW = "EC PRIVATE KEY";
pub const BR_ENCODE_PEM_PKCS8 = "PRIVATE KEY";
pub const BR_SSL_BUFSIZE_INPUT = @as(c_int, 16384) + @as(c_int, 325);
pub const BR_SSL_BUFSIZE_OUTPUT = @as(c_int, 16384) + @as(c_int, 85);
pub const BR_SSL_BUFSIZE_MONO = BR_SSL_BUFSIZE_INPUT;
pub const BR_SSL_BUFSIZE_BIDI = BR_SSL_BUFSIZE_INPUT + BR_SSL_BUFSIZE_OUTPUT;
pub const BR_SSL30 = @as(c_int, 0x0300);
pub const BR_TLS10 = @as(c_int, 0x0301);
pub const BR_TLS11 = @as(c_int, 0x0302);
pub const BR_TLS12 = @as(c_int, 0x0303);
pub const BR_ERR_OK = @as(c_int, 0);
pub const BR_ERR_BAD_PARAM = @as(c_int, 1);
pub const BR_ERR_BAD_STATE = @as(c_int, 2);
pub const BR_ERR_UNSUPPORTED_VERSION = @as(c_int, 3);
pub const BR_ERR_BAD_VERSION = @as(c_int, 4);
pub const BR_ERR_BAD_LENGTH = @as(c_int, 5);
pub const BR_ERR_TOO_LARGE = @as(c_int, 6);
pub const BR_ERR_BAD_MAC = @as(c_int, 7);
pub const BR_ERR_NO_RANDOM = @as(c_int, 8);
pub const BR_ERR_UNKNOWN_TYPE = @as(c_int, 9);
pub const BR_ERR_UNEXPECTED = @as(c_int, 10);
pub const BR_ERR_BAD_CCS = @as(c_int, 12);
pub const BR_ERR_BAD_ALERT = @as(c_int, 13);
pub const BR_ERR_BAD_HANDSHAKE = @as(c_int, 14);
pub const BR_ERR_OVERSIZED_ID = @as(c_int, 15);
pub const BR_ERR_BAD_CIPHER_SUITE = @as(c_int, 16);
pub const BR_ERR_BAD_COMPRESSION = @as(c_int, 17);
pub const BR_ERR_BAD_FRAGLEN = @as(c_int, 18);
pub const BR_ERR_BAD_SECRENEG = @as(c_int, 19);
pub const BR_ERR_EXTRA_EXTENSION = @as(c_int, 20);
pub const BR_ERR_BAD_SNI = @as(c_int, 21);
pub const BR_ERR_BAD_HELLO_DONE = @as(c_int, 22);
pub const BR_ERR_LIMIT_EXCEEDED = @as(c_int, 23);
pub const BR_ERR_BAD_FINISHED = @as(c_int, 24);
pub const BR_ERR_RESUME_MISMATCH = @as(c_int, 25);
pub const BR_ERR_INVALID_ALGORITHM = @as(c_int, 26);
pub const BR_ERR_BAD_SIGNATURE = @as(c_int, 27);
pub const BR_ERR_WRONG_KEY_USAGE = @as(c_int, 28);
pub const BR_ERR_NO_CLIENT_AUTH = @as(c_int, 29);
pub const BR_ERR_IO = @as(c_int, 31);
pub const BR_ERR_RECV_FATAL_ALERT = @as(c_int, 256);
pub const BR_ERR_SEND_FATAL_ALERT = @as(c_int, 512);
pub const BR_MAX_CIPHER_SUITES = @as(c_int, 48);
pub const BR_OPT_ENFORCE_SERVER_PREFERENCES = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 0);
pub const BR_OPT_NO_RENEGOTIATION = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 1);
pub const BR_OPT_TOLERATE_NO_CLIENT_AUTH = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 2);
pub const BR_OPT_FAIL_ON_ALPN_MISMATCH = __helpers.cast(u32, @as(c_int, 1)) << @as(c_int, 3);
pub const BR_SSL_CLOSED = @as(c_int, 0x0001);
pub const BR_SSL_SENDREC = @as(c_int, 0x0002);
pub const BR_SSL_RECVREC = @as(c_int, 0x0004);
pub const BR_SSL_SENDAPP = @as(c_int, 0x0008);
pub const BR_SSL_RECVAPP = @as(c_int, 0x0010);
pub const BR_AUTH_ECDH = @as(c_int, 0);
pub const BR_AUTH_RSA = @as(c_int, 1);
pub const BR_AUTH_ECDSA = @as(c_int, 3);
pub const BR_SSLKEYX_RSA = @as(c_int, 0);
pub const BR_SSLKEYX_ECDHE_RSA = @as(c_int, 1);
pub const BR_SSLKEYX_ECDHE_ECDSA = @as(c_int, 2);
pub const BR_SSLKEYX_ECDH_RSA = @as(c_int, 3);
pub const BR_SSLKEYX_ECDH_ECDSA = @as(c_int, 4);
pub const BR_SSLENC_3DES_CBC = @as(c_int, 0);
pub const BR_SSLENC_AES128_CBC = @as(c_int, 1);
pub const BR_SSLENC_AES256_CBC = @as(c_int, 2);
pub const BR_SSLENC_AES128_GCM = @as(c_int, 3);
pub const BR_SSLENC_AES256_GCM = @as(c_int, 4);
pub const BR_SSLENC_CHACHA20 = @as(c_int, 5);
pub const BR_SSLMAC_AEAD = @as(c_int, 0);
pub const BR_SSLMAC_SHA1 = br_sha1_ID;
pub const BR_SSLMAC_SHA256 = br_sha256_ID;
pub const BR_SSLMAC_SHA384 = br_sha384_ID;
pub const BR_SSLPRF_SHA256 = br_sha256_ID;
pub const BR_SSLPRF_SHA384 = br_sha384_ID;
pub const BR_TLS_NULL_WITH_NULL_NULL = @as(c_int, 0x0000);
pub const BR_TLS_RSA_WITH_NULL_MD5 = @as(c_int, 0x0001);
pub const BR_TLS_RSA_WITH_NULL_SHA = @as(c_int, 0x0002);
pub const BR_TLS_RSA_WITH_NULL_SHA256 = @as(c_int, 0x003B);
pub const BR_TLS_RSA_WITH_RC4_128_MD5 = @as(c_int, 0x0004);
pub const BR_TLS_RSA_WITH_RC4_128_SHA = @as(c_int, 0x0005);
pub const BR_TLS_RSA_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x000A);
pub const BR_TLS_RSA_WITH_AES_128_CBC_SHA = @as(c_int, 0x002F);
pub const BR_TLS_RSA_WITH_AES_256_CBC_SHA = @as(c_int, 0x0035);
pub const BR_TLS_RSA_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x003C);
pub const BR_TLS_RSA_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x003D);
pub const BR_TLS_DH_DSS_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x000D);
pub const BR_TLS_DH_RSA_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x0010);
pub const BR_TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x0013);
pub const BR_TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x0016);
pub const BR_TLS_DH_DSS_WITH_AES_128_CBC_SHA = @as(c_int, 0x0030);
pub const BR_TLS_DH_RSA_WITH_AES_128_CBC_SHA = @as(c_int, 0x0031);
pub const BR_TLS_DHE_DSS_WITH_AES_128_CBC_SHA = @as(c_int, 0x0032);
pub const BR_TLS_DHE_RSA_WITH_AES_128_CBC_SHA = @as(c_int, 0x0033);
pub const BR_TLS_DH_DSS_WITH_AES_256_CBC_SHA = @as(c_int, 0x0036);
pub const BR_TLS_DH_RSA_WITH_AES_256_CBC_SHA = @as(c_int, 0x0037);
pub const BR_TLS_DHE_DSS_WITH_AES_256_CBC_SHA = @as(c_int, 0x0038);
pub const BR_TLS_DHE_RSA_WITH_AES_256_CBC_SHA = @as(c_int, 0x0039);
pub const BR_TLS_DH_DSS_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x003E);
pub const BR_TLS_DH_RSA_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x003F);
pub const BR_TLS_DHE_DSS_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x0040);
pub const BR_TLS_DHE_RSA_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x0067);
pub const BR_TLS_DH_DSS_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x0068);
pub const BR_TLS_DH_RSA_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x0069);
pub const BR_TLS_DHE_DSS_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x006A);
pub const BR_TLS_DHE_RSA_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x006B);
pub const BR_TLS_DH_anon_WITH_RC4_128_MD5 = @as(c_int, 0x0018);
pub const BR_TLS_DH_anon_WITH_3DES_EDE_CBC_SHA = @as(c_int, 0x001B);
pub const BR_TLS_DH_anon_WITH_AES_128_CBC_SHA = @as(c_int, 0x0034);
pub const BR_TLS_DH_anon_WITH_AES_256_CBC_SHA = @as(c_int, 0x003A);
pub const BR_TLS_DH_anon_WITH_AES_128_CBC_SHA256 = @as(c_int, 0x006C);
pub const BR_TLS_DH_anon_WITH_AES_256_CBC_SHA256 = @as(c_int, 0x006D);
pub const BR_TLS_ECDH_ECDSA_WITH_NULL_SHA = __helpers.promoteIntLiteral(c_int, 0xC001, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_RC4_128_SHA = __helpers.promoteIntLiteral(c_int, 0xC002, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC003, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC004, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC005, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_NULL_SHA = __helpers.promoteIntLiteral(c_int, 0xC006, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_RC4_128_SHA = __helpers.promoteIntLiteral(c_int, 0xC007, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC008, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC009, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC00A, .hex);
pub const BR_TLS_ECDH_RSA_WITH_NULL_SHA = __helpers.promoteIntLiteral(c_int, 0xC00B, .hex);
pub const BR_TLS_ECDH_RSA_WITH_RC4_128_SHA = __helpers.promoteIntLiteral(c_int, 0xC00C, .hex);
pub const BR_TLS_ECDH_RSA_WITH_3DES_EDE_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC00D, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_128_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC00E, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_256_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC00F, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_NULL_SHA = __helpers.promoteIntLiteral(c_int, 0xC010, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_RC4_128_SHA = __helpers.promoteIntLiteral(c_int, 0xC011, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC012, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC013, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC014, .hex);
pub const BR_TLS_ECDH_anon_WITH_NULL_SHA = __helpers.promoteIntLiteral(c_int, 0xC015, .hex);
pub const BR_TLS_ECDH_anon_WITH_RC4_128_SHA = __helpers.promoteIntLiteral(c_int, 0xC016, .hex);
pub const BR_TLS_ECDH_anon_WITH_3DES_EDE_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC017, .hex);
pub const BR_TLS_ECDH_anon_WITH_AES_128_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC018, .hex);
pub const BR_TLS_ECDH_anon_WITH_AES_256_CBC_SHA = __helpers.promoteIntLiteral(c_int, 0xC019, .hex);
pub const BR_TLS_RSA_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x009C);
pub const BR_TLS_RSA_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x009D);
pub const BR_TLS_DHE_RSA_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x009E);
pub const BR_TLS_DHE_RSA_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x009F);
pub const BR_TLS_DH_RSA_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x00A0);
pub const BR_TLS_DH_RSA_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x00A1);
pub const BR_TLS_DHE_DSS_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x00A2);
pub const BR_TLS_DHE_DSS_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x00A3);
pub const BR_TLS_DH_DSS_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x00A4);
pub const BR_TLS_DH_DSS_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x00A5);
pub const BR_TLS_DH_anon_WITH_AES_128_GCM_SHA256 = @as(c_int, 0x00A6);
pub const BR_TLS_DH_anon_WITH_AES_256_GCM_SHA384 = @as(c_int, 0x00A7);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC023, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC024, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_128_CBC_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC025, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC026, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC027, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC028, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_128_CBC_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC029, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_256_CBC_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC02A, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC02B, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC02C, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_128_GCM_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC02D, .hex);
pub const BR_TLS_ECDH_ECDSA_WITH_AES_256_GCM_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC02E, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC02F, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC030, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_128_GCM_SHA256 = __helpers.promoteIntLiteral(c_int, 0xC031, .hex);
pub const BR_TLS_ECDH_RSA_WITH_AES_256_GCM_SHA384 = __helpers.promoteIntLiteral(c_int, 0xC032, .hex);
pub const BR_TLS_RSA_WITH_AES_128_CCM = __helpers.promoteIntLiteral(c_int, 0xC09C, .hex);
pub const BR_TLS_RSA_WITH_AES_256_CCM = __helpers.promoteIntLiteral(c_int, 0xC09D, .hex);
pub const BR_TLS_RSA_WITH_AES_128_CCM_8 = __helpers.promoteIntLiteral(c_int, 0xC0A0, .hex);
pub const BR_TLS_RSA_WITH_AES_256_CCM_8 = __helpers.promoteIntLiteral(c_int, 0xC0A1, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_128_CCM = __helpers.promoteIntLiteral(c_int, 0xC0AC, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_256_CCM = __helpers.promoteIntLiteral(c_int, 0xC0AD, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_128_CCM_8 = __helpers.promoteIntLiteral(c_int, 0xC0AE, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_AES_256_CCM_8 = __helpers.promoteIntLiteral(c_int, 0xC0AF, .hex);
pub const BR_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCA8, .hex);
pub const BR_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCA9, .hex);
pub const BR_TLS_DHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCAA, .hex);
pub const BR_TLS_PSK_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCAB, .hex);
pub const BR_TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCAC, .hex);
pub const BR_TLS_DHE_PSK_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCAD, .hex);
pub const BR_TLS_RSA_PSK_WITH_CHACHA20_POLY1305_SHA256 = __helpers.promoteIntLiteral(c_int, 0xCCAE, .hex);
pub const BR_TLS_FALLBACK_SCSV = @as(c_int, 0x5600);
pub const BR_ALERT_CLOSE_NOTIFY = @as(c_int, 0);
pub const BR_ALERT_UNEXPECTED_MESSAGE = @as(c_int, 10);
pub const BR_ALERT_BAD_RECORD_MAC = @as(c_int, 20);
pub const BR_ALERT_RECORD_OVERFLOW = @as(c_int, 22);
pub const BR_ALERT_DECOMPRESSION_FAILURE = @as(c_int, 30);
pub const BR_ALERT_HANDSHAKE_FAILURE = @as(c_int, 40);
pub const BR_ALERT_BAD_CERTIFICATE = @as(c_int, 42);
pub const BR_ALERT_UNSUPPORTED_CERTIFICATE = @as(c_int, 43);
pub const BR_ALERT_CERTIFICATE_REVOKED = @as(c_int, 44);
pub const BR_ALERT_CERTIFICATE_EXPIRED = @as(c_int, 45);
pub const BR_ALERT_CERTIFICATE_UNKNOWN = @as(c_int, 46);
pub const BR_ALERT_ILLEGAL_PARAMETER = @as(c_int, 47);
pub const BR_ALERT_UNKNOWN_CA = @as(c_int, 48);
pub const BR_ALERT_ACCESS_DENIED = @as(c_int, 49);
pub const BR_ALERT_DECODE_ERROR = @as(c_int, 50);
pub const BR_ALERT_DECRYPT_ERROR = @as(c_int, 51);
pub const BR_ALERT_PROTOCOL_VERSION = @as(c_int, 70);
pub const BR_ALERT_INSUFFICIENT_SECURITY = @as(c_int, 71);
pub const BR_ALERT_INTERNAL_ERROR = @as(c_int, 80);
pub const BR_ALERT_USER_CANCELED = @as(c_int, 90);
pub const BR_ALERT_NO_RENEGOTIATION = @as(c_int, 100);
pub const BR_ALERT_UNSUPPORTED_EXTENSION = @as(c_int, 110);
pub const BR_ALERT_NO_APPLICATION_PROTOCOL = @as(c_int, 120);
pub const BR_BEARSSL_PEM_H__ = "";
pub const BR_PEM_BEGIN_OBJ = @as(c_int, 1);
pub const BR_PEM_END_OBJ = @as(c_int, 2);
pub const BR_PEM_ERROR = @as(c_int, 3);
pub const BR_PEM_LINE64 = @as(c_int, 0x0001);
pub const BR_PEM_CRLF = @as(c_int, 0x0002);
pub const BR_FEATURE_X509_TIME_CALLBACK = @as(c_int, 1);
pub const br_hash_class_ = struct_br_hash_class_;
pub const br_block_cbcenc_class_ = struct_br_block_cbcenc_class_;
pub const br_block_cbcdec_class_ = struct_br_block_cbcdec_class_;
pub const br_block_ctr_class_ = struct_br_block_ctr_class_;
pub const br_block_ctrcbc_class_ = struct_br_block_ctrcbc_class_;
pub const br_prng_class_ = struct_br_prng_class_;
pub const br_aead_class_ = struct_br_aead_class_;
pub const br_x509_class_ = struct_br_x509_class_;
pub const br_sslrec_in_class_ = struct_br_sslrec_in_class_;
pub const br_sslrec_out_class_ = struct_br_sslrec_out_class_;
pub const br_sslrec_in_cbc_class_ = struct_br_sslrec_in_cbc_class_;
pub const br_sslrec_out_cbc_class_ = struct_br_sslrec_out_cbc_class_;
pub const br_sslrec_in_gcm_class_ = struct_br_sslrec_in_gcm_class_;
pub const br_sslrec_out_gcm_class_ = struct_br_sslrec_out_gcm_class_;
pub const br_sslrec_in_chapol_class_ = struct_br_sslrec_in_chapol_class_;
pub const br_sslrec_out_chapol_class_ = struct_br_sslrec_out_chapol_class_;
pub const br_sslrec_in_ccm_class_ = struct_br_sslrec_in_ccm_class_;
pub const br_sslrec_out_ccm_class_ = struct_br_sslrec_out_ccm_class_;
pub const br_ssl_client_certificate_class_ = struct_br_ssl_client_certificate_class_;
pub const br_ssl_client_context_ = struct_br_ssl_client_context_;
pub const br_ssl_session_cache_class_ = struct_br_ssl_session_cache_class_;
pub const br_ssl_server_policy_class_ = struct_br_ssl_server_policy_class_;
pub const br_ssl_server_context_ = struct_br_ssl_server_context_;
