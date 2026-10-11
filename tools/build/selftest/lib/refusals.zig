//! Refusal tables: targets that must fail analysis (or load), each with the
//! exact message it must fail with.
//!
//! A row runs `buck2 audit providers <target>` (analysis only: nothing is
//! built) with its `-c` pairs. It passes when the command fails and its
//! output holds the row's text, byte for byte. "Analysed but must fail" and
//! "failed without the text" are distinct failures, each naming the log.
const std = @import("std");
const Runner = @import("runner.zig").Runner;
const Report = @import("expect.zig").Report;
const text = @import("text.zig");

pub const Row = struct {
    /// The case's name in PASS/FAIL lines.
    name: []const u8,
    target: []const u8,
    /// The message, as the rule's `fail()` writes it.
    text: []const u8,
    /// More text the output must hold, each exactly: the parts of a message
    /// that buck2 interrupts with a configuration hash.
    also: []const []const u8 = &.{},
    cfg: []const []const u8 = &.{},
    /// A scratch tree's root to run in (null: the checkout).
    cwd: ?[]const u8 = null,
};

pub const Verdict = enum { refused, analysed, other_failure };

/// What a refusal command's result means for its row.
pub fn verdict(exit_ok: bool, output_stdout: []const u8, output_stderr: []const u8, want: []const u8, also: []const []const u8) Verdict {
    if (exit_ok) return .analysed;
    if (!holds(output_stdout, output_stderr, want)) return .other_failure;
    for (also) |w| if (!holds(output_stdout, output_stderr, w)) return .other_failure;
    return .refused;
}

fn holds(out: []const u8, err: []const u8, want: []const u8) bool {
    return want.len > 0 and (text.contains(err, want) or text.contains(out, want));
}

pub fn runRow(r: *Runner, rep: *Report, row: Row) !void {
    const res = try r.run(&.{ "audit", "providers", row.target }, .{ .cfg = row.cfg, .cwd = row.cwd });
    switch (verdict(res.ok(), res.stdout, res.stderr, row.text, row.also)) {
        .refused => rep.pass("{s}: {s} is refused: {s}", .{ row.name, row.target, row.text }),
        .analysed => rep.fail("{s}: {s} was analysed, but it must be refused with `{s}` (see {s})", .{ row.name, row.target, row.text, res.log }),
        .other_failure => rep.fail("{s}: {s} failed without `{s}` (see {s}); its last lines:\n{s}", .{ row.name, row.target, row.text, res.log, text.tail(res.stderr, 12) }),
    }
}

pub fn run(r: *Runner, rep: *Report, rows: []const Row) !void {
    if (rows.len == 0) {
        rep.fail("the refusal table is empty", .{});
        return;
    }
    for (rows) |row| try runRow(r, rep, row);
}
