// Why Zig: build tools are Zig (tools/build/README.md). This replaces the /bin/sh
// script that `buck2 run //release/validations:<name>` used as its launcher.
//! launch: runs a command from the repository's root, with the arguments a
//! validation run needs when the caller gave none.
//!
//! usage: launch <repository root> <command> [<argument>...]
//!
//! Changes into the repository's root, then replaces itself with the command
//! (the second and later arguments). It appends `--run-id local`, `--attempt 1`
//! and `--scratch-dir <a fresh directory under the system temp directory>` for
//! each of those the arguments do not already name (`--flag value` or
//! `--flag=value`). The command is looked up as given, as `exec` would.
//!
//! Exit status: 1 when it cannot change directory or run the command; 2 for a
//! usage error.

const std = @import("std");
const A = std.mem.Allocator;

/// Whether `args` name `flag` (as `flag` or `flag=...`).
pub fn names(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
        if (a.len > flag.len and std.mem.startsWith(u8, a, flag) and a[flag.len] == '=') return true;
    }
    return false;
}

/// `args` and the defaults it lacks. `scratch` makes the scratch directory, and
/// is called only when the arguments name none.
pub fn withDefaults(a: A, args: []const []const u8, scratch: anytype) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(a, args);
    if (!names(args, "--run-id")) try out.appendSlice(a, &.{ "--run-id", "local" });
    if (!names(args, "--attempt")) try out.appendSlice(a, &.{ "--attempt", "1" });
    if (!names(args, "--scratch-dir")) try out.appendSlice(a, &.{ "--scratch-dir", try scratch.make(a) });
    return out.toOwnedSlice(a);
}

/// A fresh, private directory under $TMPDIR (else /tmp), as `mktemp -d` makes one.
const TempScratch = struct {
    pub fn make(_: TempScratch, a: A) ![]const u8 {
        const base = std.process.getEnvVarOwned(a, "TMPDIR") catch try a.dupe(u8, "/tmp");
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            var r: [8]u8 = undefined;
            std.crypto.random.bytes(&r);
            const path = try std.fmt.allocPrint(a, "{s}/tmp.{x}", .{ std.mem.trimRight(u8, base, "/"), &r });
            std.posix.mkdir(path, 0o700) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => return e,
            };
            return path;
        }
        return error.PathAlreadyExists;
    }
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 3) {
        std.debug.print("usage: launch <repository root> <command> [<argument>...]\n", .{});
        std.process.exit(2);
    }
    std.posix.chdir(argv[1]) catch |e| {
        std.debug.print("launch: cannot change to {s}: {s}\n", .{ argv[1], @errorName(e) });
        std.process.exit(1);
    };
    const full = try withDefaults(a, argv[3..], TempScratch{});
    var cmd = std.ArrayList([]const u8).empty;
    try cmd.append(a, argv[2]);
    try cmd.appendSlice(a, full);
    const e = std.process.execv(a, cmd.items);
    std.debug.print("launch: cannot run {s}: {s}\n", .{ argv[2], @errorName(e) });
    std.process.exit(1);
}
