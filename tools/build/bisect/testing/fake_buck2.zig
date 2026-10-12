//! A stand-in for buck2 in the scenarios (scenario.zig): it answers from the
//! file `bisect_fixture.txt` of the checkout it runs in.
//!
//! - `root --kind project` prints the working directory.
//! - `kill` exits 0.
//! - `build|test --build-report <file> [-c komira.rerun=<label>#<n>] <targets>...`
//!   reads the fixture: optional infra lines first, each of which can make
//!   the build exit 2 with no report:
//!   - `infra-once`: the first build of this commit (with this rerun value);
//!   - `infra-always`: every build;
//!   - `infra-run <n>`: the first build whose rerun n is <n>;
//!   - `infra-run-always <n>`: every build whose rerun n is <n>;
//!
//!   then one of
//!   - `pass` (exit 0);
//!   - `fail <target>...`: those of the given targets fail, a report in
//!     buck2's shape naming them, exit 3;
//!   - `flaky <period> <phase> <target>...`: a listed target fails when the
//!     rerun flag names it with an n where n % period == phase (so without
//!     the flag, n is 0 and it passes), its stderr a first line naming the
//!     run, a passing test's line ending `OK` that says `error:`, and then
//!     the same `FAIL` line every run.
//!
//!   A `no-rerun <target>...` line, before or among the infra lines, is
//!   skipped by a build.
//! - `bxl <script> -c komira.rerun=<label>#<n>` stands in for
//!   tools/build/rerun/check.bxl: exit 3 when the label has no cell (the
//!   rules' refusal) or a `no-rerun` line lists it; exit 2 when a
//!   `check-infra` line is present; else exit 0.
//!
//! Targets compare without their cells; a target given without one is
//! written to the report under the cell `root`.
//!
//! Every call appends `<command> <commit> <cwd> <rerun value or -> <targets
//! joined by , or ->` to `fake_buck2.log` in the repository's git directory
//! (read from the worktree's `.git` file, so no git runs), where the
//! scenario counts builds, retries, kills and the rerun values it saw.
const std = @import("std");

const Paths = struct { commit: []const u8, log: []const u8 };

/// The commit checked out in `cwd` (a detached worktree) and the log path.
fn paths(a: std.mem.Allocator, cwd: []const u8) !Paths {
    var d = try std.fs.openDirAbsolute(cwd, .{});
    defer d.close();
    const dotgit = try d.readFileAlloc(a, ".git", 1 << 16);
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, dotgit, prefix)) return error.NotAWorktree;
    const gitdir = std.mem.trim(u8, dotgit[prefix.len..], " \r\n");
    var g = try std.fs.openDirAbsolute(gitdir, .{});
    defer g.close();
    const head = std.mem.trim(u8, try g.readFileAlloc(a, "HEAD", 1 << 16), " \r\n");
    const common_rel = std.mem.trim(u8, try g.readFileAlloc(a, "commondir", 1 << 16), " \r\n");
    const common = try std.fs.path.resolve(a, &.{ gitdir, common_rel });
    return .{ .commit = head, .log = try std.fs.path.join(a, &.{ common, "fake_buck2.log" }) };
}

fn appendLog(path: []const u8, line: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
}

/// How many builds of `commit` with the rerun value `rerun` the log holds
/// already.
fn priorBuilds(a: std.mem.Allocator, log: []const u8, commit: []const u8, rerun: []const u8) !usize {
    const bytes = std.fs.cwd().readFileAlloc(a, log, 1 << 24) catch return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = w.next() orelse continue;
        const c = w.next() orelse continue;
        _ = w.next() orelse continue;
        const r = w.next() orelse continue;
        if ((std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "test")) and std.mem.eql(u8, c, commit) and std.mem.eql(u8, r, rerun)) n += 1;
    }
    return n;
}

/// The label without its cell.
fn stripCell(label: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, label, "//") orelse return label;
    return label[i..];
}

fn sameTarget(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, stripCell(x), stripCell(y));
}

/// The stderr of a failing target: a flaky one's names its run on the first
/// line, then a passing test's line, then always the same FAIL line.
fn failureText(a: std.mem.Allocator, t: []const u8, commit: []const u8, flaky_n: ?u64) ![]const u8 {
    if (flaky_n) |n| return std.fmt.allocPrint(a, "running {s}, run {d}\n1/2 test.no error: in setup...OK\n2/2 test.planted flake of {s}...FAIL (PlantedFlake)\nthird line", .{ t, n, t });
    return std.fmt.allocPrint(a, "planted failure of {s} at {s}\nsecond line", .{ stripCell(t), commit });
}

