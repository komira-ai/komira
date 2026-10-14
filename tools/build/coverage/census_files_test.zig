//! The cases of census_files, `zig test` of this file (which imports
//! census_files.zig) run as a build action by `:census_files_unit`; the
//! executable `:census_files_exe` is not built unless every one passes.
//!
//! Each case runs the program as main does (`entry`: the command line, a
//! working directory, stderr) in a directory of its own and reads back the
//! exit status, the message and the files.

const std = @import("std");
const C = @import("census_files.zig");

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,

    fn init() Case {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
        };
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn put(self: *Case, path: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(path, bytes);
    }

    fn get(self: *Case, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(self.arena.allocator(), path, 1 << 20);
    }

    fn has(self: *Case, path: []const u8) bool {
        self.tmp.dir.access(path, .{}) catch return false;
        return true;
    }

    /// Runs the program; returns its status, its stderr in `err`.
    fn run(self: *Case, args: []const []const u8, err: *[]const u8) u8 {
        var buf = std.ArrayList(u8).init(self.arena.allocator());
        const status = C.entry(self.arena.allocator(), self.tmp.dir, args, buf.writer());
        err.* = buf.items;
        return status;
    }

    /// Runs `assemble 9900 t census.tsv held.tsv`, expecting `want` and,
    /// for a refusal, a message holding `msg`.
    fn assemble(self: *Case, want: u8, msg: []const u8) !void {
        var err: []const u8 = "";
        const status = self.run(&.{ "assemble", "9900", "t", "census.tsv", "held.tsv" }, &err);
        if (status != want or std.mem.indexOf(u8, err, msg) == null) {
            std.debug.print("status {d} (want {d}), stderr:\n{s}\nwant it to hold: {s}\n", .{ status, want, err, msg });
            return error.TestUnexpectedResult;
        }
        if (want != 0) {
            try std.testing.expect(!self.has("census.tsv"));
            try std.testing.expect(!self.has("held.tsv"));
        }
    }
};

const head = "census\t2026-10-10\tabc\t-\n";

/// Packages given out of order: src/b at 90% (held on line all the same: a
/// hold of a package below the target is the gate's to fail, not the
/// census's), src/a below, src/c at 99.00% line and 100% branch in its one
/// library with a line, its generated library (0 0) setting nothing, held
/// on both, and a test package.
fn putGood(c: *Case) !void {
    try c.put("t/src/b/coverage_held", C.held_comment ++ "line\n");
    try c.put("t/src/b/coverage_census.tsv", C.census_comment ++ head ++
        "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n");
    try c.put("t/src/a/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t10\t1\t4\tyes\tno\t-\t-\n");
    try c.put("t/src/c/coverage_held", "branch\n# both\nline\n");
    try c.put("t/src/c/coverage_census.tsv", head ++
        "komira//src/c:c\tsrc/c\tlibrary\tOK\t99\t100\t4\t4\tyes\tno\t-\t-\n" ++
        "komira//src/c:gen\tsrc/c\tlibrary\tOK\t0\t0\t-\t-\tno\tno\t-\t-\n");
    try c.put("t/src/tests/e2e/t/coverage_census.tsv", head ++ "komira//src/tests/e2e/t:t\tsrc/tests/e2e/t\ttest\tOK\t4\t4\t-\t-\tno\tno\t-\t-\n");
}

const good_census = C.assembled_census_comment ++ head ++
    "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t10\t1\t4\tyes\tno\t-\t-\n" ++
    "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
    "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
    "komira//src/c:c\tsrc/c\tlibrary\tOK\t99\t100\t4\t4\tyes\tno\t-\t-\n" ++
    "komira//src/c:gen\tsrc/c\tlibrary\tOK\t0\t0\t-\t-\tno\tno\t-\t-\n" ++
    "komira//src/tests/e2e/t:t\tsrc/tests/e2e/t\ttest\tOK\t4\t4\t-\t-\tno\tno\t-\t-\n";

