const std = @import("std");
const parser_mod = @import("../parser.zig");
const Parser = parser_mod.Parser;
const codegen = @import("codegen.zig");
const Compiler = codegen.Compiler;
const Value = @import("../vm/value.zig").Value;
const VM = @import("../vm/vm.zig").VM;
const class = @import("../vm/class.zig");
const atom = @import("../vm/atom.zig");

/// Parse, compile, and execute Ruby source. Returns the result value.
pub fn compileAndRun(source: []const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse: source -> Sexp
    var p = Parser.init(alloc, source);
    defer p.deinit();
    const sexp = p.parseProgram() catch return error.ParseError;

    // Compile: Sexp -> bytecode (parser.Sexp and syntax.Sexp have same API)
    var compiler = Compiler.init(source);
    const func = compiler.compileProgramAny(sexp) orelse return error.CompileError;

    var vm = VM.initDefault();

    // Register native methods — atoms give stable IDs, findSymByName
    // matches them against symbols that actually appear in compiled code
    const SymLookup = struct {
        var comp: *const Compiler = undefined;
        fn find(name: []const u8) ?u16 {
            return comp.findSymByName(name);
        }
    };
    SymLookup.comp = &compiler;
    class.installNatives(&vm, &SymLookup.find);

    // Well-known atoms for core VM dispatch
    vm.setSymNew(atom.ATOM_NEW);
    vm.setSymInitialize(atom.ATOM_INITIALIZE);
    const result = vm.execute(&func);
    return switch (result) {
        .ok => |v| v,
        .err => error.RuntimeError,
    };
}

// ═════════════════════════════════════════════════════════════════════
// End-to-end tests: real Ruby source → result
// ═════════════════════════════════════════════════════════════════════

fn expectFixnum(source: []const u8, expected: i32) !void {
    const result = try compileAndRun(source);
    const actual = result.asFixnum() orelse return error.NotFixnum;
    try std.testing.expectEqual(expected, actual);
}

fn expectTrue(source: []const u8) !void {
    try std.testing.expect((try compileAndRun(source)).isTrue());
}

fn expectFalse(source: []const u8) !void {
    try std.testing.expect((try compileAndRun(source)).isFalse());
}

fn expectNil(source: []const u8) !void {
    try std.testing.expect((try compileAndRun(source)).isNil());
}

/// Run `source` and expect a Float result whose value matches `expected`
/// within 1e-9 absolute tolerance. Uses the VM's getFloatData, so this
/// also verifies the Value is in fact a heap-boxed Float (not fixnum).
fn expectFloat(source: []const u8, expected: f64) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser_mod.Parser.init(alloc, source);
    defer p.deinit();
    const sexp = p.parseProgram() catch return error.ParseError;

    var compiler = codegen.Compiler.init(source);
    const func = compiler.compileProgramAny(sexp) orelse return error.CompileError;

    var vm = VM.initDefault();
    const SymLookup = struct {
        var comp: *const codegen.Compiler = undefined;
        fn find(name: []const u8) ?u16 {
            return comp.findSymByName(name);
        }
    };
    SymLookup.comp = &compiler;
    class.installNatives(&vm, &SymLookup.find);
    vm.setSymNew(atom.ATOM_NEW);
    vm.setSymInitialize(atom.ATOM_INITIALIZE);
    const result = vm.execute(&func);
    switch (result) {
        .ok => |v| {
            const f = vm.getFloatData(v) orelse return error.NotFloat;
            try std.testing.expectApproxEqAbs(expected, f, 1e-9);
        },
        .err => return error.RuntimeError,
    }
}

test "e2e: integer literal" {
    try expectFixnum("42", 42);
}

test "e2e: true" {
    try expectTrue("true");
}

test "e2e: false" {
    try expectFalse("false");
}

test "e2e: nil" {
    try expectNil("nil");
}

test "e2e: addition" {
    try expectFixnum("40 + 2", 42);
}

test "e2e: subtraction" {
    try expectFixnum("10 - 3", 7);
}

test "e2e: multiplication" {
    try expectFixnum("6 * 8", 48);
}

test "e2e: division" {
    try expectFixnum("7 / 3", 2);
}

test "e2e: comparison" {
    try expectTrue("3 < 5");
    try expectFalse("5 < 3");
    try expectTrue("3 == 3");
}

test "e2e: local variable" {
    try expectFixnum("a = 5; a", 5);
}

test "e2e: local arithmetic" { try expectFixnum("a = 40; b = 2; a + b", 42); }
test "e2e: single assignment" { try expectFixnum("a = 42; a", 42); }

test "e2e: if true" { try expectFixnum("if true then 1 else 2 end", 1); }
test "e2e: if false" { try expectFixnum("if false then 1 else 2 end", 2); }

test "e2e: nested arithmetic" {
    try expectFixnum("(10 + 20) * 2", 60);
}

test "e2e: while loop" { try expectFixnum("i = 0; while i < 5; i = i + 1; end; i", 5); }

test "e2e: complex expression" {
    try expectFixnum("a = 10; b = 3; c = a * b + 2; c", 32);
}

test "e2e: zero is truthy" { try expectFixnum("if 0 then 1 else 2 end", 1); }

test "e2e: def + call returns 42" {
    try expectFixnum("def add(a, b); a + b; end; add(20, 22)", 42);
}

test "e2e: def no-arg method" {
    try expectFixnum("def answer; 42; end; answer", 42);
}

test "e2e: multiple method defs" {
    try expectFixnum("def double(x); x + x; end; def inc(x); x + 1; end; inc(double(20))", 41);
}

test "e2e: class with method" {
    try expectFixnum(
        \\class Dog
        \\  def speak
        \\    42
        \\  end
        \\end
        \\Dog.new.speak
    , 42);
}

// ── Instance variables (3.8) ────────────────────────────────────────

test "e2e: instance variable set and get" {
    try expectFixnum(
        \\class Dog
        \\  def set_age(a)
        \\    @age = a
        \\  end
        \\  def get_age
        \\    @age
        \\  end
        \\end
        \\d = Dog.new
        \\d.set_age(5)
        \\d.get_age
    , 5);
}

