//! assert_remote: reads the output of one `./buck2 build|test|bxl ...` run (the
//! CI action tees it to a file) and exits non-zero unless the run was on the
//! farm: every `Commands:` summary line says `local: 0`, and the run is not
//! a failed one that exited quietly.
//!
//!     assert_remote <log-file>
//!
//! Exit 0: the log shows no local execution. Exit 1: it does not (the reason
//! is on stderr). Exit 2: the log cannot be read or the usage is wrong.
//!
//! What buck2 prints (recorded in fixtures/, measured on the farm):
//!   * a run that executed any action ends with
//!     `Commands: N (cached: N, remote: N, local: N)`, for `build` and for
//!     `bxl` alike;
//!   * `Cache hits: N%` is printed beside `Commands:`, and only then: both
//!     count build actions, and a cache hit is one;
//!   * a run that touched NO build action (everything already built, or a
//!     query-only script) prints neither line. A build or bxl run of that
//!     kind prints `Network: up 0B  down 0B`. A test run of that kind can
//!     still move bytes, because it looks its test results up in the farm's
//!     cache, and it ends with `Tests finished:`. Test executions themselves
//!     are never counted in `Commands:`;
//!   * `BUILD FAILED` / `BXL FAILED` end a failed run.
//! So a missing summary is accepted only when the log shows that no build
//! action was touched: the zero-network line, or a finished test run with no
//! `Cache hits:` line. A missing summary beside network traffic in any other
//! log, or beside a `Cache hits:` line, means buck2's output changed shape,
//! and that is a failure: the check must not pass by not finding what it
//! looks for.
const std = @import("std");

pub const Verdict = union(enum) {
    ok,
    /// A `Commands:` line with a nonzero local count.
    local_execution: u64,
    /// A `Commands:` line with no readable `local: N`.
    unreadable_summary,
    /// No `Commands:` line, and the log does not show that no build action
    /// was touched.
    missing_summary,
    /// buck2 said the run failed.
    run_failed,
};

/// The line without buck2's `[timestamp] ` prefix, and without a trailing CR.
fn content(line: []const u8) []const u8 {
    var s = std.mem.trimRight(u8, line, "\r");
    if (s.len > 0 and s[0] == '[') {
        if (std.mem.indexOf(u8, s, "] ")) |i| s = s[i + 2 ..];
    }
    return s;
}

/// The number after `local: ` in a summary line, if it is there and ends at a
/// non-digit.
fn localCount(summary: []const u8) ?u64 {
    const key = "local: ";
    const at = std.mem.indexOf(u8, summary, key) orelse return null;
    const rest = summary[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn isZeroNetwork(c: []const u8) bool {
    const zero = "Network: up 0B  down 0B";
    if (!std.mem.startsWith(u8, c, zero)) return false;
    return c.len == zero.len or c[zero.len] == ' ';
}

pub fn verdict(log: []const u8) Verdict {
    var summaries: usize = 0;
    var zero_network = false;
    var cache_hits_line = false;
    var tests_finished = false;
    var failed = false;
    var local: u64 = 0;
    var unreadable = false;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const c = content(raw);
        if (std.mem.startsWith(u8, c, "Commands: ")) {
            summaries += 1;
            if (localCount(c)) |n| {
                local += n;
            } else {
                unreadable = true;
            }
        } else if (isZeroNetwork(c)) {
            zero_network = true;
        } else if (std.mem.startsWith(u8, c, "Cache hits: ")) {
            cache_hits_line = true;
        } else if (std.mem.startsWith(u8, c, "Tests finished: ")) {
            tests_finished = true;
        } else if (std.mem.eql(u8, c, "BUILD FAILED") or std.mem.eql(u8, c, "BXL FAILED")) {
            failed = true;
        }
    }
    if (failed) return .run_failed;
    if (unreadable) return .unreadable_summary;
    if (local != 0) return .{ .local_execution = local };
    if (summaries == 0) {
        const no_build_action = zero_network or (tests_finished and !cache_hits_line);
        if (!no_build_action) return .missing_summary;
    }
    return .ok;
}

pub fn describe(v: Verdict, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .ok => try w.writeAll("assert_remote: ok (no local execution)\n"),
        .local_execution => |n| try w.print("assert_remote: FAILED: {d} action(s) ran locally (`local: {d}` in the Commands summary); builds go through the farm\n", .{ n, n }),
        .unreadable_summary => try w.writeAll("assert_remote: FAILED: a `Commands:` line has no `local: N` field; buck2's summary changed shape\n"),
        .missing_summary => try w.writeAll("assert_remote: FAILED: no `Commands:` summary line, and the log does not show that no build action ran; cannot show it was remote\n"),
        .run_failed => try w.writeAll("assert_remote: FAILED: the log ends a failed buck2 run (BUILD FAILED / BXL FAILED)\n"),
    }
}

/// The largest log the tool reads. A step that runs every test of a large affected set prints each test's output: the log of one such
/// pull request was 530 MB, almost all of it the lines of one package's timing test, and a cap of 256 MiB made the assertion fail on a
/// green run (`FileTooBig`). A log over the cap is still refused, so a run is never passed unread.
pub const max_log_bytes: usize = 2048 * 1024 * 1024;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&buf);
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 2) {
        try err.interface.writeAll("usage: assert_remote <log-file>\n");
        try err.interface.flush();
        return 2;
    }
    const log = std.fs.cwd().readFileAlloc(a, args[1], max_log_bytes) catch |e| {
        try err.interface.print("assert_remote: cannot read {s}: {s}\n", .{ args[1], @errorName(e) });
        try err.interface.flush();
        return 2;
    };
    defer a.free(log);
    const v = verdict(log);
    try describe(v, &err.interface);
    try err.interface.flush();
    return if (v == .ok) 0 else 1;
}
