const std = @import("std");

const Board = enum {
    pico_w,
    pico2_w,
};

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "Target board") orelse .pico_w;
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
        .root = b.path("src/vm"),
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
    const atoms_h = gen_atoms.captureStdOut();

    // Generate pico_stdlib.h (without -a flag)
    const gen_stdlib = b.addRunArtifact(stdlib_gen);
    gen_stdlib.addArg("-m32");
    const stdlib_h = gen_stdlib.captureStdOut();

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

    const fw_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
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

    fw_module.addIncludePath(b.path("ext/mquickjs"));
    fw_module.addIncludePath(gen_dir);

    // Compile the generated stdlib embedding file (includes pico_stdlib.h)
    fw_module.addCSourceFiles(.{
        .root = b.path("src/vm"),
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
        .root_source_file = b.path("src/support.zig"),
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
        .root_source_file = b.path("src/support.zig"),
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
        .root = b.path("src/vm"),
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

    // ── Unit tests ──────────────────────────────────────────────────────
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .name = "pico-tests",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