test "e2e: multiple instance variables" {
    try expectFixnum(
        \\class Point
        \\  def set(x, y)
        \\    @x = x
        \\    @y = y
        \\  end
        \\  def sum
        \\    @x + @y
        \\  end
        \\end
        \\p = Point.new
        \\p.set(10, 32)
        \\p.sum
    , 42);
}

// ── Global variables (3.21) ──────────────────────────────────────────

test "e2e: global variable" {
    try expectFixnum(
        \\$count = 42
        \\$count
    , 42);
}

// ── Comparison operators + range (3.20) ──────────────────────────────

test "e2e: not-equal" {
    try expectTrue("3 != 5");
    try expectFalse("3 != 3");
}

test "e2e: unless with else" {
    try expectFixnum("unless true; 1; else; 2; end", 2);
}

test "e2e: until loop" {
    try expectFixnum("i = 0; until i == 5; i = i + 1; end; i", 5);
}

// ── Constructor: initialize (Class#new → initialize) ─────────────────

test "e2e: initialize called by new" {
    try expectFixnum(
        \\class Dog
        \\  def initialize(a)
        \\    @age = a
        \\  end
        \\  def age
        \\    @age
        \\  end
        \\end
        \\d = Dog.new(5)
        \\d.age
    , 5);
}

test "e2e: initialize with no args" {
    try expectFixnum(
        \\class Counter
        \\  def initialize
        \\    @val = 99
        \\  end
        \\  def val
        \\    @val
        \\  end
        \\end
        \\Counter.new.val
    , 99);
}

test "e2e: new returns instance not initialize return value" {
    try expectFixnum(
        \\class Foo
        \\  def initialize
        \\    @x = 42
        \\  end
        \\  def x
        \\    @x
        \\  end
        \\end
        \\Foo.new.x
    , 42);
}

// ── Native stdlib methods ────────────────────────────────────────────

test "e2e: Integer#to_s returns string" {
    // to_s returns a string object; test that length works on it
    try expectFixnum("42.to_s.length", 2);
}

test "e2e: Integer#abs" {
    try expectFixnum("(-5).abs", 5);
    try expectFixnum("5.abs", 5);
}

test "e2e: Integer predicates" {
    try expectTrue("0.zero?");
    try expectFalse("1.zero?");
    try expectTrue("4.even?");
    try expectFalse("3.even?");
    try expectTrue("3.odd?");
    try expectFalse("4.odd?");
}

test "e2e: String#length" {
    try expectFixnum("'hello'.length", 5);
    try expectFixnum("''.length", 0);
}

test "e2e: String#empty?" {
    try expectTrue("''.empty?");
    try expectFalse("'hi'.empty?");
}

test "e2e: Array#length" {
    try expectFixnum("[1, 2, 3].length", 3);
    try expectFixnum("[].length", 0);
}

test "e2e: Array#empty?" {
    try expectTrue("[].empty?");
    try expectFalse("[1].empty?");
}

test "e2e: Array#first and Array#last" {
    try expectFixnum("[10, 20, 30].first", 10);
    try expectFixnum("[10, 20, 30].last", 30);
}

// Array#[] indexing requires compiler support for `index` Sexp tag (TODO)
// test "e2e: Array#[] indexing" { ... }

test "e2e: nil?" {
    try expectTrue("nil.nil?");
    try expectFalse("42.nil?");
    try expectFalse("true.nil?");
}

test "e2e: Object#to_s on integer" {
    try expectFixnum("42.to_s.length", 2);
}

test "e2e: NilClass#to_s" {
    try expectFixnum("nil.to_s.length", 0);
}

test "e2e: TrueClass#to_s" {
    try expectFixnum("true.to_s.length", 4);
}

test "e2e: FalseClass#to_s" {
    try expectFixnum("false.to_s.length", 5);
}

// ── Hash methods ─────────────────────────────────────────────────────

test "e2e: Hash#length" {
    try expectFixnum("{}.length", 0);
}

test "e2e: Hash#empty?" {
    try expectTrue("{}.empty?");
}

// ── Exception handling (3.17) ────────────────────────────────────────

test "e2e: begin/rescue catches and returns rescue value" {
    try expectFixnum(
        \\begin
        \\  x = 1
        \\  x
        \\rescue
        \\  99
        \\end
    , 1);
}

test "e2e: begin without rescue is transparent" {
    try expectFixnum(
        \\begin
        \\  42
        \\end
    , 42);
}

// ── Phase 1: compound assignment, bitwise, send-dispatched ops ───────

test "e2e: compound += local" { try expectFixnum("a = 5; a += 2; a", 7); }
test "e2e: compound -= local" { try expectFixnum("a = 10; a -= 3; a", 7); }
test "e2e: compound *= local" { try expectFixnum("a = 3; a *= 4; a", 12); }
test "e2e: compound /= local" { try expectFixnum("a = 20; a /= 3; a", 6); }
test "e2e: compound %= local" { try expectFixnum("a = 17; a %= 5; a", 2); }
test "e2e: compound |= local" { try expectFixnum("a = 1; a |= 6; a", 7); }
test "e2e: compound &= local" { try expectFixnum("a = 7; a &= 5; a", 5); }
test "e2e: compound <<= local" { try expectFixnum("a = 1; a <<= 4; a", 16); }
test "e2e: compound **= local" { try expectFixnum("a = 2; a **= 10; a", 1024); }
test "e2e: ||= on nil assigns" { try expectFixnum("a = nil; a ||= 9; a", 9); }
test "e2e: ||= on value keeps" { try expectFixnum("a = 1; a ||= 9; a", 1); }
test "e2e: &&= on value reassigns" { try expectFixnum("a = 1; a &&= 9; a", 9); }
test "e2e: &&= on nil short-circuits" { try expectNil("a = nil; a &&= 9; a"); }
test "e2e: += on ivar" {
    try expectFixnum(
        \\class C
        \\  def f
        \\    @x = 10
        \\    @x += 5
        \\    @x
        \\  end
        \\end
        \\C.new.f
    , 15);
}
test "e2e: += on gvar" { try expectFixnum("$x = 10; $x += 5; $x", 15); }

