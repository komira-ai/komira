//! npm_smoke: what every part of the driver shares: how a refusal travels, the digests npm and the set
//! record, and the files a step writes.
const std = @import("std");

pub const Allocator = std.mem.Allocator;

/// Every function that can refuse returns `error.Refused` and leaves the reason in a `why` it was given;
/// only the command line (cli.zig) turns it into a message and an exit status.
pub const Error = error{ Refused, OutOfMemory };

pub fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

/// The SHA-256 of `bytes` as 64 lowercase hex characters.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The length of an integrity string: `sha512-` and the padded base64 of 64 bytes.
pub const integrity_len = "sha512-".len + 88;

/// The `integrity` npm records for a tarball (package-lock.json, the registry's `dist.integrity`):
/// `sha512-` and the standard padded base64 of the tarball's SHA-512.
pub fn integrity(bytes: []const u8) [integrity_len]u8 {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    var out: [integrity_len]u8 = undefined;
    @memcpy(out[0..7], "sha512-");
    _ = std.base64.standard.Encoder.encode(out[7..], &digest);
    return out;
}

/// Append `text` to the file at `path` (made if absent): the way a step writes its outputs.
pub fn appendFile(path: []const u8, text: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text);
}

/// The last `n` non-blank lines of `text`, joined by line feeds; a fixed text when there are none.
pub fn lastLines(a: Allocator, text: []const u8, n: usize) Error![]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const s = std.mem.trimRight(u8, line, " \t\r");
        if (s.len != 0) try lines.append(a, s);
    }
    if (lines.items.len == 0) return "(nothing on stderr)";
    const from = if (lines.items.len > n) lines.items.len - n else 0;
    return std.mem.join(a, "\n", lines.items[from..]);
}

/// `out` is a directory that does not exist or is empty (`flag` names it in the refusal).
pub fn requireFreeDir(a: Allocator, why: *[]const u8, flag: []const u8, out: []const u8) Error!void {
    var dir = std.fs.cwd().openDir(out, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return refuse(a, why, "cannot open {s} {s}: {s}", .{ flag, out, @errorName(e) }),
    };
    defer dir.close();
    var it = dir.iterate();
    const first = it.next() catch |e| return refuse(a, why, "cannot list {s} {s}: {s}", .{ flag, out, @errorName(e) });
    if (first != null) return refuse(a, why, "{s} {s} is not empty", .{ flag, out });
}

/// Write `data` to `path`, refusing with the path when it cannot be written.
pub fn writeFile(a: Allocator, why: *[]const u8, path: []const u8, data: []const u8) Error!void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |e|
        return refuse(a, why, "cannot write {s}: {s}", .{ path, @errorName(e) });
}

/// The most of a file the driver reads: a tarball, the set, a lock file.
pub const max_file_bytes: usize = 1 << 30;

/// The bytes of `path`, refusing with `what` and the path when it cannot be read.
pub fn readFile(a: Allocator, why: *[]const u8, what: []const u8, path: []const u8) Error![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, max_file_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "cannot read {s} {s}: {s}", .{ what, path, @errorName(e) }),
    };
}
