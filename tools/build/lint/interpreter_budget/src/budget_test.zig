//! Unit tests of the interpreter list, over trees written to a temporary
//! directory: what is an interpreter file, and each finding the check reports.

const std = @import("std");
const budget = @import("budget.zig");

const al = "tools/build/lint/interpreter_allowlist.tsv";

const Run = struct {
    result: budget.Result,
    report: []const u8,
};

fn write(dir: std.fs.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try dir.makePath(d);
        try dir.writeFile(.{ .sub_path = f[0], .data = f[1] });
    }
}

/// Collects the interpreter files of `dir` in `scope` and checks them against `allowlist`.
fn checkScoped(arena: std.mem.Allocator, dir: std.fs.Dir, allowlist: []const u8, scope: []const []const u8) !Run {
    const found = try budget.collect(arena, dir, scope);
    var out = std.ArrayList(u8).empty;
    const r = try budget.check(arena, al, allowlist, scope, found, &out);
    return .{ .result = r, .report = out.items };
}

fn checkDir(arena: std.mem.Allocator, dir: std.fs.Dir, allowlist: []const u8) !Run {
    return checkScoped(arena, dir, allowlist, &.{});
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

// A tree of every kind of file: four listed interpreter files (one shell
// script without an extension, found by its `#!` line; one Python file with
// both), and files that are not interpreter files (a node script among them).
const clean_tree = [_][2][]const u8{
    .{ "tools/a.sh", "#!/bin/sh\necho a\necho b\n" },
    .{ "buck2", "#!/bin/sh\nexec x \"$@\"\n" },
    .{ "tools/gen.py", "#!/usr/bin/env python3\nprint(1)\n" },
    .{ "tools/sum.awk", "{ s += $1 } END { print s }\n" },
    .{ "src/lib.mojo", "fn main():\n    pass\n" },
    .{ "docs/shell.md", "# about sh and python\n" },
    .{ "tools/web/main.mjs", "#!/usr/bin/env node\nconsole.log(1)\n" },
    .{ "tools/web/run", "#!/usr/bin/env node\nconsole.log(1)\n" },
    .{ "tools/buck2", "#!/usr/bin/env dotslash\n{}\n" },
    .{ "expect/case.tsv", "#! komira-plan-conformance v1\na\tb\n" },
};
const clean_allowlist =
    "# path\treason\n" ++
    "\n" ++
    "buck2\tthe pinned buck2 launcher\n" ++
    "tools/a.sh\ta thin wrapper\n" ++
    "tools/gen.py\ta fixture generator\n" ++
    "tools/sum.awk\ta report filter\n";

test "a clean tree passes: every interpreter file has a row, every row a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), &clean_tree, clean_allowlist);
    try expectClean(r);
    try std.testing.expectEqual(@as(usize, 4), r.result.files);
}

test "an unlisted 3-line shell script is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{.{ "tools/ci/new.sh", "echo 1\necho 2\necho 3\n" }};
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, "tools/ci/new.sh: an interpreter file (a `.sh` file) with no row in " ++ al);
}

test "an unlisted .py file is refused, with or without a #! line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{
        .{ "src/x/tests/fixtures/gen.py", "import sys\nprint(sys.argv)\n" },
        .{ "tools/old.PY", "print(1)\n" },
        .{ "tools/win.pyw", "print(1)\n" },
    };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 3), r.result.findings);
    try expectFinding(r, "src/x/tests/fixtures/gen.py: an interpreter file (a `.py` file) with no row");
    try expectFinding(r, "tools/old.PY: an interpreter file (a `.PY` file) with no row");
    try expectFinding(r, "tools/win.pyw: an interpreter file (a `.pyw` file) with no row");
}

test "an extensionless file whose #! line is env python3 is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{
        .{ "tools/release_check", "#!/usr/bin/env python3\nimport sys\n" },
        .{ "tools/direct", "#!/usr/bin/python3.13 -I\npass\n" },
    };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 2), r.result.findings);
    try expectFinding(r, "tools/release_check: an interpreter file (its `#!` line runs `python3`) with no row");
    try expectFinding(r, "tools/direct: an interpreter file (its `#!` line runs `python3.13`) with no row");
}

