//! config_refusals: buckconfig values refused at load, each with its exact
//! message: `komira.coverage` and `komira.mutation` other than true or false
//! (coverage.bzl, mutation.bzl), and `komira.test_timeout_s` that is not a
//! whole number or not over the 60 s margin (test_limit.bzl). Catches any
//! value but true read as false, and the margin's `<=` made `<`.
//!
//! And the command `buck2 test` runs for a time-limited `mojo_test`: under
//! `komira.test_timeout_s=90` its provider dump names `--deadline-s 30` and
//! `--runner-timeout-s 90` (test_limit.bzl). The test itself is never run:
//! that it is killed at its limit is the gate's tests (tools/build/run),
//! and that the gate is handed the limit is this. Catches `deadline_prefix`
//! returning nothing, or the margin not taken off.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "coverage_switch_yes",
        .target = "tests//functional/coverage:covlib",
        .text = "[komira] coverage = \"yes\": it must be `true` or `false` (default false); it turns on the coverage build of every mojo_library (tools/build/mojo/README.md, Coverage builds)",
        .cfg = &.{ "komira.coverage=yes" },
    },
    .{
        .name = "test_deadline_bad_abc",
        .target = "tests//negative/test_deadline:test_slow",
        .text = "[komira] test_timeout_s = \"abc\" is not a whole number of seconds",
        .cfg = &.{ "komira.test_timeout_s=abc" },
    },
    .{
        .name = "test_deadline_bad_60",
        .target = "tests//negative/test_deadline:test_slow",
        .text = "[komira] test_timeout_s = 60 must be over 60 s: a mojo_test is stopped 60 s before it",
        .cfg = &.{ "komira.test_timeout_s=60" },
    },
    .{
        .name = "mutation_switch_yes",
        .target = "tests//functional/coverage:covlib",
        .text = "[komira] mutation = \"yes\": it must be `true` or `false` (default false)",
        .cfg = &.{ "komira.mutation=yes" },
    },
};

const LIMITED = "tests//negative/test_deadline:test_slow";
const WANT = "\"--deadline-s\", \"30\", \"--runner-timeout-s\", \"90\"";

/// `text` with every run of white space (the dump wraps its lines) one space.
fn squeezed(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, w);
    }
    return out.items;
}

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
    const r = try c.run(&.{ "audit", "providers", LIMITED }, .{ .cfg = &.{"komira.test_timeout_s=90"} });
    if (!r.ok()) {
        c.fail("test_deadline_command: buck2 audit providers {s} failed (see {s})", .{ LIMITED, r.log });
        return;
    }
    if (std.mem.indexOf(u8, try squeezed(c.a, r.stdout), WANT) == null) {
        c.fail("test_deadline_command: the test command of {s} under komira.test_timeout_s=90 lacks {s} (see {s})", .{ LIMITED, WANT, r.log });
    } else {
        c.pass("test_deadline_command: {s} is run by `buck2 test` with {s}", .{ LIMITED, WANT });
    }
}

pub fn main() u8 {
    return lib.main(body);
}