test "e2e: bitwise &" { try expectFixnum("6 & 3", 2); }
test "e2e: bitwise |" { try expectFixnum("5 | 2", 7); }
test "e2e: bitwise ^" { try expectFixnum("5 ^ 3", 6); }
test "e2e: shift <<" { try expectFixnum("1 << 4", 16); }
test "e2e: shift >>" { try expectFixnum("16 >> 2", 4); }
test "e2e: bitwise ~" { try expectFixnum("~5", -6); }
test "e2e: power **" { try expectFixnum("2 ** 10", 1024); }

test "e2e: spaceship lt" { try expectFixnum("1 <=> 2", -1); }
test "e2e: spaceship eq" { try expectFixnum("2 <=> 2", 0); }
test "e2e: spaceship gt" { try expectFixnum("3 <=> 2", 1); }

// ── Phase 1: string / array method dispatch via ADD fallback ─────────

test "e2e: string concat +" {
    // Runs and returns a heap string; we sanity-check via length.
    try expectFixnum("('hello' + ' world').length", 11);
}
test "e2e: string multiply" { try expectFixnum("('ab' * 3).length", 6); }
test "e2e: string ==" { try expectTrue("'abc' == 'abc'"); }
test "e2e: string == different" { try expectFalse("'abc' == 'xyz'"); }
test "e2e: string == after concat" { try expectTrue("('a' + 'b') == 'ab'"); }
test "e2e: array +" { try expectFixnum("([1,2] + [3,4]).length", 4); }
test "e2e: array include? hit" { try expectTrue("[1,2,3].include?(2)"); }
test "e2e: array include? miss" { try expectFalse("[1,2,3].include?(99)"); }
// NOTE: `[1,2,3].join(',').length` is blocked by a parser precedence
// gap — the rewriter attaches `.length` to the ',' string inside the
// join-args parens rather than to the join result.
test "e2e: array join length via local" {
    try expectFixnum("s = [1,2,3].join(','); s.length", 5);
}

// ── Phase 1: safe navigation ─────────────────────────────────────────

test "e2e: safe nav on nil" { try expectNil("nil&.foo"); }
test "e2e: safe nav on value" { try expectFixnum("'hi'&.length", 2); }

// ── Phase 1: equality on immediates ──────────────────────────────────

test "e2e: nil == nil" { try expectTrue("nil == nil"); }
test "e2e: true != false" { try expectTrue("true != false"); }
test "e2e: symbol equality" { try expectTrue(":foo == :foo"); }

// ── Phase 2: multiple assignment ─────────────────────────────────────

test "e2e: masgn simple" { try expectFixnum("a, b = 1, 2; a + b", 3); }
test "e2e: masgn three" { try expectFixnum("a, b, c = 10, 20, 30; a + b + c", 60); }
test "e2e: masgn swap" { try expectFixnum("a = 1; b = 2; a, b = b, a; a * 10 + b", 21); }

// ── Phase 2: defined? (minimal, narrow semantics) ────────────────────

test "e2e: defined? local (undef)" {
    // Unknown bare name → "method" (6 chars). Parser precedence makes
    // `.length` on a defined? result problematic at the expression site,
    // so we stash it in a local first.
    try expectFixnum("r = defined?(foo_that_is_unknown); r.length", 6);
}
test "e2e: defined? integer" {
    try expectFixnum("r = defined?(42); r.length", 10); // "expression"
}
test "e2e: defined? local (defined)" {
    try expectFixnum("x = 1; r = defined?(x); r.length", 14); // "local-variable"
}

// ── Phase 2: rescue modifier ─────────────────────────────────────────
//
// Rescue modifier compiles to a PUSH_HANDLER / body / POP_HANDLER / JMP
// pattern, identical to `begin/rescue/end`. Catches explicitly raised
// exceptions; built-in VM errors (DivisionByZero, TypeError, …) don't
// currently unwind to handlers — pre-existing VM limitation, same as
// the full begin/rescue form. Documented here for future wiring.

test "e2e: rescue modifier (success path)" {
    try expectFixnum("x = 42 rescue 99", 42);
}

// ── Phase 3: blocks ──────────────────────────────────────────────────
//
// Blocks compile as child IrFuncs; at the call site, BLOCK packages
// the child-func ID into a Value passed alongside args via SEND_BLOCK.
// Natives with block-consuming semantics (times / each / map) receive
// the block as `?Value` and invoke it through VM.yieldBlock, which
// reenters the interpreter at the current frame depth and returns the
// block's last expression.
//
// One-level closures work: a block sees its enclosing method's locals
// via GET_UPVAR / SET_UPVAR (level=1). Nested blocks (block-inside-a-
// block) are intentionally not yet supported — the N-level upvar chain
// and sym-table merging haven't been wired.
// `break`/`next`/`redo` inside blocks are also deferred.

test "e2e: 3.times returns receiver" { try expectFixnum("3.times { |i| 1 }", 3); }
test "e2e: times counts invocations" { try expectFixnum("n = 0; 3.times { |i| n = n + 1 }; n", 3); }
test "e2e: times passes index" { try expectFixnum("s = 0; 5.times { |i| s = s + i }; s", 10); }
test "e2e: array each sums" { try expectFixnum("s = 0; [1,2,3].each { |x| s = s + x }; s", 6); }
test "e2e: array each with predicate" {
    try expectFixnum("c = 0; [1,2,3,4,5].each { |x| c = c + 1 if x > 2 }; c", 3);
}
test "e2e: array map length" {
    try expectFixnum("r = [1,2,3].map { |x| x * 2 }; r.length", 3);
}
test "e2e: array map first" {
    try expectFixnum("r = [1,2,3].map { |x| x * 2 }; r.first", 2);
}
test "e2e: range each inclusive" { try expectFixnum("s = 0; (1..5).each { |i| s = s + i }; s", 15); }
test "e2e: range each exclusive" { try expectFixnum("s = 0; (1...5).each { |i| s = s + i }; s", 10); }
test "e2e: range each big" { try expectFixnum("s = 0; (0..9).each { |i| s = s + i }; s", 45); }

// ── Grammar gaps 1 & 2: indexed read + no-paren brace-block ──────────

