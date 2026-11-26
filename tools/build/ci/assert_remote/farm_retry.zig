//! The run again of a buck2 step whose only failure is a cut connection to the
//! farm: `assert_remote run`, the first line of the buck2-farm action
//! (.github/actions/buck2-farm/action.yml).
//!
//!     assert_remote run --log <file> --summary <file> --farm-config <file> -- <buck2> <subcommand> [args...]
//!
//! It runs the command with its stdout and stderr merged, copied to this
//! program's stdout (the job log) and to `--log` as they arrive, as
//! `2>&1 | tee` would. A run that exits 0 ends here with 0. A failed run of
//! `build`, `test` or `bxl` whose log `classify` calls a cut is run again,
//! after a wait for the farm (farm_wait.zig): `--farm-config` is the machine
//! buckconfig farm-connect wrote, which names the farm's address and the
//! longest wait (`farm_wait_seconds`). The tool probes the farm's port until
//! it answers, at most that long, with a line in the job log each minute.
//!   * When the farm answers, the failed run's log is kept beside `--log` as
//!     `<name>.first.log` (the first run's) or `<name>.second.log` (the
//!     second's), one line goes to `--summary` (the job summary) saying how
//!     long the farm was unreachable and that the step ran again, and the next
//!     run's log takes `--log`.
//!   * When the bound passes first, one line goes to the job summary saying
//!     how long the farm was unreachable and that the step was not run again;
//!     `--log` keeps the failed run's log, and the step fails with its code.
//! A step runs at most `max_runs` (3) times: a third run that is cut too is
//! final. The farm config is read only when a run is to be run again, so a
//! step that passes, or fails for good, never needs it. The exit code is
//! buck2's own, of the last run; 2 for a wrong command line, a log that cannot
//! be written or read, a farm config that cannot be read or names no farm, or
//! a job summary that cannot be written.
//!
//! When the connection between the runner and the farm is cut, buck2 fails
//! every action in flight at once, each with a block like this (recorded in
//! fixtures/build_cut.log):
//!
//!     [<time>] Action failed: <target> (<configuration>) (<category>)
//!     [<time>] Internal error (stage: remote_call_error): Remote Execution Error on Execute ...
//!     [<time>] Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', ...
//!     [<time>] Remote action digest: '<digest>'
//!     [<time>] Stdout: <empty>
//!     [<time>] Stderr: <empty>
//!
//! and ends `BUILD FAILED` with a `Failed to build '<target> (<configuration>)'`
//! line for each. An action that failed on its own says `Remote command
//! returned non-zero exit code N` in that place and prints its output after
//! `Stdout:`/`Stderr:` (fixtures/build_cut_and_compile_error.log). A test's result is
//! a block too: `✗ Fail: <name> (<time>)`, then the test's output between
//! `---- STDOUT ----` and `---- STDERR ----` markers; the run ends with
//! `Tests finished: Pass N. Fail N. Timeout N. Fatal N. ...`.
//!
//! So a log is a cut, and only then, when:
//!   * it has at least one failure block (`Action failed:` or a test's
//!     `✗ Fail:`), and every failure block has, in its head (before the first
//!     output marker), buck2's own `Error:` line with `RE channel error: code: `.
//!     buck2's own lines carry its `[<time>] ` prefix; an action's output does
//!     not, and a test's output comes after a marker, so the phrase quoted by
//!     a compiler or a test never counts. The one exception is the output
//!     buck2 gives a test whose run on the farm was cut, which never ran
//!     (fixtures/test_cut.log): an empty `---- STDOUT ----`, then
//!     `---- STDERR ----` holding only buck2's
//!     `Remote Execution Error on Execute with digest ...` line and, on the
//!     next line, the cut line. A failed test with that output and nothing
//!     else (empty lines before the first and after the second) is a cut;
//!     one more line of any kind makes it the test's own failure;
//!   * no test timed out, was fatal, failed for the infrastructure or failed
//!     to list (a block of that kind, or a nonzero count on `Tests finished:`);
//!   * every line outside a block is one buck2 prints around such a run:
//!     its progress and summary lines, the files its daemon saw change
//!     (`File changed: <path>`, `<N> additional file change events`),
//!     `BUILD FAILED`, a `Failed to build` line naming a target that has an
//!     `Action failed:` block, the test counts and the list of failed tests
//!     after them (ended by `...and <N> more not shown...` when it is cut
//!     short). Any other line (an analysis error, a bxl script's error, a
//!     line of a shape not seen before) is a failure that is not a cut.
//! Anything else is final: a log that mixes one real failure with any number
//! of cuts is never run again.

