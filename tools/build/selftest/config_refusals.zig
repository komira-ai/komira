//! config_refusals: buckconfig values refused at load, each with its exact
//! message: `komira.coverage` and `komira.mutation` other than true or false
//! (coverage.bzl, mutation.bzl), and `komira.test_timeout_s` that is not a
//! whole number or not over the 60 s margin (test_limit.bzl). Catches any
//! value but true read as false, and the margin's `<=` made `<`.
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

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