test "assemble: every row, sorted by label, one census line, and every package's holds" {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    try c.assemble(0, "");
    try std.testing.expectEqualStrings(good_census, try c.get("census.tsv"));
    try std.testing.expectEqualStrings(C.assembled_held_comment ++
        "src/b\tline\n" ++
        "src/c\tline,branch\n", try c.get("held.tsv"));
}

test "assemble: a label twice stays twice (render refuses it); a marker holding nothing is -" {
    var c = Case.init();
    defer c.deinit();
    try c.put("t/src/a/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tx\n" ++ "komira//src/a:a\tsrc/a\tx\n");
    try c.put("t/src/a/coverage_held", "# nothing\n");
    try c.assemble(0, "");
    try std.testing.expectEqualStrings(C.assembled_census_comment ++ head ++ "komira//src/a:a\tsrc/a\tx\n" ++ "komira//src/a:a\tsrc/a\tx\n", try c.get("census.tsv"));
    try std.testing.expectEqualStrings(C.assembled_held_comment ++ "src/a\t-\n", try c.get("held.tsv"));
}

test "combine: one date and note kept; dates differ; commits or notes differ" {
    var a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("census\t2026-10-10\tabc\tmain + fix\n", C.combine(a.allocator(), &.{
        .{ .date = "2026-10-10", .commit = "abc", .note = "main + fix" },
        .{ .date = "2026-10-10", .commit = "abc", .note = "main + fix" },
    }));
    try std.testing.expectEqualStrings("census\t2026-10-12\t-\tpackages measured from 2026-10-09 to 2026-10-12\n", C.combine(a.allocator(), &.{
        .{ .date = "2026-10-10", .commit = "abc", .note = "-" },
        .{ .date = "2026-10-12", .commit = "def", .note = "-" },
        .{ .date = "2026-10-09", .commit = "abc", .note = "-" },
    }));
    try std.testing.expectEqualStrings("census\t2026-10-10\tabc\t-\n", C.combine(a.allocator(), &.{
        .{ .date = "2026-10-10", .commit = "abc", .note = "one" },
        .{ .date = "2026-10-10", .commit = "abc", .note = "two" },
    }));
}

/// A good tree with one file replaced (`bytes` null: deleted): `assemble`
/// must refuse with `msg`.
fn refusedWith(path: []const u8, bytes: ?[]const u8, msg: []const u8) !void {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    if (bytes) |b| try c.put(path, b) else try c.tmp.dir.deleteFile(path);
    try c.assemble(1, msg);
}

test "assemble refuses a package that reached the target without holding it, naming every one" {
    // src/c's marker gone: both metrics reached and not held.
    try refusedWith("t/src/c/coverage_held", null, "a package the census measured at the target does not hold it (census_files split adds the hold):\n" ++
        "  src/c: line reached 9900 basis points in every library; add `line` to src/c/coverage_held\n" ++
        "  src/c: branch reached 9900 basis points in every library; add `branch` to src/c/coverage_held\n");
    try refusedWith("t/src/c/coverage_held", "line\n", "  src/c: branch reached 9900 basis points");
    // A package at 100% on a library of its own: src/a's one row raised.
    try refusedWith("t/src/a/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t10\t10\t1\t4\tyes\tno\t-\t-\n", "  src/a: line reached 9900");
}