const std = @import("std");
const posix = std.posix;
const farm_wait = @import("farm_wait.zig");

/// What a failed run's log shows.
pub const Verdict = union(enum) {
    /// Every failure is a cut connection to the farm: this many failure blocks.
    cut: usize,
    /// A failure block that is not a cut: its first line.
    failure: []const u8,
    /// A test result or count that is never a cut (a timeout, a fatal, an
    /// infrastructure failure, a failed listing): the line.
    test_status: []const u8,
    /// A line outside every block that buck2 does not print around a cut: the line.
    unexplained: []const u8,
    /// A `Failed to build` line whose target has no `Action failed:` block: the line.
    unmatched_target: []const u8,
    /// The log has no failure block.
    no_failure,
};

/// The content of one of buck2's own lines (after its `[<time>]` prefix and
/// one space), or null when the line has no such prefix. A prefix is `[`, a
/// digit, and the first `]` within 48 bytes.
fn stamped(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[' or !std.ascii.isDigit(line[1])) return null;
    const end = std.mem.indexOfScalar(u8, line[0..@min(line.len, 48)], ']') orelse return null;
    const rest = line[end + 1 ..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

/// The line with the escape sequences of a terminal colour removed (buck2
/// colours its test counts even without a terminal), into `buf`.
fn plain(buf: *std.ArrayList(u8), a: std.mem.Allocator, line: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len and !(line[i] >= 0x40 and line[i] <= 0x7e)) i += 1;
            i += 1; // the final byte
            continue;
        }
        try buf.append(a, line[i]);
        i += 1;
    }
    return buf.items;
}

const Kind = enum {
    /// `Action failed:`: a failure; its output follows `Stdout:` / `Stderr:`.
    action,
    /// `✗ Fail:`: a failure; its output follows `---- STDOUT ----` / `---- STDERR ----`.
    test_fail,
    /// A passing, skipped or omitted test that printed its output.
    test_other,
};

/// The block a buck2 line opens, if it opens one.
fn opens(c: []const u8) ?Kind {
    if (std.mem.startsWith(u8, c, "Action failed: ")) return .action;
    if (std.mem.startsWith(u8, c, "✗ Fail: ")) return .test_fail;
    for ([_][]const u8{ "✓ Pass: ", "↷ Skip: ", "\u{20E0} Omitted: ", "✓ Listing success: " }) |p| {
        if (std.mem.startsWith(u8, c, p)) return .test_other;
    }
    return null;
}

/// A test result that is never a cut.
fn finalTestResult(c: []const u8) bool {
    for ([_][]const u8{ "⚠ Fatal: ", "✉ Timeout: ", "🛠 Infra Failure: ", "? Unknown: ", "↻ Rerun: ", "⚠ Listing failed: " }) |p| {
        if (std.mem.startsWith(u8, c, p)) return true;
    }
    return false;
}

