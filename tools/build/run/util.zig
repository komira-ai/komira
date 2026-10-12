//! What the modes share besides the supervisor: messages to stderr, the
//! tail of a log, the run directory, paths and numbers.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");

/// 66 `=`: the rule that opens and closes every banner.
pub const rule = "==================================================================";

/// Formats to stderr. Messages are short; a longer one is cut at 64 KiB.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    sys.writeAll(2, s);
}

/// Formats to stdout.
pub fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    sys.writeAll(1, s);
}

/// The offset in `data` at which its last `n` lines start, as busybox
/// `tail -n <n>` counts them: a final line with no newline is a line, and
/// is printed without one.
pub fn tailStart(data: []const u8, n: usize) usize {
    if (n == 0) return data.len;
    var end = data.len;
    if (end > 0 and data[end - 1] == '\n') end -= 1;
    var seen: usize = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        if (data[i] == '\n') {
            seen += 1;
            if (seen == n) return i + 1;
        }
    }
    return 0;
}

/// Writes the last `n` lines of the file at `path` to `fd`, reading the
/// file from its end in blocks, so a long log is not read whole. Nothing
/// when the file cannot be read.
pub fn writeTail(fd: sys.fd_t, path: []const u8, n: usize) void {
    const f = std.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const size = f.getEndPos() catch return;
    if (n == 0 or size == 0) return;
    var block: [65536]u8 = undefined;
    // The offset the tail starts at: count newlines backwards, skipping a
    // final newline (it ends the last line, it does not separate one).
    var last: [1]u8 = undefined;
    _ = f.preadAll(&last, size - 1) catch return;
    var end: u64 = if (last[0] == '\n') size - 1 else size;
    var seen: usize = 0;
    var start: u64 = 0;
    outer: while (end > 0) {
        const len: u64 = @min(end, block.len);
        const off = end - len;
        const got = f.preadAll(block[0..len], off) catch return;
        if (got != len) return;
        var i: usize = @intCast(len);
        while (i > 0) {
            i -= 1;
            if (block[i] == '\n') {
                seen += 1;
                if (seen == n) {
                    start = off + i + 1;
                    break :outer;
                }
            }
        }
        end = off;
    }
    var pos = start;
    while (pos < size) {
        const got = f.preadAll(&block, pos) catch return;
        if (got == 0) return;
        sys.writeAll(fd, block[0..got]);
        pos += got;
    }
}

/// Every line of `data` (split at '\n'; a final line with no newline is a
/// line, a final newline does not start one).
pub fn lines(data: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const body = if (data.len > 0 and data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
    return std.mem.splitScalar(u8, body, '\n');
}

/// A positive whole number with no leading zero (the shell's
/// `"" | *[!0-9]* | 0*` refusal).
pub fn positiveStrict(s: []const u8) ?u64 {
    if (s.len == 0 or s[0] == '0') return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// The working directory as the shell knows it: $PWD when it names the
/// same directory as ".", else getcwd. Paths the tool gives the test are
/// built on it, as gate_runner.sh built them on $PWD.
pub fn actionDir(alloc: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("PWD")) |pwd| {
        if (pwd.len > 0 and pwd[0] == '/') {
            const a = posix.fstatat(posix.AT.FDCWD, pwd, 0) catch null;
            const b = posix.fstatat(posix.AT.FDCWD, ".", 0) catch null;
            if (a != null and b != null and a.?.dev == b.?.dev and a.?.ino == b.?.ino) return alloc.dupe(u8, pwd);
        }
    }
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    return alloc.dupe(u8, try posix.getcwd(&buf));
}

/// `p` absolute against `dir`.
pub fn abs(alloc: std.mem.Allocator, dir: []const u8, p: []const u8) ![]const u8 {
    if (p.len > 0 and p[0] == '/') return alloc.dupe(u8, p);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, p });
}

/// Makes `<parent>/<prefix>XXXXXX` (mode 0700) with a random suffix.
pub fn makeTempDir(alloc: std.mem.Allocator, parent: []const u8, prefix: []const u8) ![]const u8 {
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        var suffix: [6]u8 = undefined;
        sys.randomSuffix(&suffix);
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}", .{ parent, prefix, suffix });
        const z = try alloc.dupeZ(u8, path);
        posix.mkdirZ(z, 0o700) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        return path;
    }
    return error.PathAlreadyExists;
}

pub fn mkdirs(alloc: std.mem.Allocator, base: []const u8, names: []const []const u8) !void {
    for (names) |n| {
        const p = try std.fmt.allocPrintZ(alloc, "{s}/{s}", .{ base, n });
        posix.mkdirZ(p, 0o777) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
}

/// Removes a run directory and everything in it; errors are ignored.
pub fn removeTree(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

/// Creates (truncating) a file for a child's output; close-on-exec.
pub fn createLog(path: []const u8) !sys.fd_t {
    return posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 30);
}

/// argv for execve: each value NUL-terminated, the list null-terminated.
pub fn zList(alloc: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const z = try alloc.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |a, i| z[i] = (try alloc.dupeZ(u8, a)).ptr;
    return z;
}

/// Replaces every `token` in `s` by `with`.
pub fn replaceAll(alloc: std.mem.Allocator, s: []const u8, token: []const u8, with: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, alloc, s, token, with);
}