test "e2e: indexed read local array" {
    try expectFixnum("a = [10, 20, 30]; a[1]", 20);
}
test "e2e: indexed read negative" {
    try expectFixnum("a = [10, 20, 30]; a[-1]", 30);
}
test "e2e: indexed read literal" {
    try expectFixnum("[10, 20, 30][2]", 30);
}
test "e2e: indexed read hash" {
    try expectFixnum("h = {:a=>1, :b=>2, :c=>3}; h[:b]", 2);
}
test "e2e: indexed read hash missing" {
    try expectNil("h = {:a=>1}; h[:missing]");
}
test "e2e: no-paren method + brace block" {
    try expectFixnum("def f; yield 42; end; f { |x| x + 1 }", 43);
}
test "e2e: no-paren method + brace block multi-arg" {
    try expectFixnum("def g; yield 3, 4; end; g { |a, b| a + b }", 7);
}

// ── B7: blocks inside method bodies ──────────────────────────────────

test "e2e: block inside method — each sums" {
    try expectFixnum("def f; s = 0; [1,2,3].each { |x| s = s + x }; s; end; f", 6);
}
test "e2e: block inside method — times counts" {
    try expectFixnum("def f; n = 0; 5.times { |i| n = n + i }; n; end; f", 10);
}
test "e2e: block inside method with arg" {
    try expectFixnum("def f(arr); s=0; arr.each { |x| s=s+x }; s; end; f([10,20,30])", 60);
}
test "e2e: map inside method" {
    try expectFixnum("def f; [1,2,3].map { |x| x * 2 }; end; f.length", 3);
}

// ── Nested blocks ────────────────────────────────────────────────────

test "e2e: nested times top-level" {
    try expectFixnum("n = 0; 2.times { |i| 2.times { |j| n = n + 1 } }; n", 4);
}
test "e2e: nested with both indexes" {
    try expectFixnum("s = 0; 3.times { |i| 3.times { |j| s = s + i*10 + j } }; s", 99);
}
test "e2e: nested in method body" {
    try expectFixnum("def f; n = 0; 2.times { |i| 2.times { |j| n = n + 1 } }; n; end; f", 4);
}
test "e2e: nested with method-arg closure" {
    try expectFixnum(
        \\def f(arr)
        \\  s = 0
        \\  arr.each { |row| row.each { |x| s = s + x } }
        \\  s
        \\end
        \\f([[1,2], [3,4]])
    , 10);
}
test "e2e: range.to_a then select then sum" {
    try expectFixnum(
        \\s = 0
        \\(1..10).to_a.select { |x| x.even? }.each { |x| s = s + x }
        \\s
    , 30);
}

// ── Iteration stdlib ────────────────────────────────────────────────

test "e2e: Array#select filters by predicate" {
    try expectFixnum("[1,2,3,4,5].select { |x| x > 2 }.length", 3);
}
test "e2e: Array#reject is inverse of select" {
    try expectFixnum("[1,2,3,4,5].reject { |x| x.even? }.length", 3);
}
test "e2e: Array#inject sums with init" {
    try expectFixnum("[1,2,3,4,5].inject(0) { |a, x| a + x }", 15);
}
test "e2e: Array#inject without init uses first" {
    try expectFixnum("[1,2,3,4,5].inject { |a, x| a + x }", 15);
}
test "e2e: Array#reduce as alias" {
    try expectFixnum("[2,3,4].reduce(1) { |a, x| a * x }", 24);
}
test "e2e: Array#sort returns sorted copy (first)" {
    try expectFixnum("a = [3,1,4,1,5,9,2,6]; a.sort.first", 1);
}
test "e2e: Array#sort returns sorted copy (last)" {
    try expectFixnum("[3,1,4,1,5,9,2,6].sort.last", 9);
}
test "e2e: Array#each_with_index" {
    try expectFixnum(
        \\s = 0
        \\[10, 20, 30].each_with_index { |x, i| s = s + x + i }
        \\s
    , 63);
}
test "e2e: Hash#each yields key/value" {
    try expectFixnum("h = {:a=>1, :b=>2, :c=>3}; s = 0; h.each { |k, v| s = s + v }; s", 6);
}
test "e2e: Integer#upto sums" {
    try expectFixnum("s = 0; 1.upto(5) { |i| s = s + i }; s", 15);
}
test "e2e: Integer#downto" {
    try expectFixnum("s = 0; 5.downto(1) { |i| s = s + i }; s", 15);
}
test "e2e: Range#to_a length" {
    try expectFixnum("(1..5).to_a.length", 5);
}

// ── String interpolation (dstr) ─────────────────────────────────────

test "e2e: string interp basic length" {
    try expectFixnum("x = 42; (\"value=#{x}\").length", 8);
}
test "e2e: string interp multiple" {
    try expectFixnum("a = 1; b = 2; (\"#{a}+#{b}=#{a+b}\").length", 5);
}
test "e2e: string interp leading" {
    try expectFixnum("x = 5; (\"#{x}!\").length", 2);
}

// ── break / next / return-if-modifier ───────────────────────────────

test "e2e: break stops iteration" {
    try expectFixnum("n = 0; 5.times { |i| break if i == 3; n = n + 1 }; n", 3);
}
test "e2e: break returns value from iterator" {
    try expectFixnum("r = 5.times { |i| break 99 if i == 3 }; r", 99);
}
test "e2e: next skips iteration" {
    try expectFixnum("n = 0; 5.times { |i| next if i == 2; n = n + 1 }; n", 4);
}
test "e2e: next sums evens in range" {
    try expectFixnum("s = 0; (1..10).each { |i| next if i.odd?; s = s + i }; s", 30);
}
test "e2e: early exit via upto + break" {
    try expectFixnum("found = 0; 1.upto(100) { |i| found = i; break if i * i > 50 }; found", 8);
}
test "e2e: inner break doesn't affect outer loop" {
    // i=0: j=0 increments (count=1), j=1 breaks inner;
    // i=1: j=0 increments (count=2), j=1 breaks inner.
    try expectFixnum(
        "count = 0; 2.times { |i| 2.times { |j| break if j == 1; count = count + 1 } }; count",
        2,
    );
}
test "e2e: inject with break" {
    // Accumulate until x > 3, then break with current accumulator.
    try expectFixnum("[1,2,3,4,5].inject(0) { |a, x| break a if x > 3; a + x }", 6);
}
test "e2e: return val from method" {
    try expectFixnum("def f; return 42; end; f", 42);
}
test "e2e: early return via modifier" {
    try expectFixnum("def f(x); return 99 if x < 0; x * 2; end; f(-5)", 99);
}
test "e2e: return past modifier when cond false" {
    try expectFixnum("def f(x); return 99 if x < 0; x * 2; end; f(5)", 10);
}

