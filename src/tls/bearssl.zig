// Zig bindings for BearSSL — TLS 1.2 client on freestanding ARM.
//
// Thin wrapper around the BearSSL C API. Exposes only what we need for
// a TLS client: engine state machine, buffer access, client context init,
// x509 known-key trust, HMAC-DRBG seeding, and cipher configuration.
//
// BearSSL docs: https://bearssl.org/apidoc/

const c = @cImport({
    @cInclude("bearssl.h");
});

// ── Types ────────────────────────────────────────────────────────────

pub const EngineContext = c.br_ssl_engine_context;
pub const ClientContext = c.br_ssl_client_context;
pub const X509KnownKeyContext = c.br_x509_knownkey_context;
pub const X509MinimalContext = c.br_x509_minimal_context;
pub const X509Class = c.br_x509_class;
pub const RsaPublicKey = c.br_rsa_public_key;
pub const EcPublicKey = c.br_ec_public_key;
pub const X509TrustAnchor = c.br_x509_trust_anchor;
pub const HmacDrbgContext = c.br_hmac_drbg_context;

// ── Engine state flags ───────────────────────────────────────────────

pub const SSL_CLOSED: c_uint = c.BR_SSL_CLOSED;
pub const SSL_SENDREC: c_uint = c.BR_SSL_SENDREC;
pub const SSL_RECVREC: c_uint = c.BR_SSL_RECVREC;
pub const SSL_SENDAPP: c_uint = c.BR_SSL_SENDAPP;
pub const SSL_RECVAPP: c_uint = c.BR_SSL_RECVAPP;

// ── Error codes ──────────────────────────────────────────────────────

pub const ERR_OK: c_int = c.BR_ERR_OK;
pub const ERR_NO_RANDOM: c_int = c.BR_ERR_NO_RANDOM;
pub const ERR_TOO_LARGE: c_int = c.BR_ERR_TOO_LARGE;

// ── Key usage flags ──────────────────────────────────────────────────

pub const KEYTYPE_RSA: c_uint = c.BR_KEYTYPE_RSA;
pub const KEYTYPE_EC: c_uint = c.BR_KEYTYPE_EC;
pub const KEYTYPE_KEYX: c_uint = c.BR_KEYTYPE_KEYX;
pub const KEYTYPE_SIGN: c_uint = c.BR_KEYTYPE_SIGN;

// ── Client context ───────────────────────────────────────────────────

pub fn clientZero(cc: *ClientContext) void {
    c.br_ssl_client_zero(cc);
}

pub fn clientReset(cc: *ClientContext, server_name: [*:0]const u8, resume_session: bool) bool {
    return c.br_ssl_client_reset(cc, server_name, @intFromBool(resume_session)) != 0;
}

pub fn clientInitFull(
    cc: *ClientContext,
    xc: *X509MinimalContext,
    trust_anchors: [*]const X509TrustAnchor,
    trust_anchors_num: usize,
) void {
    c.br_ssl_client_init_full(cc, xc, trust_anchors, trust_anchors_num);
}

// ── Engine configuration ─────────────────────────────────────────────

pub fn engineSetVersions(eng: *EngineContext, min: u16, max: u16) void {
    c.br_ssl_engine_set_versions(eng, min, max);
}

pub fn engineSetSuites(eng: *EngineContext, suites: []const u16) void {
    c.br_ssl_engine_set_suites(eng, suites.ptr, suites.len);
}

pub fn engineSetBuffer(eng: *EngineContext, buf: []u8, bidi: bool) void {
    c.br_ssl_engine_set_buffer(eng, buf.ptr, buf.len, @intFromBool(bidi));
}

pub fn engineSetBuffersBidi(
    eng: *EngineContext,
    ibuf: []u8,
    obuf: []u8,
) void {
    c.br_ssl_engine_set_buffers_bidi(eng, ibuf.ptr, ibuf.len, obuf.ptr, obuf.len);
}

pub fn engineSetX509(eng: *EngineContext, x509ctx: *const *const X509Class) void {
    c.br_ssl_engine_set_x509(eng, x509ctx);
}

pub fn engineInjectEntropy(eng: *EngineContext, data: []const u8) void {
    c.br_ssl_engine_inject_entropy(eng, data.ptr, data.len);
}

