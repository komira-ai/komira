//! planted_red_builds_mojo_hang: the hang limit of a library's welded tests
//! (`test_hang_limit_s`, `gate mojo --hang-limit-s`; tools/build/mojo/README.md,
//! "Time limits"). Two checks:
//!
//!   - a welded test that blocks forever, on a target that sets its limit to
//!     5 s, fails in its action on the farm with the gate's banner and the
//!     hang line, naming the test and the limit it did not finish within
//!     (tests//negative/mojo_hang). Catches a limit that is not handed to the
//!     gate, a gate that does not stop the test, and a verdict that does not
//!     say the test hung;
//!   - the gated test action's command carries `--hang-limit-s 1800` on a
//!     target that sets nothing and `--hang-limit-s 5` on one that sets 5
//!     (tests//functional/mojo_hang, aquery), and both build: a test that
//!     ends is unchanged by the limit. Catches a default that is not 1800, an
//!     override that is ignored, and a limit that fails a passing test.
//!
//! The limit itself is exercised on a clock the gate's tests move
//! (tools/build/run); this scenario never waits for it on a test's behalf
//! beyond the 5 s the fixture's own limit takes to expire.
const std = @import("std");
const lib = @import("lib/lib.zig");

const NEG = "tests//negative/mojo_hang:lib_never_ends";
const FUN = "tests//functional/mojo_hang:";

const ROWS = [_]lib.Row{
    .{
        .name = "hang_limit_stops_a_blocked_test",
        .target = NEG,
        .text = "hang limit: " ++ NEG ++ ":tests/test_never_ends.mojo did not finish within 5 s and was stopped; a test never waits on time, so this means it hung (an event that never came)",
        .also = &.{
            "GATED TEST FAILED: " ++ NEG ++ ":tests/test_never_ends.mojo (exit 137)",
            "HANG_FIXTURE start 42",
        },
    },
};

/// `text` without white space (aquery pretty-prints the command's list).
fn squeezed(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (text) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') try out.append(a, ch);
    }
    return out.items;
}

/// `flat` holds `word` as a whole argument: the next character ends it.
fn followedByEnd(flat: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, flat, from, word)) |i| {
        const n = i + word.len;
        if (n < flat.len and (flat[n] == ',' or flat[n] == ']')) return true;
        from = i + 1;
    }
    return false;
}

/// The gated test action of `target` carries `--hang-limit-s <want>`, and no
/// other value of it.
fn limitOf(c: *lib.Ctx, name: []const u8, target: []const u8, want: []const u8, other: []const u8) !void {
    const q = try std.fmt.allocPrint(c.a, "deps({s})", .{target});
    const r = try c.run(&.{ "aquery", q, "--output-attribute", "cmd" }, .{});
    if (!r.ok()) {
        c.fail("{s}: buck2 aquery {s} failed (see {s})", .{ name, q, r.log });
        return;
    }
    const flat = try squeezed(c.a, r.stdout);
    // aquery prints the command as `[a, b, --hang-limit-s, 1800]`.
    const have = try std.fmt.allocPrint(c.a, "--hang-limit-s,{s}", .{want});
    const not = try std.fmt.allocPrint(c.a, "--hang-limit-s,{s}", .{other});
    if (!followedByEnd(flat, have)) {
        c.fail("{s}: the commands of {s} lack {s} (see {s})", .{ name, target, have, r.log });
    } else if (followedByEnd(flat, not)) {
        c.fail("{s}: the commands of {s} carry {s} as well (see {s})", .{ name, target, not, r.log });
    } else {
        c.pass("{s}: the welded test of {s} runs with {s}", .{ name, target, have });
    }
}

fn builds(c: *lib.Ctx, name: []const u8, target: []const u8) !void {
    const r = try c.run(&.{ "build", target }, .{});
    if (r.ok()) {
        c.pass("{s}: {s} builds, its test ended before its limit", .{ name, target });
    } else {
        c.fail("{s}: {s} failed (see {s}); its last lines:\n{s}", .{ name, target, r.log, r.stderr[r.stderr.len -| 800..] });
    }
}

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
    try limitOf(c, "hang_limit_default", FUN ++ "lib_default_limit", "1800", "5");
    try limitOf(c, "hang_limit_override", FUN ++ "lib_override_limit", "5", "1800");
    try builds(c, "hang_limit_default_builds", FUN ++ "lib_default_limit");
    try builds(c, "hang_limit_override_builds", FUN ++ "lib_override_limit");
}

pub fn main() u8 {
    return lib.main(body);
}