// ── Exception binding: `rescue => e` ────────────────────────────────

test "e2e: rescue => e binds the exception value" {
    // The bound value is a symbol encoding the error name — different
    // errors get different symbol ids; the same error gives the same id.
    try expectTrue(
        \\a = nil; b = nil
        \\begin; 1/0; rescue => e1; a = e1; end
        \\begin; 1/0; rescue => e2; b = e2; end
        \\a == b
    );
}
test "e2e: different errors bind different symbols" {
    try expectFalse(
        \\a = nil; b = nil
        \\begin; 1/0; rescue => e1; a = e1; end
        \\begin; nil.missing_method; rescue => e2; b = e2; end
        \\a == b
    );
}
test "e2e: exception binding inside method" {
    try expectFixnum(
        \\def safe_div(x, y)
        \\  begin
        \\    x / y
        \\  rescue => e
        \\    -1
        \\  end
        \\end
        \\safe_div(10, 0)
    , -1);
}

// ── D: runtime errors route to rescue handlers ──────────────────────
//
// Built-in VM errors (DivisionByZero, TypeError, NoMethodError, …)
// now unwind to the innermost active PUSH_HANDLER within the current
// run(base_fp) window. Both `begin/rescue/end` and the `x rescue y`
// modifier catch them. The handler binds a synthesized fixnum
// exception value (the error name's int-from-error encoding) —
// enough for control flow; proper Exception objects are a later
// layer.

test "e2e: begin/rescue catches DivisionByZero" {
    try expectFixnum("begin; (1/0); rescue; 99; end", 99);
}
test "e2e: rescue modifier catches DivisionByZero" {
    try expectFixnum("x = (1/0) rescue 99; x", 99);
}
test "e2e: begin/rescue preserves body value on success" {
    try expectFixnum("begin; 42; rescue; 99; end", 42);
}
test "e2e: rescue body can be an expression" {
    try expectFixnum("begin; (1/0); rescue; 7 + 8; end", 15);
}
test "e2e: rescue inside method body" {
    try expectFixnum("def f; begin; 1/0; rescue; 7; end; end; f", 7);
}
test "e2e: nested begin/rescue — inner catches" {
    try expectFixnum("begin; begin; 1/0; rescue; 5; end; rescue; 9; end", 5);
}
test "e2e: begin/rescue catches NoMethodError" {
    // Rescue catches and returns its body; the literal `99` is the
    // unambiguous signal that the rescue path ran.
    try expectFixnum("begin; nil.missing_method; rescue; 99; end", 99);
}

// ── Float support (Phase 1: host-runnable) ───────────────────────────
//
// Floats are heap-boxed (see `RFloatPayload`) so 32-bit `Value`
// encoding stays intact. Every arithmetic / comparison operator that
// already fast-paths fixnums now has a second numeric fast path
// through `doFloatBinOp`: if either operand is a heap Float, both
// sides are coerced to f64 and the computation runs in double
// precision. Mixed-type expressions like `1 + 2.0` promote as Ruby
// does and the result is a new heap Float. Per Bellard's approach,
// this keeps us from having to widen `Value` to 64 bits or adopt
// NaN-boxing on the host.
//
// The embedded pass (Bellard's dtoa.c / libm.c / softfp_template.h)
// is intentionally left for a later phase — host Zig stdlib carries
// us for now.

test "e2e: float literal" { try expectFloat("3.14", 3.14); }
test "e2e: float literal with underscores" { try expectFloat("1_000.5", 1000.5); }
test "e2e: float with exponent" { try expectFloat("1.5e3", 1500.0); }

test "e2e: float addition" { try expectFloat("1.5 + 2.5", 4.0); }
test "e2e: float subtraction" { try expectFloat("5.25 - 1.25", 4.0); }
test "e2e: float multiplication" { try expectFloat("2.0 * 3.5", 7.0); }
test "e2e: float division" { try expectFloat("10.0 / 4.0", 2.5); }
test "e2e: float modulo" { try expectFloat("10.0 % 3.0", 1.0); }

test "e2e: float unary minus" { try expectFloat("-3.14", -3.14); }

test "e2e: int promoted by float rhs" { try expectFloat("1 + 2.0", 3.0); }
test "e2e: float promoted by int rhs" { try expectFloat("2.5 + 1", 3.5); }
test "e2e: int * float" { try expectFloat("3 * 0.5", 1.5); }
test "e2e: float / int" { try expectFloat("7.0 / 2", 3.5); }

// Classic Ruby "float is floating point, not exact decimal" smoke test —
// confirms we're using real f64 arithmetic, not some integer approx.
test "e2e: float imprecision visible" {
    // 0.1 + 0.2 != 0.3 in IEEE-754
    try expectFalse("0.1 + 0.2 == 0.3");
}

test "e2e: float comparison <" { try expectTrue("1.5 < 2.5"); }
test "e2e: float comparison >=" { try expectTrue("2.5 >= 2.5"); }
test "e2e: mixed numeric comparison" { try expectTrue("5 == 5.0"); }
test "e2e: mixed numeric comparison lt" { try expectTrue("4 < 4.5"); }

test "e2e: float equality same value" { try expectTrue("1.5 == 1.5"); }
test "e2e: float equality different values" { try expectFalse("1.5 == 1.6"); }

test "e2e: Integer#to_f" { try expectFloat("42.to_f", 42.0); }
test "e2e: Float#to_i truncates" { try expectFixnum("3.9.to_i", 3); }
test "e2e: Float#to_i negative truncates toward zero" { try expectFixnum("(-3.9).to_i", -3); }
test "e2e: Float#to_f is identity" { try expectFloat("3.14.to_f", 3.14); }

test "e2e: Float#abs" { try expectFloat("(-5.5).abs", 5.5); }
test "e2e: Float#zero?" { try expectTrue("0.0.zero?"); }
test "e2e: Float#zero? nonzero" { try expectFalse("0.1.zero?"); }

