//! Unit tests of the no-shell list: each finding the check reports, what the
//! walk of a tree collects, and the verdict of a planted defect.

const std = @import("std");
const scan = @import("scan.zig");
const rules = @import("rules.zig");
const t = std.testing;

const al = "tools/build/lint/no_shell_list.tsv";

const Run = struct {
    result: rules.Result,
    report: []const u8,
};

fn counts(sh_argv: usize, busybox_sh: usize) scan.Counts {
    var c = [_]usize{0} ** scan.category_count;
    c[@intFromEnum(scan.Category.sh_argv)] = sh_argv;
    c[@intFromEnum(scan.Category.busybox_sh)] = busybox_sh;
    return c;
}

fn runWith(arena: std.mem.Allocator, builds: []const rules.BuildFile, scripts: []const rules.Script, list: []const u8) !Run {
    var out = std.ArrayList(u8).empty;
    const r = try rules.check(arena, al, list, .{ .build_files = builds, .scripts = scripts }, &out);
    return .{ .result = r, .report = out.items };
}

fn expectFinding(r: Run, needle: []const u8) !void {
    if (std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("no finding holding `{s}` in:\n{s}\n", .{ needle, r.report });
        return error.TestExpectedFinding;
    }
}

fn expectClean(r: Run) !void {
    try t.expectEqualStrings("", r.report);
    try t.expectEqual(@as(usize, 0), r.result.findings);
}

const row_argv = "use\ta/defs.bzl\tsh_argv\t2\tport to Zig\n";
const row_bb = "use\ta/defs.bzl\tbusybox_sh\t1\tport to Zig\n";
const row_script = "script\ta/run.sh\t-\t-\tport to Zig\n";
const row_human = "human\tci/\t-\t-\tCI runners\n";

const build_a = [_]rules.BuildFile{.{ .path = "a/defs.bzl", .counts = counts(2, 1) }};
const script_a = [_]rules.Script{.{ .path = "a/run.sh", .why = "a `.sh` file" }};
const scripts_ab = [_]rules.Script{ .{ .path = "a/run.sh", .why = "a `.sh` file" }, .{ .path = "ci/go.sh", .why = "a `.sh` file" } };

test "a tree whose every site and script is listed is clean" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const list = "# a comment\n\n" ++ row_argv ++ row_bb ++ row_script ++ row_human;
    const r = try runWith(arena.allocator(), &build_a, &scripts_ab, list);
    try expectClean(r);
    try t.expectEqual(@as(usize, 1), r.result.build_files);
    try t.expectEqual(@as(usize, 2), r.result.scripts);
}

test "a shell site with no row is named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try runWith(arena.allocator(), &build_a, &.{}, row_argv);
    try expectFinding(r, "a/defs.bzl: 1 `busybox_sh` site(s) with no row in " ++ al);
    try t.expectEqual(@as(usize, 1), r.result.findings);
}

test "more sites than the row says is a new use of a shell" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const grown = [_]rules.BuildFile{.{ .path = "a/defs.bzl", .counts = counts(3, 1) }};
    const r = try runWith(arena.allocator(), &grown, &.{}, row_argv ++ row_bb);
    try expectFinding(r, al ++ ":1: a/defs.bzl: 3 `sh_argv` site(s), the row says 2: a new use of a shell");
    try t.expectEqual(@as(usize, 1), r.result.findings);
}

test "fewer sites than the row says: the row is lowered" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const shrunk = [_]rules.BuildFile{.{ .path = "a/defs.bzl", .counts = counts(1, 1) }};
    const r = try runWith(arena.allocator(), &shrunk, &.{}, row_argv ++ row_bb);
    try expectFinding(r, al ++ ":1: a/defs.bzl: 1 `sh_argv` site(s) remain, the row says 2: lower the row");
}

test "a row whose sites are gone is removed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const only_bb = [_]rules.BuildFile{.{ .path = "a/defs.bzl", .counts = counts(0, 1) }};
    const r = try runWith(arena.allocator(), &only_bb, &.{}, row_argv ++ row_bb);
    try expectFinding(r, al ++ ":1: a/defs.bzl: no `sh_argv` site in this file: remove the row");
    const r2 = try runWith(arena.allocator(), &.{}, &.{}, row_bb);
    try expectFinding(r2, al ++ ":1: a/defs.bzl: no `busybox_sh` site in this file: remove the row");
}

test "a shell script with no row, and none of a human place, is named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try runWith(arena.allocator(), &.{}, &script_a, row_human);
    try expectFinding(r, "a/run.sh: a shell script (a `.sh` file) outside the places " ++ al ++ " names");
    // ... the human prefix is a directory, not a name prefix: ci/ does not cover cix/.
    const other = [_]rules.Script{.{ .path = "cix/run.sh", .why = "a `.sh` file" }};
    const r2 = try runWith(arena.allocator(), &.{}, &other, row_human);
    try expectFinding(r2, "cix/run.sh: a shell script");
}

