//! One parity case of //tools/build/ci:affected or :derive_checks, run as a
//! build action (defs.bzl, `ci_parity_case`): the subject runs in a tree of
//! the case's making, every buck2 and git question it asks is answered from
//! the case's transcript, and the case passes only when the subject printed
//! the golden stdout and stderr, exited with the golden code, and asked
//! exactly the recorded questions.
//!
//! A case is a directory (format.zig says how each file reads):
//!
//!   case.txt         the argv (kci's, byte for byte, for the cases kci's
//!                    calls reach), the inputs it names, the tree, the
//!                    golden exit code, the declared divergences
//!   transcript.txt   every call the subject makes, with its answer
//!   stdout, stderr   the golden streams, with the timing normalized
//!
//! The run, in the action's scratch directory:
//!
//!  1. the tree: every `file` of case.txt, and an empty BUCK file for every
//!     path the transcript's `git ls-files` answer lists (affected reads a
//!     package's existence from the tree, as it reads a changed file's);
//!  2. replay.zig at `./buck2` (affected's default --buck2), at
//!     `.parity/bin/buck2` (derive_checks' default, `buck2` on PATH) and at
//!     `.parity/bin/git` (affected runs `git` from PATH);
//!  3. PATH is `.parity/bin` alone, TMPDIR and HOME are the scratch's own;
//!  4. the subject runs from the tree's root with the case's argv, each
//!     `{name}` bound to `.parity/in/<name>`, the input of that name;
//!  5. stdout, stderr and the exit code are compared to the goldens. The
//!     only normalization is the timing (`normalize`); a declared `alt` lets
//!     the subject print its other text where the golden holds its own
//!     (`applyAlts`), and every other byte is compared;
//!  6. the calls are compared: the multiset of calls the replay logged must
//!     equal the transcript's entries (`checkCalls`), so a subject that asks a
//!     different, an extra or one question fewer fails even when its output
//!     happens to match.
//!
//! `--out <file>` is written only when every check held. `--record <dir>`
//! instead writes what the subject did (normalized streams, exit, the call
//! log, and the checks that failed) and passes whatever happened: the
//! goldens are made from it, and reviewed.
const std = @import("std");
const format = @import("format.zig");

// ---- normalization -------------------------------------------------------

const timing_placeholder = "#.###s";
const ms_key = "\"milliseconds\":";

/// `<digits>.<3 digits>s` at `text[i..]`: its length, or 0.
fn secondsAt(text: []const u8, i: usize) usize {
    var k = i;
    while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
    if (k == i or k + 5 > text.len or text[k] != '.') return 0;
    for (text[k + 1 .. k + 4]) |c| if (!std.ascii.isDigit(c)) return 0;
    if (text[k + 4] != 's') return 0;
    return k + 5 - i;
}

/// The one line of `line` to normalize: affected's summary (`affected:
/// <KIND>: ..., <s>` with an optional ` -- <reason>`) and its coverage line
/// put `render_seconds` after `, `; that first time becomes `#.###s`. In
/// any line, the first `"milliseconds":<digits>` (affected's --json) becomes
/// `"milliseconds":#`. Nothing else changes.
fn normalizeLine(out: *std.ArrayList(u8), line: []const u8) !void {
    if (std.mem.startsWith(u8, line, "affected: ") and !std.mem.startsWith(u8, line, "affected: WARN ") and
        !std.mem.startsWith(u8, line, "affected: cannot tell: "))
    {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, ", ")) |at| {
            const n = secondsAt(line, at + 2);
            const end = at + 2 + n;
            if (n > 0 and (end == line.len or std.mem.startsWith(u8, line[end..], " -- "))) {
                try out.appendSlice(line[0 .. at + 2]);
                try out.appendSlice(timing_placeholder);
                try out.appendSlice(line[end..]);
                return;
            }
            i = at + 2;
        }
    }
    if (std.mem.indexOf(u8, line, ms_key)) |at| {
        var k = at + ms_key.len;
        while (k < line.len and std.ascii.isDigit(line[k])) k += 1;
        if (k > at + ms_key.len) {
            try out.appendSlice(line[0 .. at + ms_key.len]);
            try out.append('#');
            try out.appendSlice(line[k..]);
            return;
        }
    }
    try out.appendSlice(line);
}

