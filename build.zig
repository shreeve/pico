const std = @import("std");

const Board = enum {
    pico_w,
    pico2_w,
};

const Engine = enum {
    js,
    ruby,
};

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "Target board") orelse .pico_w;
    const engine = b.option(Engine, "engine", "Script engine: js (default) or ruby") orelse .js;
    const optimize = b.standardOptimizeOption(.{});

    const fw_query: std.Target.Query = switch (board) {
        .pico_w => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
            .os_tag = .freestanding,
            .abi = .eabi,
        },
        .pico2_w => .{
            .cpu_arch = .thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
            .os_tag = .freestanding,
            .abi = .eabihf,
        },
    };
    const fw_target = b.resolveTargetQuery(fw_query);
    const fw_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSmall else optimize;

    const host_target = b.resolveTargetQuery(.{});

    // ── MQuickJS stdlib generator (runs on host) ────────────────────────

    const gen_module = b.createModule(.{
        .target = host_target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    gen_module.addCSourceFiles(.{
        .root = b.path("ext/mquickjs"),
        .files = &.{"mquickjs_build.c"},
        .flags = &.{ "-D_GNU_SOURCE", "-fno-math-errno", "-fno-trapping-math" },
    });
    gen_module.addCSourceFiles(.{
        .root = b.path("src/js"),
        .files = &.{"pico_stdlib_gen.c"},
        .flags = &.{ "-D_GNU_SOURCE", "-fno-math-errno", "-fno-trapping-math" },
    });
    gen_module.addIncludePath(b.path("ext/mquickjs"));

    const stdlib_gen = b.addExecutable(.{
        .name = "pico_stdlib_gen",
        .root_module = gen_module,
    });

    // Generate mquickjs_atom.h (with -a flag)
    const gen_atoms = b.addRunArtifact(stdlib_gen);
    gen_atoms.addArgs(&.{ "-a", "-m32" });
    const atoms_h = gen_atoms.captureStdOut(.{});

    // Generate pico_stdlib.h (without -a flag)
    const gen_stdlib = b.addRunArtifact(stdlib_gen);
    gen_stdlib.addArg("-m32");
    const stdlib_h = gen_stdlib.captureStdOut(.{});

    // Place generated headers in a WriteFile step so we can use its
    // directory as a C include path.
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(atoms_h, "mquickjs_atom.h");
    _ = generated.addCopyFile(stdlib_h, "pico_stdlib.h");
    const gen_dir = generated.getDirectory();

    // ── Firmware executable ─────────────────────────────────────────────

    const c_flags: []const []const u8 = &.{
        "-DCONFIG_SMALL",
        "-DUSE_SOFTFLOAT",
        "-fno-math-errno",
        "-fno-trapping-math",
        "-fno-stack-protector",
        "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables",
        "-ffreestanding",
        "-nostdinc",
    };

    const bearssl_flags: []const []const u8 = &.{
        "-DBR_ARMEL_CORTEXM_GCC=0",
        "-DBR_LOMUL=1",
        "-DBR_AES_X86NI=0",
        "-DBR_SSE2=0",
        "-DBR_POWER8=0",
        "-DBR_INT128=0",
        "-DBR_UMUL128=0",
        "-DBR_RDRAND=0",
        "-DBR_USE_GETENTROPY=0",
        "-DBR_USE_URANDOM=0",
        "-DBR_USE_WIN32_RAND=0",
        "-DBR_USE_UNIX_TIME=0",
        "-DBR_USE_WIN32_TIME=0",
        "-fno-stack-protector",
        "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables",
        "-ffreestanding",
        "-nostdinc",
    };

    // Wi-Fi credentials (build-time): zig build -DSSID=MyNetwork:MyPassword
    const wifi_cred = b.option([]const u8, "SSID", "WiFi credentials as SSID:password") orelse "";
    var wifi_ssid: []const u8 = "";
    var wifi_pass: []const u8 = "";
    if (wifi_cred.len > 0) {
        if (std.mem.indexOfScalar(u8, wifi_cred, ':')) |sep| {
            wifi_ssid = wifi_cred[0..sep];
            wifi_pass = wifi_cred[sep + 1 ..];
        } else {
            wifi_ssid = wifi_cred;
        }
    }

    // USB host mode: zig build -DUSB_HOST (enables USB host for Piccolo)
    const usb_host_enabled = b.option(bool, "USB_HOST", "Enable USB host mode (disables flashing via USB)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "ssid", wifi_ssid);
    build_options.addOption([]const u8, "pass", wifi_pass);
    build_options.addOption(bool, "usb_host", usb_host_enabled);

    // Engine selects the root source file. `-Dengine=js` (default) keeps
    // `src/main.zig` untouched so the firmware is byte-identical to the
    // pre-integration build (docs/NANORUBY.md A2.5 acceptance gate).
    const fw_root_source = switch (engine) {
        .js => b.path("src/main.zig"),
        .ruby => b.path("src/main_ruby.zig"),
    };

    const fw_module = b.createModule(.{
        .root_source_file = fw_root_source,
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    });
    fw_module.addImport("build_config", build_options.createModule());

    // Shim headers must come FIRST so they override system headers
    fw_module.addIncludePath(b.path("src/libc"));

    // Boot2 stage-2 bootloader (configures QSPI XIP)
    fw_module.addCSourceFiles(.{
        .root = b.path("src/platform"),
        .files = &.{"boot2.c"},
        .flags = &.{ "-ffreestanding", "-nostdinc" },
    });

    fw_module.addCSourceFiles(.{
        .root = b.path("ext/mquickjs"),
        .files = &.{
            "mquickjs.c",
            "dtoa.c",
            "libm.c",
            "cutils.c",
        },
        .flags = c_flags,
    });

    // libc stubs (memcpy, strlen, setjmp, abort, etc.)
    fw_module.addCSourceFiles(.{
        .root = b.path("src/libc"),
        .files = &.{"stubs.c"},
        .flags = c_flags,
    });

    // ── BearSSL TLS library ──────────────────────────────────────────────
    fw_module.addIncludePath(b.path("ext/bearssl/inc"));
    fw_module.addIncludePath(b.path("ext/bearssl/src"));

    fw_module.addCSourceFiles(.{
        .root = b.path("ext/bearssl/src"),
        .files = bearssl_sources,
        .flags = bearssl_flags,
    });

    fw_module.addIncludePath(b.path("ext/mquickjs"));
    fw_module.addIncludePath(gen_dir);

    // Compile the generated stdlib embedding file (includes pico_stdlib.h)
    fw_module.addCSourceFiles(.{
        .root = b.path("src/js"),
        .files = &.{"pico_stdlib_data.c"},
        .flags = c_flags,
    });

    const firmware = b.addExecutable(.{
        .name = "pico",
        .root_module = fw_module,
    });
    firmware.entry = .{ .symbol_name = "_reset_handler" };

    // Linker script
    firmware.setLinkerScript(switch (board) {
        .pico_w => b.path("src/platform/rp2040.ld"),
        .pico2_w => b.path("src/platform/rp2350.ld"),
    });

    b.installArtifact(firmware);

    // ── UF2 conversion step ─────────────────────────────────────────────

    const uf2_module = b.createModule(.{
        .root_source_file = b.path("tools/uf2conv.zig"),
        .target = host_target,
        .optimize = .ReleaseFast,
    });
    const uf2_tool = b.addExecutable(.{
        .name = "uf2conv",
        .root_module = uf2_module,
    });

    const uf2_run = b.addRunArtifact(uf2_tool);
    uf2_run.addArtifactArg(firmware);
    const family_id: []const u8 = switch (board) {
        .pico_w => "rp2040",
        .pico2_w => "rp2350",
    };
    uf2_run.addArg(family_id);
    const uf2_output = uf2_run.addOutputFileArg("pico.uf2");

    const uf2_install = b.addInstallFile(uf2_output, "firmware/pico.uf2");

    const uf2_step = b.step("uf2", "Build UF2 firmware image");
    uf2_step.dependOn(&uf2_install.step);

    // ── Generate step (run the stdlib generator only) ───────────────────
    const gen_step = b.step("gen", "Generate MQuickJS stdlib headers");
    gen_step.dependOn(&generated.step);

    // ── Minimal UART test (RAM-only, for SWD development) ────────────────
    const test_uart_module = b.createModule(.{
        .root_source_file = b.path("tests/test_uart.zig"),
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    });
    test_uart_module.addIncludePath(b.path("src/libc"));
    test_uart_module.addCSourceFiles(.{
        .root = b.path("src/platform"),
        .files = &.{"boot2.c"},
        .flags = &.{ "-ffreestanding", "-nostdinc" },
    });
    const test_uart = b.addExecutable(.{
        .name = "test-uart",
        .root_module = test_uart_module,
    });
    test_uart.entry = .{ .symbol_name = "_reset_handler" };
    test_uart.setLinkerScript(b.path("src/platform/rp2040_flash.ld"));

    const test_uart_install = b.addInstallArtifact(test_uart, .{});
    const test_uart_step = b.step("test-uart", "Build minimal UART test (RAM-only, for SWD)");
    test_uart_step.dependOn(&test_uart_install.step);

    // ── HAL integration test (flash, uses full clock init + PLL) ─────────
    const test_hal_module = b.createModule(.{
        .root_source_file = b.path("tests/test_hal.zig"),
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    });
    test_hal_module.addImport("support", b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    }));
    test_hal_module.addIncludePath(b.path("src/libc"));
    test_hal_module.addCSourceFiles(.{
        .root = b.path("src/platform"),
        .files = &.{"boot2.c"},
        .flags = &.{ "-ffreestanding", "-nostdinc" },
    });
    const test_hal = b.addExecutable(.{
        .name = "test-hal",
        .root_module = test_hal_module,
    });
    test_hal.entry = .{ .symbol_name = "_reset_handler" };
    test_hal.setLinkerScript(b.path("src/platform/rp2040_flash.ld"));

    const test_hal_install = b.addInstallArtifact(test_hal, .{});
    const test_hal_step = b.step("test-hal", "Build HAL integration test (PLL + UART @ 125 MHz)");
    test_hal_step.dependOn(&test_hal_install.step);

    // ── MQuickJS bring-up test (staged, with JS VM) ────────────────────
    const test_main_module = b.createModule(.{
        .root_source_file = b.path("tests/test_main.zig"),
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    });
    test_main_module.addImport("support", b.createModule(.{
        .root_source_file = b.path("src/test_support.zig"),
        .target = fw_target,
        .optimize = fw_optimize,
        .link_libc = false,
    }));

    test_main_module.addIncludePath(b.path("src/libc"));
    test_main_module.addIncludePath(b.path("ext/mquickjs"));
    test_main_module.addIncludePath(gen_dir);

    test_main_module.addCSourceFiles(.{
        .root = b.path("src/platform"),
        .files = &.{"boot2.c"},
        .flags = &.{ "-ffreestanding", "-nostdinc" },
    });

    // MQuickJS engine
    test_main_module.addCSourceFiles(.{
        .root = b.path("ext/mquickjs"),
        .files = &.{
            "mquickjs.c",
            "dtoa.c",
            "libm.c",
            "cutils.c",
        },
        .flags = c_flags,
    });

    // libc stubs
    test_main_module.addCSourceFiles(.{
        .root = b.path("src/libc"),
        .files = &.{"stubs.c"},
        .flags = c_flags,
    });

    // Generated stdlib embedding (defines js_stdlib symbol)
    test_main_module.addCSourceFiles(.{
        .root = b.path("src/js"),
        .files = &.{ "pico_stdlib_data.c", "pico_bringup.c" },
        .flags = c_flags,
    });

    const test_main = b.addExecutable(.{
        .name = "test-main",
        .root_module = test_main_module,
    });
    test_main.entry = .{ .symbol_name = "_reset_handler" };
    test_main.setLinkerScript(b.path("src/platform/rp2040.ld"));

    const test_main_install = b.addInstallArtifact(test_main, .{});
    const test_main_step = b.step("test-main", "Build MQuickJS bring-up test (staged, with JS VM)");
    test_main_step.dependOn(&test_main_install.step);

    // ── Network stack unit tests (host-side, pure logic) ────────────────
    const test_net_module = b.createModule(.{
        .root_source_file = b.path("tests/test_net.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    test_net_module.addImport("byteutil", b.createModule(.{
        .root_source_file = b.path("src/lib/byteutil.zig"),
        .target = host_target,
        .optimize = optimize,
    }));
    const test_net = b.addTest(.{
        .name = "test-net",
        .root_module = test_net_module,
    });
    const run_test_net = b.addRunArtifact(test_net);
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&run_test_net.step);
}