test "e2e: Float#to_s integral keeps .0" {
    // 2.0.to_s should be "2.0" (4 chars). The length check avoids
    // any cross-platform display drift.
    try expectFixnum("2.0.to_s.length", 3);
}
test "e2e: Float#to_s non-integral" {
    try expectFixnum("3.14.to_s.length", 4);
}

test "e2e: String#to_f basic" { try expectFloat("'3.14'.to_f", 3.14); }
test "e2e: String#to_f garbage" { try expectFloat("'abc'.to_f", 0.0); }
test "e2e: String#to_i basic" { try expectFixnum("'42'.to_i", 42); }

// IEEE-754 semantics for float division: zero divisors produce
// ±Infinity / NaN, no exception. Only `%` on a zero divisor raises
// (Ruby's asymmetric convention, mirrored here).
test "e2e: float divide by zero is positive infinity" {
    try expectTrue("(1.0 / 0.0) > 1.0e300");
}
test "e2e: negative float divide by zero is negative infinity" {
    try expectTrue("(-1.0 / 0.0) < -1.0e300");
}
test "e2e: zero divide zero is NaN" {
    // NaN != NaN, so (0.0/0.0) == (0.0/0.0) is false.
    try expectFalse("(0.0 / 0.0) == (0.0 / 0.0)");
}
test "e2e: float modulo by zero still raises" {
    try expectFixnum("x = (1.0 % 0.0) rescue 99; x", 99);
}
test "e2e: Ruby-compat float modulo sign follows divisor" {
    // 5.5 % -2.0 should be -0.5 (sign of divisor), not 1.5 (C fmod sign).
    try expectTrue("(5.5 % -2.0) < 0.0");
    try expectTrue("(-5.5 % 2.0) > 0.0");
}

// NaN unordered-comparison semantics.
test "e2e: NaN equals nothing" {
    try expectFalse("(0.0 / 0.0) == 1.0");
    try expectFalse("(0.0 / 0.0) == (0.0 / 0.0)");
}
test "e2e: NaN <=> returns nil" {
    try expectNil("(0.0 / 0.0) <=> 1.0");
    try expectNil("1.0 <=> (0.0 / 0.0)"); // Integer#<=> promotes Float RHS
}

// Hash key equality uses `eql?`-shape semantics — strict about type —
// so two separately-allocated heap `1.5`s do match but `1` and `1.0`
// do NOT (matches Ruby: `1.eql?(1.0) == false`). Array#include? still
// uses `==` (numeric coercion) and is covered separately below.
test "e2e: float hash key lookup" {
    try expectFixnum("h = {1.5 => 42}; h[1.5]", 42);
}
test "e2e: cross-type hash lookup is type-strict (Ruby eql? semantics)" {
    try expectNil("h = {1.0 => 42}; h[1]");
    try expectNil("h = {1 => 42}; h[1.0]");
}
test "e2e: Array#include? uses == (numeric coercion)" {
    // Array#include? is `==`-based, not `eql?`-based, so mixed
    // numeric types do match. This is the complement of the Hash
    // test above.
    try expectTrue("[1, 2, 3].include?(1.0)");
    try expectTrue("[1.0, 2.0].include?(1)");
}

// String#to_f longest-prefix parsing.
test "e2e: String#to_f ignores trailing garbage" {
    try expectFloat("'3.14abc'.to_f", 3.14);
}
test "e2e: String#to_f leading whitespace and sign" {
    try expectFloat("'   -2.5'.to_f", -2.5);
}
test "e2e: String#to_f with exponent prefix" {
    try expectFloat("'1.5e3 extra'.to_f", 1500.0);
}

// ── for/in loops ─────────────────────────────────────────────────────
//
// `for x in expr; body; end` is lowered in codegen to
// `expr.each { |x| body }` with the iteration variable bound in the
// ENCLOSING scope (Ruby semantics: no new scope, `x` leaks). Inherits
// the existing block control-flow plumbing (break/next). One known
// limitation: `return` from inside the body does not do non-local
// return — that's a pre-existing limitation of the block implementation,
// not specific to for/in. Multi-variable destructuring (`for a, b in …`)
// also deferred.

test "e2e: for/in basic sum" {
    try expectFixnum("s = 0; for i in [1,2,3]; s = s + i; end; s", 6);
}
test "e2e: for/in variable leaks with last value" {
    try expectFixnum("for x in [1,2,3]; end; x", 3);
}
test "e2e: for/in reuses pre-existing outer local" {
    try expectFixnum("x = 100; for x in [1,2]; end; x", 2);
}
test "e2e: for/in over range" {
    try expectFixnum("s = 0; for i in 1..5; s = s + i; end; s", 15);
}
test "e2e: for/in exclusive range" {
    try expectFixnum("s = 0; for i in 1...5; s = s + i; end; s", 10);
}
test "e2e: for/in with break" {
    try expectFixnum("for x in [1,2,3]; break if x == 2; end; x", 2);
}
test "e2e: for/in with break value (expression)" {
    try expectFixnum("def f; for x in [1,2,3]; break 7 if x == 2; end; end; f", 7);
}
test "e2e: for/in with next" {
    try expectFixnum("n = 0; for x in [1,2,3,4]; next if x == 2; n = n + x; end; n", 8);
}
test "e2e: for/in nested" {
    try expectFixnum("s = 0; for i in [1,2]; for j in [10,20]; s = s + i + j; end; end; s", 66);
}
test "e2e: for/in empty collection leaves body unrun" {
    try expectFixnum("s = 99; for x in []; s = 0; end; s", 99);
}

// ── `%w[…]` / `%i[…]` array literals ─────────────────────────────────
//
// `%w[…]` expands to an array of strings; `%i[…]` to an array of
// symbols. The literal is scanned by a custom path in `src/ruby.zig`'s
// Lexer wrapper (not the generated base lexer) because Nexus's regex
// engine doesn't cleanly express multi-delimiter scanning. Four paired
// delimiters are supported: `[]`, `()`, `{}`, `<>`. Commands like
// `puts %w[…]` and `p %w[…]` work too because `isCommandArg`
// special-cases the `%[wi]<delim>` prefix. Escapes (`\\ ` for embedded
// space) and `%W`/`%I` (interpolating forms) are out of scope.

