//! rerun: `-c komira.rerun=<label>#<n>` re-runs exactly the named target's
//! test actions (tools/build/rerun/README.md).
//!
//! 1. One target of each rule whose actions run a test (KINDS), and one test
//!    target never named (CONTROL), are built without the flag, then with
//!    the flag naming the first kind's target, then with it naming every
//!    kind's target, each with an <n> no build used before. In one daemon
//!    `log what-ran` lists only the actions whose key changed. After each
//!    flagged build it must list only actions of the named targets, each
//!    executed on the farm (not a cache hit), and in the second at least one
//!    of every kind. Catches the helper salting every target (an unnamed
//!    target's test action is listed) and a rule that does not call
//!    rerun_env (its kind re-runs nothing).
//! 2. `buck2 test`'s command of a mojo_test and of a rust_test carries
//!    `KOMIRA_RERUN` when the flag names it, and not when it names another
//!    target.
//! 3. Values refused at analysis, each with its message: `#x`, no `#<n>`, no
//!    cell, a sub-target, a label named twice; by
//!    `tools/build/rerun/check.bxl`, an unknown label and a target that runs
//!    no test action, while it accepts two test targets.
const std = @import("std");
const lib = @import("lib/lib.zig");

const Kind = struct { rule: []const u8, target: []const u8 };

const KINDS = [_]Kind{
    .{ .rule = "mojo_library test_srcs", .target = "komira//tools/build/examples/libgate_ok:libgate_ok" },
    .{ .rule = "mojo_library README examples", .target = "tests//functional/readme_examples/ok:ok" },
    .{ .rule = "mojo_binary run check", .target = "komira//tools/build/examples:hello" },
    .{ .rule = "mojo_shared_lib gate", .target = "komira//tools/build/examples/shared_lib:plain" },
    .{ .rule = "rust_test", .target = "komira//tools/build/examples/rust/ext:ext_unit" },
    .{ .rule = "rust_library test_srcs", .target = "komira//tools/build/examples/rust/ext:ext" },
    .{ .rule = "rust_binary run check", .target = "komira//tools/build/examples/rust/ext:ext_consumer" },
    .{ .rule = "zig_test", .target = "komira//tools/build/markdown:markdown_unit" },
    .{ .rule = "node_test", .target = "komira//src/tests/helpers/komira_test_node:isolation" },
    .{ .rule = "py_test", .target = "komira//release/ci/tests:test_derive_checks" },
    .{ .rule = "launcher_level_test", .target = "komira//tools/build/package:level_test" },
    .{ .rule = "release_order_test", .target = "komira//tools/build/package:release_order_passes_a_longer_name" },
    .{ .rule = "kcov_guard_cases", .target = "komira//tools/build/package:kcov_guard_cases" },
    .{ .rule = "kcov_tool_cases", .target = "komira//tools/build/coverage/kcov:cov_zig_cases" },
    .{ .rule = "coverage_ci_cases", .target = "komira//:coverage_ci_cases" },
    .{ .rule = "proto_fixture_case", .target = "komira//tools/build/mojo/proto_fixture_testdata:accepts" },
    .{ .rule = "proto_check_case", .target = "komira//tools/vendor/googleapis:proto_check_accepts" },
};

/// Test rules whose `buck2 test` command (ExternalRunnerTestInfo) takes the variable.
const RUNNER_TESTS = [_]Kind{
    .{ .rule = "mojo_test", .target = "komira//tools/build/examples:test_hellopkg" },
    .{ .rule = "rust_test", .target = "komira//tools/build/examples/rust/ext:ext_unit" },
};

const HELLO = "komira//tools/build/examples:hello";
const CHECK = "//tools/build/rerun/check.bxl:check";

// check.bxl over `-c komira.rerun`: the value, and the text its output must
// hold (null: it must pass).
const BxlRow = struct { name: []const u8, value: []const u8, text: ?[]const u8, also: []const u8 = "" };

const BXL_ROWS = [_]BxlRow{
    .{
        .name = "rerun_check_known",
        .value = "komira//release/ci/tests:test_derive_checks#3,tests//functional/readme_examples/ok:ok#4",
        .text = null,
        .also = "rerun: tests//functional/readme_examples/ok:ok runs its test actions again with KOMIRA_RERUN=4",
    },
    .{
        .name = "rerun_unknown_label",
        .value = "komira//tools/build/examples:hello_nope#1",
        .text = "Unknown target `hello_nope` from package `komira//tools/build/examples`",
        .also = "tools/build/rerun/check.bxl",
    },
    .{
        .name = "rerun_not_a_test",
        .value = "komira//:LICENSE#1",
        .text = "[komira] rerun names komira//:LICENSE, which runs no test action: its rule does not call rerun_env (tools/build/rerun/README.md lists the rules that do)",
    },
};

