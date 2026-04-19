const std = @import("std");
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const codegen = @import("compiler/codegen.zig");
const Compiler = codegen.Compiler;
const Value = @import("vm/value.zig").Value;
const VM = @import("vm/vm.zig").VM;
const nrb = @import("vm/nrb.zig");
const class = @import("vm/class.zig");
const class_debug = @import("vm/class_debug.zig");
const atom = @import("vm/atom.zig");

const usage =
    \\nrbc — nanoruby bytecode compiler
    \\
    \\Usage:
    \\  nrbc --run <source.rb>       Compile and execute immediately
    \\  nrbc <source.rb> -o <out>    Compile to .nrb binary
    \\  nrbc -e '<code>' --run       Compile string and execute
    \\
;

fn writeTo(io: std.Io, file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    fw.interface.print(fmt, args) catch return;
    fw.interface.flush() catch {};
}

fn print(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    writeTo(io, std.Io.File.stdout(), fmt, args);
}

fn eprint(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    writeTo(io, std.Io.File.stderr(), fmt, args);
}

fn die(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    eprint(io, fmt, args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);

    var source_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var eval_source: ?[]const u8 = null;
    var run_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--run")) {
            run_mode = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i < args.len) eval_source = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            eprint(io, "{s}", .{usage});
            return;
        } else {
            source_file = arg;
        }
    }

    const source: []const u8 = if (eval_source) |e|
        e
    else if (source_file) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch
            die(io, "nrbc: cannot read '{s}'\n", .{path})
    else {
        eprint(io, "{s}", .{usage});
        std.process.exit(1);
    };

    // Parse
    var p = Parser.init(alloc, source);
    defer p.deinit();
    const sexp = p.parseProgram() catch die(io, "nrbc: parse error\n", .{});

    // Compile
    var compiler = Compiler.init(source);
    const func = compiler.compileProgramAny(sexp) orelse {
        const msg = if (compiler.err) |e| e.message else "unknown error";
        die(io, "nrbc: compile error: {s}\n", .{msg});
    };

    if (run_mode) {
        var vm = VM.initDefault();

        // Register native methods
        const SymLookup = struct {
            var comp: *const Compiler = undefined;
            fn find(name: []const u8) ?u16 {
                return comp.findSymByName(name);
            }
        };
        SymLookup.comp = &compiler;
        class_debug.installNatives(&vm, &SymLookup.find);
        vm.setSymNew(atom.ATOM_NEW);
        vm.setSymInitialize(atom.ATOM_INITIALIZE);

        const result = vm.execute(&func);
        switch (result) {
            .ok => |v| {
                var out_buf: [4096]u8 = undefined;
                var fw = std.Io.File.stdout().writer(io, &out_buf);
                vm.inspect(&fw.interface, v) catch {};
                fw.interface.writeByte('\n') catch {};
                fw.interface.flush() catch {};
            },
            .err => |e| die(io, "nrbc: runtime error: {s}\n", .{@errorName(e)}),
        }
    }

    if (output_file) |path| {
        var buf: [32768]u8 = undefined;
        const data = nrb.serialize(&func, &buf) catch
            die(io, "nrbc: serialization error\n", .{});

        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch
            die(io, "nrbc: cannot write '{s}'\n", .{path});
        defer file.close(io);
        file.writeStreamingAll(io, data) catch die(io, "nrbc: write failed\n", .{});

        print(io, "nrbc: wrote {d} bytes to {s}\n", .{ data.len, path });
    }

    if (!run_mode and output_file == null)
        die(io, "nrbc: specify --run or -o <output>\n", .{});
}
