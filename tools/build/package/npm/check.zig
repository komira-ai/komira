//! komira_npm check: a written tarball read back from its bytes, and refused
//! unless it is exactly what the rule asked for.
//!
//! What is held, in order:
//!   * with `require_stamped`, the package is stamped (never `0.0.0`): an
//!     unstamped package is not publishable;
//!   * the file is named as `npm pack` names it, with the stamp's version;
//!   * the tarball reads back (tarball.zig): its gzip and tar are the ones
//!     this tool writes, every member dated with npm pack's date;
//!   * the members are exactly package.json and the files given, in order,
//!     each with the bytes and mode the build gives it: a member the rule did
//!     not give, a missing one, other bytes or another mode is refused;
//!   * the package.json read back is held to the rule again on its own
//!     (manifest.zig `checkWritten`): name, licence, repository.url, the
//!     platform's os, cpu and libc, the stamp's version on the package and its
//!     optional dependencies, and `private` exactly when unstamped;
//!   * every member read back is one npm packs for that package.json's
//!     `files`, within the size bound, and passes the native policy again;
//!   * with a twin (the same tarball written by a second action from inputs
//!     staged elsewhere), the two are the same bytes.

const std = @import("std");
const diag = @import("native_policy").diag;
const manifest = @import("manifest.zig");
const npm = @import("npm.zig");
const tarball = @import("tarball.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

/// The tarball named `name` with bytes `bytes`, against the input it was
/// written from.
pub fn check(alloc: Alloc, d: *Diag, in: npm.Input, name: []const u8, bytes: []const u8, require_stamped: bool, twin: ?[]const u8) Refused!void {
    if (require_stamped and !in.stamped)
        return refuse(d, alloc, "stamp: the package is unstamped (version {s}): a development package, never a release", .{in.version});
    const want_name = try npm.fileName(alloc, in.name, in.version);
    if (!std.mem.eql(u8, name, want_name)) return refuse(d, alloc, "name: the tarball is named {s}, not {s}", .{ name, want_name });

    const want = try npm.members(alloc, d, in);
    const got = try tarball.read(alloc, d, bytes);
    for (got, 0..) |m, i| {
        if (i >= want.len) return refuse(d, alloc, "members: the tarball carries {s}, which the rule did not give", .{m.name});
        const w = want[i];
        if (!std.mem.eql(u8, m.name, w.name)) return refuse(d, alloc, "members: member {d} is {s}, not {s}", .{ i, m.name, w.name });
        if (!std.mem.eql(u8, m.data, w.data)) return refuse(d, alloc, "members: {s} is not the file given", .{m.name});
        if (m.mode != w.mode) return refuse(d, alloc, "mode: {s} has mode {o}, not {o}", .{ m.name, m.mode, w.mode });
    }
    if (got.len < want.len) return refuse(d, alloc, "members: the tarball has no {s}", .{want[got.len].name});

    // The members as the package lays them out, package.json among them.
    var files = std.ArrayList(npm.File).empty;
    var pkg: ?[]const u8 = null;
    for (got) |m| {
        const path = m.name[tarball.root.len..];
        if (std.mem.eql(u8, path, "package.json")) pkg = m.data;
        try files.append(alloc, .{ .path = path, .data = m.data });
    }
    const listed = try manifest.checkWritten(alloc, d, pkg orelse return refuse(d, alloc, "members: the tarball has no package/package.json", .{}), npm.want(in));
    try npm.checkMembers(alloc, d, in, listed, files.items);

    if (twin) |tw| {
        if (!std.mem.eql(u8, tw, bytes)) return refuse(d, alloc, "twin: the package written twice from the same inputs, staged at two paths, is not the same bytes ({d} and {d} bytes): the build is not reproducible", .{ bytes.len, tw.len });
    }
}