test "reached: the lowest library decides; not OK, no number, 0 0 branch keep it out; 0 0 lines set nothing" {
    var a = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer a.deinit();
    const al = a.allocator();
    const rows = [_]C.Row{
        .{ .key = "x", .line = "komira//src/p:p1\tsrc/p\tlibrary\tOK\t99\t100\t99\t100\tyes\tno\t-\t-" },
        .{ .key = "x", .line = "komira//src/p:p2\tsrc/p\tlibrary\tOK\t197\t199\t1\t1\tyes\tno\t-\t-" },
        .{ .key = "x", .line = "komira//src/q:q\tsrc/q\tlibrary\tOK\t10\t10\t-\t-\tno\tno\t-\t-" },
        .{ .key = "x", .line = "komira//src/q:q2\tsrc/q\tlibrary\tRUN_FAILED\t-\t-\t-\t-\tno\tno\t-\tboom" },
        .{ .key = "x", .line = "komira//src/r:r\tsrc/r\tlibrary\tOK\t10\t10\t0\t0\tyes\tno\t-\t-" },
        .{ .key = "x", .line = "komira//src/s:gen\tsrc/s\tlibrary\tOK\t0\t0\t-\t-\tno\tno\t-\t-" },
        .{ .key = "x", .line = "komira//src/tests/t:t\tsrc/tests/t\ttest\tOK\t1\t1\t1\t1\tyes\tno\t-\t-" },
    };
    var r = C.reached(al, &rows, 9900);
    // p: line 99.00% and 98.99% (197 of 199, rounded down): not reached.
    try std.testing.expectEqual(@as(i8, -1), r.get("src/p").?.line);
    try std.testing.expectEqual(@as(i8, 1), r.get("src/p").?.branch);
    try std.testing.expectEqual(@as(i8, -1), r.get("src/q").?.line);
    try std.testing.expectEqual(@as(i8, 1), r.get("src/r").?.line);
    try std.testing.expectEqual(@as(i8, -1), r.get("src/r").?.branch);
    try std.testing.expectEqual(@as(i8, 0), r.get("src/s").?.line);
    try std.testing.expect(r.get("src/tests/t") == null);
    var at = C.reached(al, rows[0..1], 9900);
    try std.testing.expectEqual(@as(i8, 1), at.get("src/p").?.line);
}

test "assemble refuses a malformed marker" {
    try refusedWith("t/src/b/coverage_held", "# c\nline 9900\n", "census_files: src/b/coverage_held:2: 'line 9900' is not a held metric");
    try refusedWith("t/src/b/coverage_held", "lines\n", "src/b/coverage_held:1: 'lines' is not a held metric");
    // A metric name is matched whole: a prefix match (startsWith for eql)
    // would take these as `branch` and `line`.
    try refusedWith("t/src/b/coverage_held", "branchX\n", "src/b/coverage_held:1: 'branchX' is not a held metric");
    try refusedWith("t/src/b/coverage_held", "linex\n", "src/b/coverage_held:1: 'linex' is not a held metric");
    try refusedWith("t/src/b/coverage_held", "line\nline\n", "src/b/coverage_held:2: line is held twice");
    try refusedWith("t/src/b/coverage_held", "line\r\n", "census_files: src/b/coverage_held:1: a carriage return");
    try refusedWith("t/src/b/coverage_held", "# c\n\nline\n", "census_files: src/b/coverage_held:2: an empty line");
}

test "assemble refuses a census file without its census line, a row of another package, no row" {
    try refusedWith("t/src/b/coverage_census.tsv", "komira//src/b:b\tsrc/b\n", "census_files: src/b/coverage_census.tsv:1: the first line is census");
    try refusedWith("t/src/b/coverage_census.tsv", "census\t2026-10-1\tabc\t-\n", ":1: the first line is census");
    try refusedWith("t/src/b/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tx\n", "census_files: src/b/coverage_census.tsv:2: the row's package is src/a, not its directory src/b");
    try refusedWith("t/src/b/coverage_census.tsv", head ++ "komira//src/b:b\n", "the row's package is missing");
    try refusedWith("t/src/b/coverage_census.tsv", head, "census_files: src/b/coverage_census.tsv: no census line and library row");
}

test "assemble refuses another file, a file at the top, and a tree with no census" {
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\t-\n", "census_files: src/b/coverage_floor.tsv: not a coverage_held or a coverage_census.tsv");
    try refusedWith("t/coverage_held", "line\n", "coverage_held: at the top of t");
    var c = Case.init();
    defer c.deinit();
    try c.put("t/src/a/coverage_held", "line\n");
    try c.assemble(1, "t: no coverage_census.tsv under it");
}