test "unlisted awk, Perl, Ruby and sed files are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = clean_tree ++ [_][2][]const u8{
        .{ "tools/cols.awk", "{ print $2 }\n" },
        .{ "tools/filter", "#!/usr/bin/gawk -f\n{ print }\n" },
        .{ "tools/x.pl", "print 1;\n" },
        .{ "tools/Lib.pm", "package Lib;\n1;\n" },
        .{ "tools/perl_tool", "#!/usr/bin/env perl\nprint 1;\n" },
        .{ "tools/x.rb", "puts 1\n" },
        .{ "tools/ruby_tool", "#!/usr/bin/env ruby\nputs 1\n" },
        .{ "tools/edit.sed", "s/a/b/\n" },
    };
    const r = try run(arena.allocator(), &tree, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 8), r.result.findings);
    try expectFinding(r, "tools/cols.awk: an interpreter file (a `.awk` file) with no row");
    try expectFinding(r, "tools/filter: an interpreter file (its `#!` line runs `gawk`) with no row");
    try expectFinding(r, "tools/x.pl: an interpreter file (a `.pl` file) with no row");
    try expectFinding(r, "tools/Lib.pm: an interpreter file (a `.pm` file) with no row");
    try expectFinding(r, "tools/perl_tool: an interpreter file (its `#!` line runs `perl`) with no row");
    try expectFinding(r, "tools/x.rb: an interpreter file (a `.rb` file) with no row");
    try expectFinding(r, "tools/ruby_tool: an interpreter file (its `#!` line runs `ruby`) with no row");
    try expectFinding(r, "tools/edit.sed: an interpreter file (a `.sed` file) with no row");
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

test "a stale row is refused once its file is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, &clean_tree);
    try expectClean(try checkDir(arena.allocator(), tmp.dir, clean_allowlist));
    try tmp.dir.deleteFile("tools/gen.py");
    const r = try checkDir(arena.allocator(), tmp.dir, clean_allowlist);
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, al ++ ":5: tools/gen.py: no interpreter file at this path: remove the row");
}

test "a row naming a file that is not an interpreter file is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // tools/web/run exists, with a node `#!` line: node is not counted.
    const r = try run(arena.allocator(), &clean_tree, clean_allowlist ++ "tools/web/run\tnot counted\n");
    try std.testing.expectEqual(@as(usize, 1), r.result.findings);
    try expectFinding(r, al ++ ":7: tools/web/run: no interpreter file at this path: remove the row");
}

test "a file without .sh whose first line names a shell is caught" {
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
    try expectFinding(r, "tools/build/run_it.txt: an interpreter file (its `#!` line runs `sh`) with no row");
    try expectFinding(r, "tools/run: an interpreter file (its `#!` line runs `bash`) with no row");
    try expectFinding(r, "tools/bb: an interpreter file (its `#!` line runs `sh`) with no row");
    try expectFinding(r, "tools/envs: an interpreter file (its `#!` line runs `bash`) with no row");
}

test "a scope counts only files under its prefixes, and refuses a row outside them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(tmp.dir, &clean_tree);
    try write(tmp.dir, &.{ .{ "deploy/app-x/apply.sh", "true\n" }, .{ "deploy/other/run.py", "pass\n" } });
    const scope = [_][]const u8{ "deploy/app-", "tools/gen" };
    // Only deploy/app-x/apply.sh and tools/gen.py are in the scope.
    const r = try checkScoped(arena.allocator(), tmp.dir, "deploy/app-x/apply.sh\twhy\ntools/gen.py\twhy\n", &scope);
    try expectClean(r);
    try std.testing.expectEqual(@as(usize, 2), r.result.files);
    // A row outside the scope is refused even though its file exists.
    const out = try checkScoped(arena.allocator(), tmp.dir, "deploy/app-x/apply.sh\twhy\ntools/gen.py\twhy\ntools/a.sh\twhy\n", &scope);
    try std.testing.expectEqual(@as(usize, 1), out.result.findings);
    try expectFinding(out, al ++ ":3: tools/a.sh: outside the scope of the check: remove the row");
    // An unlisted file in the scope is still refused.
    const un = try checkScoped(arena.allocator(), tmp.dir, "tools/gen.py\twhy\n", &scope);
    try std.testing.expectEqual(@as(usize, 1), un.result.findings);
    try expectFinding(un, "deploy/app-x/apply.sh: an interpreter file (a `.sh` file) with no row");
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
    try expectFinding(r, al ++ ":7: 1 field(s), not 2");
    try expectFinding(r, al ++ ":8: 3 field(s), not 2");
    try expectFinding(r, al ++ ":9: tools/z.sh: no reason");
    try expectFinding(r, al ++ ":10: the path `/abs.sh` is not a path in the repository");
    try expectFinding(r, al ++ ":11: tools/a.sh: a second row (the first is line 4)");
}

