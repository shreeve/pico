/// Shared syntax types for the nanoruby parser and compiler.
///
/// Sexp is the universal AST representation produced by the Nexus-generated
/// parser and consumed by the compiler. Tag is the semantic node type enum
/// defined by the grammar.

/// Re-export Tag from the language module (ruby.zig).
/// This is the canonical source of truth for all semantic node types.
pub const Tag = @import("../ruby.zig").Tag;

/// S-expression node — the parser's output and compiler's input.
///
/// Encoding follows the Nexus convention:
///   (tag child1 child2 ...)  → .list with first element .tag
///   source token             → .src with position/length into source
///   embedded string          → .str
///   absent / placeholder     → .nil
pub const Sexp = union(enum) {
    nil: void,
    tag: Tag,
    src: SrcRef,
    str: []const u8,
    list: []const Sexp,

    pub const SrcRef = struct { pos: u32, len: u16, id: u16 };

    /// Extract token text from the original source string.
    pub fn getText(self: Sexp, source: []const u8) []const u8 {
        return switch (self) {
            .src => |s| source[s.pos..][0..s.len],
            .str => |s| s,
            else => "",
        };
    }

    /// Get the semantic tag if this is a compound node (list with tag prefix)
    /// or a bare tag.
    pub fn nodeTag(self: Sexp) ?Tag {
        return switch (self) {
            .tag => |t| t,
            .list => |items| if (items.len > 0) switch (items[0]) {
                .tag => |t| t,
                else => null,
            } else null,
            else => null,
        };
    }

    /// Check if this is a node with a specific tag.
    pub fn isNode(self: Sexp, tag: Tag) bool {
        const t = self.nodeTag() orelse return false;
        return t == tag;
    }

    /// Get the nth semantic child (0-indexed, excludes the tag element).
    /// For a list `[tag, c0, c1, c2]`, `child(0)` returns `c0`.
    pub fn child(self: Sexp, index: usize) Sexp {
        return switch (self) {
            .list => |items| {
                const ci = index + 1; // skip tag
                return if (ci < items.len) items[ci] else .nil;
            },
            else => .nil,
        };
    }

    /// Number of semantic children (excludes the tag element).
    pub fn childCount(self: Sexp) usize {
        return switch (self) {
            .list => |items| if (items.len > 0) items.len - 1 else 0,
            else => 0,
        };
    }

    /// Is this a nil/empty node?
    pub fn isNil(self: Sexp) bool {
        return self == .nil;
    }

    /// Is this a source token (identifier, literal, etc.)?
    pub fn isToken(self: Sexp) bool {
        return switch (self) {
            .src, .str => true,
            else => false,
        };
    }

    // ── Builders (for tests and hand-constructed trees) ──────────────

    /// Create a compound node: (tag children...).
    pub fn makeList(alloc: @import("std").mem.Allocator, tag: Tag, children: []const Sexp) !Sexp {
        const items = try alloc.alloc(Sexp, children.len + 1);
        items[0] = .{ .tag = tag };
        @memcpy(items[1..], children);
        return .{ .list = items };
    }

    /// Create a source token referencing a position in source text.
    pub fn makeSrc(pos: u32, len: u16) Sexp {
        return .{ .src = .{ .pos = pos, .len = len, .id = 0 } };
    }

    /// Create an embedded string token (for tests without a source buffer).
    pub fn makeStr(text: []const u8) Sexp {
        return .{ .str = text };
    }

    /// Create a bare tag node (e.g., `(true)`, `(false)`, `(nil)`).
    pub fn makeTag(tag: Tag) Sexp {
        return .{ .tag = tag };
    }
};
