//! graph_check_refusals: the graph checks over planted graphs
//! (tools/build/tests/negative/python_closure). Each row runs `buck2 bxl
//! //tools/build/selftest/graph/checks.bxl:check -- --check <target>`: a
//! refused row passes when the command fails and its output holds the
//! row's text exactly; an accepted row passes when it succeeds.
//!
//!   - exec_dep: a target reaching a Python rule only through an exec
//!     dependency is refused. Catches the BXL's closure or a node's
//!     dependencies narrowed to target dependencies.
//!   - exec_dep_in_ceiling: the same graph with each finding in the ceiling
//!     passes, so exec_dep is refused for its findings alone.
//!   - stale_ceiling: a ceiling entry the check no longer finds is refused.
//!     Catches the ceiling read as a cap rather than as exact.
const std = @import("std");
const lib = @import("lib/lib.zig");

const CHECK = "//tools/build/selftest/graph/checks.bxl:check";
const PKG = "tests//negative/python_closure:";

const Case = struct {
    name: []const u8,
    /// Null: the check must pass.
    text: ?[]const u8,
};

const CASES = [_]Case{
    .{ .name = "exec_dep", .text = "python_closure: target tests//negative/python_closure:lib: its closure holds tests//negative/python_closure:interpreter: it is a Python rule (python_stand_in)" },
    .{ .name = "exec_dep_in_ceiling", .text = null },
    .{ .name = "stale_ceiling", .text = "python_closure: the ceiling entry `target tests//negative/python_closure:lib` is no longer found" },
};

fn body(c: *lib.Ctx) !void {
    for (CASES) |k| {
        const target = try std.fmt.allocPrint(c.a, "{s}{s}", .{ PKG, k.name });
        const res = try c.run(&.{ "bxl", CHECK, "--", "--check", target }, .{});
        if (k.text) |want| {
            if (res.ok()) {
                c.fail("{s}: the check passed, but it must refuse `{s}` (see {s})", .{ target, want, res.log });
            } else if (lib.text.contains(res.stderr, want) or lib.text.contains(res.stdout, want)) {
                c.pass("{s} is refused: {s}", .{ target, want });
            } else {
                c.fail("{s} failed without `{s}` (see {s}); its last lines:\n{s}", .{ target, want, res.log, lib.text.tail(res.stderr, 12) });
            }
        } else if (res.ok()) {
            c.pass("{s} passes", .{target});
        } else {
            c.fail("{s} must pass (see {s}); its last lines:\n{s}", .{ target, res.log, lib.text.tail(res.stderr, 12) });
        }
    }
}

pub fn main() u8 {
    return lib.main(body);
}