fn bxlRows(c: *lib.Ctx) !void {
    for (BXL_ROWS) |row| {
        const cfg = try std.fmt.allocPrint(c.a, "komira.rerun={s}", .{row.value});
        const res = try c.run(&.{ "bxl", CHECK }, .{ .cfg = &.{cfg} });
        const out_has = lib.text.contains(res.stdout, row.also) or lib.text.contains(res.stderr, row.also);
        if (row.text) |want| {
            const also = [_][]const u8{row.also};
            const v = lib.refusals.verdict(res.ok(), res.stdout, res.stderr, want, if (row.also.len > 0) also[0..] else also[0..0]);
            c.rep.check(v == .refused, try std.fmt.allocPrint(c.a, "{s}: check.bxl refuses -c {s} with `{s}`", .{ row.name, cfg, want }), res.log);
        } else {
            c.rep.check(res.ok() and out_has, try std.fmt.allocPrint(c.a, "{s}: check.bxl accepts -c {s}", .{ row.name, cfg }), res.log);
        }
    }
}

const ROWS = [_]lib.Row{
    .{
        .name = "rerun_not_a_number",
        .target = HELLO,
        .text = "[komira] rerun = \"komira//tools/build/examples:hello#x\": the entry \"komira//tools/build/examples:hello#x\": `x` is not a whole number from 1",
        .cfg = &.{"komira.rerun=komira//tools/build/examples:hello#x"},
    },
    .{
        .name = "rerun_no_number",
        .target = HELLO,
        .text = "[komira] rerun = \"komira//tools/build/examples:hello\": the entry \"komira//tools/build/examples:hello\" has no `#<n>`; give `<cell>//<package>:<name>#<n>`",
        .cfg = &.{"komira.rerun=komira//tools/build/examples:hello"},
    },
    .{
        .name = "rerun_no_cell",
        .target = HELLO,
        .text = "[komira] rerun = \"//tools/build/examples:hello#1\": the entry \"//tools/build/examples:hello#1\": name the cell, as `komira//tools/build/examples:hello` or `<cell>//tools/build/examples:hello`",
        .cfg = &.{"komira.rerun=//tools/build/examples:hello#1"},
    },
    .{
        .name = "rerun_sub_target",
        .target = HELLO,
        .text = "[komira] rerun = \"komira//tools/build/examples:hello[run_check]#1\": the entry \"komira//tools/build/examples:hello[run_check]#1\": name the target, without a sub-target or a configuration",
        .cfg = &.{"komira.rerun=komira//tools/build/examples:hello[run_check]#1"},
    },
    .{
        .name = "rerun_named_twice",
        .target = HELLO,
        .text = "[komira] rerun = \"komira//tools/build/examples:hello#1,komira//tools/build/examples:hello#2\": komira//tools/build/examples:hello is named twice",
        .cfg = &.{"komira.rerun=komira//tools/build/examples:hello#1,komira//tools/build/examples:hello#2"},
    },
};

/// A test target no build here names: its actions must never change key.
const CONTROL = "komira//tools/build/markdown:importer_unit";

fn build(c: *lib.Ctx, cfg: []const []const u8) !lib.runner.Result {
    var words = std.ArrayList([]const u8).init(c.a);
    try words.append("build");
    for (KINDS) |k| try words.append(k.target);
    try words.append(CONTROL);
    return c.run(words.items, .{ .cfg = cfg, .timeout_s = 1200 });
}

/// An <n> no earlier build used: a fresh key, so the action cannot be a
/// cache hit of an earlier run.
fn fresh(c: *lib.Ctx) ![]const u8 {
    return std.fmt.allocPrint(c.a, "{d}", .{std.time.nanoTimestamp()});
}

/// Builds every target with `-c komira.rerun=<value>`; the what-ran of
/// that build, or null (failed, reported).
fn flagged(c: *lib.Ctx, what: []const u8, value: []const u8) !?[]const u8 {
    const flag = try std.fmt.allocPrint(c.a, "komira.rerun={s}", .{value});
    const res = try build(c, &.{flag});
    if (!res.ok()) {
        c.fail("{s}: the build with -c {s} failed (see {s})", .{ what, flag, res.log });
        return null;
    }
    const wr = try c.run(&.{ "log", "what-ran" }, .{ .configured = false });
    if (!wr.ok()) {
        c.fail("{s}: cannot read what-ran (see {s})", .{ what, wr.log });
        return null;
    }
    return wr.stdout;
}