test "a script under a human directory, or listed by a human path, is allowed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const in_ci = [_]rules.Script{ .{ .path = "ci/run.sh", .why = "x" }, .{ .path = "ci/deep/er.sh", .why = "x" } };
    try expectClean(try runWith(arena.allocator(), &.{}, &in_ci, row_human));
    const one = [_]rules.Script{.{ .path = "buck2", .why = "its `#!` line runs `sh`" }};
    try expectClean(try runWith(arena.allocator(), &.{}, &one, "human\tbuck2\t-\t-\tthe wrapper people run\n"));
}

test "a script row or human row that names nothing is removed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try runWith(arena.allocator(), &.{}, &.{}, row_script ++ row_human);
    try expectFinding(r, al ++ ":1: a/run.sh: no shell script at this path: remove the row");
    try expectFinding(r, al ++ ":2: ci/: no shell script here: remove the row");
}

test "malformed rows" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFinding(try runWith(a, &.{}, &.{}, "use\ta\tsh_argv\t2\n"), "4 field(s), not 5");
    try expectFinding(try runWith(a, &.{}, &.{}, "later\ta\t-\t-\tr\n"), "the kind `later` is not use, script or human");
    try expectFinding(try runWith(a, &.{}, &.{}, "use\t/a\tsh_argv\t2\tr\n"), "the path `/a` is not a path in the repository");
    try expectFinding(try runWith(a, &.{}, &.{}, "use\ta\tsh_argv\t2\t \n"), "a: no reason");
    try expectFinding(try runWith(a, &.{}, &.{}, "use\ta\tbash\t2\tr\n"), "`bash` is not a category of shell use");
    try expectFinding(try runWith(a, &.{}, &.{}, "use\ta\tsh_argv\t0\tr\n"), "the count `0` is not a positive integer");
    try expectFinding(try runWith(a, &.{}, &.{}, "use\ta\tsh_argv\tmany\tr\n"), "the count `many` is not a positive integer");
    try expectFinding(try runWith(a, &.{}, &.{}, "script\ta.sh\tsh_argv\t-\tr\n"), "a script row has `-` for category and count");
    try expectFinding(try runWith(a, &.{}, &.{}, "script\tdir/\t-\t-\tr\n"), "a script row names one file");
    try expectFinding(try runWith(a, &.{}, &.{}, row_argv ++ row_argv), "a second row (the first is line 1)");
}

test "one file may have a use row for each category" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectClean(try runWith(arena.allocator(), &build_a, &.{}, row_argv ++ row_bb));
}

test "shebangProgram and classify: the shells, through env and busybox" {
    try t.expectEqualStrings("sh", rules.shebangProgram("#!/bin/sh\n").?);
    try t.expectEqualStrings("bash", rules.shebangProgram("#!/usr/bin/env -S bash -e\n").?);
    try t.expectEqualStrings("sh", rules.shebangProgram("#!/bin/busybox sh\n").?);
    try t.expectEqualStrings("python3", rules.shebangProgram("#!/usr/bin/env FOO=1 python3\n").?);
    try t.expect(rules.shebangProgram("echo\n#!/bin/sh\n") == null);
    try t.expect(rules.shebangProgram("#!\n") == null);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try rules.classify(a, "x/y.sh", "")) != null);
    try t.expect((try rules.classify(a, "x/y.ZSH", "")) != null);
    try t.expect((try rules.classify(a, "x/buck2", "#!/bin/sh\n")) != null);
    try t.expect((try rules.classify(a, "x/y", "#!/usr/bin/env dash\n")) != null);
    try t.expect((try rules.classify(a, "x/y.py", "#!/usr/bin/env python3\n")) == null);
    try t.expect((try rules.classify(a, "x/y", "#!/usr/bin/env node\n")) == null);
    try t.expect((try rules.classify(a, "x/y.txt", "plain\n")) == null);
}

test "covers: a path, or a directory prefix" {
    try t.expect(rules.covers("a/b.sh", "a/b.sh"));
    try t.expect(rules.covers("a/", "a/b/c.sh"));
    try t.expect(!rules.covers("a", "a/b.sh"));
    try t.expect(!rules.covers("a/", "ab/c.sh"));
}

fn put(dir: std.fs.Dir, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    const f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(text);
}