/// `text` with its timing normalized, line by line (`normalizeLine`).
pub fn normalize(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        try normalizeLine(&out, line);
    }
    return out.toOwnedSlice();
}

/// `actual` with each declared divergence of `stream` undone: every `other`
/// text replaced by its `golden` text.
pub fn applyAlts(a: std.mem.Allocator, actual: []const u8, alts: []const format.Alt, stream: format.Stream) ![]const u8 {
    var cur: []const u8 = actual;
    for (alts) |alt| {
        if (alt.stream != stream) continue;
        cur = try std.mem.replaceOwned(u8, a, cur, alt.other, alt.golden);
    }
    return cur;
}

// ---- the checks ----------------------------------------------------------

pub const Term = union(enum) { exited: u8, signaled: u32, other: void };

pub const Actual = struct {
    term: Term,
    stdout: []const u8,
    stderr: []const u8,
    calls: []const format.Call,
};

pub const Golden = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
    alts: []const format.Alt,
};

/// Where `want` and `got` first differ, as a message: the line number and the
/// two lines, quoted.
fn firstDifference(a: std.mem.Allocator, what: []const u8, want: []const u8, got: []const u8) ![]u8 {
    var at: usize = 0;
    while (at < want.len and at < got.len and want[at] == got[at]) at += 1;
    const line_no = std.mem.count(u8, want[0..at], "\n") + 1;
    const start = if (std.mem.lastIndexOfScalar(u8, want[0..at], '\n')) |p| p + 1 else 0;
    const want_end = std.mem.indexOfScalarPos(u8, want, at, '\n') orelse want.len;
    const got_end = std.mem.indexOfScalarPos(u8, got, at, '\n') orelse got.len;
    var out = std.ArrayList(u8).init(a);
    try out.writer().print("{s} differs from the golden at byte {d} (line {d}; golden {d} bytes, subject {d} bytes)\n  golden:  ", .{ what, at, line_no, want.len, got.len });
    try format.quote(&out, want[start..want_end]);
    try out.appendSlice("\n  subject: ");
    try format.quote(&out, got[start..got_end]);
    return out.toOwnedSlice();
}

/// The failures of the calls: an unrecorded call, a call made more often
/// than the transcript holds it, and an entry no call consumed.
pub fn checkCalls(a: std.mem.Allocator, entries: []const format.Entry, calls: []const format.Call, failures: *std.ArrayList([]const u8)) !void {
    const used = try a.alloc(bool, entries.len);
    @memset(used, false);
    for (calls) |c| {
        if (!c.recorded) {
            try failures.append(try std.fmt.allocPrint(a, "unrecorded call: {s}", .{try format.quoteArgv(a, c.argv)}));
            continue;
        }
        var hit = false;
        for (entries, 0..) |e, k| {
            if (used[k] or !format.sameCall(e.argv, c.argv)) continue;
            used[k] = true;
            hit = true;
            break;
        }
        if (!hit) try failures.append(try std.fmt.allocPrint(a, "a call made more often than recorded: {s}", .{try format.quoteArgv(a, c.argv)}));
    }
    for (entries, 0..) |e, k| {
        if (!used[k]) try failures.append(try std.fmt.allocPrint(a, "a recorded call the subject never made: {s}", .{try format.quoteArgv(a, e.argv)}));
    }
}

/// Every check of a run, as messages; none: the case passes.
pub fn check(a: std.mem.Allocator, golden: Golden, entries: []const format.Entry, actual: Actual) ![]const []const u8 {
    var failures = std.ArrayList([]const u8).init(a);
    switch (actual.term) {
        .exited => |v| if (v != golden.exit) try failures.append(try std.fmt.allocPrint(a, "exit {d}, golden {d}", .{ v, golden.exit })),
        .signaled => |s| try failures.append(try std.fmt.allocPrint(a, "killed by signal {d}, golden exit {d}", .{ s, golden.exit })),
        .other => try failures.append("the subject ended neither by exit nor by signal"),
    }
    const out = try applyAlts(a, try normalize(a, actual.stdout), golden.alts, .stdout);
    if (!std.mem.eql(u8, out, golden.stdout)) try failures.append(try firstDifference(a, "stdout", golden.stdout, out));
    const err = try applyAlts(a, try normalize(a, actual.stderr), golden.alts, .stderr);
    if (!std.mem.eql(u8, err, golden.stderr)) try failures.append(try firstDifference(a, "stderr", golden.stderr, err));
    try checkCalls(a, entries, actual.calls, &failures);
    return failures.toOwnedSlice();
}

