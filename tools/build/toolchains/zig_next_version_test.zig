//! The pinned `:zig_next` is the release the platform table names. The
//! zig_test's `env_tools` hands the unpacked distribution's directory in
//! ZIG_NEXT (without it the case fails); the case runs its `zig version`
//! and requires exactly the release below. A pin that unpacks to another
//! release (a wrong archive under a right checksum, a table edited without
//! this file) fails here, in the build, not in the first kpin compile.

const std = @import("std");

const want = "0.15.2";

test "zig_next reports the release the table pins" {
    const a = std.testing.allocator;
    const dir = std.posix.getenv("ZIG_NEXT") orelse return error.ZigNextNotInEnvironment;
    const exe = try std.fs.path.join(a, &.{ dir, "zig" });
    defer a.free(exe);
    const r = try std.ChildProcess.run(.{ .allocator = a, .argv = &.{ exe, "version" } });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expect(r.term == .Exited and r.term.Exited == 0);
    try std.testing.expectEqualStrings(want, std.mem.trim(u8, r.stdout, " \r\n"));
}
