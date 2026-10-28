//! Unit tests of git_check's pure parts. Its process behaviour (the eight
//! checks, the decoys, the report) is tests//functional/git_check; the
//! `git_check` validation of the git oracle runs through it too.
const std = @import("std");
const G = @import("git_check.zig");
const U = @import("act_util");
const t = std.testing;

test "isDecoy: the five names, no others" {
    for (G.decoys) |d| try t.expect(G.isDecoy(d));
    try t.expect(!G.isDecoy("git_check"));
    try t.expect(!G.isDecoy("git-lfs2"));
    try t.expect(!G.isDecoy("Git"));
    try t.expect(!G.isDecoy(""));
}

test "objectId: git's own vectors" {
    // `printf 'hello\n' | git hash-object --stdin`, `git hash-object -t tree /dev/null`
    try t.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &G.objectId("blob", "hello\n"));
    try t.expectEqualStrings("4b825dc642cb6eb9a060e54bf8d69288fbee4904", &G.objectId("tree", ""));
    try t.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &G.objectId("blob", ""));
}

test "commitBody: fixed identities and dates, one trailing newline" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try G.commitBody(a, "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
    try t.expectEqualStrings("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A U Thor <author@example.com> 1790000000 +0000\ncommitter C O Mitter <committer@example.com> 1790000000 +0000\n\nsmoke\n", body);
    try t.expectEqual(@as(usize, 40), G.objectId("commit", body).len);
}

test "msSubst: the milliseconds git waited are written <ms>, the first time on a line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after <ms> ms: Could not connect to server\n",
        try G.msSubst(a, "fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after 0 ms: Could not connect to server\n"),
    );
    try t.expectEqualStrings("x after <ms> ms: y after 7 ms: z", try G.msSubst(a, "x after 12 ms: y after 7 ms: z"));
    // not a number, no milliseconds, no space after the colon
    try t.expectEqualStrings("after x ms: ", try G.msSubst(a, "after x ms: "));
    try t.expectEqualStrings("a after 5 ms:", try G.msSubst(a, "a after 5 ms:"));
    // an earlier " after " that is not it does not hide the one that is
    try t.expectEqualStrings("a after b after <ms> ms: c", try G.msSubst(a, "a after b after 31 ms: c"));
    // a second line is treated alone
    try t.expectEqualStrings("p after <ms> ms: q\nr after <ms> ms: s", try G.msSubst(a, "p after 1 ms: q\nr after 2 ms: s"));
}

test "lastLines: tail -n" {
    try t.expectEqualStrings("b\nc\n", G.lastLines("a\nb\nc\n", 2));
    try t.expectEqualStrings("b\nc", G.lastLines("a\nb\nc", 2));
    try t.expectEqualStrings("a\nb\nc\n", G.lastLines("a\nb\nc\n", 40));
    try t.expectEqualStrings("", G.lastLines("", 40));
}

test "sharedLibraries: .so and .so.* by name, sorted, under the prefix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/sub");
    try U.writeAll(tmp.dir, "lib/libz.so.1", "z");
    try U.writeAll(tmp.dir, "lib/sub/libc.so", "c");
    try U.writeAll(tmp.dir, "lib/libz.a", "a");
    try U.writeAll(tmp.dir, "lib/solid", "s");
    try U.writeAll(tmp.dir, "bin_so", "b");
    const found = try G.sharedLibraries(a, tmp.dir, "/d");
    try t.expectEqual(@as(usize, 2), found.len);
    try t.expectEqualStrings("/d/lib/libz.so.1", found[0]);
    try t.expectEqualStrings("/d/lib/sub/libc.so", found[1]);
    var none = t.tmpDir(.{ .iterate = true });
    defer none.cleanup();
    try t.expectEqual(@as(usize, 0), (try G.sharedLibraries(a, none.dir, "/d")).len);
}

test "required: the distribution's files" {
    try t.expect(G.required.len == 9);
    try t.expectEqualStrings("bin/git", G.required[0]);
}

test "decoyDir: the directory of a path, else the first PATH entry holding the name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/t/decoy", (try G.decoyDir(a, "/t/decoy/git", null)).?);
    try t.expectEqualStrings(".", (try G.decoyDir(a, "git", null)) orelse ".");
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("one");
    try tmp.dir.makePath("two");
    try U.writeAll(tmp.dir, "two/git-lfs", "x");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const one = try std.fs.path.join(a, &.{ root, "one" });
    const two = try std.fs.path.join(a, &.{ root, "two" });
    const path = try std.fmt.allocPrint(a, ":{s}:{s}:/nowhere", .{ one, two });
    try t.expectEqualStrings(two, (try G.decoyDir(a, "git-lfs", path)).?);
    try t.expect((try G.decoyDir(a, "git-other", path)) == null);
}
