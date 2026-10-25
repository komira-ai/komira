//! The process behaviour of `fresh` (tools/build/gen/fresh.zig), the action of every
//! `<name>_fresh`: green only when the committed directory is what the generator
//! wrote, red for each way it is not, with the command that regenerates it.
const std = @import("std");
const kit = @import("driver_kit");
const t = std.testing;
const has = kit.has;

const regen = "./buck2 run komira//tools/build/gen:regen -- komira//src/svc:svc";

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "FRESH");
}

/// A generator output and a committed directory that are equal.
fn inSync(c: *kit.Ctx) !void {
    for ([_][]const u8{ "gen", "committed" }) |d| {
        try c.write(try std.fmt.allocPrint(c.alloc(), "{s}/__init__.mojo", .{d}), "# @generated\n", 0o644);
        try c.write(try std.fmt.allocPrint(c.alloc(), "{s}/svc.mojo", .{d}), "struct A:\n    pass\n", 0o644);
        try c.write(try std.fmt.allocPrint(c.alloc(), "{s}/_layout_probe.mojo", .{d}), "probe\n", 0o644);
    }
}

fn runFresh(c: *kit.Ctx) !kit.Result {
    return c.run(&.{ "--gen", "gen", "--committed", "committed", "--label", "komira//src/svc:svc", "--dir", "src/svc/generated/svc", "--regen", regen, "--out", "stamp" }, &.{});
}

fn expectRedWithCommand(r: kit.Result) !void {
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.stderr, "the committed generated sources of komira//src/svc:svc are out of date (src/svc/generated/svc/)"));
    try t.expect(has(r.stderr, "Regenerate with:\n    " ++ regen ++ "\nand commit src/svc/generated/svc/.\n"));
}

test "a committed directory equal to the generator's output is green, and leaves the marker" {
    var c = try newCtx("in_sync");
    defer c.deinit();
    try inSync(&c);
    const r = try runFresh(&c);
    if (r.code != 0) std.debug.print("[fresh stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.stderr);
    try t.expect(c.exists("stamp"));
}

test "a hand edit to a committed generated file is red, names the file and the line, leaves no marker" {
    var c = try newCtx("hand_edit");
    defer c.deinit();
    try inSync(&c);
    try c.write("committed/svc.mojo", "struct A:\n    var x: Int\n", 0o644);
    const r = try runFresh(&c);
    try expectRedWithCommand(r);
    try t.expect(has(r.stderr, "differs: svc.mojo, first at line 2:\n    committed:     var x: Int\n    generated:     pass\n"));
    try t.expect(!has(r.stderr, "missing"));
    try t.expect(!has(r.stderr, "stale"));
    try t.expect(!c.exists("stamp"));
}

test "a committed file that is missing is red and named" {
    var c = try newCtx("missing");
    defer c.deinit();
    try inSync(&c);
    try std.fs.cwd().deleteFile(try c.path("committed/_layout_probe.mojo"));
    const r = try runFresh(&c);
    try expectRedWithCommand(r);
    try t.expect(has(r.stderr, "missing, generated now but not committed: _layout_probe.mojo\n"));
    try t.expect(!c.exists("stamp"));
}

test "an extra committed file the generator does not write is red and named" {
    var c = try newCtx("stale");
    defer c.deinit();
    try inSync(&c);
    try c.write("committed/old_module.mojo", "x\n", 0o644);
    try c.write("committed/nested/deep.mojo", "x\n", 0o644);
    const r = try runFresh(&c);
    try expectRedWithCommand(r);
    try t.expect(has(r.stderr, "stale, committed but no longer generated: nested/deep.mojo\n"));
    try t.expect(has(r.stderr, "stale, committed but no longer generated: old_module.mojo\n"));
    try t.expect(!c.exists("stamp"));
}

test "a change of the generator's output (a model, an attribute or the generator itself) with the commit left alone is red" {
    var c = try newCtx("generator_moved");
    defer c.deinit();
    try inSync(&c);
    // The output now has another operation and a new module; the commit is as it was.
    try c.write("gen/svc.mojo", "struct A:\n    pass\nstruct B:\n    pass\n", 0o644);
    try c.write("gen/new_module.mojo", "y\n", 0o644);
    const r = try runFresh(&c);
    try expectRedWithCommand(r);
    try t.expect(has(r.stderr, "differs: svc.mojo, first at line 3:"));
    try t.expect(has(r.stderr, "missing, generated now but not committed: new_module.mojo\n"));
    try t.expect(!c.exists("stamp"));
}

test "a committed directory with nothing in it is red for every generated file" {
    var c = try newCtx("empty_commit");
    defer c.deinit();
    try inSync(&c);
    try std.fs.cwd().deleteTree(try c.path("committed"));
    try c.mkdir("committed");
    const r = try runFresh(&c);
    try expectRedWithCommand(r);
    try t.expect(has(r.stderr, "missing, generated now but not committed: __init__.mojo\n"));
    try t.expect(has(r.stderr, "missing, generated now but not committed: svc.mojo\n"));
}

test "a stale marker from an earlier green run does not make a red run green" {
    var c = try newCtx("old_marker");
    defer c.deinit();
    try inSync(&c);
    const first = try runFresh(&c);
    try t.expectEqual(@as(u8, 0), first.code);
    try c.write("committed/svc.mojo", "edited\n", 0o644);
    const r = try runFresh(&c);
    try t.expectEqual(@as(u8, 1), r.code);
}

test "usage errors exit 2: a missing flag, an unknown flag, a directory that is not there" {
    var c = try newCtx("usage");
    defer c.deinit();
    try inSync(&c);
    const r1 = try c.run(&.{ "--gen", "gen" }, &.{});
    try t.expectEqual(@as(u8, 2), r1.code);
    try t.expect(has(r1.stderr, "needs --committed"));
    const r2 = try c.run(&.{ "--bogus", "x" }, &.{});
    try t.expectEqual(@as(u8, 2), r2.code);
    const r3 = try c.run(&.{ "--gen", "nowhere", "--committed", "committed", "--label", "l", "--dir", "d", "--regen", "r", "--out", "stamp" }, &.{});
    try t.expectEqual(@as(u8, 2), r3.code);
    try t.expect(has(r3.stderr, "cannot open nowhere"));
}
