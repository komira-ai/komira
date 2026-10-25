//! Unit tests of regen.zig: how a committed directory is made equal to the
//! generator's output, how a target on the command line becomes a query, and how
//! buck2's answers are read. The process behaviour (the buck2 commands it runs,
//! over a stand-in buck2) is tests//functional/gen_regen.
const std = @import("std");
const R = @import("regen.zig");
const U = @import("act_util");
const t = std.testing;

fn lay(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
    try U.makeParent(dir, name);
    try U.writeAll(dir, name, data);
}

fn expectFile(dir: std.fs.Dir, a: std.mem.Allocator, name: []const u8, data: []const u8) !void {
    try t.expectEqualStrings(data, try U.readAll(a, dir, name));
}

test "sync: a new directory gets every file, with mode 0644" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(src.dir, "__init__.mojo", "# h\n");
    try lay(src.dir, "svc.mojo", "x\n");
    const sum = try R.sync(a, src.dir, dst.dir);
    try t.expectEqual(@as(usize, 2), sum.wrote);
    try t.expectEqual(@as(usize, 0), sum.removed);
    try t.expectEqual(@as(usize, 0), sum.unchanged);
    try expectFile(dst.dir, a, "svc.mojo", "x\n");
    const st = try dst.dir.statFile("svc.mojo");
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), st.mode & 0o777);
}

test "sync: a file that changed is rewritten, a file that is the same is not touched, a file no longer generated is removed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(src.dir, "same.mojo", "same\n");
    try lay(src.dir, "changed.mojo", "new\n");
    try lay(dst.dir, "same.mojo", "same\n");
    try lay(dst.dir, "changed.mojo", "old and longer\n");
    try lay(dst.dir, "gone.mojo", "gone\n");
    const sum = try R.sync(a, src.dir, dst.dir);
    try t.expectEqual(@as(usize, 1), sum.wrote);
    try t.expectEqual(@as(usize, 1), sum.removed);
    try t.expectEqual(@as(usize, 1), sum.unchanged);
    try expectFile(dst.dir, a, "changed.mojo", "new\n");
    try t.expectError(error.FileNotFound, dst.dir.statFile("gone.mojo"));
}

test "sync: a second run changes nothing (the files are not even rewritten)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(src.dir, "a.mojo", "a\n");
    try lay(src.dir, "sub/b.mojo", "b\n");
    try lay(dst.dir, "stale.mojo", "s\n");
    _ = try R.sync(a, src.dir, dst.dir);
    const before = try dst.dir.statFile("a.mojo");
    const again = try R.sync(a, src.dir, dst.dir);
    try t.expectEqual(@as(usize, 0), again.wrote);
    try t.expectEqual(@as(usize, 0), again.removed);
    try t.expectEqual(@as(usize, 2), again.unchanged);
    const after = try dst.dir.statFile("a.mojo");
    try t.expectEqual(before.mtime, after.mtime);
    try t.expectEqual(before.inode, after.inode);
}

test "sync: a directory the generator no longer fills is removed with its files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(src.dir, "a.mojo", "a\n");
    try lay(dst.dir, "old/deep/x.mojo", "x\n");
    try lay(dst.dir, "old/y.mojo", "y\n");
    const sum = try R.sync(a, src.dir, dst.dir);
    try t.expectEqual(@as(usize, 2), sum.removed);
    try t.expectError(error.FileNotFound, dst.dir.statFile("old"));
    try t.expectError(error.FileNotFound, dst.dir.statFile("old/deep"));
}

test "sync: output files that are links to the files (buck-out) are copied as files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = t.tmpDir(.{ .iterate = true });
    defer store.cleanup();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(store.dir, "blob", "payload\n");
    const real = try store.dir.realpathAlloc(a, "blob");
    try src.dir.symLink(real, "linked.mojo", .{});
    _ = try R.sync(a, src.dir, dst.dir);
    const st = try dst.dir.statFile("linked.mojo");
    try t.expectEqual(std.fs.File.Kind.file, st.kind);
    try expectFile(dst.dir, a, "linked.mojo", "payload\n");
}

test "patternOf: all, a package, and a library label become the patterns the query takes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("komira//...", try R.patternOf(a, "all"));
    try t.expectEqualStrings("komira//src/komira_gcp_firestore:", try R.patternOf(a, "komira//src/komira_gcp_firestore:"));
    try t.expectEqualStrings("komira//src/komira_aws_sqs:komira_aws_sqs_fresh", try R.patternOf(a, "komira//src/komira_aws_sqs:komira_aws_sqs"));
    try t.expectEqualStrings("tests//functional/x:y_fresh", try R.patternOf(a, "tests//functional/x:y"));
    try t.expectError(error.NotALabel, R.patternOf(a, "komira_aws_sqs"));
    try t.expectError(error.NotALabel, R.patternOf(a, "src/komira_aws_sqs"));
}