test "e2e: %w length and elements" {
    try expectFixnum("a = %w[foo bar baz]; a.length", 3);
}
test "e2e: %w element equality" {
    try expectTrue("%w[hello world][0] == 'hello'");
}
test "e2e: %w paren delimiter" {
    try expectFixnum("%w(a b c).length", 3);
}
test "e2e: %w brace delimiter" {
    try expectFixnum("%w{x y z}.length", 3);
}
test "e2e: %w angle delimiter" {
    try expectFixnum("%w<p q>.length", 2);
}
test "e2e: %w empty literal" {
    try expectFixnum("%w[].length", 0);
}
test "e2e: %w extra whitespace is collapsed" {
    try expectFixnum("%w[  a   b  c  ].length", 3);
}
test "e2e: %i returns symbols" {
    try expectTrue("%i[foo bar][0] == :foo");
}
test "e2e: %i length" {
    try expectFixnum("%i[a b c d].length", 4);
}
test "e2e: modulo operator unaffected by %w recognition" {
    try expectFixnum("10 % 3", 1);
}
test "e2e: %w as command-call argument" {
    try expectFixnum("a = nil; a = %w[one two three]; a.length", 3);
}

// ── Compound assignment inside blocks (regression) ──────────────────
//
// `+=`, `-=`, etc. went through `emitStoreByName`, which originally
// bypassed the enclosing-local / upvar routing that plain `=` does —
// silently creating a shadowing block-local. The fix makes every
// store-by-name check `findEnclosingLocal` first. These tests pin
// the semantics so it can't regress.

test "e2e: += in .each block reaches outer local" {
    try expectFixnum("s = 0; [1,2,3].each { |x| s += x }; s", 6);
}
test "e2e: -= in .each block" {
    try expectFixnum("s = 100; [1,2,3].each { |x| s -= x }; s", 94);
}
test "e2e: *= in .times block" {
    try expectFixnum("s = 1; 4.times { |_| s *= 2 }; s", 16);
}
test "e2e: += in for-body reaches outer local" {
    try expectFixnum("s = 0; for x in [1,2,3]; s += x; end; s", 6);
}
test "e2e: two sequential for loops accumulating into same outer" {
    try expectFixnum(
        \\s = 0
        \\for x in [1,2]; s += x; end
        \\for y in [10,20]; s += y; end
        \\s
    , 33);
}
test "e2e: block-local shadows outer when assigned without = first" {
    // If a block explicitly assigns to a name that isn't an outer
    // local, it creates a fresh block-local — outer s unchanged.
    try expectFixnum(
        \\s = 100
        \\[1,2,3].each { |x| t = x; t += 10 }
        \\s
    , 100);
}

// ── for/in sequential loops (regression) ─────────────────────────────
//
// The `<for-pad>` placeholder trick works across repeated `for`
// loops in the same scope. First loop inserts the pad; subsequent
// loops see the existing pad and fall into the `dst == outer_slot`
// path which still preserves the iteration variable via the
// no-MOVE branch.

test "e2e: sequential for leaves both loop variables" {
    try expectFixnum(
        \\for x in [1,2]; end
        \\for y in [3,4,5]; end
        \\x * 100 + y
    , 205);
}
test "e2e: method tail is sequential for — last for's collection wins" {
    // Method body where the final expression is the SECOND of two
    // sequential `for` loops. MRI returns the second loop's
    // collection. Before the anonymous-pad fix, nanoruby returned
    // the last yielded value because `<for-pad>` was reused across
    // fors and the second one didn't actually pad.
    try expectFixnum(
        \\def f
        \\  for x in [1,2]; end
        \\  for y in [10,20,30]; end
        \\end
        \\f.length
    , 3);
}

// ── Unterminated %w/%i is a parse error (regression) ─────────────────
//
// Before the fix, a missing close delimiter silently fell back to
// `.percent` and cascaded misleading errors deeper in the file.

test "e2e: unterminated %w is a parse error" {
    const result = compileAndRun("%w[foo bar");
    try std.testing.expectError(error.ParseError, result);
}
test "e2e: unterminated %i is a parse error" {
    const result = compileAndRun("%i[a b c");
    try std.testing.expectError(error.ParseError, result);
}

// ── Native exception channel (DEFERRED F2, now resolved) ────────────
//
// Native methods can now raise VmError via `vm.raise(err)` + the
// sideband `pending_native_error` protocol, translated by
// `VM.invokeNative` into proper exception-handler dispatch. These
// tests pin the behavior so the channel can't silently regress to
// "return nil on error", which was the pre-fix state.

// Float#to_i raises FloatDomainError for non-finite / out-of-range.
test "e2e: NaN.to_i raises FloatDomainError" {
    try expectFixnum("x = (0.0/0.0).to_i rescue 99; x", 99);
}
test "e2e: Infinity.to_i raises FloatDomainError" {
    try expectFixnum("x = (1.0/0.0).to_i rescue 99; x", 99);
}
test "e2e: -Infinity.to_i raises FloatDomainError" {
    try expectFixnum("x = (-1.0/0.0).to_i rescue 99; x", 99);
}
test "e2e: Float#to_i happy path still works" {
    try expectFixnum("3.9.to_i", 3);
}
test "e2e: Float#to_i negative still truncates toward zero" {
    try expectFixnum("(-3.9).to_i", -3);
}

// Opcode-path Float modulo by zero still raises. The native path
// (`.send(:%, 0.0)`) now agrees because `floatBinArith` uses
// `vm.raise`. We can't directly express `:%` as a symbol literal in
// our parser yet, so the two paths are exercised together via the
// opcode-level test only; the native path is covered by the Zig-level
// `floatBinArith` review, not an e2e test.
test "e2e: 1.0 % 0.0 raises DivisionByZero" {
    try expectFixnum("x = 1.0 % 0.0 rescue 99; x", 99);
}