// Hash functions
pub fn engineSetHash(eng: *EngineContext, id: c_int, hc: *const c.br_hash_class) void {
    c.br_ssl_engine_set_hash(eng, id, hc);
}

// PRF
pub fn engineSetPrf10(eng: *EngineContext) void {
    c.br_ssl_engine_set_prf10(eng, c.br_tls10_prf);
}
pub fn engineSetPrfSha256(eng: *EngineContext) void {
    c.br_ssl_engine_set_prf_sha256(eng, c.br_tls12_sha256_prf);
}
pub fn engineSetPrfSha384(eng: *EngineContext) void {
    c.br_ssl_engine_set_prf_sha384(eng, c.br_tls12_sha384_prf);
}

// Crypto implementations — use "default" selectors (pick best for platform)
pub fn clientSetDefaultRsaPub(cc: *ClientContext) void {
    c.br_ssl_client_set_default_rsapub(cc);
}
pub fn engineSetDefaultRsaVrfy(eng: *EngineContext) void {
    c.br_ssl_engine_set_default_rsavrfy(eng);
}
pub fn engineSetDefaultEcdsa(eng: *EngineContext) void {
    c.br_ssl_engine_set_default_ecdsa(eng);
}
pub fn engineSetDefaultAesGcm(eng: *EngineContext) void {
    c.br_ssl_engine_set_default_aes_gcm(eng);
}
pub fn engineSetDefaultAesCbc(eng: *EngineContext) void {
    c.br_ssl_engine_set_default_aes_cbc(eng);
}
pub fn engineSetDefaultEc(eng: *EngineContext) void {
    c.br_ssl_engine_set_default_ec(eng);
}

// ── Engine state machine ─────────────────────────────────────────────

pub fn engineCurrentState(eng: *const EngineContext) c_uint {
    return c.br_ssl_engine_current_state(eng);
}

pub fn engineLastError(eng: *const EngineContext) c_int {
    return c.br_ssl_engine_last_error(eng);
}

/// Get pointer to record-data output buffer (ciphertext ready to send to peer).
pub fn engineSendrecBuf(eng: *const EngineContext) ?[]u8 {
    var len: usize = 0;
    const ptr: ?[*]u8 = c.br_ssl_engine_sendrec_buf(eng, &len);
    if (ptr == null or len == 0) return null;
    return ptr.?[0..len];
}

pub fn engineSendrecAck(eng: *EngineContext, len: usize) void {
    c.br_ssl_engine_sendrec_ack(eng, len);
}

/// Get pointer to record-data input buffer (space for incoming ciphertext).
pub fn engineRecvrecBuf(eng: *const EngineContext) ?[]u8 {
    var len: usize = 0;
    const ptr: ?[*]u8 = c.br_ssl_engine_recvrec_buf(eng, &len);
    if (ptr == null or len == 0) return null;
    return ptr.?[0..len];
}

pub fn engineRecvrecAck(eng: *EngineContext, len: usize) void {
    c.br_ssl_engine_recvrec_ack(eng, len);
}

/// Get pointer to application data output buffer (space for plaintext to send).
pub fn engineSendappBuf(eng: *const EngineContext) ?[]u8 {
    var len: usize = 0;
    const ptr: ?[*]u8 = c.br_ssl_engine_sendapp_buf(eng, &len);
    if (ptr == null or len == 0) return null;
    return ptr.?[0..len];
}

pub fn engineSendappAck(eng: *EngineContext, len: usize) void {
    c.br_ssl_engine_sendapp_ack(eng, len);
}

/// Get pointer to application data input buffer (decrypted plaintext available).
pub fn engineRecvappBuf(eng: *const EngineContext) ?[]u8 {
    var len: usize = 0;
    const ptr: ?[*]u8 = c.br_ssl_engine_recvapp_buf(eng, &len);
    if (ptr == null or len == 0) return null;
    return ptr.?[0..len];
}

pub fn engineRecvappAck(eng: *EngineContext, len: usize) void {
    c.br_ssl_engine_recvapp_ack(eng, len);
}

pub fn engineClose(eng: *EngineContext) void {
    c.br_ssl_engine_close(eng);
}

/// Flush pending application data.
pub fn engineFlush(eng: *EngineContext, force: bool) void {
    c.br_ssl_engine_flush(eng, @intFromBool(force));
}