/// buck2's own lines that end a block's output and stand outside any block.
fn progressOrSummary(c: []const u8) bool {
    for ([_][]const u8{ "Waiting on ", "Build ID: ", "RE Session: ", "Cache hits: ", "Commands: ", "Network: ", "BUILD ERRORS (", "The following actions failed during the execution of this command:" }) |p| {
        if (std.mem.startsWith(u8, c, p)) return true;
    }
    // A warning of buck2's own log, as `<time>Z  WARN <module>: ...` (its
    // remote client's `Transient error ..., retrying`): a warning, not an error.
    if (c.len > 0 and std.ascii.isDigit(c[0])) {
        if (std.mem.indexOf(u8, c, "Z  WARN ")) |at| {
            if (at < 40 and std.mem.indexOfScalar(u8, c[0..at], ' ') == null) return true;
        }
    }
    if (fileChanges(c)) return true;
    // A warning buck2 prints while it builds a target with no outputs.
    return std.mem.startsWith(u8, c, "Target ") and std.mem.endsWith(u8, c, " does not have any outputs. This means the rule did not define any outputs. See https://buck2.build/docs/users/faq/common_issues/#why-does-my-target-not-have-any-outputs for more information");
}

/// The lines buck2 prints at the start of a command when its daemon saw files
/// change since the last one (fixtures/build_cut_after_file_changes.log, after
/// a step that wrote the packages' mopm.toml): `File changed: <path>` for the
/// first few, then `<N> additional file change events`. The path is one word:
/// a line with more after it is not this one.
fn fileChanges(c: []const u8) bool {
    const changed = "File changed: ";
    if (std.mem.startsWith(u8, c, changed)) {
        const path = c[changed.len..];
        return path.len > 0 and std.mem.indexOfScalar(u8, path, ' ') == null;
    }
    var end: usize = 0;
    while (end < c.len and std.ascii.isDigit(c[end])) end += 1;
    return end > 0 and std.mem.eql(u8, c[end..], " additional file change events");
}

/// buck2's verdict on a build or bxl run, unstamped.
fn verdictLine(l: []const u8) bool {
    for ([_][]const u8{ "BUILD FAILED", "BXL FAILED", "BUILD SUCCEEDED", "BXL SUCCEEDED" }) |v| {
        if (std.mem.eql(u8, l, v)) return true;
    }
    return false;
}

/// The unstamped lines that end a run and stand outside any block.
fn runEnd(l: []const u8) bool {
    return verdictLine(l) or std.mem.startsWith(u8, l, "Tests finished: ");
}

/// The cut line: buck2's `Error:` with the error of its channel to the farm.
fn isCut(c: []const u8) bool {
    return std.mem.startsWith(u8, c, "Error: ") and std.mem.indexOf(u8, c, "RE channel error: code: ") != null;
}

/// The count after `<label> ` on a `Tests finished:` line, or null when the label is not there.
fn count(line: []const u8, label: []const u8) ?u64 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, label)) |at| {
        from = at + label.len;
        const before_ok = at == 0 or line[at - 1] == ' ';
        if (!before_ok or from >= line.len or line[from] != ' ') continue;
        var end = from + 1;
        while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
        if (end == from + 1) continue;
        return std.fmt.parseInt(u64, line[from + 1 .. end], 10) catch null;
    }
    return null;
}

/// True when a `Tests finished:` line counts only results a cut can explain:
/// no timeout, fatal or infrastructure failure, no failed listing, and all
/// three counts there to be read.
fn testCountsAllow(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "Listing") != null) return false;
    for ([_][]const u8{ "Timeout", "Fatal", "Infra Failure" }) |label| {
        if ((count(line, label) orelse return false) != 0) return false;
    }
    return true;
}

/// True when `log` has an `Action failed: <target> (` line of buck2's.
fn hasActionBlock(log: []const u8, target: []const u8) bool {
    const key = "] Action failed: ";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, log, from, key)) |at| {
        from = at + key.len;
        const rest = log[from..];
        if (std.mem.startsWith(u8, rest, target) and rest.len > target.len + 1 and rest[target.len] == ' ' and rest[target.len + 1] == '(') return true;
    }
    return false;
}

