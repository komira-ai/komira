//! komira_wheel: a wheel's tag and what it bounds.
//!
//! The rule derives the tag from a platform row (wheel.bzl `wheel_tag`); the
//! tool takes it and reads back what it promises, so the tag and the checks
//! cannot disagree. Taken: `py3-none-manylinux_<major>_<minor>_x86_64`,
//! `py3-none-manylinux_<major>_<minor>_aarch64` and
//! `py3-none-macosx_<major>_<minor>_arm64`. The package loads its library
//! with ctypes, so the interpreter part is `py3` and the ABI part `none`; a
//! wheel with a native library is never `any`.

const std = @import("std");
const diag = @import("native_policy").diag;
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const Tag = struct {
    text: []const u8,
    /// The glibc a manylinux tag promises (`2.34`); null for macOS.
    glibc: ?[]const u8,
    /// The macOS a macosx tag promises (`11.0`); null for manylinux.
    macos: ?[]const u8,
    /// Whether the wheel's libraries are ELF (Linux) or Mach-O (macOS).
    linux: bool,
    /// The architecture the tag names: `x86_64`, `aarch64` or `arm64`.
    arch: []const u8,
};

fn number(s: []const u8) bool {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn parse(alloc: Alloc, d: *Diag, tag: []const u8) Refused!Tag {
    const head = "py3-none-";
    if (!std.mem.startsWith(u8, tag, head))
        return refuse(d, alloc, "the tag `{s}` is not `py3-none-<platform>` (the package loads its library with ctypes and uses no CPython ABI)", .{tag});
    const plat = tag[head.len..];
    if (std.mem.eql(u8, plat, "any")) return refuse(d, alloc, "the tag `{s}` says any platform, but a wheel holding a native library is built for one", .{tag});
    var parts = std.mem.splitScalar(u8, plat, '_');
    const family = parts.next().?;
    const major = parts.next() orelse "";
    const minor = parts.next() orelse "";
    const arch = parts.rest();
    if (!number(major) or !number(minor))
        return refuse(d, alloc, "the platform tag `{s}` is not <family>_<major>_<minor>_<arch>", .{plat});
    if (std.mem.eql(u8, family, "manylinux")) {
        if (!std.mem.eql(u8, arch, "x86_64") and !std.mem.eql(u8, arch, "aarch64"))
            return refuse(d, alloc, "the manylinux tag `{s}` names the architecture `{s}`, not x86_64 or aarch64", .{ plat, arch });
        return .{ .text = tag, .glibc = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ major, minor }), .macos = null, .linux = true, .arch = arch };
    }
    if (std.mem.eql(u8, family, "macosx")) {
        if (!std.mem.eql(u8, arch, "arm64"))
            return refuse(d, alloc, "the macosx tag `{s}` names the architecture `{s}`, not arm64", .{ plat, arch });
        return .{ .text = tag, .glibc = null, .macos = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ major, minor }), .linux = false, .arch = arch };
    }
    return refuse(d, alloc, "the platform tag `{s}` is neither manylinux nor macosx", .{plat});
}
