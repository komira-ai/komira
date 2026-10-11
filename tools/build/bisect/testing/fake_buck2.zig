//! A stand-in for buck2 in the scenarios (scenario.zig): it answers from the
//! file `bisect_fixture.txt` of the checkout it runs in.
//!
//! - `root --kind project` prints the working directory.
//! - `kill` exits 0.
//! - `build|test --build-report <file> <targets>...` reads the fixture:
//!   an optional first line `infra-once` (the first build of this commit
//!   exits 2 with no report) or `infra-always` (every build does), then
//!   `pass` (exit 0) or `fail <target>...` (those of the given targets fail:
//!   a report in buck2's shape naming them, exit 3).
//!
//! Every call appends `<command> <commit> <cwd>` to `fake_buck2.log` in the
//! repository's git directory (read from the worktree's `.git` file, so no
//! git runs), where the scenario counts builds, retries and kills.
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

/// How many builds of `commit` the log holds already.
fn priorBuilds(a: std.mem.Allocator, log: []const u8, commit: []const u8) !usize {
    const bytes = std.fs.cwd().readFileAlloc(a, log, 1 << 24) catch return 0;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = w.next() orelse continue;
        const c = w.next() orelse continue;
        if ((std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "test")) and std.mem.eql(u8, c, commit)) n += 1;
    }
    return n;
}

fn writeReport(a: std.mem.Allocator, path: []const u8, cwd: []const u8, commit: []const u8, targets: []const []const u8, failing: []const []const u8) !bool {
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
            if (std.mem.eql(u8, f, t)) failed = true;
        }
        any = any or failed;
        // Labels as buck2 writes them: with the cell.
        try w.objectField(try std.fmt.allocPrint(a, "root{s}", .{t}));
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
            try strings.append(.{ msg_id, try std.fmt.allocPrint(a, "Action failed: root{s} (genrule)", .{t}) });
            try strings.append(.{ err_id, try std.fmt.allocPrint(a, "planted failure of {s} at {s}\nsecond line", .{ t, commit }) });
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
    const prior = try priorBuilds(a, p.log, p.commit);
    try appendLog(p.log, try std.fmt.allocPrint(a, "{s} {s} {s}\n", .{ cmd, p.commit, cwd }));

    if (std.mem.eql(u8, cmd, "kill")) return;
    if (std.mem.eql(u8, cmd, "root")) {
        try std.io.getStdOut().writer().print("{s}\n", .{cwd});
        return;
    }
    if (!std.mem.eql(u8, cmd, "build") and !std.mem.eql(u8, cmd, "test")) std.process.exit(64);
    if (argv.len < 4 or !std.mem.eql(u8, argv[2], "--build-report")) std.process.exit(64);
    const report = argv[3];
    var targets = std.ArrayList([]const u8).init(a);
    for (argv[4..]) |x| if (std.mem.startsWith(u8, x, "//")) try targets.append(x);

    const fixture = try std.fs.cwd().readFileAlloc(a, "bisect_fixture.txt", 1 << 16);
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    var state = lines.next() orelse std.process.exit(64);
    if (std.mem.eql(u8, state, "infra-always") or (std.mem.eql(u8, state, "infra-once") and prior == 0)) {
        std.io.getStdErr().writer().writeAll("Remote execution error: planted infrastructure failure\n") catch {};
        std.process.exit(2);
    }
    if (std.mem.startsWith(u8, state, "infra-")) state = lines.next() orelse std.process.exit(64);
    var failing = std.ArrayList([]const u8).init(a);
    var words = std.mem.tokenizeScalar(u8, state, ' ');
    const kind = words.next() orelse std.process.exit(64);
    if (std.mem.eql(u8, kind, "fail")) {
        while (words.next()) |t| try failing.append(t);
    } else if (!std.mem.eql(u8, kind, "pass")) std.process.exit(64);
    const any = try writeReport(a, report, cwd, p.commit, targets.items, failing.items);
    if (any) {
        std.io.getStdErr().writer().writeAll("BUILD FAILED\n") catch {};
        std.process.exit(3);
    }
}
