//! `pkg_act bundle`: assembles a mojo_bundle directory (tools/build/package/
//! defs.bzl), in place of its busybox script.
//!
//!     bin/<name>                                  the launcher
//!     lib/glibc-hwcaps/<cpu>/lib<name>.so         the program
//!     lib/<each regular file of the runtime>      Mojo runtime, C++ runtime
//!     <dest>                                      each --file <dest> <src>
//!     VERSION
//!     SHA256SUMS                                  every other file, sorted by path
//!
//! Directories are 0755, files 0644, and everything in bin/ is 0755.

const std = @import("std");
const U = @import("act_util");

pub const Plan = struct {
    out: []const u8,
    name: []const u8,
    cpu: []const u8,
    launcher: []const u8,
    so: []const u8,
    runtime: []const u8,
    version: []const u8,
    /// (dest, src) pairs: data files and helpers.
    files: []const [2][]const u8,
};

/// The SHA256SUMS text of the files under `dir`: `<sha256>  <path>` per file,
/// paths relative and sorted bytewise (`find . -type f | sed 's|^\./||' |
/// LC_ALL=C sort`, then `sha256sum`).
pub fn sums(a: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    const files = try U.listFiles(a, dir, false);
    var b = std.ArrayList(u8).init(a);
    for (files) |rel| {
        const data = try dir.readFileAlloc(std.heap.page_allocator, rel, 1 << 30);
        defer std.heap.page_allocator.free(data);
        try b.writer().print("{s}  {s}\n", .{ &U.sha256Hex(data), rel });
    }
    return b.toOwnedSlice();
}

pub fn assemble(a: std.mem.Allocator, p: Plan) !void {
    const cwd = std.fs.cwd();
    var out = try cwd.makeOpenPath(p.out, .{ .iterate = true });
    defer out.close();
    try out.makePath("bin");
    const hwcaps = try std.fmt.allocPrint(a, "lib/glibc-hwcaps/{s}", .{p.cpu});
    try out.makePath(hwcaps);

    try cwd.copyFile(p.launcher, out, try std.fmt.allocPrint(a, "bin/{s}", .{p.name}), .{});
    try cwd.copyFile(p.so, out, try std.fmt.allocPrint(a, "{s}/lib{s}.so", .{ hwcaps, p.name }), .{});

    // Every entry of the runtime directory is a file (a link is followed); a
    // directory in it is an error, as `cp` of one is.
    var rt = try cwd.openDir(p.runtime, .{ .iterate = true });
    defer rt.close();
    var any = false;
    var it = rt.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) return error.RuntimeHoldsDirectory;
        try rt.copyFile(e.name, out, try std.fmt.allocPrint(a, "lib/{s}", .{e.name}), .{});
        any = true;
    }
    if (!any) return error.RuntimeIsEmpty;

    for (p.files) |f| {
        try U.makeParent(out, f[0]);
        try cwd.copyFile(f[1], out, f[0], .{});
    }
    try cwd.copyFile(p.version, out, "VERSION", .{});

    try U.setModes(out, 0o755, 0o644);
    {
        var bin = try out.openDir("bin", .{ .iterate = true });
        defer bin.close();
        var bit = bin.iterate();
        while (try bit.next()) |e| {
            if (e.kind != .file) continue;
            const f = try bin.openFile(e.name, .{});
            defer f.close();
            try f.chmod(0o755);
        }
    }
    const text = try sums(a, out);
    try U.writeAll(out, "SHA256SUMS", text);
    const f = try out.openFile("SHA256SUMS", .{});
    defer f.close();
    try f.chmod(0o644);
}
