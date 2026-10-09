//! Test fixtures on the filesystem: directories under the test run's own
//! TMPDIR, files with a given mode, symbolic links.

const std = @import("std");
const C = @import("common.zig");

/// A directory of its own under this run's TMPDIR: `<prefix>_<name>_<pid>`.
pub fn scratch(prefix: []const u8, name: []const u8) []const u8 {
    const tmp = C.posix.getenv("TMPDIR") orelse "/tmp";
    const d = C.fmt("{s}/{s}_{s}_{d}", .{ tmp, prefix, name, std.os.linux.getpid() });
    std.fs.cwd().makePath(d) catch |e| std.debug.panic("cannot create {s}: {s}", .{ d, @errorName(e) });
    return d;
}

pub fn path(dir: []const u8, rel: []const u8) []const u8 {
    return C.pathJoin(dir, rel);
}

pub fn mkdirAll(p: []const u8) void {
    std.fs.cwd().makePath(p) catch |e| std.debug.panic("cannot create {s}: {s}", .{ p, @errorName(e) });
}

pub fn mkdir(p: []const u8) void {
    std.fs.cwd().makeDir(p) catch |e| std.debug.panic("cannot create {s}: {s}", .{ p, @errorName(e) });
}

pub fn write(p: []const u8, data: []const u8) void {
    C.writeFile(p, data) catch |e| std.debug.panic("cannot write {s}: {s}", .{ p, @errorName(e) });
}

/// `data` at `p`, then its mode set to `mode`.
pub fn writeMode(p: []const u8, data: []const u8, mode: u32) void {
    write(p, data);
    C.chmod(p, mode) catch |e| std.debug.panic("cannot chmod {s}: {s}", .{ p, @errorName(e) });
}

pub fn symlink(target: []const u8, p: []const u8) void {
    std.fs.cwd().symLink(target, p, .{}) catch |e| std.debug.panic("cannot link {s}: {s}", .{ p, @errorName(e) });
}

pub fn read(p: []const u8) []const u8 {
    return C.readFile(p) catch |e| std.debug.panic("cannot read {s}: {s}", .{ p, @errorName(e) });
}

/// The permission bits of `p` itself.
pub fn modeOf(p: []const u8) u32 {
    const st = C.lstat(p) catch |e| std.debug.panic("cannot stat {s}: {s}", .{ p, @errorName(e) });
    return st.mode & 0o7777;
}