test "split writes each census file, adds what was reached to the marker, never takes a hold out" {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    try c.assemble(0, "");
    try c.tmp.dir.makePath("out/src/b");
    // src/b: held on line though measured at 90%: kept as written.
    try c.put("out/src/b/coverage_held", "# kept\nline\n");
    // src/c: holds branch already; split adds line, keeping its comment.
    try c.put("out/src/c/coverage_held", "# mine\nbranch\n");
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "split", "9900", "census.tsv", "out" }, &err));
    try std.testing.expectEqualStrings("# kept\nline\n", try c.get("out/src/b/coverage_held"));
    try std.testing.expectEqualStrings("# mine\nline\nbranch\n", try c.get("out/src/c/coverage_held"));
    try std.testing.expect(!c.has("out/src/a/coverage_held"));
    try std.testing.expectEqualStrings(C.census_comment ++ head ++
        "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n", try c.get("out/src/b/coverage_census.tsv"));
    try std.testing.expect(!c.has("out/src/tests/e2e/t/coverage_held"));
    try std.testing.expect(c.has("out/src/tests/e2e/t/coverage_census.tsv"));
    // Assembled again, the split tree gives back the census it read.
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "assemble", "9900", "out", "census2.tsv", "held2.tsv" }, &err));
    try std.testing.expectEqualStrings(try c.get("census.tsv"), try c.get("census2.tsv"));
    try std.testing.expectEqualStrings(C.assembled_held_comment ++ "src/b\tline\nsrc/c\tline,branch\n", try c.get("held2.tsv"));
    // A package with no marker that reached the target gets one, with the
    // standard comment.
    try c.tmp.dir.makePath("fresh");
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "split", "9900", "census.tsv", "fresh" }, &err));
    try std.testing.expectEqualStrings(C.held_comment ++ "line\nbranch\n", try c.get("fresh/src/c/coverage_held"));
    try std.testing.expect(!c.has("fresh/src/b/coverage_held"));
}

test "split keeps a hold on the metric a package did not reach while adding the one it did" {
    var c = Case.init();
    defer c.deinit();
    // src/d: line 90%, branch 100%; holds line. src/e: line 100%, branch 75%; holds branch.
    try c.put("census.tsv", head ++
        "komira//src/d:d\tsrc/d\tlibrary\tOK\t9\t10\t4\t4\tno\tno\t-\t-\n" ++
        "komira//src/e:e\tsrc/e\tlibrary\tOK\t10\t10\t3\t4\tno\tno\t-\t-\n");
    try c.put("out/src/d/coverage_held", "# k\nline\n");
    try c.put("out/src/e/coverage_held", "# k\nbranch\n");
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "split", "9900", "census.tsv", "out" }, &err));
    try std.testing.expectEqualStrings("# k\nline\nbranch\n", try c.get("out/src/d/coverage_held"));
    try std.testing.expectEqualStrings("# k\nline\nbranch\n", try c.get("out/src/e/coverage_held"));
}

test "split refuses a malformed marker it would add to, writing nothing" {
    var c = Case.init();
    defer c.deinit();
    try c.put("census.tsv", head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t10\t10\t-\t-\tno\tno\t-\t-\n");
    try c.tmp.dir.makePath("out/src/a");
    try c.put("out/src/a/coverage_held", "line 9900\n");
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 1), c.run(&.{ "split", "9900", "census.tsv", "out" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "src/a/coverage_held:1: 'line 9900' is not a held metric") != null);
    try std.testing.expect(!c.has("out/src/a/coverage_census.tsv"));
}

test "bad usage exits 2 with the usage" {
    var c = Case.init();
    defer c.deinit();
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{}, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "census_files: no command\nusage: census_files assemble") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{"merge"}, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "unknown command 'merge'") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{ "assemble", "t" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "assemble takes 4 arguments, not 1") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{ "split", "a", "b" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "split takes 3 arguments, not 2") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{ "split", "10001", "b", "c" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "<target bp> '10001' is not a number") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{ "assemble", "x", "t", "c", "r" }, &err));
    try std.testing.expectEqual(@as(u8, 1), c.run(&.{ "assemble", "9900", "missing", "c", "r" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "missing: cannot open it") != null);
}