// ── X.509 known-key trust ────────────────────────────────────────────

pub fn x509KnownkeyInitRsa(ctx: *X509KnownKeyContext, pk: *const RsaPublicKey, usages: c_uint) void {
    c.br_x509_knownkey_init_rsa(ctx, pk, usages);
}

pub fn x509KnownkeyInitEc(ctx: *X509KnownKeyContext, pk: *const EcPublicKey, usages: c_uint) void {
    c.br_x509_knownkey_init_ec(ctx, pk, usages);
}

// ── X.509 minimal (for CA-based validation) ──────────────────────────

pub fn x509MinimalInit(
    ctx: *X509MinimalContext,
    trust_anchors: [*]const X509TrustAnchor,
    trust_anchors_num: usize,
) void {
    c.br_x509_minimal_init(ctx, &c.br_sha256_vtable, trust_anchors, trust_anchors_num);
}

pub fn x509MinimalSetRsa(ctx: *X509MinimalContext, eng: *const EngineContext) void {
    c.br_x509_minimal_set_rsa(ctx, c.br_ssl_engine_get_rsavrfy(eng));
}

pub fn x509MinimalSetEcdsa(ctx: *X509MinimalContext, eng: *const EngineContext) void {
    c.br_x509_minimal_set_ecdsa(
        ctx,
        c.br_ssl_engine_get_ec(eng),
        c.br_ssl_engine_get_ecdsa(eng),
    );
}

pub fn x509MinimalSetHash(ctx: *X509MinimalContext, id: c_int, hc: *const c.br_hash_class) void {
    c.br_x509_minimal_set_hash(ctx, id, hc);
}

// ── Hash vtables ─────────────────────────────────────────────────────

pub fn sha256Vtable() *const c.br_hash_class {
    return &c.br_sha256_vtable;
}
pub fn sha1Vtable() *const c.br_hash_class {
    return &c.br_sha1_vtable;
}
pub fn sha384Vtable() *const c.br_hash_class {
    return &c.br_sha384_vtable;
}
pub fn sha512Vtable() *const c.br_hash_class {
    return &c.br_sha512_vtable;
}
pub fn md5Vtable() *const c.br_hash_class {
    return &c.br_md5_vtable;
}
pub fn sha224Vtable() *const c.br_hash_class {
    return &c.br_sha224_vtable;
}

// Hash IDs
pub const MD5_ID: c_int = c.br_md5_ID;
pub const SHA1_ID: c_int = c.br_sha1_ID;
pub const SHA224_ID: c_int = c.br_sha224_ID;
pub const SHA256_ID: c_int = c.br_sha256_ID;
pub const SHA384_ID: c_int = c.br_sha384_ID;
pub const SHA512_ID: c_int = c.br_sha512_ID;

// ── HMAC-DRBG ────────────────────────────────────────────────────────

pub fn hmacDrbgInit(ctx: *HmacDrbgContext, seed: []const u8) void {
    c.br_hmac_drbg_init(ctx, &c.br_sha256_vtable, seed.ptr, seed.len);
}

pub fn hmacDrbgGenerate(ctx: *HmacDrbgContext, out: []u8) void {
    c.br_hmac_drbg_generate(ctx, out.ptr, out.len);
}

pub fn hmacDrbgUpdate(ctx: *HmacDrbgContext, seed: []const u8) void {
    c.br_hmac_drbg_update(ctx, seed.ptr, seed.len);
}

// ── SHA-256 for entropy conditioning ─────────────────────────────────

pub const Sha256Context = c.br_sha256_context;

pub fn sha256Init(ctx: *Sha256Context) void {
    c.br_sha256_init(ctx);
}

pub fn sha256Update(ctx: *Sha256Context, data: []const u8) void {
    c.br_sha256_update(ctx, data.ptr, data.len);
}

pub fn sha256Out(ctx: *const Sha256Context, out: *[32]u8) void {
    c.br_sha256_out(ctx, out);
}

// ── TLS version constants ────────────────────────────────────────────

pub const TLS10: u16 = c.BR_TLS10;
pub const TLS12: u16 = c.BR_TLS12;

// ── Cipher suite constants ───────────────────────────────────────────

pub const TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256: u16 = c.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256;
pub const TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256: u16 = c.BR_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256;
