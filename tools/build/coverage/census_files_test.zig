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

    /// Runs `assemble t census.tsv ratchet.tsv`, expecting `want` and, for
    /// a refusal, a message holding `msg`.
    fn assemble(self: *Case, want: u8, msg: []const u8) !void {
        var err: []const u8 = "";
        const status = self.run(&.{ "assemble", "t", "census.tsv", "ratchet.tsv" }, &err);
        if (status != want or std.mem.indexOf(u8, err, msg) == null) {
            std.debug.print("status {d} (want {d}), stderr:\n{s}\nwant it to hold: {s}\n", .{ status, want, err, msg });
            return error.TestUnexpectedResult;
        }
        if (want != 0) {
            try std.testing.expect(!self.has("census.tsv"));
            try std.testing.expect(!self.has("ratchet.tsv"));
        }
    }
};

const head = "census\t2026-10-10\tabc\t-\n";

/// Two packages, given out of order and one nested under another's name.
fn putGood(c: *Case) !void {
    try c.put("t/src/b/coverage_floor.tsv", C.floor_comment ++ "src/b\t9000\t-\n");
    try c.put("t/src/b/coverage_census.tsv", C.census_comment ++ head ++
        "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n");
    try c.put("t/src/a/coverage_floor.tsv", "src/a\t5000\t2500\tlines run only when contended");
    try c.put("t/src/a/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t10\t1\t4\tyes\tno\t-\t-\n");
    try c.put("t/src/tests/e2e/t/coverage_census.tsv", head ++ "komira//src/tests/e2e/t:t\tsrc/tests/e2e/t\ttest\tOK\t3\t4\t-\t-\tno\tno\t-\t-\n");
}

test "assemble: every row, sorted by label and by package, one census line" {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    try c.assemble(0, "");
    try std.testing.expectEqualStrings(C.assembled_census_comment ++ head ++
        "komira//src/a:a\tsrc/a\tlibrary\tOK\t5\t10\t1\t4\tyes\tno\t-\t-\n" ++
        "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/tests/e2e/t:t\tsrc/tests/e2e/t\ttest\tOK\t3\t4\t-\t-\tno\tno\t-\t-\n", try c.get("census.tsv"));
    try std.testing.expectEqualStrings(C.assembled_ratchet_comment ++
        "src/a\t5000\t2500\tlines run only when contended\n" ++
        "src/b\t9000\t-\n", try c.get("ratchet.tsv"));
}

test "assemble: a label twice stays twice (render refuses it)" {
    var c = Case.init();
    defer c.deinit();
    try c.put("t/src/a/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tx\n" ++ "komira//src/a:a\tsrc/a\tx\n");
    try c.assemble(0, "");
    try std.testing.expectEqualStrings(C.assembled_census_comment ++ head ++ "komira//src/a:a\tsrc/a\tx\n" ++ "komira//src/a:a\tsrc/a\tx\n", try c.get("census.tsv"));
    try std.testing.expectEqualStrings(C.assembled_ratchet_comment, try c.get("ratchet.tsv"));
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

/// A good tree with one file replaced: `assemble` must refuse with `msg`.
fn refusedWith(path: []const u8, bytes: []const u8, msg: []const u8) !void {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    try c.put(path, bytes);
    try c.assemble(1, msg);
}

test "assemble refuses a floor file that is not exactly one row of its own package" {
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\t-\nsrc/b\t9100\t-\n", "census_files: src/b/coverage_floor.tsv:2: a second row");
    try refusedWith("t/src/b/coverage_floor.tsv", C.floor_comment, "census_files: src/b/coverage_floor.tsv: no row");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/a\t9000\t-\n", "census_files: src/b/coverage_floor.tsv:1: the row names package src/a, not its directory src/b");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\n", "not 2");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\t-\tx\ty\n", "not 5");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\t-\t\n", ":1: a pinned row has an empty reason");
}

test "assemble refuses a floor that is not 0 to 10000 basis points" {
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t10001\t-\n", "line floor '10001' is not");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t0900\t-\n", "line floor '0900' is not");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t-\t-\n", "line floor '-' is not");
    try refusedWith("t/src/b/coverage_floor.tsv", "src/b\t9000\tx\n", "branch floor 'x' is not");
}