test "#! lines: interpreters through a path, env and busybox; nothing else" {
    const yes = [_][2][]const u8{
        .{ "#!/bin/sh\n", "sh" },                         .{ "#!/bin/bash -e\n", "bash" },
        .{ "#! /bin/sh\n", "sh" },                        .{ "#!/usr/bin/env bash\n", "bash" },
        .{ "#!/usr/bin/env -S bash -e\n", "bash" },       .{ "#!/usr/bin/env FOO=1 sh\n", "sh" },
        .{ "#!/bin/busybox sh\n", "sh" },                 .{ "#!/bin/dash", "dash" },
        .{ "#!/bin/zsh\r\n", "zsh" },                     .{ "#!/usr/bin/ash\necho\n", "ash" },
        .{ "#!/usr/bin/env python3\n", "python3" },       .{ "#!/usr/bin/python\n", "python" },
        .{ "#!/usr/bin/env -S python3 -u\n", "python3" }, .{ "#!/usr/bin/env -u HOME python3\n", "python3" },
        .{ "#!/usr/bin/env -C /x perl\n", "perl" },       .{ "#!/usr/bin/perl -w\n", "perl" },
        .{ "#!/usr/bin/awk -f\n", "awk" },                .{ "#!/usr/bin/env mawk -f\n", "mawk" },
        .{ "#!/usr/bin/env ruby\n", "ruby" },             .{ "#!/bin/sed -f\n", "sed" },
        .{ "#!/bin/busybox awk -f\n", "awk" },            .{ "#!/usr/bin/env busybox sh\n", "sh" },
    };
    for (yes) |c| {
        const prog = budget.shebangProgram(c[0]) orelse {
            std.debug.print("no program: {s}\n", .{c[0]});
            return error.TestExpectedInterpreter;
        };
        if (!std.mem.eql(u8, prog, c[1]) or !budget.isInterpreter(prog)) {
            std.debug.print("{s}: read `{s}`, want the interpreter `{s}`\n", .{ c[0], prog, c[1] });
            return error.TestExpectedInterpreter;
        }
    }
    const no = [_][]const u8{
        "#!/usr/bin/env node\n",     "#!/usr/bin/env\n",                "#!\n",                        "# sh\n",
        "echo hi\n#!/bin/sh\n",      "",                                "#!/bin/shell\n",              "#!/usr/bin/env -S\n",
        "#!/bin/busybox\n",          "#!/usr/bin/env dotslash\n",       "#! komira-plan-conformance v1\n", "#![allow(unused)]\n",
        "#!/usr/bin/env -u python3\n", "#!/usr/bin/env deno run\n",
    };
    for (no) |h| {
        if (budget.shebangProgram(h)) |prog| {
            if (budget.isInterpreter(prog)) {
                std.debug.print("counted: {s} (as `{s}`)\n", .{ h, prog });
                return error.TestUnexpectedInterpreter;
            }
        }
    }
    try std.testing.expect(budget.interpreterExtension("a/b.sh") != null);
    try std.testing.expect(budget.interpreterExtension("a/b.bash") != null);
    try std.testing.expect(budget.interpreterExtension("a/b.Rb") != null);
    try std.testing.expect(budget.interpreterExtension("a/b.shx") == null);
    try std.testing.expect(budget.interpreterExtension("a/py") == null);
    try std.testing.expect(budget.interpreterExtension("a.py/b") == null);
    try std.testing.expect(budget.interpreterExtension("a/b.mjs") == null);
    try std.testing.expect(budget.interpreterExtension("a/b.mojo") == null);
}

test "the verdict: no finding passes; with expected texts, only their findings pass" {
    const clean: budget.Result = .{ .files = 3, .findings = 0 };
    const red: budget.Result = .{ .files = 3, .findings = 1 };
    const report = "x.py: an interpreter file (a `.py` file) with no row in al\n";
    try std.testing.expect(budget.verdict(clean, "", &.{}).ok);
    try std.testing.expect(!budget.verdict(red, report, &.{}).ok);
    try std.testing.expect(budget.verdict(red, report, &.{"x.py: an interpreter file"}).ok);
    const missing = budget.verdict(red, report, &.{ "x.py", "y.awk" });
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("y.awk", missing.missing.?);
    // An expected defect that the check did not refuse fails.
    try std.testing.expect(!budget.verdict(clean, "", &.{"x.py"}).ok);
}