/// True for a line buck2 prints after a test run's counts: `N TESTS FAILED`,
/// `N BUILDS FAILED`, the list of failed tests (`✗ <target>`) and the line
/// that ends a list cut short (`...and N more not shown...`).
fn testRunTail(l: []const u8) bool {
    if (std.mem.startsWith(u8, l, "✗ ")) return true;
    const more = "...and ";
    if (std.mem.startsWith(u8, l, more)) {
        var at: usize = more.len;
        while (at < l.len and std.ascii.isDigit(l[at])) at += 1;
        return at > more.len and std.mem.eql(u8, l[at..], " more not shown...");
    }
    var end: usize = 0;
    while (end < l.len and std.ascii.isDigit(l[end])) end += 1;
    if (end == 0) return false;
    const rest = l[end..];
    return std.mem.eql(u8, rest, " TESTS FAILED") or std.mem.eql(u8, rest, " BUILDS FAILED");
}

/// An open block: where in it the reading is, and whether its head had the cut line.
const Block = struct {
    kind: Kind,
    /// The line that opened it.
    first: []const u8,
    part: enum {
        /// buck2's lines that say why the action or test failed.
        head,
        /// An action's `Stdout:` and its output (an action's output carries
        /// no `[<time>]` prefix).
        stdout,
        /// An action's `Stderr:` and its output, or a test's output after
        /// its first marker.
        output,
    } = .head,
    cut: bool = false,
    /// For a failed test: how far its output is the output buck2 prints for a
    /// test whose run on the farm was cut (fixtures/test_cut.log): an empty
    /// `---- STDOUT ----`, then `---- STDERR ----` with buck2's
    /// `Remote Execution Error on Execute with digest ...` line and, on the
    /// next line, its cut line; empty lines only before the first and after
    /// the second. A test that printed exactly those two lines itself, with
    /// nothing else, would read as a cut and run once more; nothing else does.
    unrun: enum {
        /// Before the test's first output marker.
        start,
        /// In its stdout, only empty lines so far.
        stdout,
        /// In its stderr, only empty lines so far.
        stderr,
        /// After the `Remote Execution Error on Execute` line.
        execute,
        /// After the cut line: the whole shape, if nothing follows.
        cut,
        /// Any other output: the test's own, never a cut.
        other,
    } = .start,

    /// True when every failure the block holds is a cut connection to the farm.
    fn isCutBlock(b: Block) bool {
        return b.cut or b.unrun == .cut;
    }

    /// For a failed test's output line: true when it is the next line of the
    /// shape `unrun` follows, and so belongs to the block; false, and the
    /// shape broken for good, when it is not.
    fn unrunTakes(b: *Block, s: []const u8) bool {
        switch (b.unrun) {
            .stdout => {
                if (s.len == 0) return true;
                if (std.mem.eql(u8, s, "---- STDERR ----")) {
                    b.unrun = .stderr;
                    return true;
                }
            },
            .stderr => {
                if (s.len == 0) return true;
                if (std.mem.startsWith(u8, s, "Remote Execution Error on Execute with digest ")) {
                    b.unrun = .execute;
                    return true;
                }
            },
            .execute => if (isCut(s)) {
                b.unrun = .cut;
                return true;
            },
            .cut => if (s.len == 0) return true,
            .start, .other => {},
        }
        b.unrun = .other;
        return false;
    }

    /// True when the line (`c` its content if buck2 stamped it, `l` the
    /// line) belongs to the block, after noting what it says; false when it
    /// ends the block and stands outside it.
    fn takes(b: *Block, c: ?[]const u8, l: []const u8) bool {
        const s = c orelse {
            // A line without buck2's prefix in a test's block is the test's
            // own: that test ran, so its output is not the cut-run shape.
            if (std.mem.trim(u8, l, " ").len > 0) b.unrun = .other;
            return !runEnd(l);
        };
        if (opens(s) != null or finalTestResult(s) or progressOrSummary(s)) return false;
        switch (b.kind) {
            .action => switch (b.part) {
                .head => {
                    if (std.mem.startsWith(u8, s, "Stdout:")) {
                        b.part = .stdout;
                    } else if (std.mem.startsWith(u8, s, "Stderr:")) {
                        b.part = .output;
                    } else if (isCut(s)) {
                        b.cut = true;
                    }
                    return true;
                },
                .stdout => {
                    if (!std.mem.startsWith(u8, s, "Stderr:")) return false;
                    b.part = .output;
                    return true;
                },
                // A line of buck2's after the action's output is not the action's.
                .output => return false,
            },
            .test_fail, .test_other => switch (b.part) {
                .head => {
                    if (std.mem.eql(u8, s, "---- STDOUT ----")) {
                        b.part = .output;
                        b.unrun = .stdout;
                    } else if (std.mem.eql(u8, s, "---- STDERR ----")) {
                        b.part = .output;
                        b.unrun = .stderr;
                    } else if (isCut(s)) {
                        b.cut = true;
                    }
                    return true;
                },
                // A test's output carries buck2's prefix, so buck2's own error
                // after it cannot be told from the test's: an `Error` line
                // ends the block and is judged outside it, never passed over,
                // unless it is the cut line of the whole shape of a failed
                // test's cut run (`unrun`).
                .stdout, .output => {
                    if (b.kind == .test_fail and b.unrunTakes(s)) return true;
                    return !std.mem.startsWith(u8, s, "Error");
                },
            },
        }
    }
};