// ── BearSSL source file list ─────────────────────────────────────────
// All C sources from ext/bearssl/src/, excluding sysrng.c (needs OS APIs).
// Platform-specific code (x86, POWER8, 64-bit) is guarded by #if macros
// and compiles to empty translation units on ARM Cortex-M.

const bearssl_sources: []const []const u8 = &.{
    // AEAD modes
    "aead/ccm.c",
    "aead/eax.c",
    "aead/gcm.c",
    // Codec (byte-order, PEM)
    "codec/ccopy.c",
    "codec/dec16be.c",
    "codec/dec16le.c",
    "codec/dec32be.c",
    "codec/dec32le.c",
    "codec/dec64be.c",
    "codec/dec64le.c",
    "codec/enc16be.c",
    "codec/enc16le.c",
    "codec/enc32be.c",
    "codec/enc32le.c",
    "codec/enc64be.c",
    "codec/enc64le.c",
    "codec/pemdec.c",
    "codec/pemenc.c",
    // Elliptic curve
    "ec/ec_all_m15.c",
    "ec/ec_all_m31.c",
    "ec/ec_c25519_i15.c",
    "ec/ec_c25519_i31.c",
    "ec/ec_c25519_m15.c",
    "ec/ec_c25519_m31.c",
    "ec/ec_c25519_m62.c",
    "ec/ec_c25519_m64.c",
    "ec/ec_curve25519.c",
    "ec/ec_default.c",
    "ec/ec_keygen.c",
    "ec/ec_p256_m15.c",
    "ec/ec_p256_m31.c",
    "ec/ec_p256_m62.c",
    "ec/ec_p256_m64.c",
    "ec/ec_prime_i15.c",
    "ec/ec_prime_i31.c",
    "ec/ec_pubkey.c",
    "ec/ec_secp256r1.c",
    "ec/ec_secp384r1.c",
    "ec/ec_secp521r1.c",
    "ec/ecdsa_atr.c",
    "ec/ecdsa_default_sign_asn1.c",
    "ec/ecdsa_default_sign_raw.c",
    "ec/ecdsa_default_vrfy_asn1.c",
    "ec/ecdsa_default_vrfy_raw.c",
    "ec/ecdsa_i15_bits.c",
    "ec/ecdsa_i15_sign_asn1.c",
    "ec/ecdsa_i15_sign_raw.c",
    "ec/ecdsa_i15_vrfy_asn1.c",
    "ec/ecdsa_i15_vrfy_raw.c",
    "ec/ecdsa_i31_bits.c",
    "ec/ecdsa_i31_sign_asn1.c",
    "ec/ecdsa_i31_sign_raw.c",
    "ec/ecdsa_i31_vrfy_asn1.c",
    "ec/ecdsa_i31_vrfy_raw.c",
    "ec/ecdsa_rta.c",
    // Hash functions
    "hash/dig_oid.c",
    "hash/dig_size.c",
    "hash/ghash_ctmul.c",
    "hash/ghash_ctmul32.c",
    "hash/ghash_ctmul64.c",
    "hash/ghash_pclmul.c",
    "hash/ghash_pwr8.c",
    "hash/md5.c",
    "hash/md5sha1.c",
    "hash/mgf1.c",
    "hash/multihash.c",
    "hash/sha1.c",
    "hash/sha2big.c",
    "hash/sha2small.c",
    // Big integer (all three sizes for BearSSL's internal dispatch)
    "int/i15_add.c",
    "int/i15_bitlen.c",
    "int/i15_decmod.c",
    "int/i15_decode.c",
    "int/i15_decred.c",
    "int/i15_encode.c",
    "int/i15_fmont.c",
    "int/i15_iszero.c",
    "int/i15_moddiv.c",
    "int/i15_modpow.c",
    "int/i15_modpow2.c",
    "int/i15_montmul.c",
    "int/i15_mulacc.c",
    "int/i15_muladd.c",
    "int/i15_ninv15.c",
    "int/i15_reduce.c",
    "int/i15_rshift.c",
    "int/i15_sub.c",
    "int/i15_tmont.c",
    "int/i31_add.c",
    "int/i31_bitlen.c",
    "int/i31_decmod.c",
    "int/i31_decode.c",
    "int/i31_decred.c",
    "int/i31_encode.c",
    "int/i31_fmont.c",
    "int/i31_iszero.c",
    "int/i31_moddiv.c",
    "int/i31_modpow.c",
    "int/i31_modpow2.c",
    "int/i31_montmul.c",
    "int/i31_mulacc.c",
    "int/i31_muladd.c",
    "int/i31_ninv31.c",
    "int/i31_reduce.c",
    "int/i31_rshift.c",
    "int/i31_sub.c",
    "int/i31_tmont.c",
    "int/i32_add.c",
    "int/i32_bitlen.c",
    "int/i32_decmod.c",
    "int/i32_decode.c",
    "int/i32_decred.c",
    "int/i32_div32.c",
    "int/i32_encode.c",
    "int/i32_fmont.c",
    "int/i32_iszero.c",
    "int/i32_modpow.c",
    "int/i32_montmul.c",
    "int/i32_mulacc.c",
    "int/i32_muladd.c",
    "int/i32_ninv32.c",
    "int/i32_reduce.c",
    "int/i32_sub.c",
    "int/i32_tmont.c",
    "int/i62_modpow2.c",
    // KDF
    "kdf/hkdf.c",
    "kdf/shake.c",
    // MAC
    "mac/hmac.c",
    "mac/hmac_ct.c",
    // PRNG
    "rand/aesctr_drbg.c",
    "rand/hmac_drbg.c",
    // RSA
    "rsa/rsa_default_keygen.c",
    "rsa/rsa_default_modulus.c",
    "rsa/rsa_default_oaep_decrypt.c",
    "rsa/rsa_default_oaep_encrypt.c",
    "rsa/rsa_default_pkcs1_sign.c",
    "rsa/rsa_default_pkcs1_vrfy.c",
    "rsa/rsa_default_priv.c",
    "rsa/rsa_default_privexp.c",
    "rsa/rsa_default_pss_sign.c",
    "rsa/rsa_default_pss_vrfy.c",
    "rsa/rsa_default_pub.c",
    "rsa/rsa_default_pubexp.c",
    "rsa/rsa_i15_keygen.c",
    "rsa/rsa_i15_modulus.c",
    "rsa/rsa_i15_oaep_decrypt.c",
    "rsa/rsa_i15_oaep_encrypt.c",
    "rsa/rsa_i15_pkcs1_sign.c",
    "rsa/rsa_i15_pkcs1_vrfy.c",
    "rsa/rsa_i15_priv.c",
    "rsa/rsa_i15_privexp.c",
    "rsa/rsa_i15_pss_sign.c",
    "rsa/rsa_i15_pss_vrfy.c",
    "rsa/rsa_i15_pub.c",
    "rsa/rsa_i15_pubexp.c",
    "rsa/rsa_i31_keygen_inner.c",
    "rsa/rsa_i31_keygen.c",
    "rsa/rsa_i31_modulus.c",
    "rsa/rsa_i31_oaep_decrypt.c",
    "rsa/rsa_i31_oaep_encrypt.c",
    "rsa/rsa_i31_pkcs1_sign.c",
    "rsa/rsa_i31_pkcs1_vrfy.c",
    "rsa/rsa_i31_priv.c",
    "rsa/rsa_i31_privexp.c",
    "rsa/rsa_i31_pss_sign.c",
    "rsa/rsa_i31_pss_vrfy.c",
    "rsa/rsa_i31_pub.c",
    "rsa/rsa_i31_pubexp.c",
    "rsa/rsa_i32_oaep_decrypt.c",
    "rsa/rsa_i32_oaep_encrypt.c",
    "rsa/rsa_i32_pkcs1_sign.c",
    "rsa/rsa_i32_pkcs1_vrfy.c",
    "rsa/rsa_i32_priv.c",
    "rsa/rsa_i32_pss_sign.c",
    "rsa/rsa_i32_pss_vrfy.c",
    "rsa/rsa_i32_pub.c",
    "rsa/rsa_i62_keygen.c",
    "rsa/rsa_i62_oaep_decrypt.c",
    "rsa/rsa_i62_oaep_encrypt.c",
    "rsa/rsa_i62_pkcs1_sign.c",
    "rsa/rsa_i62_pkcs1_vrfy.c",
    "rsa/rsa_i62_priv.c",
    "rsa/rsa_i62_pss_sign.c",
    "rsa/rsa_i62_pss_vrfy.c",
    "rsa/rsa_i62_pub.c",
    "rsa/rsa_oaep_pad.c",
    "rsa/rsa_oaep_unpad.c",
    "rsa/rsa_pkcs1_sig_pad.c",
    "rsa/rsa_pkcs1_sig_unpad.c",
    "rsa/rsa_pss_sig_pad.c",
    "rsa/rsa_pss_sig_unpad.c",
    "rsa/rsa_ssl_decrypt.c",
    // Settings
    "settings.c",
    // SSL/TLS engine
    "ssl/prf.c",
    "ssl/prf_md5sha1.c",
    "ssl/prf_sha256.c",
    "ssl/prf_sha384.c",
    "ssl/ssl_ccert_single_ec.c",
    "ssl/ssl_ccert_single_rsa.c",
    "ssl/ssl_client.c",
    "ssl/ssl_client_default_rsapub.c",
    "ssl/ssl_client_full.c",
    "ssl/ssl_engine.c",
    "ssl/ssl_engine_default_aescbc.c",
    "ssl/ssl_engine_default_aesccm.c",
    "ssl/ssl_engine_default_aesgcm.c",
    "ssl/ssl_engine_default_chapol.c",
    "ssl/ssl_engine_default_descbc.c",
    "ssl/ssl_engine_default_ec.c",
    "ssl/ssl_engine_default_ecdsa.c",
    "ssl/ssl_engine_default_rsavrfy.c",
    "ssl/ssl_hashes.c",
    "ssl/ssl_hs_client.c",
    "ssl/ssl_hs_server.c",
    "ssl/ssl_io.c",
    "ssl/ssl_keyexport.c",
    "ssl/ssl_lru.c",
    "ssl/ssl_rec_cbc.c",
    "ssl/ssl_rec_ccm.c",
    "ssl/ssl_rec_chapol.c",
    "ssl/ssl_rec_gcm.c",
    "ssl/ssl_scert_single_ec.c",
    "ssl/ssl_scert_single_rsa.c",
    "ssl/ssl_server.c",
    "ssl/ssl_server_full_ec.c",
    "ssl/ssl_server_full_rsa.c",
    "ssl/ssl_server_mine2c.c",
    "ssl/ssl_server_mine2g.c",
    "ssl/ssl_server_minf2c.c",
    "ssl/ssl_server_minf2g.c",
    "ssl/ssl_server_minr2g.c",
    "ssl/ssl_server_minu2g.c",
    "ssl/ssl_server_minv2g.c",
    // Symmetric ciphers
    "symcipher/aes_big_cbcdec.c",
    "symcipher/aes_big_cbcenc.c",
    "symcipher/aes_big_ctr.c",
    "symcipher/aes_big_ctrcbc.c",
    "symcipher/aes_big_dec.c",
    "symcipher/aes_big_enc.c",
    "symcipher/aes_common.c",
    "symcipher/aes_ct.c",
    "symcipher/aes_ct_cbcdec.c",
    "symcipher/aes_ct_cbcenc.c",
    "symcipher/aes_ct_ctr.c",
    "symcipher/aes_ct_ctrcbc.c",
    "symcipher/aes_ct_dec.c",
    "symcipher/aes_ct_enc.c",
    "symcipher/aes_ct64.c",
    "symcipher/aes_ct64_cbcdec.c",
    "symcipher/aes_ct64_cbcenc.c",
    "symcipher/aes_ct64_ctr.c",
    "symcipher/aes_ct64_ctrcbc.c",
    "symcipher/aes_ct64_dec.c",
    "symcipher/aes_ct64_enc.c",
    "symcipher/aes_pwr8.c",
    "symcipher/aes_pwr8_cbcdec.c",
    "symcipher/aes_pwr8_cbcenc.c",
    "symcipher/aes_pwr8_ctr.c",
    "symcipher/aes_pwr8_ctrcbc.c",
    "symcipher/aes_small_cbcdec.c",
    "symcipher/aes_small_cbcenc.c",
    "symcipher/aes_small_ctr.c",
    "symcipher/aes_small_ctrcbc.c",
    "symcipher/aes_small_dec.c",
    "symcipher/aes_small_enc.c",
    "symcipher/aes_x86ni.c",
    "symcipher/aes_x86ni_cbcdec.c",
    "symcipher/aes_x86ni_cbcenc.c",
    "symcipher/aes_x86ni_ctr.c",
    "symcipher/aes_x86ni_ctrcbc.c",
    "symcipher/chacha20_ct.c",
    "symcipher/chacha20_sse2.c",
    "symcipher/des_ct.c",
    "symcipher/des_ct_cbcdec.c",
    "symcipher/des_ct_cbcenc.c",
    "symcipher/des_support.c",
    "symcipher/des_tab.c",
    "symcipher/des_tab_cbcdec.c",
    "symcipher/des_tab_cbcenc.c",
    "symcipher/poly1305_ctmul.c",
    "symcipher/poly1305_ctmul32.c",
    "symcipher/poly1305_ctmulq.c",
    "symcipher/poly1305_i15.c",
    // X.509 certificate handling
    "x509/asn1enc.c",
    "x509/encode_ec_pk8der.c",
    "x509/encode_ec_rawder.c",
    "x509/encode_rsa_pk8der.c",
    "x509/encode_rsa_rawder.c",
    "x509/skey_decoder.c",
    "x509/x509_decoder.c",
    "x509/x509_knownkey.c",
    "x509/x509_minimal.c",
    "x509/x509_minimal_full.c",
};
