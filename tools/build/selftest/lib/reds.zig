//! Planted-red tables: targets whose build must fail in an action, each with
//! text its failure must print.
//!
//! A row runs `buck2 build <target>` with its `-c` pairs. It passes when the
//! build fails, its output holds the row's text byte for byte, and
//! `buck2 log what-ran` lists the actions the build ran, all on the farm. A
//! target that builds, a failure without the text, and a failure before any
//! action ran (an analysis refusal: those rows belong in a refusal table,
//! refusals.zig) are distinct failures, each naming the log.
const std = @import("std");
const Runner = @import("runner.zig").Runner;
const Report = @import("expect.zig").Report;
const refusals = @import("refusals.zig");
const text = @import("text.zig");

pub const Row = refusals.Row;

pub fn runRow(r: *Runner, rep: *Report, row: Row) !void {
    const res = try r.run(&.{ "build", row.target }, .{ .cfg = row.cfg, .cwd = row.cwd });
    switch (refusals.verdict(res.ok(), res.stdout, res.stderr, row.text, row.also)) {
        .analysed => {
            rep.fail("{s}: {s} built, but it must fail with `{s}` (see {s})", .{ row.name, row.target, row.text, res.log });
            return;
        },
        .other_failure => {
            rep.fail("{s}: {s} failed without `{s}` (see {s}); its last lines:\n{s}", .{ row.name, row.target, row.text, res.log, text.tail(res.stderr, 12) });
            return;
        },
        .refused => {},
    }
    var why: []const u8 = "";
    const n = r.checkWhatRan(row.cwd, &why) catch |e| switch (e) {
        error.WhatRan => {
            rep.fail("{s}: {s} failed with `{s}`, but not in an action on the farm: {s}", .{ row.name, row.target, row.text, why });
            return;
        },
        else => return e,
    };
    rep.pass("{s}: {s} fails in an action ({d} ran, all on the farm): {s}", .{ row.name, row.target, n, row.text });
}

pub fn run(r: *Runner, rep: *Report, rows: []const Row) !void {
    if (rows.len == 0) {
        rep.fail("the planted-red table is empty", .{});
        return;
    }
    for (rows) |row| try runRow(r, rep, row);
}