fn writeReport(a: std.mem.Allocator, path: []const u8, cwd: []const u8, commit: []const u8, targets: []const []const u8, failing: []const []const u8, flaky_n: ?u64) !bool {
    var buf = std.ArrayList(u8).init(a);
    var w = std.json.writeStream(buf.writer(), .{ .whitespace = .indent_2 });
    var any = false;
    try w.beginObject();
    try w.objectField("trace_id");
    try w.write("00000000-0000-0000-0000-000000000000");
    try w.objectField("results");
    try w.beginObject();
    var strings = std.ArrayList([2][]const u8).init(a);
    for (targets) |t| {
        var failed = false;
        for (failing) |f| {
            if (sameTarget(f, t)) failed = true;
        }
        any = any or failed;
        // Labels as buck2 writes them: with the cell.
        try w.objectField(if (std.mem.startsWith(u8, t, "//")) try std.fmt.allocPrint(a, "root{s}", .{t}) else t);
        try w.beginObject();
        try w.objectField("success");
        try w.write(if (failed) "FAIL" else "SUCCESS");
        try w.objectField("configured");
        try w.beginObject();
        try w.objectField("root//platforms:default#0000000000000000");
        try w.beginObject();
        try w.objectField("errors");
        try w.beginArray();
        if (failed) {
            const msg_id = try std.fmt.allocPrint(a, "{d}", .{strings.items.len * 2 + 1});
            const err_id = try std.fmt.allocPrint(a, "{d}", .{strings.items.len * 2 + 2});
            try strings.append(.{ msg_id, try std.fmt.allocPrint(a, "Action failed: root{s} (genrule)", .{stripCell(t)}) });
            try strings.append(.{ err_id, try failureText(a, t, commit, flaky_n) });
            try w.beginObject();
            try w.objectField("message_content");
            try w.write(msg_id);
            try w.objectField("action_error");
            try w.beginObject();
            try w.objectField("stderr_content");
            try w.write(err_id);
            try w.endObject();
            try w.objectField("error_category");
            try w.write("USER");
            try w.endObject();
        }
        try w.endArray();
        try w.objectField("success");
        try w.write(if (failed) "FAIL" else "SUCCESS");
        try w.endObject();
        try w.endObject();
        try w.objectField("errors");
        try w.beginArray();
        try w.endArray();
        try w.endObject();
    }
    try w.endObject();
    try w.objectField("success");
    try w.write(!any);
    try w.objectField("failures");
    try w.beginObject();
    try w.endObject();
    try w.objectField("project_root");
    try w.write(cwd);
    try w.objectField("truncated");
    try w.write(false);
    try w.objectField("strings");
    try w.beginObject();
    for (strings.items) |kv| {
        try w.objectField(kv[0]);
        try w.write(kv[1]);
    }
    try w.endObject();
    try w.endObject();
    try std.fs.cwd().writeFile(path, buf.items);
    return any;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) std.process.exit(64);
    const cmd = argv[1];
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const p = paths(a, cwd) catch |e| {
        std.io.getStdErr().writer().print("fake_buck2: {s} is not a probe worktree: {s}\n", .{ cwd, @errorName(e) }) catch {};
        std.process.exit(64);
    };

    // The rerun flag and the targets of a build (a bxl's script is not one).
    const is_bxl = std.mem.eql(u8, cmd, "bxl");
    var rerun: []const u8 = "-";
    var targets = std.ArrayList([]const u8).init(a);
    var script: []const u8 = "";
    {
        var k: usize = 2;
        while (k < argv.len) : (k += 1) {
            const x = argv[k];
            if (std.mem.eql(u8, x, "--build-report")) {
                k += 1;
            } else if (std.mem.eql(u8, x, "-c") and k + 1 < argv.len and std.mem.startsWith(u8, argv[k + 1], "komira.rerun=")) {
                rerun = argv[k + 1]["komira.rerun=".len..];
                k += 1;
            } else if (std.mem.indexOf(u8, x, "//") != null) {
                if (is_bxl) script = x else try targets.append(x);
            }
        }
    }
    const joined = if (targets.items.len == 0) "-" else try std.mem.join(a, ",", targets.items);
    const prior = try priorBuilds(a, p.log, p.commit, rerun);
    try appendLog(p.log, try std.fmt.allocPrint(a, "{s} {s} {s} {s} {s}\n", .{ cmd, p.commit, cwd, rerun, joined }));

    if (std.mem.eql(u8, cmd, "kill")) return;
    if (std.mem.eql(u8, cmd, "root")) {
        try std.io.getStdOut().writer().print("{s}\n", .{cwd});
        return;
    }
    if (is_bxl) return check(a, script, rerun);
    if (!std.mem.eql(u8, cmd, "build") and !std.mem.eql(u8, cmd, "test")) std.process.exit(64);
    if (argv.len < 4 or !std.mem.eql(u8, argv[2], "--build-report")) std.process.exit(64);
    const report = argv[3];
    // The rerun's label and n; n is 0 without the flag.
    var rerun_label: []const u8 = "";
    var rerun_n: u64 = 0;
    if (!std.mem.eql(u8, rerun, "-")) {
        const hash = std.mem.lastIndexOfScalar(u8, rerun, '#') orelse std.process.exit(64);
        rerun_label = rerun[0..hash];
        rerun_n = std.fmt.parseInt(u64, rerun[hash + 1 ..], 10) catch std.process.exit(64);
    }

    const fixture = try std.fs.cwd().readFileAlloc(a, "bisect_fixture.txt", 1 << 16);
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    var state: []const u8 = "";
    while (lines.next()) |line| {
        var infra = false;
        if (std.mem.startsWith(u8, line, "no-rerun ") or std.mem.eql(u8, line, "check-infra")) {
            continue;
        } else if (std.mem.eql(u8, line, "infra-always")) {
            infra = true;
        } else if (std.mem.eql(u8, line, "infra-once")) {
            infra = prior == 0;
        } else if (std.mem.startsWith(u8, line, "infra-run ")) {
            const n = std.fmt.parseInt(u64, line["infra-run ".len..], 10) catch std.process.exit(64);
            infra = rerun_n == n and prior == 0;
        } else if (std.mem.startsWith(u8, line, "infra-run-always ")) {
            const n = std.fmt.parseInt(u64, line["infra-run-always ".len..], 10) catch std.process.exit(64);
            infra = rerun_n == n;
        } else {
            state = line;
            break;
        }
        if (infra) {
            std.io.getStdErr().writer().writeAll("Remote execution error: planted infrastructure failure\n") catch {};
            std.process.exit(2);
        }
    }
    var failing = std.ArrayList([]const u8).init(a);
    var flaky_n: ?u64 = null;
    var words = std.mem.tokenizeScalar(u8, state, ' ');
    const kind = words.next() orelse std.process.exit(64);
    if (std.mem.eql(u8, kind, "fail")) {
        while (words.next()) |t| try failing.append(t);
    } else if (std.mem.eql(u8, kind, "flaky")) {
        const period = std.fmt.parseInt(u64, words.next() orelse std.process.exit(64), 10) catch std.process.exit(64);
        const phase = std.fmt.parseInt(u64, words.next() orelse std.process.exit(64), 10) catch std.process.exit(64);
        if (period == 0) std.process.exit(64);
        while (words.next()) |t| {
            if (sameTarget(t, rerun_label) and rerun_n % period == phase) {
                try failing.append(t);
                flaky_n = rerun_n;
            }
        }
    } else if (!std.mem.eql(u8, kind, "pass")) std.process.exit(64);
    const any = try writeReport(a, report, cwd, p.commit, targets.items, failing.items, flaky_n);
    if (any) {
        std.io.getStdErr().writer().writeAll("BUILD FAILED\n") catch {};
        std.process.exit(3);
    }
}