/// What a failed run's log shows: whether every failure in it is a cut
/// connection to the farm (the header says what counts). The slices of the
/// verdict point into `log`. `a` holds one line at a time.
pub fn classify(a: std.mem.Allocator, log: []const u8) !Verdict {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);

    var block: ?Block = null;
    var cuts: usize = 0;

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw_line| {
        const raw = std.mem.trimRight(u8, raw_line, "\r");
        const l = try plain(&buf, a, raw);
        const c = stamped(l);

        if (block) |*b| {
            if (b.takes(c, l)) continue;
            if (b.kind != .test_other) {
                if (!b.isCutBlock()) return .{ .failure = b.first };
                cuts += 1;
            }
            block = null;
        }

        if (c) |s| {
            if (opens(s)) |k| {
                block = .{ .kind = k, .first = raw };
                continue;
            }
            if (finalTestResult(s)) return .{ .test_status = raw };
            if (s.len == 0 or progressOrSummary(s)) continue;
            return .{ .unexplained = raw };
        }

        const trimmed = std.mem.trim(u8, l, " ");
        if (trimmed.len == 0 or verdictLine(trimmed)) continue;
        if (std.mem.startsWith(u8, trimmed, "Tests finished: ")) {
            if (!testCountsAllow(trimmed)) return .{ .test_status = raw };
            continue;
        }
        if (testRunTail(trimmed)) continue;
        const fb = "Failed to build '";
        if (std.mem.startsWith(u8, trimmed, fb) and std.mem.endsWith(u8, trimmed, "'") and trimmed.len > fb.len + 1) {
            if (!hasActionBlock(log, trimmed[fb.len .. trimmed.len - 1])) return .{ .unmatched_target = raw };
            continue;
        }
        return .{ .unexplained = raw };
    }
    if (block) |b| {
        if (b.kind != .test_other) {
            if (!b.isCutBlock()) return .{ .failure = b.first };
            cuts += 1;
        }
    }
    return if (cuts == 0) .no_failure else .{ .cut = cuts };
}

/// Why a failed run is not run again, for the job log.
pub fn describe(v: Verdict, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .cut => |n| try w.print("every failure ({d} block(s)) is a cut connection to the farm (buck2's `RE channel error`)", .{n}),
        .failure => |l| try w.print("a failure that is not a cut connection: {s}", .{l}),
        .test_status => |l| try w.print("a test result a cut connection does not explain: {s}", .{l}),
        .unexplained => |l| try w.print("an error outside the failed actions and tests: {s}", .{l}),
        .unmatched_target => |l| try w.print("a target failed with no failed action of its own: {s}", .{l}),
        .no_failure => try w.writeAll("no failed action or test in the log"),
    }
}

