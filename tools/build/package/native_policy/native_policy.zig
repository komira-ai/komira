//! native_policy: what a package's native libraries may ask of the system
//! that loads them, the checks a package tool runs on every member it would
//! write (policy.zig), and the readers they rest on: ELF (elf.zig), Mach-O
//! (macho.zig) and the Mach-O code signature (codesign.zig). Every check
//! refuses through diag.zig, so a tool that imports the module reports a
//! refusal as its own. komira_wheel (../wheel/) imports it; `testing` is the
//! synthetic ELF and Mach-O libraries the tests of a tool build their
//! packages from, analysed only by a compile that names it.

pub const codesign = @import("codesign.zig");
pub const diag = @import("diag.zig");
pub const elf = @import("elf.zig");
pub const macho = @import("macho.zig");
pub const policy = @import("policy.zig");
pub const testing = @import("testing.zig");
