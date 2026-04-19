const std = @import("std");
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Sexp = parser_mod.Sexp;

fn dumpSexp(sexp: Sexp, source: []const u8, writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    const spaces = "                                                ";
    const indent = spaces[0..@min(depth * 2, spaces.len)];
    switch (sexp) {
        .nil => try writer.print("{s}NIL\n", .{indent}),
        .tag => |t| try writer.print("{s}TAG:{s}\n", .{ indent, @tagName(t) }),
        .src => |s| {
            const text = source[s.pos..][0..s.len];
            try writer.print("{s}SRC:\"{s}\"\n", .{ indent, text });
        },
        .str => |s| try writer.print("{s}STR:\"{s}\"\n", .{ indent, s }),
        .list => |items| {
            if (items.len > 0) {
                switch (items[0]) {
                    .tag => |t| try writer.print("{s}({s}\n", .{ indent, @tagName(t) }),
                    else => try writer.print("{s}(\n", .{indent}),
                }
                for (items[1..]) |item| try dumpSexp(item, source, writer, depth + 1);
                try writer.print("{s})\n", .{indent});
            } else {
                try writer.print("{s}()\n", .{indent});
            }
        },
    }
}

fn testParse(allocator: std.mem.Allocator, io: std.Io, source: []const u8) void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    w.print("\n=== \"{s}\" ===\n", .{source}) catch {};
    var p = Parser.init(allocator, source);
    defer p.deinit();
    const result = p.parseProgram() catch {
        w.print("PARSE ERROR\n", .{}) catch {};
        std.Io.File.stderr().writeStreamingAll(io, w.buffered()) catch {};
        return;
    };
    dumpSexp(result, source, &w, 0) catch {};
    std.Io.File.stderr().writeStreamingAll(io, w.buffered()) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    // Basics
    testParse(alloc, io, "42");
    testParse(alloc, io, "1 + 2");
    testParse(alloc, io, "true");
    testParse(alloc, io, "false");
    testParse(alloc, io, "nil");
    testParse(alloc, io, "a = 5");

    // Multi-statement
    testParse(alloc, io, "a = 40; b = 2; a + b");

    // If/else
    testParse(alloc, io, "if true then 1 else 2 end");
    testParse(alloc, io, "if false then 1 else 2 end");
    testParse(alloc, io, "if 0 then 1 else 2 end");

    // Unless
    testParse(alloc, io, "unless false then 3 end");

    // While
    testParse(alloc, io, "while true; 1; end");

    // Nested
    testParse(alloc, io, "if true then if false then 1 else 2 end else 3 end");

    // Def
    testParse(alloc, io, "def add(a,b); a + b; end");

    // Constant reference
    testParse(alloc, io, "Dog");
    testParse(alloc, io, "42; Dog");

    // Class
    testParse(alloc, io, "class Dog; end");

    // Indexing
    testParse(alloc, io, "a = [1,2,3]; a[1]");
    testParse(alloc, io, "[1,2,3][1]");
    testParse(alloc, io, "[1,2,3].join(',')");
    testParse(alloc, io, "[1,2,3].join(',').length");

    // Multiple assignment + defined? + rescue modifier
    testParse(alloc, io, "a, b = 1, 2");
    testParse(alloc, io, "a, b, c = 10, 20, 30");
    testParse(alloc, io, "defined?(foo)");
    testParse(alloc, io, "defined?(a)");
    testParse(alloc, io, "defined?(42)");
    testParse(alloc, io, "x = 1/0 rescue 99");

    // Block forms
    testParse(alloc, io, "3.times { |i| 1 }");
    testParse(alloc, io, "[1,2,3].each { |x| x }");
    testParse(alloc, io, "def f; yield 7; end; f { |x| x }");
    testParse(alloc, io, "f(1) { |x| x }");

    // Chain precedence debug
    testParse(alloc, io, "x.length");
    testParse(alloc, io, "x.y(1).z");
    testParse(alloc, io, "x.y('a').z");
    testParse(alloc, io, "f(1).g");
    testParse(alloc, io, "f(1, 2).g");
    testParse(alloc, io, "(1).z");
    testParse(alloc, io, "(1)");
    testParse(alloc, io, "foo.bar(x).baz");
    testParse(alloc, io, "x.y(1) + 2");
    testParse(alloc, io, "x.y(1); z");
    testParse(alloc, io, "a = x.y(1); a.z");
    testParse(alloc, io, "x.y(a).z");
    testParse(alloc, io, "x.y(1.0).z");
    testParse(alloc, io, "x.y().z");
    testParse(alloc, io, "x.y(1).z.w");

    // Gap-1 diagnostics
    testParse(alloc, io, "a[1]");
    testParse(alloc, io, "a[1,2]");
    testParse(alloc, io, "[1,2,3][0]");

    // Begin/rescue diag
    testParse(alloc, io, "begin; 1; rescue; 2; end");
    testParse(alloc, io, "begin; 1/0; rescue; 42; end");
}