/// The buck2 subcommands that run again after a cut: they only read the
/// farm and write buck-out (and `--out`), so a second run repeats the first.
pub fn retriable(subcommand: []const u8) bool {
    return std.mem.eql(u8, subcommand, "build") or std.mem.eql(u8, subcommand, "test") or std.mem.eql(u8, subcommand, "bxl");
}

/// How a run ended.
pub const End = union(enum) {
    exited: u8,
    signal: u32,
};

/// Runs `argv` with stdout and stderr on one pipe, copying what it writes to
/// fd 1 and to a new file at `log` as it arrives, and waits for it.
fn runTee(a: std.mem.Allocator, argv: []const [:0]const u8, log: []const u8) !End {
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    defer a.free(argv_z);
    for (argv, 0..) |arg, i| argv_z[i] = arg.ptr;
    const envp = try a.allocSentinel(?[*:0]const u8, std.os.environ.len, null);
    defer a.free(envp);
    for (std.os.environ, 0..) |e, i| envp[i] = e;

    var file = try std.fs.cwd().createFile(log, .{});
    defer file.close();

    const pipe = try posix.pipe2(.{ .CLOEXEC = true });
    const pid = posix.fork() catch |e| {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
        return e;
    };
    if (pid == 0) {
        posix.dup2(pipe[1], 1) catch posix.exit(127);
        posix.dup2(pipe[1], 2) catch posix.exit(127);
        const err = posix.execvpeZ(argv_z[0].?, argv_z, envp);
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "assert_remote run: cannot run {s}: {s}\n", .{ argv[0], @errorName(err) }) catch "assert_remote run: cannot run the command\n";
        _ = posix.write(2, msg) catch {};
        posix.exit(127);
    }
    posix.close(pipe[1]);
    defer posix.close(pipe[0]);

    var chunk: [64 * 1024]u8 = undefined;
    var write_error: ?anyerror = null;
    while (true) {
        const n = try posix.read(pipe[0], &chunk);
        if (n == 0) break;
        // The job log is a copy: a closed stdout must not stop the run or its log.
        writeAllFd(1, chunk[0..n]);
        if (write_error == null) file.writeAll(chunk[0..n]) catch |e| {
            write_error = e;
        };
    }
    const status = posix.waitpid(pid, 0).status;
    if (write_error) |e| return e;
    if (posix.W.IFEXITED(status)) return .{ .exited = posix.W.EXITSTATUS(status) };
    return .{ .signal = posix.W.TERMSIG(status) };
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = posix.write(fd, rest) catch return;
        if (n == 0) return;
        rest = rest[n..];
    }
}

/// `<dir>/<name>.<ordinal>.log` for `<dir>/<name>.log` (`<log>.<ordinal>` for
/// a name without `.log`): where the log of a run run again is kept.
pub fn keptLogPath(a: std.mem.Allocator, log: []const u8, ordinal_name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, log, ".log")) return std.fmt.allocPrint(a, "{s}.{s}.log", .{ log[0 .. log.len - 4], ordinal_name });
    return std.fmt.allocPrint(a, "{s}.{s}", .{ log, ordinal_name });
}

/// Appends `line` and a newline to the file at `path`, creating it if needed.
fn appendLine(path: []const u8, line: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
    try f.writeAll("\n");
}

const Args = struct {
    log: []const u8,
    summary: []const u8,
    farm_config: []const u8,
    command: []const [:0]const u8,
};

