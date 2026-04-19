// Narrow public face of the vendored nanoruby runtime.
//
// Firmware imports from this file only; the rest of `src/ruby/nanoruby/`
// is implementation detail (VM/heap/class core) or host-tool code
// (parser, codegen, nrbc — never linked into firmware).
//
// See `src/ruby/nanoruby/UPSTREAM.md` for the re-vendor procedure and
// the enumerated local modifications.

const vm_mod = @import("nanoruby/vm/vm.zig");
const value_mod = @import("nanoruby/vm/value.zig");
const class_mod = @import("nanoruby/vm/class.zig");
const atom_mod = @import("nanoruby/vm/atom.zig");

// ── Core VM types ────────────────────────────────────────────────────
pub const VM = vm_mod.VM;
pub const IrFunc = vm_mod.IrFunc;
pub const Value = value_mod.Value;
pub const VmError = vm_mod.VmError;
pub const ExecResult = vm_mod.ExecResult;

// ── Bytecode loader (deserialize only on firmware; serialize is host) ─
pub const Loader = @import("nanoruby/vm/nrb.zig");

// ── Native-method registration ───────────────────────────────────────
pub const NativeFn = class_mod.NativeFn;
pub const NativeMethodDef = class_mod.NativeMethodDef;
pub const installCoreNatives = class_mod.installCoreNatives;
pub const installPlatformNatives = class_mod.installPlatformNatives;

// Class IDs frequently referenced by platform-native adapters (binding
// GPIO/LED/etc. to CLASS_OBJECT). Firmware should NOT import other
// CLASS_* ids unless it also imports a class-dispatch helper.
pub const CLASS_OBJECT = class_mod.CLASS_OBJECT;

// ── Atom/symbol interning ────────────────────────────────────────────
pub const atom = atom_mod.atom;
pub const ATOM_NEW = atom_mod.ATOM_NEW;
pub const ATOM_INITIALIZE = atom_mod.ATOM_INITIALIZE;
