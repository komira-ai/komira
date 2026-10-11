//! Unit tests of the shell list, over trees written to a temporary directory:
//! what is a shell script, and each finding the check reports.

const std = @import("std");
const budget = @import("budget.zig");

const al = "tools/build/lint/shell_allowlist.tsv";

const Run = struct {
    result: budget.Result,
    report: []const u8,
};

fn write(dir: std.fs.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try dir.makePath(d);
        try dir.writeFile(f[0], f[1]);
    }
}

/// Collects the shell scripts of `dir` and checks them against `allowlist`.
fn checkDir(arena: std.mem.Allocator, dir: std.fs.Dir, allowlist: []const u8) !Run {
    const scripts = try budget.collect(arena, dir);
    var out = std.ArrayList(u8).init(arena);
    const r = try budget.check(arena, al, allowlist, scripts, &out);
    return .{ .result = r, .report = out.items };
}

/// Writes `files` (path, contents) under a fresh temporary directory, then
/// checks it against `allowlist`.
fn run(arena: std.mem.Allocator, files: []const [2][]const u8, allowlist: []const u8) !Run {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, files);
    return checkDir(arena, tmp.dir, allowlist);
}

fn expectFinding(r: Run, needle: []const u8) !void {
    if (std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("no finding holding `{s}` in:\n{s}\n", .{ needle, r.report });
        return error.TestExpectedFinding;
    }
}

fn expectClean(r: Run) !void {
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(@as(usize, 0), r.result.findings);
}

// A tree of every kind of file: two listed scripts (one extensionless, found
// by its shebang), and files that are not shell.
const clean_tree = [_][2][]const u8{
    .{ "tools/a.sh", "#!/bin/sh\necho a\necho b\n" },
    .{ "buck2", "#!/bin/sh\nexec x \"$@\"\n" },
    .{ "src/lib.mojo", "fn main():\n    pass\n" },
    .{ "tools/gen.py", "#!/usr/bin/env python3\nprint(1)\n" },
    .{ "docs/shell.md", "# about sh\n" },
};
const clean_allowlist =
    "# path\treason\n" ++
    "\n" ++
    "buck2\tthe pinned buck2 launcher\n" ++
    "tools/a.sh\ta thin wrapper\n";

test "a clean tree passes: every script has a row, every row a script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), &clean_tree, clean_allowlist);
    try expectClean(r);
    try std.testing.expectEqual(@as(usize, 2), r.result.scripts);
}

test "an unlisted 3-line script is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{.{ "tools/ci/new.sh", "echo 1\necho 2\necho 3\n" }};
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, "tools/ci/new.sh: a shell script with no row in " ++ al);
}

test "a listed script grown by 50 lines passes with no change to the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, &clean_tree);
    try expectClean(try checkDir(arena.allocator(), tmp.dir, clean_allowlist));
    {
        const f = try tmp.dir.openFile("tools/a.sh", .{ .mode = .write_only });
        defer f.close();
        try f.seekFromEnd(0);
        for (0..50) |_| try f.writeAll("echo more\n");
    }
    const st = try tmp.dir.statFile("tools/a.sh");
    try std.testing.expectEqual(@as(u64, 24 + 50 * 10), st.size);
    try expectClean(try checkDir(arena.allocator(), tmp.dir, clean_allowlist));
}

test "a stale row is refused once its script is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, &clean_tree);
    try expectClean(try checkDir(arena.allocator(), tmp.dir, clean_allowlist));
    try tmp.dir.deleteFile("tools/a.sh");
    const r = try checkDir(arena.allocator(), tmp.dir, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, al ++ ":4: tools/a.sh: no shell script at this path: remove the row");
}

test "a row naming a file that is not shell is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // tools/gen.py exists, with a python shebang.
    const r = try run(arena.allocator(), &clean_tree, clean_allowlist ++ "tools/gen.py\tnot shell\n");
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, al ++ ":5: tools/gen.py: no shell script at this path: remove the row");
}

test "a file without .sh whose first line is #!/bin/sh is caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{
        .{ "tools/build/run_it.txt", "#!/bin/sh\necho hi\n" },
        .{ "tools/run", "#!/usr/bin/env bash\nset -e\n" },
        .{ "tools/bb", "#!/bin/busybox sh\ntrue\n" },
        .{ "tools/envs", "#!/usr/bin/env -S bash -eu\ntrue" },
    };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 4), r.result.findings);
    try expectFinding(r, "tools/build/run_it.txt: a shell script with no row");
    try expectFinding(r, "tools/run: a shell script with no row");
    try expectFinding(r, "tools/bb: a shell script with no row");
    try expectFinding(r, "tools/envs: a shell script with no row");
}

test "malformed and repeated rows are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allowlist = clean_allowlist ++
        "tools/one_field.sh\n" ++
        "tools/x.sh\t3\twhy\n" ++
        "tools/z.sh\t \n" ++
        "/abs.sh\twhy\n" ++
        "tools/a.sh\tagain\n";
    const r = try run(arena.allocator(), &clean_tree, allowlist);
    try std.testing.expectEqual(@as(usize, 5), r.result.findings);
    try expectFinding(r, al ++ ":5: 1 field(s), not 2");
    try expectFinding(r, al ++ ":6: 3 field(s), not 2");
    try expectFinding(r, al ++ ":7: tools/z.sh: no reason");
    try expectFinding(r, al ++ ":8: the path `/abs.sh` is not a path in the repository");
    try expectFinding(r, al ++ ":9: tools/a.sh: a second row (the first is line 4)");
}

test "shebangs: shells through a path, env and busybox; nothing else" {
    const yes = [_][]const u8{
        "#!/bin/sh\n",            "#!/bin/bash -e\n",            "#! /bin/sh\n",
        "#!/usr/bin/env bash\n",  "#!/usr/bin/env -S bash -e\n", "#!/usr/bin/env FOO=1 sh\n",
        "#!/bin/busybox sh\n",    "#!/bin/dash",                 "#!/bin/zsh\r\n",
        "#!/usr/bin/ash\necho\n",
    };
    for (yes) |h| {
        if (!budget.shebangShell(h)) {
            std.debug.print("not caught: {s}\n", .{h});
            return error.TestExpectedShell;
        }
    }
    const no = [_][]const u8{
        "#!/usr/bin/env python3\n", "#!/usr/bin/env\n", "#!\n",          "# sh\n",
        "echo hi\n#!/bin/sh\n",     "",                  "#!/bin/shell\n", "#!/usr/bin/env -S\n",
        "#!/bin/busybox\n",
    };
    for (no) |h| {
        if (budget.shebangShell(h)) {
            std.debug.print("caught: {s}\n", .{h});
            return error.TestUnexpectedShell;
        }
    }
    try std.testing.expect(budget.isShell("a/b.sh", ""));
    try std.testing.expect(budget.isShell("a/b.bash", ""));
    try std.testing.expect(!budget.isShell("a/b.shx", ""));
    try std.testing.expect(!budget.isShell("a/sh", "x"));
}