fn parseArgs(args: []const [:0]const u8) ?Args {
    var log: ?[]const u8 = null;
    var summary: ?[]const u8 = null;
    var farm_config: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const command = args[i + 1 ..];
            // The command is a program and its buck2 subcommand at least.
            if (command.len < 2) return null;
            const l = log orelse return null;
            const s = summary orelse return null;
            const f = farm_config orelse return null;
            if (l.len == 0 or s.len == 0 or f.len == 0) return null;
            return .{ .log = l, .summary = s, .farm_config = f, .command = command };
        }
        if (i + 1 >= args.len) return null;
        if (std.mem.eql(u8, arg, "--log")) {
            log = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary = args[i + 1];
        } else if (std.mem.eql(u8, arg, "--farm-config")) {
            farm_config = args[i + 1];
        } else return null;
        i += 1;
    }
    return null;
}

pub const usage = "usage: assert_remote run --log <file> --summary <file> --farm-config <file> -- <buck2> <subcommand> [args...]\n";

/// The most runs of one step: the first, and two more after a cut each.
pub const max_runs = 3;

/// The name of the n-th run (1-based), for the job log and the kept logs.
pub fn ordinal(n: usize) []const u8 {
    return switch (n) {
        1 => "first",
        2 => "second",
        3 => "third",
        else => "next",
    };
}

