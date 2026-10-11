//! Unit tests of the shell budget, over trees written to a temporary
//! directory: what is a shell script, and each finding the check reports.

const std = @import("std");
const budget = @import("budget.zig");

const al = "tools/build/lint/shell_allowlist.tsv";

const Run = struct {
    result: budget.Result,
    report: []const u8,
};

/// Writes `files` (path, contents) under a fresh temporary directory, then
/// collects its shell scripts and checks them against `allowlist`.
fn run(arena: std.mem.Allocator, files: []const [2][]const u8, allowlist: []const u8) !Run {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.makePath(d);
        try tmp.dir.writeFile(f[0], f[1]);
    }
    const scripts = try budget.collect(arena, tmp.dir);
    var out = std.ArrayList(u8).init(arena);
    const r = try budget.check(arena, al, allowlist, scripts, &out);
    return .{ .result = r, .report = out.items };
}

fn expectFinding(r: Run, needle: []const u8) !void {
    if (std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("no finding holding `{s}` in:\n{s}\n", .{ needle, r.report });
        return error.TestExpectedFinding;
    }
}

// A tree of every kind of file: two scripts, each with a row at its exact
// size (one extensionless, found by its shebang), and files that are not shell.
const clean_tree = [_][2][]const u8{
    .{ "tools/a.sh", "#!/bin/sh\necho a\necho b\n" },
    .{ "buck2", "#!/bin/sh\nexec x \"$@\"\n" },
    .{ "src/lib.mojo", "fn main():\n    pass\n" },
    .{ "tools/gen.py", "#!/usr/bin/env python3\nprint(1)\n" },
    .{ "docs/shell.md", "# about sh\n" },
};
const clean_allowlist =
    "# path\tmax_lines\treason\n" ++
    "\n" ++
    "buck2\t2\tthe pinned buck2 launcher\n" ++
    "tools/a.sh\t3\ta thin wrapper\n";

test "a clean tree passes: every script has a row at its size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), &clean_tree, clean_allowlist);
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(@as(usize, 0), r.result.findings);
    try std.testing.expectEqual(@as(usize, 2), r.result.scripts);
}

test "an unlisted script is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{.{ "tools/ci/new.sh", "echo 1\necho 2\necho 3\n" }};
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, "tools/ci/new.sh: a shell script (3 lines) with no row in " ++ al);
}

test "a script over its cap is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // tools/a.sh grew one line past its row's 3.
    const tree = [_][2][]const u8{ clean_tree[1], .{ "tools/a.sh", "#!/bin/sh\necho a\necho b\necho c\n" } };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, "tools/a.sh: 4 lines, over its cap of 3 (" ++ al ++ ":4)");
}

test "an extensionless file with a sh or bash shebang is caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{
        .{ "tools/run", "#!/usr/bin/env bash\nset -e\n" },
        .{ "tools/bb", "#!/bin/busybox sh\ntrue\n" },
        .{ "tools/envs", "#!/usr/bin/env -S bash -eu\ntrue" },
    };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 3), r.result.findings);
    try expectFinding(r, "tools/run: a shell script (2 lines) with no row");
    try expectFinding(r, "tools/bb: a shell script (2 lines) with no row");
    // The last line has no newline and still counts.
    try expectFinding(r, "tools/envs: a shell script (2 lines) with no row");
}

test "a cap above the script's size is refused: caps only go down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allowlist = "buck2\t2\tlauncher\ntools/a.sh\t40\ta wrapper\n";
    const r = try run(arena.allocator(), &clean_tree, allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, "tools/a.sh: 3 lines, under its cap of 40: lower the cap to 3");
}

test "a row naming no shell script is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // tools/gen.py exists but is not shell; tools/gone.sh does not exist.
    const allowlist = clean_allowlist ++ "tools/gone.sh\t9\tdeleted\ntools/gen.py\t2\tnot shell\n";
    const r = try run(arena.allocator(), &clean_tree, allowlist);
    try std.testing.expectEqual(@as(usize, 2), r.result.findings);
    try expectFinding(r, al ++ ":5: tools/gone.sh: no shell script at this path: remove the row");
    try expectFinding(r, al ++ ":6: tools/gen.py: no shell script at this path");
}

test "malformed and repeated rows are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allowlist = clean_allowlist ++
        "tools/two_fields.sh\t3\n" ++
        "tools/x.sh\tmany\twhy\n" ++
        "tools/y.sh\t0\twhy\n" ++
        "tools/z.sh\t3\t \n" ++
        "/abs.sh\t3\twhy\n" ++
        "tools/a.sh\t3\tagain\n";
    const r = try run(arena.allocator(), &clean_tree, allowlist);
    try std.testing.expectEqual(@as(usize, 6), r.result.findings);
    try expectFinding(r, al ++ ":5: 2 field(s), not 3");
    try expectFinding(r, al ++ ":6: tools/x.sh: max_lines `many` is not a number above 0");
    try expectFinding(r, al ++ ":7: tools/y.sh: max_lines `0` is not a number above 0");
    try expectFinding(r, al ++ ":8: tools/z.sh: no reason");
    try expectFinding(r, al ++ ":9: the path `/abs.sh` is not a path in the repository");
    try expectFinding(r, al ++ ":10: tools/a.sh: a second row (the first is line 4)");
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

test "line counts" {
    try std.testing.expectEqual(@as(u64, 0), budget.countLines(""));
    try std.testing.expectEqual(@as(u64, 1), budget.countLines("a"));
    try std.testing.expectEqual(@as(u64, 1), budget.countLines("a\n"));
    try std.testing.expectEqual(@as(u64, 2), budget.countLines("a\nb"));
    try std.testing.expectEqual(@as(u64, 2), budget.countLines("\n\n"));
}
