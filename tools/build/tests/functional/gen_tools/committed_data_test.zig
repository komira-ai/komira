//! `committed_data` of tools/build/gen/defs.bzl over generated/nested_fixture/
//! (a.mojo, notes.txt and _parts/b.mojo): what a test is given of a committed
//! directory, and where.
const std = @import("std");
const t = std.testing;

fn exists(rel: []const u8) !bool {
    const work = try std.process.getEnvVarOwned(t.allocator, "KOMIRA_TEST_WORK");
    defer t.allocator.free(work);
    var dir = try std.fs.openDirAbsolute(work, .{});
    defer dir.close();
    dir.access(rel, .{}) catch return false;
    return true;
}

test "a nested file keeps its path inside the committed directory" {
    try t.expect(try exists("all/a.mojo"));
    try t.expect(try exists("all/_parts/b.mojo"));
    try t.expect(!(try exists("all/b.mojo")));
}

test "without a suffix every file is taken" {
    try t.expect(try exists("all/notes.txt"));
}

test "a suffix keeps only the files ending so, nested ones with their paths" {
    try t.expect(try exists("mojo_only/a.mojo"));
    try t.expect(try exists("mojo_only/_parts/b.mojo"));
    try t.expect(!(try exists("mojo_only/notes.txt")));
}
