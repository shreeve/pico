comptime {
    // VM tests
    _ = @import("vm/value.zig");
    _ = @import("vm/opcode.zig");
    _ = @import("vm/vm.zig");
    _ = @import("vm/assembler.zig");
    _ = @import("vm/demo.zig");
    _ = @import("vm/nrb.zig");
    _ = @import("vm/symbol.zig");
    _ = @import("vm/heap.zig");
    _ = @import("vm/class.zig");
    _ = @import("vm/atom.zig");

    // Shared syntax types
    _ = @import("ruby/syntax.zig");

    // Compiler tests
    _ = @import("compiler/codegen.zig");

    // End-to-end: Ruby source → parse → compile → execute
    _ = @import("compiler/pipeline.zig");
}