test "parseJobs: each fresh target's committed directory is under its package, in label order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"komira//src/b:b_fresh":{"buck.type":"gen_fresh","committed_dir":"generated/b","gen":"komira//src/b:b_gen"},
        \\ "tests//functional/x:y_fresh":{"committed_dir":"generated/y","gen":"tests//functional/x:y_gen"},
        \\ "komira//src/a:a_fresh":{"committed_dir":"generated/a","gen":"komira//src/a:a_gen"}}
    ;
    const jobs = try R.parseJobs(a, json);
    try t.expectEqual(@as(usize, 3), jobs.len);
    try t.expectEqualStrings("komira//src/a:a_fresh", jobs[0].fresh);
    try t.expectEqualStrings("src/a/generated/a", jobs[0].dest);
    try t.expectEqualStrings("komira//src/a:a_gen", jobs[0].gen);
    try t.expectEqualStrings("komira", jobs[0].cell);
    try t.expectEqualStrings("tests", jobs[2].cell);
    try t.expectEqualStrings("functional/x/generated/y", jobs[2].dest);
}

test "parseJobs: an answer that is not that is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadQueryResult, R.parseJobs(a, "[]"));
    try t.expectError(error.BadQueryResult, R.parseJobs(a, "{\"komira//a:a_fresh\":{\"gen\":\"komira//a:a_gen\"}}"));
    try t.expectError(error.BadQueryResult, R.parseJobs(a, "{\"komira//a:a_fresh\":{\"committed_dir\":3,\"gen\":\"x\"}}"));
}

test "outputOf: the path printed for a label, not for a label it is a prefix of" {
    const text = "komira//src/a:a_gen /out/one\nkomira//src/a:a_gen2 /out/two\n";
    try t.expectEqualStrings("/out/one", R.outputOf(text, "komira//src/a:a_gen").?);
    try t.expectEqualStrings("/out/two", R.outputOf(text, "komira//src/a:a_gen2").?);
    try t.expect(R.outputOf(text, "komira//src/a:a") == null);
}

test "findLink: a symbolic link to a file or to a directory, at any depth, is found without following it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = t.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try lay(out.dir, "x.mojo", "x\n");
    const target = try out.dir.realpathAlloc(a, ".");
    try lay(dst.dir, "plain.mojo", "p\n");
    try t.expect((try R.findLink(a, dst.dir)) == null);
    try lay(dst.dir, "sub/deeper/f.mojo", "f\n");
    try dst.dir.symLink(try std.fmt.allocPrint(a, "{s}/x.mojo", .{target}), "sub/deeper/link.mojo", .{});
    try t.expectEqualStrings("sub/deeper/link.mojo", (try R.findLink(a, dst.dir)).?);
    try dst.dir.symLink(target, "aaa_dir", .{ .is_directory = true });
    try t.expectEqualStrings("aaa_dir", (try R.findLink(a, dst.dir)).?);
}

test "sync: a symbolic link to a file outside the directory is refused, and the file outside is not written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    var outside = t.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try lay(src.dir, "a.mojo", "generated\n");
    try lay(outside.dir, "victim.txt", "keep me\n");
    const victim = try outside.dir.realpathAlloc(a, "victim.txt");
    try dst.dir.symLink(victim, "a.mojo", .{});
    try t.expectError(error.SymlinkInDestination, R.sync(a, src.dir, dst.dir));
    try expectFile(outside.dir, a, "victim.txt", "keep me\n");
}

test "sync: a symbolic link to a directory outside is refused, and nothing outside is deleted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = t.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = t.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    var outside = t.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try lay(src.dir, "a.mojo", "generated\n");
    try outside.dir.makePath("empty_dir");
    try lay(outside.dir, "kept/file.txt", "keep me\n");
    const target = try outside.dir.realpathAlloc(a, ".");
    try dst.dir.symLink(target, "link", .{ .is_directory = true });
    try t.expectError(error.SymlinkInDestination, R.sync(a, src.dir, dst.dir));
    try expectFile(outside.dir, a, "kept/file.txt", "keep me\n");
    _ = try outside.dir.statFile("empty_dir");
}

test "linkOnPath: a link anywhere on the path to the committed directory is found; plain and missing paths are not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = t.tmpDir(.{ .iterate = true });
    defer root.cleanup();
    var outside = t.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try root.dir.makePath("src/x/generated/x");
    try t.expect((try R.linkOnPath(a, root.dir, "src/x/generated/x")) == null);
    try t.expect((try R.linkOnPath(a, root.dir, "src/y/generated/y")) == null);
    const target = try outside.dir.realpathAlloc(a, ".");
    try root.dir.symLink(target, "src/x/generated/z", .{ .is_directory = true });
    try t.expectEqualStrings("src/x/generated/z", (try R.linkOnPath(a, root.dir, "src/x/generated/z")).?);
    try t.expectEqualStrings("src/x/generated/z", (try R.linkOnPath(a, root.dir, "src/x/generated/z/deeper")).?);
    try root.dir.symLink(target, "src/w", .{ .is_directory = true });
    try t.expectEqualStrings("src/w", (try R.linkOnPath(a, root.dir, "src/w/generated/w")).?);
}