fn verdict(c: *lib.Ctx, what: []const u8, v: lib.whatran.Rerun) void {
    if (v.others > 0) {
        c.fail("{s}: {d} action(s) of targets it does not name changed key, first {s}", .{ what, v.others, v.first_other.? });
    } else if (v.stale > 0) {
        c.fail("{s}: {d} action(s) of a named target did not execute on the farm, first {s}", .{ what, v.stale, v.first_stale.? });
    } else if (v.ran == 0) {
        c.fail("{s}: no action re-ran", .{what});
    } else {
        c.pass("{s}: only the named targets' test actions re-ran ({d}, on the farm)", .{ what, v.ran });
    }
}

/// The warm build, then (1) the flag naming one target: in one daemon only
/// an action whose key changed is listed by what-ran, so another target's
/// action listed is the flag salting it; (2) the flag naming every kind's
/// target at once: each must have re-run an action on the farm, so a rule
/// that does not call rerun_env is red; CONTROL is in both builds, unnamed.
fn kinds(c: *lib.Ctx) !void {
    const warm = try build(c, &.{});
    if (!warm.ok()) {
        c.fail("warm: the build without -c komira.rerun failed (see {s})", .{warm.log});
        return;
    }
    var why: []const u8 = "";
    _ = c.r.checkWhatRan(null, &why) catch {
        c.fail("warm: {s}", .{why});
        return;
    };

    const one = KINDS[0].target;
    const v1 = try std.fmt.allocPrint(c.a, "{s}#{s}", .{ one, try fresh(c) });
    if (try flagged(c, "one named", v1)) |wr| {
        verdict(c, try std.fmt.allocPrint(c.a, "one named ({s})", .{v1}), lib.whatran.rerun(wr, &.{one}));
    }

    var labels = std.ArrayList([]const u8).init(c.a);
    var entries = std.ArrayList([]const u8).init(c.a);
    const n = try fresh(c);
    for (KINDS) |k| {
        try labels.append(k.target);
        try entries.append(try std.fmt.allocPrint(c.a, "{s}#{s}", .{ k.target, n }));
    }
    const all = try lib.text.join(c.a, entries.items, ",");
    if (try flagged(c, "every kind named", all)) |wr| {
        verdict(c, "every kind named", lib.whatran.rerun(wr, labels.items));
        for (KINDS) |k| {
            const ran = lib.whatran.ranOf(wr, k.target);
            if (ran > 0) {
                c.pass("{s}: {s} re-ran {d} test action(s) on the farm", .{ k.rule, k.target, ran });
            } else {
                c.fail("{s}: {s} re-ran nothing: its rule does not add KOMIRA_RERUN to its test actions", .{ k.rule, k.target });
            }
        }
    }
}

fn runnerEnv(c: *lib.Ctx) !void {
    for (RUNNER_TESTS) |k| {
        const n = try fresh(c);
        const want = try std.fmt.allocPrint(c.a, "\"KOMIRA_RERUN\": \"{s}\"", .{n});
        const named = try std.fmt.allocPrint(c.a, "komira.rerun={s}#{s}", .{ k.target, n });
        const r1 = try c.run(&.{ "audit", "providers", k.target }, .{ .cfg = &.{named} });
        c.rep.check(r1.ok() and lib.text.contains(r1.stdout, want), try std.fmt.allocPrint(c.a, "{s}: the buck2 test command of {s} has KOMIRA_RERUN={s} when -c komira.rerun names it", .{ k.rule, k.target, n }), r1.log);
        const other = try std.fmt.allocPrint(c.a, "komira.rerun={s}#{s}", .{ HELLO, n });
        const r2 = try c.run(&.{ "audit", "providers", k.target }, .{ .cfg = &.{other} });
        c.rep.check(r2.ok() and !lib.text.contains(r2.stdout, "KOMIRA_RERUN"), try std.fmt.allocPrint(c.a, "{s}: the buck2 test command of {s} has no KOMIRA_RERUN when -c komira.rerun names another target", .{ k.rule, k.target }), r2.log);
    }
}

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
    try bxlRows(c);
    try runnerEnv(c);
    try kinds(c);
}

pub fn main() u8 {
    return lib.main(body);
}
