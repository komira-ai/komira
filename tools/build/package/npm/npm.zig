//! komira_npm: an npm package made from the rule's manifest and files, byte
//! for byte reproducible.
//!
//! The tarball holds `package/package.json` (manifest.zig: the source
//! manifest stamped) and each file at `package/<its path>`, sorted bytewise by
//! that path (tarball.zig). A native library (an ELF or Mach-O file) is mode
//! 0755, every other file 0644. Before anything is written, every file is
//! held to these checks, each refusal naming its check:
//!
//!   path      a relative path of printable ASCII with no empty, `.` or `..`
//!             part and no `\`, given once; `package.json` is the rule's own;
//!   files     npm packs it: package.json, a README or licence file at the
//!             top, or a path the manifest's `files` names, so the tarball is
//!             the one `npm pack` makes of the same files and a file the
//!             manifest leaves out is refused rather than shipped;
//!   size      no member over 90 MB (90,000,000 bytes, the wheel's bound);
//!   platform  a package with no platform holds no native library;
//!   and for a platform package, native_policy's policy.zig, as for a wheel:
//!   the glibc floor, the GLIBCXX_ and CXXABI_ bounds, every run path at
//!   `$ORIGIN` or under it (`@loader_path` for Mach-O), every DT_NEEDED a
//!   member or a system library, so a library whose Mojo runtime library is
//!   missing is refused.

const std = @import("std");
const native = @import("native_policy");
const diag = native.diag;
const policy = native.policy;
const manifest = @import("manifest.zig");
const tarball = @import("tarball.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const File = struct {
    /// The path in the package (under `package/` in the tarball).
    path: []const u8,
    data: []const u8,
};

pub const Input = struct {
    /// The npm name (`@komira-ai/komira`).
    name: []const u8,
    /// The source manifest's text.
    manifest: []const u8,
    /// The stamp's version, and whether the stamp is set.
    version: []const u8,
    stamped: bool,
    /// The manifest's `license`.
    license: []const u8,
    files: []const File,
    /// The manifest's `os`, `cpu` and `libc`; all null with no platform.
    platform: manifest.Platform = .{},
    /// The glibc floor (Linux) or the macOS (macOS) native files are held
    /// to; both null for a package with no platform, which holds none.
    glibc: ?[]const u8 = null,
    macos: ?[]const u8 = null,
    /// The ELF machine's name: `x86_64` or `aarch64`.
    arch: []const u8 = "x86_64",
    max_glibcxx: ?[]const u8 = null,
    max_cxxabi: ?[]const u8 = null,
    /// The optional dependencies the package names (manifest.Want.optional).
    optional: []const []const u8 = &.{},
};

pub const max_member: usize = 90_000_000;

pub fn want(in: Input) manifest.Want {
    return .{ .name = in.name, .version = in.version, .stamped = in.stamped, .license = in.license, .platform = in.platform, .optional = in.optional };
}

pub fn isNative(data: []const u8) bool {
    return native.elf.isElf(data) or native.macho.isMachO(data);
}

/// The mode a file is written with: 0755 for a native library, else 0644.
pub fn modeOf(data: []const u8) u32 {
    return if (isNative(data)) 0o755 else 0o644;
}

/// The tarball's file name, as `npm pack` names it: the name without its `@`
/// and with `/` as `-`, then the version: `komira-ai-komira-0.1.7.tgz`.
pub fn fileName(alloc: Alloc, name: []const u8, version: []const u8) Alloc.Error![]const u8 {
    const bare = if (name.len > 0 and name[0] == '@') name[1..] else name;
    const out = try std.fmt.allocPrint(alloc, "{s}-{s}.tgz", .{ bare, version });
    std.mem.replaceScalar(u8, out, '/', '-');
    return out;
}

/// A path the package can carry.
pub fn checkPath(alloc: Alloc, d: *Diag, path: []const u8) Refused!void {
    if (path.len == 0 or path[0] == '/') return refuse(d, alloc, "path: `{s}` is not a relative path", .{path});
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return refuse(d, alloc, "path: `{s}` holds a backslash", .{path});
    for (path) |c| {
        if (c >= 0x7f or c < 0x20) return refuse(d, alloc, "path: `{s}` holds a byte outside printable ASCII", .{path});
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, ".."))
            return refuse(d, alloc, "path: `{s}` has an empty, `.` or `..` part", .{path});
    }
    if (std.mem.eql(u8, path, "package.json")) return refuse(d, alloc, "path: package.json is the rule's own, stamped from the manifest; it is not a file to give", .{});
}

fn lessFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The files of a package (package.json first among them, as a path), held
/// to the checks above but `path`; `files` is the manifest's list.
pub fn checkMembers(alloc: Alloc, d: *Diag, in: Input, files: []const []const u8, ms: []const File) Refused!void {
    for (ms) |m| {
        if (!try manifest.packs(alloc, files, m.path))
            return refuse(d, alloc, "files: the package carries {s}, which the manifest's `files` does not name, so npm pack would leave it out", .{m.path});
        if (m.data.len > max_member)
            return refuse(d, alloc, "size: {s} is {d} bytes, over the {d} a package member may be", .{ m.path, m.data.len, max_member });
    }
    if (in.glibc == null and in.macos == null) {
        for (ms) |m| {
            if (isNative(m.data)) return refuse(d, alloc, "platform: {s} is a native library, and a package with no platform holds none", .{m.path});
        }
        return;
    }
    var checked = std.ArrayList(policy.Member).empty;
    for (ms) |m| try checked.append(alloc, .{ .name = m.path, .data = m.data });
    try policy.check(alloc, d, .{
        .glibc = in.glibc,
        .macos = in.macos,
        .arch = in.arch,
        .max_glibcxx = in.max_glibcxx,
        .max_cxxabi = in.max_cxxabi,
        .package = "package",
    }, checked.items);
}

/// The members of the package of `in`, in the tarball's order, every check
/// above passed.
pub fn members(alloc: Alloc, d: *Diag, in: Input) Refused![]tarball.Member {
    const stamped = try manifest.stamp(alloc, d, in.manifest, want(in));
    var all = std.ArrayList(File).empty;
    for (in.files) |f| {
        try checkPath(alloc, d, f.path);
        try all.append(alloc, f);
    }
    try all.append(alloc, .{ .path = "package.json", .data = stamped.bytes });
    std.mem.sort(File, all.items, {}, lessFile);
    for (all.items[1..], 1..) |f, i| {
        if (std.mem.eql(u8, f.path, all.items[i - 1].path)) return refuse(d, alloc, "path: `{s}` is given twice", .{f.path});
    }
    try checkMembers(alloc, d, in, stamped.files, all.items);
    var out = std.ArrayList(tarball.Member).empty;
    for (all.items) |f| {
        try out.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ tarball.root, f.path }), .data = f.data, .mode = modeOf(f.data) });
    }
    return out.toOwnedSlice(alloc);
}

/// The tarball of `in`.
pub fn build(alloc: Alloc, d: *Diag, in: Input) Refused![]u8 {
    return tarball.write(alloc, d, try members(alloc, d, in));
}