// Hash#fetch: miss raises KeyError; default arg short-circuits.
// (Uses hashrocket literal form `{:a=>1}` rather than label-style
// `{a: 1}` because the compiler currently treats label keys as
// bareword method calls — a separate pre-existing issue.)
test "e2e: Hash#fetch miss raises KeyError" {
    try expectFixnum("x = {:a=>1}.fetch(:missing) rescue 99; x", 99);
}
test "e2e: Hash#fetch with default returns default on miss" {
    try expectFixnum("{:a=>1}.fetch(:missing, 99)", 99);
}
test "e2e: Hash#fetch with hit returns the value" {
    try expectFixnum("{:a=>42, :b=>2}.fetch(:a)", 42);
}

// Symbol identity: the rescue-bound value is a stable symbol whose
// ID is derived from the VmError name. Two raises of the same error
// kind bind equal symbols; raises of different kinds bind unequal
// ones. This matches the pattern used for `1/0` / `nil.missing`
// elsewhere in this file.
test "e2e: two NaN.to_i raises bind the same :FloatDomainError symbol" {
    try expectTrue(
        \\a = nil; b = nil
        \\begin; (0.0/0.0).to_i; rescue => e1; a = e1; end
        \\begin; (0.0/0.0).to_i; rescue => e2; b = e2; end
        \\a == b
    );
}
test "e2e: FloatDomainError and KeyError bind DIFFERENT symbols" {
    try expectFalse(
        \\a = nil; b = nil
        \\begin; (0.0/0.0).to_i; rescue => e1; a = e1; end
        \\begin; {:x=>1}.fetch(:missing); rescue => e2; b = e2; end
        \\a == b
    );
}

// No-leak test: the one-shot sideband channel must not leave stale
// state after an error is rescued. A subsequent successful native
// call on a value that would NOT raise must succeed. Wraps each
// probe in a full `begin/rescue` (not rescue-modifier in parens,
// which the grammar doesn't accept yet).
test "e2e: pending_native_error does not leak across calls" {
    try expectFixnum(
        \\rescued = 0
        \\begin; (0.0/0.0).to_i; rescue; rescued = 1; end
        \\5.5.to_i
    , 5);
}
test "e2e: second fetch after rescue proceeds normally" {
    try expectFixnum(
        \\h = {:a=>1, :b=>2}
        \\begin; h.fetch(:missing); rescue; end
        \\h.fetch(:b)
    , 2);
}

// Block-yield propagation: a raise inside a block body must unwind
// out of the iterator native and be catchable by a `begin/rescue`
// around the iterator call. Pre-fix, `yieldBlock` converted the
// inner `.err` into a null return and iterators silently stopped
// with the exception lost.
test "e2e: raise inside .each propagates to outer rescue" {
    try expectFixnum(
        \\r = 0
        \\begin
        \\  [1,2,3].each { |x| {:a=>1}.fetch(:missing) }
        \\rescue
        \\  r = 99
        \\end
        \\r
    , 99);
}
test "e2e: raise inside .times propagates to outer rescue" {
    try expectFixnum(
        \\r = 0
        \\begin
        \\  3.times { (0.0/0.0).to_i }
        \\rescue
        \\  r = 42
        \\end
        \\r
    , 42);
}
test "e2e: break still works after yieldBlock error-propagation fix" {
    try expectFixnum("x = [1,2,3].each { |v| break 99 if v == 2 }; x", 99);
}
test "e2e: raise inside nested .each (block inside block) propagates" {
    try expectFixnum(
        \\r = 0
        \\begin
        \\  [[1,2]].each { |arr| arr.each { |x| {:a=>1}.fetch(:missing) } }
        \\rescue
        \\  r = 77
        \\end
        \\r
    , 77);
}

// Hash#fetch with zero args raises ArgumentError (Ruby-compat) —
// previously returned nil.
test "e2e: Hash#fetch with no args raises ArgumentError" {
    try expectFixnum("x = {:a=>1}.fetch rescue 99; x", 99);
}

// Chained raises: rescue one, then raise another — the second must
// be observed normally, not conflated with the first.
test "e2e: rescue A then raise B observes B as distinct" {
    try expectFalse(
        \\a = nil; b = nil
        \\begin; (0.0/0.0).to_i; rescue => e1; a = e1; end
        \\begin; {:x=>1}.fetch(:z); rescue => e2; b = e2; end
        \\a == b
    );
}

// Raise through one method into a method that wraps it.
test "e2e: raise propagates up through method calls" {
    try expectFixnum(
        \\def inner; (0.0/0.0).to_i; end
        \\def outer; inner; end
        \\x = outer rescue 42
        \\x
    , 42);
}
test "e2e: String#to_f underscore grouping" {
    try expectFloat("'1_2_3.4_5'.to_f", 123.45);
}
test "e2e: String#to_f bare exponent letter doesn't consume" {
    // "1e" has no digits after 'e', so the prefix scanner stops at
    // '1' and parseFloat sees just "1" → 1.0. Same for "1e+".
    try expectFloat("'1e'.to_f", 1.0);
    try expectFloat("'1e+'.to_f", 1.0);
}
test "e2e: String#to_f degenerate inputs are 0.0" {
    try expectFloat("''.to_f", 0.0);
    try expectFloat("'-'.to_f", 0.0);
    try expectFloat("'.'.to_f", 0.0);
}

// Ruby-compat floored modulo: coverage for all sign quadrants and
// exact multiples. Catches the @rem/@mod sign-convention trap.
test "e2e: float mod positive/positive" { try expectFloat("5.0 % 2.0", 1.0); }
test "e2e: float mod negative/positive" { try expectFloat("-5.0 % 2.0", 1.0); }
test "e2e: float mod positive/negative" { try expectFloat("5.0 % -2.0", -1.0); }
test "e2e: float mod negative/negative" { try expectFloat("-5.0 % -2.0", -1.0); }
test "e2e: float mod exact multiple" { try expectFloat("4.0 % 2.0", 0.0); }

// Inside a block / closure — verify the float pool propagates through
// the child-IrFunc plumbing (LOAD_FLOAT inside a block body).
test "e2e: float literal inside a block" {
    try expectFloat("r = nil; 1.times { |_| r = 2.5 + 0.5 }; r", 3.0);
}
test "e2e: float literal inside a method body" {
    try expectFloat("def f; 1.5 * 4; end; f", 6.0);
}
