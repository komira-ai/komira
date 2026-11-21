//! komira_wheel: the wheel the rule refuses to write. Every member is held
//! to these checks, and every ELF member is read (elf.zig):
//!
//!   size      no member over 90 MB (90,000,000 bytes; PyPI takes 100 MB a file);
//!   external  no member is a library named in `external_needed`: those come
//!             from another package, never from this wheel;
//!   platform  an ELF member only in a manylinux wheel;
//!   arch      an ELF member's machine is the tag's (x86-64 or AArch64);
//!   glibc     the highest GLIBC_ version an ELF member needs is at most the
//!             tag's glibc (`GLIBC_PRIVATE` is refused: no glibc promises it);
//!   glibcxx   the highest GLIBCXX_ version at most `max_glibcxx`, and none
//!             at all while `max_glibcxx` is unset; the same for CXXABI_ and
//!             `max_cxxabi`;
//!   runpath   every DT_RUNPATH and DT_RPATH entry is `$ORIGIN` or under it
//!             (`$ORIGIN/...`, `${ORIGIN}`), so the wheel loads where it is
//!             installed and never from a path of the build machine;
//!   needed    every DT_NEEDED is a member of the wheel (by file name), a
//!             system library of the manylinux list, or in `external_needed`.
//!
//! Each refusal names its check first (`glibc: ...`), so a test asserts which
//! check refused.

const std = @import("std");
const diag = @import("diag.zig");
const elf = @import("elf.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const max_member: usize = 90_000_000;

/// The libraries a manylinux wheel may need from the system (PEP 600's
/// policy, the glibc and GCC runtime libraries).
pub const system_libs = [_][]const u8{
    "ld-linux-aarch64.so.1",
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libstdc++.so.6",
};

pub const Policy = struct {
    /// The glibc the tag promises; null for a macOS wheel (no ELF allowed).
    glibc: ?[]const u8,
    /// The tag's architecture (`x86_64` or `aarch64`), which every ELF
    /// member's e_machine must be.
    arch: []const u8 = "x86_64",
    max_glibcxx: ?[]const u8 = null,
    max_cxxabi: ?[]const u8 = null,
    external_needed: []const []const u8 = &.{},
};

pub const Member = struct { name: []const u8, data: []const u8 };

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn originRelative(entry: []const u8) bool {
    for ([_][]const u8{ "$ORIGIN", "${ORIGIN}" }) |o| {
        if (std.mem.eql(u8, entry, o)) return true;
        if (std.mem.startsWith(u8, entry, o) and entry[o.len] == '/') return true;
    }
    return false;
}

/// A symbol version `<prefix><dotted number>` against its bound. `what` names
/// the check and `attr` the attribute that sets the bound.
fn bounded(alloc: Alloc, d: *Diag, member: []const u8, version: []const u8, prefix: []const u8, bound: ?[]const u8, what: []const u8, attr: []const u8) Refused!void {
    const v = version[prefix.len..];
    if (v.len == 0 or !std.ascii.isDigit(v[0])) return; // CXXABI_TM_1 and the like: not a version of the library's line
    const b = bound orelse return refuse(d, alloc, "{s}: {s} needs {s}, and the rule sets no {s}", .{ what, member, version, attr });
    const order = diag.compareVersions(v, b) orelse return refuse(d, alloc, "{s}: {s} needs {s}, which is not a dotted version", .{ what, member, version });
    if (order == .gt) return refuse(d, alloc, "{s}: {s} needs {s}, newer than the {s} {s}", .{ what, member, version, attr, b });
}

pub fn check(alloc: Alloc, d: *Diag, p: Policy, members: []const Member) Refused!void {
    var names = std.ArrayList([]const u8).empty;
    for (members) |m| try names.append(alloc, diag.baseName(m.name));
    for (members) |m| {
        if (m.data.len > max_member)
            return refuse(d, alloc, "size: {s} is {d} bytes, over the {d} a wheel member may be (PyPI takes 100 MB a file)", .{ m.name, m.data.len, max_member });
        const base = diag.baseName(m.name);
        if (has(p.external_needed, base))
            return refuse(d, alloc, "external: the wheel carries {s}, which external_needed says comes from another package and never from this wheel", .{m.name});
        if (!elf.isElf(m.data)) continue;
        const glibc = p.glibc orelse return refuse(d, alloc, "platform: {s} is an ELF file, and a macOS wheel holds none", .{m.name});
        const info = try elf.read(alloc, d, m.name, m.data);
        const want: u16 = if (std.mem.eql(u8, p.arch, "aarch64")) 183 else 62;
        if (info.machine != want) return refuse(d, alloc, "arch: {s} is an ELF file for machine {d}, not the tag's {s} ({d})", .{ m.name, info.machine, p.arch, want });
        for (info.versions) |v| {
            if (std.mem.startsWith(u8, v, "GLIBCXX_")) {
                try bounded(alloc, d, m.name, v, "GLIBCXX_", p.max_glibcxx, "glibcxx", "max_glibcxx");
            } else if (std.mem.startsWith(u8, v, "CXXABI_")) {
                try bounded(alloc, d, m.name, v, "CXXABI_", p.max_cxxabi, "cxxabi", "max_cxxabi");
            } else if (std.mem.startsWith(u8, v, "GLIBC_")) {
                if (std.mem.eql(u8, v, "GLIBC_PRIVATE")) return refuse(d, alloc, "glibc: {s} needs GLIBC_PRIVATE, which no glibc release promises", .{m.name});
                try bounded(alloc, d, m.name, v, "GLIBC_", glibc, "glibc", "tag's glibc");
            }
        }
        for (info.runpath) |r| {
            if (!originRelative(r)) return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which is not $ORIGIN-relative", .{ m.name, r });
        }
        for (info.needed) |n| {
            if (has(names.items, n) or has(&system_libs, n) or has(p.external_needed, n)) continue;
            return refuse(d, alloc, "needed: {s} needs {s}, which is not in the wheel, not a manylinux system library, and not in external_needed", .{ m.name, n });
        }
    }
}