/// The paths of the BUCK files the transcript's `git ls-files` answer
/// lists (its non-empty lines, a trailing CR dropped, as affected reads them).
pub fn listedBuckFiles(a: std.mem.Allocator, entries: []const format.Entry) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (entries) |e| {
        if (e.argv.len < 2 or !std.mem.eql(u8, e.argv[0], "git") or !std.mem.eql(u8, e.argv[1], "ls-files")) continue;
        var it = std.mem.splitScalar(u8, e.stdout, '\n');
        while (it.next()) |raw| {
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            if (line.len > 0 and format.safeRelative(line)) try out.append(line);
        }
    }
    return out.toOwnedSlice();
}

/// `arg` with each `{name}` of a declared input replaced by its path.
pub fn bindArg(a: std.mem.Allocator, arg: []const u8, inputs: []const format.Input) ![]const u8 {
    var cur: []const u8 = arg;
    for (inputs) |in| {
        const key = try std.fmt.allocPrint(a, "{{{s}}}", .{in.name});
        const path = try std.fmt.allocPrint(a, ".parity/in/{s}", .{in.name});
        cur = try std.mem.replaceOwned(u8, a, cur, key, path);
    }
    return cur;
}

// ---- the run -------------------------------------------------------------

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("parity: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

fn writeAt(root: std.fs.Dir, path: []const u8, bytes: []const u8) void {
    if (std.fs.path.dirname(path)) |d| root.makePath(d) catch |e| die("cannot make {s}: {s}", .{ d, @errorName(e) });
    root.writeFile(path, bytes) catch |e| die("cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn placeReplay(root: std.fs.Dir, replay: []const u8, path: []const u8) void {
    std.fs.cwd().copyFile(replay, root, path, .{}) catch |e| die("cannot copy the replay to {s}: {s}", .{ path, @errorName(e) });
    var f = root.openFile(path, .{}) catch |e| die("cannot open {s}: {s}", .{ path, @errorName(e) });
    defer f.close();
    f.chmod(0o755) catch |e| die("cannot make {s} executable: {s}", .{ path, @errorName(e) });
}

fn readCaseFile(a: std.mem.Allocator, dir: []const u8, name: []const u8, missing_ok: bool) []const u8 {
    const path = std.fs.path.join(a, &.{ dir, name }) catch die("out of memory", .{});
    return std.fs.cwd().readFileAlloc(a, path, 1 << 28) catch |e| {
        if (missing_ok and e == error.FileNotFound) return "";
        die("cannot read {s}: {s}", .{ path, @errorName(e) });
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var subject: []const u8 = "";
    var replay: []const u8 = "";
    var case_dir: []const u8 = "";
    var common_dir: []const u8 = "";
    var out: []const u8 = "";
    var record: []const u8 = "";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const k = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, k, "--subject")) subject = v else if (std.mem.eql(u8, k, "--replay")) replay = v else if (std.mem.eql(u8, k, "--case")) case_dir = v else if (std.mem.eql(u8, k, "--common")) common_dir = v else if (std.mem.eql(u8, k, "--out")) out = v else if (std.mem.eql(u8, k, "--record")) record = v else die("unknown argument {s}", .{k});
    }
    if (i != argv.len or subject.len == 0 or replay.len == 0 or case_dir.len == 0 or common_dir.len == 0 or (out.len == 0) == (record.len == 0))
        die("usage: runner --subject <exe> --replay <exe> --case <dir> --common <dir> (--out <file> | --record <dir>)", .{});
    const recording = record.len > 0;
    const name = std.fs.path.basename(case_dir);

    var diag = format.Diag{};
    const files = format.Files{ .case_dir = case_dir, .common_dir = common_dir };
    const case = format.parseCase(a, readCaseFile(a, case_dir, "case.txt", false), files, &diag) catch die("{s}/case.txt line {d}: {s}", .{ case_dir, diag.line, diag.msg });
    const entries = format.parseTranscript(a, readCaseFile(a, case_dir, "transcript.txt", false), files, &diag) catch die("{s}/transcript.txt line {d}: {s}", .{ case_dir, diag.line, diag.msg });
    const golden = Golden{
        .exit = case.exit,
        .stdout = readCaseFile(a, case_dir, "stdout", recording),
        .stderr = readCaseFile(a, case_dir, "stderr", recording),
        .alts = case.alts,
    };

    // The tree, in a directory of its own: buck2's per-action scratch
    // directory when it names one, else under the working directory.
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const scratch_base = if (std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH")) |p|
        (if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(a, &.{ cwd, p }))
    else |_|
        cwd;
    const root_path = try std.fs.path.join(a, &.{ scratch_base, try std.fmt.allocPrint(a, "parity_{s}", .{name}) });
    std.fs.deleteTreeAbsolute(root_path) catch {};
    try std.fs.cwd().makePath(root_path);
    var root = try std.fs.openDirAbsolute(root_path, .{});
    defer root.close();
    for (try listedBuckFiles(a, entries)) |p| writeAt(root, p, "");
    for (case.files) |f| writeAt(root, f.path, f.bytes);
    for (case.inputs) |in| writeAt(root, try std.fmt.allocPrint(a, ".parity/in/{s}", .{in.name}), in.bytes);
    try root.makePath(".parity/bin");
    try root.makePath("tmp");
    try root.makePath("home");
    placeReplay(root, replay, "buck2");
    placeReplay(root, replay, ".parity/bin/buck2");
    placeReplay(root, replay, ".parity/bin/git");
    writeAt(root, ".parity/transcript", try format.renderTranscript(a, entries));
    writeAt(root, ".parity/calls", "");

    // The run.
    var cmd = std.ArrayList([]const u8).init(a);
    try cmd.append(try std.fs.cwd().realpathAlloc(a, subject));
    for (case.args) |arg| try cmd.append(try bindArg(a, arg, case.inputs));
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", try std.fs.path.join(a, &.{ root_path, ".parity", "bin" }));
    try env.put("TMPDIR", try std.fs.path.join(a, &.{ root_path, "tmp" }));
    try env.put("HOME", try std.fs.path.join(a, &.{ root_path, "home" }));
    const r = std.ChildProcess.run(.{ .allocator = a, .argv = cmd.items, .cwd = root_path, .env_map = &env, .max_output_bytes = 1 << 28 }) catch |e|
        die("cannot run the subject {s}: {s}", .{ subject, @errorName(e) });
    const term: Term = switch (r.term) {
        .Exited => |v| .{ .exited = v },
        .Signal => |s| .{ .signaled = s },
        else => .other,
    };
    const log_text = try root.readFileAlloc(a, ".parity/calls", 1 << 28);
    const calls = format.parseLog(a, log_text, &diag) catch die("the call log, line {d}: {s}", .{ diag.line, diag.msg });
    const failures = try check(a, golden, entries, .{ .term = term, .stdout = r.stdout, .stderr = r.stderr, .calls = calls });

    var report = std.ArrayList(u8).init(a);
    for (failures) |f| try report.writer().print("FAILED: {s}\n", .{f});
    if (recording) {
        try std.fs.cwd().makePath(record);
        var d = try std.fs.cwd().openDir(record, .{});
        defer d.close();
        try d.writeFile("stdout", try normalize(a, r.stdout));
        try d.writeFile("stderr", try normalize(a, r.stderr));
        try d.writeFile("exit", switch (term) {
            .exited => |v| try std.fmt.allocPrint(a, "exit {d}\n", .{v}),
            .signaled => |s| try std.fmt.allocPrint(a, "signal {d}\n", .{s}),
            .other => "other\n",
        });
        try d.writeFile("calls", log_text);
        try d.writeFile("failures", report.items);
        std.fs.deleteTreeAbsolute(root_path) catch {};
        return;
    }
    if (failures.len > 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("parity case {s}: {d} check(s) failed\n{s}---- subject stderr (raw)\n{s}----\n", .{ name, failures.len, report.items, r.stderr });
        std.process.exit(1);
    }
    std.fs.deleteTreeAbsolute(root_path) catch {};
    try std.fs.cwd().writeFile(out, "passed\n");
}