/// Reads the log a run wrote, or null after the reason is on `w`.
fn readLog(a: std.mem.Allocator, path: []const u8, cap: usize, w: *std.Io.Writer) !?[]u8 {
    return std.fs.cwd().readFileAlloc(a, path, cap) catch |e| {
        try w.print("buck2-farm: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        try w.flush();
        return null;
    };
}

/// Reads the farm from the machine buckconfig at `path`, or null after the reason is on `w`.
fn readFarm(a: std.mem.Allocator, path: []const u8, w: *std.Io.Writer) !?farm_wait.Farm {
    const text = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| {
        try w.print("buck2-farm: not run again: cannot read the farm config {s}: {s}\n", .{ path, @errorName(e) });
        try w.flush();
        return null;
    };
    return farm_wait.parseConfig(text) catch |e| {
        try w.print("buck2-farm: not run again: the farm config {s} names no farm: {s}\n", .{ path, farm_wait.describeConfigError(e) });
        try w.flush();
        return null;
    };
}

/// The exit code for a run that ended as `end`: buck2's own, or 128 plus the signal.
fn exitCode(end: End) u8 {
    return switch (end) {
        .exited => |c| c,
        .signal => |s| @truncate(128 +% s),
    };
}

/// The job summary line for a step whose `run`-th run was cut (`blocks`
/// failure blocks) and whose wait for the farm ended as `waited`. `kept` is
/// the base name of the kept log when the step runs again.
pub fn summaryLine(a: std.mem.Allocator, subcommand: []const u8, run: usize, blocks: usize, waited: farm_wait.Waited, kept: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("buck2-farm: the {s} run of `{s}` was cut by a lost connection to the farm (buck2's `RE channel error` in each of {d} failed block(s)); ", .{ ordinal(run), subcommand, blocks });
    switch (waited) {
        .answered => |s| {
            if (s == 0) {
                try w.writeAll("the farm answered at once; ran again");
            } else {
                try w.writeAll("farm unreachable for ");
                try farm_wait.writeDuration(w, s);
                try w.writeAll("; ran again");
            }
            try w.print(" (run {d} of at most {d}); the {s} run's log is {s}", .{ run + 1, max_runs, ordinal(run), kept });
        },
        .gave_up => |s| {
            try w.writeAll("farm unreachable for ");
            try farm_wait.writeDuration(w, s);
            try w.writeAll(", the longest wait; not run again");
        },
    }
    return out.toOwnedSlice();
}

/// `assert_remote run <args>`: the header says what it does. `args` are the
/// arguments after `run`; messages go to `w` (stderr); `cap` bounds a log read.
pub fn main(a: std.mem.Allocator, args: []const [:0]const u8, cap: usize, w: *std.Io.Writer) !u8 {
    const p = parseArgs(args) orelse {
        try w.writeAll(usage);
        try w.flush();
        return 2;
    };
    var last = runTee(a, p.command, p.log) catch |e| {
        try w.print("buck2-farm: cannot run the command or write {s}: {s}\n", .{ p.log, @errorName(e) });
        try w.flush();
        return 2;
    };
    switch (last) {
        .exited => |c| if (c == 0) return 0,
        .signal => |s| {
            try w.print("buck2-farm: not run again: buck2 was ended by signal {d}\n", .{s});
            try w.flush();
            return exitCode(last);
        },
    }
    const subcommand = p.command[1];
    if (!retriable(subcommand)) {
        try w.print("buck2-farm: not run again: `{s}` is not build, test or bxl\n", .{subcommand});
        try w.flush();
        return exitCode(last);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var run: usize = 1;
    while (true) {
        // `last` is the `run`-th run, which exited non-zero.
        const log = try readLog(ar, p.log, cap, w) orelse return 2;
        const v = try classify(ar, log);
        if (v != .cut) {
            if (run == 1) {
                try w.writeAll("buck2-farm: not run again: ");
            } else {
                try w.print("buck2-farm: FAILED: the {s} run failed: ", .{ordinal(run)});
            }
            try describe(v, w);
            try w.writeAll("\n");
            try w.flush();
            return exitCode(last);
        }
        if (run == max_runs) {
            try w.print("buck2-farm: FAILED: the {s} run was cut too: the connection to the farm was cut in each of {d} runs (buck2's `RE channel error`); not run again\n", .{ ordinal(run), run });
            try w.flush();
            return exitCode(last);
        }
        const farm = try readFarm(ar, p.farm_config, w) orelse return 2;
        try w.print("buck2-farm: the {s} run was cut by a lost connection to the farm (buck2's `RE channel error` in each of {d} failed block(s)); waiting for the farm's port to answer, up to ", .{ ordinal(run), v.cut });
        try farm_wait.writeDuration(w, farm.wait_seconds);
        try w.writeAll("\n");
        try w.flush();
        var clock = farm_wait.RealClock.init() catch |e| {
            try w.print("buck2-farm: not run again: no monotonic clock: {s}\n", .{@errorName(e)});
            try w.flush();
            return 2;
        };
        const prober: farm_wait.TcpProber = .{ .a = ar, .host = farm.host, .port = farm.port };
        const waited = try farm_wait.waitForFarm(&clock, prober, farm.wait_seconds, w);

        const kept = try keptLogPath(ar, p.log, ordinal(run));
        const note = try summaryLine(ar, subcommand, run, v.cut, waited, std.fs.path.basename(kept));
        if (waited == .answered) {
            std.fs.cwd().rename(p.log, kept) catch |e| {
                try w.print("buck2-farm: cannot keep the {s} run's log as {s}: {s}\n", .{ ordinal(run), kept, @errorName(e) });
                try w.flush();
                return 2;
            };
        }
        appendLine(p.summary, note) catch |e| {
            try w.print("buck2-farm: cannot write the job summary {s}: {s}\n", .{ p.summary, @errorName(e) });
            try w.flush();
            return 2;
        };
        try w.print("{s}\n", .{note});
        if (waited == .gave_up) {
            try w.writeAll("buck2-farm: FAILED: the farm did not answer within the longest wait\n");
            try w.flush();
            return exitCode(last);
        }
        try w.flush();

        run += 1;
        last = runTee(a, p.command, p.log) catch |e| {
            try w.print("buck2-farm: cannot run the command again or write {s}: {s}\n", .{ p.log, @errorName(e) });
            try w.flush();
            return 2;
        };
        switch (last) {
            .exited => |c| if (c == 0) {
                try w.print("buck2-farm: the {s} run passed\n", .{ordinal(run)});
                try w.flush();
                return 0;
            },
            .signal => |s| {
                try w.print("buck2-farm: FAILED: the {s} run was ended by signal {d}\n", .{ ordinal(run), s });
                try w.flush();
                return exitCode(last);
            },
        }
    }
}
