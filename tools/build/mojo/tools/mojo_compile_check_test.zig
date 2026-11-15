//! Unit tests of the output checks of mojo_compile.zig: exit 3 for a missing or
//! empty output, exit 4 only when the output holds the working directory as a
//! whole path. The process behaviour (the watchdog, the environment, the
//! signals) is held by the functional tests of the repositories that build
//! through the wrapper.
const std = @import("std");
const W = @import("mojo_compile.zig");
const t = std.testing;

test "holdsPath: whole paths, the ends of the text, NUL, and names that merely hold the string" {
    try t.expect(W.holdsPath("/work", "/work"));
    try t.expect(W.holdsPath("x /work/buck-out/x", "/work"));
    try t.expect(W.holdsPath("x /work\x00y", "/work"));
    try t.expect(W.holdsPath("file:///work/a", "/work"));
    try t.expect(W.holdsPath("/workflows and /work/x", "/work"));
    try t.expect(!W.holdsPath("github.com/tokio-rs/prost/actions/workflows/ci.yml", "/work"));
    try t.expect(!W.holdsPath("/work-x /work.rs /work_a /work9", "/work"));
    try t.expect(!W.holdsPath("/a/work/x a/work ./work", "/work"));
    try t.expect(!W.holdsPath("", "/work"));
    try t.expect(!W.holdsPath("/work", ""));
}

fn outputWith(tmp: *std.testing.TmpDir, data: []const u8) ![]u8 {
    const f = try tmp.dir.createFile("out.o", .{});
    defer f.close();
    try f.writeAll(data);
    const root = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);
    return std.fs.path.join(t.allocator, &.{ root, "out.o" });
}

test "postCheck: a compiler failure passes through; a missing or empty output is 3" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try t.expectEqual(@as(u8, 7), W.postCheck(arena.allocator(), 7, "nothing", "/work"));
    try t.expectEqual(@as(u8, 3), W.postCheck(arena.allocator(), 0, "nothing", "/work"));
    const p = try outputWith(&tmp, "");
    defer t.allocator.free(p);
    try t.expectEqual(@as(u8, 3), W.postCheck(arena.allocator(), 0, p, "/work"));
}

test "postCheck: the working directory as a whole path is 4; a longer name such as /workflows is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const leak = try outputWith(&tmp, "debug info: /work/crate/src/lib.rs");
    defer t.allocator.free(leak);
    try t.expectEqual(@as(u8, 4), W.postCheck(arena.allocator(), 0, leak, "/work"));
    const readme = try outputWith(&tmp, "see github.com/tokio-rs/prost/actions/workflows/ci.yml");
    defer t.allocator.free(readme);
    try t.expectEqual(@as(u8, 0), W.postCheck(arena.allocator(), 0, readme, "/work"));
    const bare = try outputWith(&tmp, "ab /work");
    defer t.allocator.free(bare);
    try t.expectEqual(@as(u8, 4), W.postCheck(arena.allocator(), 0, bare, "/work"));
}