test "collect: build files with sites, shell scripts by extension or #!, nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "p/BUCK", "x = busybox_sh(1)\ny = \"sh\"\n");
    try put(tmp.dir, "p/defs.bzl", "def f(): pass\n");
    try put(tmp.dir, "p/notes.txt", "busybox_sh \"sh\"\n");
    try put(tmp.dir, "p/run.sh", "echo hi\n");
    try put(tmp.dir, "p/tool", "#!/usr/bin/env bash\necho hi\n");
    try put(tmp.dir, "p/gen", "#!/usr/bin/env python3\nprint(1)\n");
    try put(tmp.dir, "q/checks.bxl", "x = [\"-euc\"]\n");
    const found = try rules.collect(a, tmp.dir);
    try t.expectEqual(@as(usize, 2), found.build_files.len);
    try t.expectEqualStrings("p/BUCK", found.build_files[0].path);
    try t.expectEqual(@as(usize, 1), found.build_files[0].counts[@intFromEnum(scan.Category.busybox_sh)]);
    try t.expectEqual(@as(usize, 1), found.build_files[0].counts[@intFromEnum(scan.Category.sh_argv)]);
    try t.expectEqualStrings("q/checks.bxl", found.build_files[1].path);
    try t.expectEqual(@as(usize, 2), found.scripts.len);
    try t.expectEqualStrings("p/run.sh", found.scripts[0].path);
    try t.expectEqualStrings("p/tool", found.scripts[1].path);
}

test "verdict: green with no finding; a planted defect only when refused with every expected text" {
    const clean = rules.Result{ .build_files = 1, .scripts = 0, .findings = 0 };
    const dirty = rules.Result{ .build_files = 1, .scripts = 0, .findings = 2 };
    try t.expect(rules.verdict(clean, "", &.{}).ok);
    try t.expect(!rules.verdict(dirty, "x", &.{}).ok);
    try t.expect(rules.verdict(dirty, "a: busybox_sh b: sh", &.{ "busybox_sh", "sh" }).ok);
    const miss = rules.verdict(dirty, "a: busybox_sh", &.{ "busybox_sh", "bash" });
    try t.expect(!miss.ok);
    try t.expectEqualStrings("bash", miss.missing.?);
    // Expected text and no finding: the planted defect was not refused.
    try t.expect(!rules.verdict(clean, "busybox_sh", &.{"busybox_sh"}).ok);
}

fn rendered(r: rules.Result, report: []const u8, expect: []const []const u8) !rules.Rendered {
    return rules.render(t.allocator, al, r, rules.verdict(r, report, expect), report, expect);
}

fn expectStatus(json: []const u8, status: []const u8) !void {
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "\"status\": \"{s}\"", .{status});
    if (std.mem.indexOf(u8, json, want) == null) {
        std.debug.print("no `{s}` in:\n{s}\n", .{ want, json });
        return error.TestExpectedStatus;
    }
}

test "render: a finding is a failure, none a success, and a planted case inverts" {
    const clean = rules.Result{ .build_files = 3, .scripts = 4, .findings = 0 };
    const dirty = rules.Result{ .build_files = 3, .scripts = 4, .findings = 2 };

    const ok = try rendered(clean, "", &.{});
    defer t.allocator.free(ok.json);
    defer t.allocator.free(ok.message);
    try expectStatus(ok.json, "success");
    try t.expectEqualStrings("no_shell: 3 build file(s) with shell sites and 4 shell script(s) checked against " ++ al, ok.message);

    const bad = try rendered(dirty, "x: finding\n", &.{});
    defer t.allocator.free(bad.json);
    defer t.allocator.free(bad.message);
    try expectStatus(bad.json, "failure");
    try t.expect(std.mem.indexOf(u8, bad.message, "2 finding(s) over 3 build file(s) with shell sites and 4 shell script(s)\nx: finding\n") != null);

    const refused = try rendered(dirty, "x: busybox_sh\n", &.{"busybox_sh"});
    defer t.allocator.free(refused.json);
    defer t.allocator.free(refused.message);
    try expectStatus(refused.json, "success");
    try t.expect(std.mem.indexOf(u8, refused.message, "refused as expected (2 finding(s))") != null);

    const wrong = try rendered(dirty, "x: other\n", &.{"busybox_sh"});
    defer t.allocator.free(wrong.json);
    defer t.allocator.free(wrong.message);
    try expectStatus(wrong.json, "failure");
    try t.expect(std.mem.indexOf(u8, wrong.message, "no finding holds `busybox_sh`") != null);

    // (Only reachable when the report holds the text and counts no finding.)
    const none = try rendered(clean, "busybox_sh", &.{"busybox_sh"});
    defer t.allocator.free(none.json);
    defer t.allocator.free(none.message);
    try expectStatus(none.json, "failure");
    try t.expect(std.mem.indexOf(u8, none.message, "was not refused: no finding over 3 build file(s) and 4 script(s)") != null);
}

test "render: the message is one JSON string, escaped" {
    const dirty = rules.Result{ .build_files = 1, .scripts = 0, .findings = 1 };
    const r = try rendered(dirty, "a \"quoted\" path\n", &.{});
    defer t.allocator.free(r.json);
    defer t.allocator.free(r.message);
    try t.expect(std.mem.indexOf(u8, r.json, "a \\\"quoted\\\" path\\n") != null);
    try t.expect(std.mem.endsWith(u8, r.json, "}}\n"));
}