test "assemble refuses a carriage return and an empty line" {
    try refusedWith("t/src/b/coverage_floor.tsv", "# c\nsrc/b\t9000\t-\r\n", "census_files: src/b/coverage_floor.tsv:2: a carriage return");
    try refusedWith("t/src/b/coverage_floor.tsv", "# c\n\nsrc/b\t9000\t-\n", "census_files: src/b/coverage_floor.tsv:2: an empty line");
}

test "assemble refuses a census file without its census line, a row of another package, no row" {
    try refusedWith("t/src/b/coverage_census.tsv", "komira//src/b:b\tsrc/b\n", "census_files: src/b/coverage_census.tsv:1: the first line is census");
    try refusedWith("t/src/b/coverage_census.tsv", "census\t2026-10-1\tabc\t-\n", ":1: the first line is census");
    try refusedWith("t/src/b/coverage_census.tsv", head ++ "komira//src/a:a\tsrc/a\tx\n", "census_files: src/b/coverage_census.tsv:2: the row's package is src/a, not its directory src/b");
    try refusedWith("t/src/b/coverage_census.tsv", head ++ "komira//src/b:b\n", "the row's package is missing");
    try refusedWith("t/src/b/coverage_census.tsv", head, "census_files: src/b/coverage_census.tsv: no census line and library row");
}

test "assemble refuses another file, a file at the top, and a tree with no census" {
    try refusedWith("t/src/b/ratchet.tsv", "src/b\t9000\t-\n", "census_files: src/b/ratchet.tsv: not a coverage_floor.tsv or a coverage_census.tsv");
    try refusedWith("t/coverage_floor.tsv", "x\t0\t-\n", "coverage_floor.tsv: at the top of t");
    var c = Case.init();
    defer c.deinit();
    try c.put("t/src/a/coverage_floor.tsv", "src/a\t0\t-\n");
    try c.assemble(1, "t: no coverage_census.tsv under it");
}

test "split writes each package's two files, and assemble gives back what it read" {
    var c = Case.init();
    defer c.deinit();
    try putGood(&c);
    try c.assemble(0, "");
    try c.tmp.dir.makePath("out");
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "split", "census.tsv", "ratchet.tsv", "out" }, &err));
    try std.testing.expectEqualStrings(C.floor_comment ++ "src/b\t9000\t-\n", try c.get("out/src/b/coverage_floor.tsv"));
    try std.testing.expectEqualStrings(C.census_comment ++ head ++
        "komira//src/b:b1\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n" ++
        "komira//src/b:b2\tsrc/b\tlibrary\tOK\t9\t10\t-\t-\tno\tno\t-\t-\n", try c.get("out/src/b/coverage_census.tsv"));
    try std.testing.expect(!c.has("out/src/tests/e2e/t/coverage_floor.tsv"));
    try std.testing.expect(c.has("out/src/tests/e2e/t/coverage_census.tsv"));
    try std.testing.expectEqual(@as(u8, 0), c.run(&.{ "assemble", "out", "census2.tsv", "ratchet2.tsv" }, &err));
    try std.testing.expectEqualStrings(try c.get("census.tsv"), try c.get("census2.tsv"));
    try std.testing.expectEqualStrings(try c.get("ratchet.tsv"), try c.get("ratchet2.tsv"));
}

test "split refuses a floor row twice and a malformed one, writing nothing" {
    var c = Case.init();
    defer c.deinit();
    try c.put("census.tsv", head ++ "komira//src/a:a\tsrc/a\tx\n");
    try c.put("ratchet.tsv", "src/a\t1\t-\nsrc/a\t2\t-\n");
    try c.tmp.dir.makePath("out");
    var err: []const u8 = "";
    try std.testing.expectEqual(@as(u8, 1), c.run(&.{ "split", "census.tsv", "ratchet.tsv", "out" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "ratchet.tsv: package src/a has a second row") != null);
    try std.testing.expect(!c.has("out/src/a/coverage_census.tsv"));
    try c.put("ratchet.tsv", "src/a\t10001\t-\n");
    try std.testing.expectEqual(@as(u8, 1), c.run(&.{ "split", "census.tsv", "ratchet.tsv", "out" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "line floor '10001'") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, err, "assemble takes 3 arguments, not 1") != null);
    try std.testing.expectEqual(@as(u8, 2), c.run(&.{ "split", "a", "b" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "split takes 3 arguments, not 2") != null);
    try std.testing.expectEqual(@as(u8, 1), c.run(&.{ "assemble", "missing", "c", "r" }, &err));
    try std.testing.expect(std.mem.indexOf(u8, err, "missing: cannot open it") != null);
}
