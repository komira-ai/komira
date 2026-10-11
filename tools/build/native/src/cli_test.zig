//! The cases of cli.zig: each mode's flags, and the exit code and output of a
//! command that cannot run.

const std = @import("std");
const P = @import("prefix.zig");
const M = @import("cli.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn expectFail(r: anytype, want: []const u8) !void {
    if (r) |_| {
        std.debug.print("want the refusal: {s}\n", .{want});
        return error.TestUnexpectedResult;
    } else |_| try eqs(want, P.msg);
}

const header_ok = [_][]const u8{ "prefix_tool", "header", "--elfsyms", "e", "--archive", "l.a", "--header", "h", "--symbols", "s", "--style", "strip", "--prefix", "k_", "--min", "5" };
const check_ok = [_][]const u8{ "prefix_tool", "check", "--elfsyms", "./no-such-elfsyms", "--archive", "l.a", "--result", "r", "--prefix", "k_", "--min", "5" };

fn with(base: []const []const u8, more: []const []const u8) []const []const u8 {
    return std.mem.concat(P.a(), []const u8, &.{ base, more }) catch unreachable;
}

test "args: header and check, repeated flags kept in order" {
    const h = try M.Args.parse(with(&header_ok, &.{ "--extra", "b", "--strip", "s_", "--extra", "a" }));
    try eqs("header", h.mode);
    try eqs("s_", h.get("--strip"));
    try expect(h.list("--extra").len == 2);
    try eqs("b", h.list("--extra")[0]);
    try eqs("a", h.list("--extra")[1]);
    try expect((try h.min()) == 5);
    const c = try M.Args.parse(with(&check_ok, &.{ "--names", "n1", "--allow", "_Z*", "--names", "n2" }));
    try eqs("n2", c.list("--names")[1]);
    try eqs("_Z*", c.list("--allow")[0]);
    try expect(c.list("--extra").len == 0);
}

test "args: refusals" {
    try expectFail(M.Args.parse(&.{"prefix_tool"}), "prefix_tool: no mode");
    try expectFail(M.Args.parse(&.{ "prefix_tool", "nm" }), "prefix_tool: unknown mode nm");
    try expectFail(M.Args.parse(header_ok[0 .. header_ok.len - 2]), "prefix_tool header: --min is required");
    try expectFail(M.Args.parse(with(&header_ok, &.{"--extra"})), "prefix_tool: --extra needs a value");
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--prefix", "j_" })), "prefix_tool: --prefix given twice");
    // Each mode takes only its own flags.
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--allow", "x" })), "prefix_tool header: unknown flag --allow");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--extra", "x" })), "prefix_tool check: unknown flag --extra");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--strip", "x" })), "prefix_tool check: unknown flag --strip");
    const m = try M.Args.parse(with(header_ok[0 .. header_ok.len - 2], &.{ "--min", "-1" }));
    try expectFail(m.min(), "prefix_tool: --min -1 is not a number");
}

test "outcome: bad arguments exit 2 with the usage; a refusal exits 1" {
    const o = M.outcome(&.{ "prefix_tool", "nm" }, "/w");
    try expect(o.code == 2);
    try eqs("prefix_tool: unknown mode nm\n" ++ M.usage, o.stderr);
    const s = M.outcome(with(header_ok[0 .. header_ok.len - 6], &.{ "--style", "nope", "--prefix", "k_", "--min", "1" }), "/w");
    try expect(s.code == 1);
    try eqs("prefix_tool: unknown style nope\n", s.stderr);
    // elfsyms that cannot be run fails the command, before anything is written.
    const e = M.outcome(&check_ok, "/w");
    try expect(e.code == 1);
    try expect(std.mem.startsWith(u8, e.stderr, "prefix_tool: "));
}

test "outcome: messages name the archive by its absolute path" {
    try eqs("/w/buck-out/l.a", M.shown("/w", "buck-out/l.a"));
    try eqs("/abs/l.a", M.shown("/w", "/abs/l.a"));
}