/// check.bxl's stand-in: exit 3 (buck2's user error) for a label without a
/// cell or one a `no-rerun` line lists, 2 with a `check-infra` line, else 0.
fn check(a: std.mem.Allocator, script: []const u8, rerun: []const u8) !void {
    const stderr = std.io.getStdErr().writer();
    if (!std.mem.endsWith(u8, script, "tools/build/rerun/check.bxl:check")) std.process.exit(64);
    const hash = std.mem.lastIndexOfScalar(u8, rerun, '#') orelse std.process.exit(64);
    const label = rerun[0..hash];
    const fixture = try std.fs.cwd().readFileAlloc(a, "bisect_fixture.txt", 1 << 16);
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "check-infra")) {
            stderr.writeAll("Remote execution error: planted infrastructure failure in the check\n") catch {};
            std.process.exit(2);
        }
    }
    if (std.mem.startsWith(u8, label, "//")) {
        stderr.print("fail: [komira] rerun: {s}: name the cell\n", .{label}) catch {};
        std.process.exit(3);
    }
    lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "no-rerun ")) continue;
        var words = std.mem.tokenizeScalar(u8, line["no-rerun ".len..], ' ');
        while (words.next()) |t| {
            if (sameTarget(t, label)) {
                stderr.print("fail: [komira] rerun names {s}, which runs no test action\n", .{label}) catch {};
                std.process.exit(3);
            }
        }
    }
    try std.io.getStdOut().writer().print("rerun: {s} runs its test actions again\n", .{label});
}
