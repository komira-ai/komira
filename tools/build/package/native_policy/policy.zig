//! native_policy: the package a tool refuses to write, a wheel (komira_wheel)
//! or an npm package (komira_npm); `Policy.package` is the word its refusals
//! use for it, and the text below says wheel. Every member is held to these
//! checks, and every ELF member (elf.zig) and Mach-O member
//! (macho.zig) is read:
//!
//!   size      no member over 90 MB (90,000,000 bytes; PyPI takes 100 MB a file);
//!   external  no member is a library named in `external_needed`: those come
//!             from another package, never from this wheel;
//!   platform  an ELF member only in a manylinux wheel, a Mach-O member only in
//!             a macosx wheel;
//!   arch      an ELF member's machine is the tag's (x86-64 or AArch64), a
//!             Mach-O member's CPU type is arm64;
//!   glibc     the highest GLIBC_ version an ELF member needs is at most the
//!             tag's glibc (`GLIBC_PRIVATE` is refused: no glibc promises it);
//!   glibcxx   the highest GLIBCXX_ version at most `max_glibcxx`, and none
//!             at all while `max_glibcxx` is unset; the same for CXXABI_ and
//!             `max_cxxabi` (ELF only);
//!   minos     every Mach-O member states a minimum macOS (LC_BUILD_VERSION or
//!             LC_VERSION_MIN_MACOSX), at most the tag's macOS;
//!   signature every Mach-O member carries a code signature that matches its
//!             bytes (codesign.zig): macOS on arm64 loads no other code;
//!   installname  a Mach-O member's install name is `@rpath/<file name>`;
//!   runpath   every DT_RUNPATH and DT_RPATH entry is `$ORIGIN` or under it
//!             (`$ORIGIN/...`, `${ORIGIN}`), and every Mach-O LC_RPATH entry
//!             is `@loader_path` or under it, so the wheel loads where it is
//!             installed and never from a path of the build machine;
//!   needed    every DT_NEEDED is a member of the wheel (by file name), a
//!             system library of the manylinux list, or in `external_needed`;
//!             every Mach-O load command names `@rpath/<file>` or
//!             `@loader_path/<path>` of a member (by file name) or an
//!             `@rpath/<file>` in `external_needed`, or an operating system
//!             library under /usr/lib/ or /System/Library/.
//!
//! Each refusal names its check first (`glibc: ...`), so a test asserts which
//! check refused.

const std = @import("std");
const codesign = @import("codesign.zig");
const diag = @import("diag.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
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
    /// The macOS the tag promises (`11.0`); null for a manylinux wheel (no
    /// Mach-O allowed).
    macos: ?[]const u8 = null,
    /// The tag's architecture (`x86_64` or `aarch64`), which every ELF
    /// member's e_machine must be.
    arch: []const u8 = "x86_64",
    max_glibcxx: ?[]const u8 = null,
    max_cxxabi: ?[]const u8 = null,
    external_needed: []const []const u8 = &.{},
    /// What the members are packed in, as the refusals name it: `wheel`, or
    /// `package` for an npm package (komira_npm).
    package: []const u8 = "wheel",
};

pub const Member = struct { name: []const u8, data: []const u8 };

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn loaderRelative(entry: []const u8) bool {
    const o = "@loader_path";
    return std.mem.eql(u8, entry, o) or (std.mem.startsWith(u8, entry, o) and entry[o.len] == '/');
}

/// An operating system library: an absolute path under /usr/lib/ or
/// /System/Library/, with no `..` step out of them.
fn systemLibrary(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/usr/lib/") and !std.mem.startsWith(u8, path, "/System/Library/")) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return false;
    return true;
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

fn checkMachO(alloc: Alloc, d: *Diag, p: Policy, m: Member, names: []const []const u8) Refused!void {
    const tag_macos = p.macos orelse return refuse(d, alloc, "platform: {s} is a Mach-O file, and a manylinux {s} holds none", .{ m.name, p.package });
    const info = try macho.read(alloc, d, m.name, m.data);
    if (info.cputype != macho.CPU_TYPE_ARM64) return refuse(d, alloc, "arch: {s} is a Mach-O file for CPU type {x}, not arm64", .{ m.name, info.cputype });
    const minos = info.minos orelse return refuse(d, alloc, "minos: {s} states no minimum macOS version (no LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX)", .{m.name});
    const minos_text = try macho.versionText(alloc, minos);
    if ((diag.compareVersions(minos_text, tag_macos) orelse unreachable) == .gt)
        return refuse(d, alloc, "minos: {s} needs macOS {s}, newer than the tag's macOS {s}", .{ m.name, minos_text, tag_macos });
    try codesign.check(alloc, d, m.name, m.data);
    if (info.install_name) |n| {
        const file = if (std.mem.startsWith(u8, n, "@rpath/")) n["@rpath/".len..] else "";
        if (file.len == 0 or std.mem.indexOfScalar(u8, file, '/') != null)
            return refuse(d, alloc, "installname: {s} has the install name `{s}`, which is not @rpath/<file>", .{ m.name, n });
    }
    for (info.rpaths) |r| {
        if (!loaderRelative(r)) return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which is not @loader_path-relative", .{ m.name, r });
    }
    for (info.loads) |n| {
        const base = diag.baseName(n);
        const rpath = std.mem.startsWith(u8, n, "@rpath/");
        const loader = std.mem.startsWith(u8, n, "@loader_path/");
        if (has(names, base) and (rpath or loader)) continue;
        if (rpath and has(p.external_needed, base)) continue;
        if (systemLibrary(n)) continue;
        return refuse(d, alloc, "needed: {s} loads `{s}`, which is not in the {s}, not an operating system library under /usr/lib or /System/Library, and not in external_needed", .{ m.name, n, p.package });
    }
}

pub fn check(alloc: Alloc, d: *Diag, p: Policy, members: []const Member) Refused!void {
    var names = std.ArrayList([]const u8).empty;
    for (members) |m| try names.append(alloc, diag.baseName(m.name));
    for (members) |m| {
        if (m.data.len > max_member)
            return refuse(d, alloc, "size: {s} is {d} bytes, over the {d} a wheel member may be (PyPI takes 100 MB a file)", .{ m.name, m.data.len, max_member });
        const base = diag.baseName(m.name);
        if (has(p.external_needed, base))
            return refuse(d, alloc, "external: the {s} carries {s}, which external_needed says comes from another package and never from this {s}", .{ p.package, m.name, p.package });
        if (macho.isMachO(m.data)) {
            try checkMachO(alloc, d, p, m, names.items);
            continue;
        }
        if (!elf.isElf(m.data)) continue;
        const glibc = p.glibc orelse return refuse(d, alloc, "platform: {s} is an ELF file, and a macOS {s} holds none", .{ m.name, p.package });
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
            return refuse(d, alloc, "needed: {s} needs {s}, which is not in the {s}, not a manylinux system library, and not in external_needed", .{ m.name, n, p.package });
        }
    }
}
