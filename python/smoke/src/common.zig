//! pypi_smoke: what every part of the driver shares: how a refusal travels, the two indexes, a few text
//! helpers and the file the GitHub steps read their outputs from.
const std = @import("std");
pub const zip = @import("wheel_zip");

pub const Allocator = std.mem.Allocator;

/// Every function that can refuse returns `error.Refused` and leaves the reason in a `why` it was given;
/// only the command line (cli.zig) turns it into a message and an exit status.
pub const Error = error{ Refused, OutOfMemory };

pub fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

/// The diagnostic type of the wheel zip reader (tools/build/package/native_policy/diag.zig), named
/// through the reader's own signature: the
/// module exports `read` and `write` but not the type they take.
pub const Diag = @typeInfo(@typeInfo(@TypeOf(zip.read)).@"fn".params[1].type.?).pointer.child;

/// An index the smoke publishes to and reads back: where its JSON API and its simple index are, and where it
/// serves files from.
pub const Index = struct {
    name: []const u8,
    /// `<json_base><name>/<version>/json` is the release's JSON.
    json_base: []const u8,
    /// The simple index `pip --index-url` reads.
    simple: []const u8,
    /// The files of a release are served from URLs that start with this.
    files_prefix: []const u8,
};

pub const testpypi = Index{
    .name = "testpypi",
    .json_base = "https://test.pypi.org/pypi/",
    .simple = "https://test.pypi.org/simple/",
    .files_prefix = "https://test-files.pythonhosted.org/",
};

pub const pypi = Index{
    .name = "pypi",
    .json_base = "https://pypi.org/pypi/",
    .simple = "https://pypi.org/simple/",
    .files_prefix = "https://files.pythonhosted.org/",
};

/// The index every real dependency comes from, whichever index komira is installed from.
pub const dependency_index = "https://pypi.org/simple/";

pub fn indexNamed(name: []const u8) ?Index {
    if (std.mem.eql(u8, name, "testpypi")) return testpypi;
    if (std.mem.eql(u8, name, "pypi")) return pypi;
    return null;
}

pub fn hexSha(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
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
        const t = std.mem.trimRight(u8, line, " \t\r");
        if (t.len != 0) try lines.append(a, t);
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
