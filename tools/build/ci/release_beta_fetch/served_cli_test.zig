//! The cases of release_staged_verify's executable through its verb `served`, //tools/build/ci:served_cli_cases: each
//! runs the built tool (`RELEASE_STAGED_VERIFY`, an exec tool) as release.yml's `beta-served-readmes` and
//! `prod-served-readmes` run it, in a directory of the case's own under KOMIRA_TEST_WORK, on cases that fail before
//! any request (the build action has no network), and checks the exit code, stdout and stderr by exact equality.
//! served_test.zig holds every branch of `served` against a registry in memory; these hold what only the executable
//! does: that `served` reaches its own parser and its own check, and the exit code and line each failure prints.
//! What the cases catch:
//!  - `served` with a `--stage` that is neither registry exits 2 with its line, so the verb is dispatched to `served`'s
//!    parser and not refused as an unknown verb;
//!  - `served` with no flags exits 2 with `served`'s own usage;
//!  - `served` on a set with no `plan.json` exits 1 with `SERVED FAILED` and the path, writes no `--out`, and asks
//!    nothing of the network: the verb runs the check itself;
//!  - the tool with no verb exits 2 with a usage that names `served`.
const std = @import("std");
const t = std.testing;

const SERVED_USAGE = "usage: release_staged_verify served --stage <beta|prod> --staged <dir> --out <dir> [--attempts <n>] [--delay <seconds>]\n";

const Outcome = struct { code: u8, stdout: []const u8, stderr: []const u8 };

var case_no: usize = 0;

/// An empty directory of the case's own.
fn caseDir(ar: std.mem.Allocator) ![]const u8 {
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/served_case{d}", .{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), case_no });
    try std.fs.cwd().makePath(dir);
    // absolute, since the tool runs in it and the cases pass paths under it
    return std.fs.cwd().realpathAlloc(ar, dir);
}

/// Runs the built tool with `args` in `dir`, with an empty environment.
fn runTool(ar: std.mem.Allocator, dir: []const u8, args: []const []const u8) !Outcome {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(ar, try std.process.getEnvVarOwned(ar, "RELEASE_STAGED_VERIFY"));
    try argv.appendSlice(ar, args);
    var env = std.process.EnvMap.init(ar);
    const r = try std.process.Child.run(.{ .allocator = ar, .argv = argv.items, .cwd = dir, .env_map = &env });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

test "served with a stage that is neither registry exits 2 with its line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const o = try runTool(ar, dir, &.{ "served", "--stage", "gamma", "--staged", "s", "--out", "o" });
    try t.expectEqual(@as(u8, 2), o.code);
    try t.expectEqualStrings("", o.stdout);
    try t.expectEqualStrings("release_staged_verify: --stage is beta or prod, not gamma\n", o.stderr);
}

test "served with no flags exits 2 with served's usage" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const o = try runTool(ar, dir, &.{"served"});
    try t.expectEqual(@as(u8, 2), o.code);
    try t.expectEqualStrings("", o.stdout);
    try t.expectEqualStrings(SERVED_USAGE, o.stderr);
}

test "served on a set with no plan.json exits 1 with SERVED FAILED and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const staged = try std.fs.path.join(ar, &.{ dir, "staged" });
    try std.fs.cwd().makePath(staged);
    const out = try std.fs.path.join(ar, &.{ dir, "out" });
    const o = try runTool(ar, dir, &.{ "served", "--stage", "beta", "--staged", staged, "--out", out, "--attempts", "1", "--delay", "0" });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expectEqualStrings("", o.stdout);
    const want = try std.fmt.allocPrint(ar, "release_staged_verify: SERVED FAILED: cannot read {s}/plan.json: FileNotFound\n", .{staged});
    try t.expectEqualStrings(want, o.stderr);
    try t.expectError(error.FileNotFound, std.fs.cwd().access(out, .{}));
}

test "the tool with no verb exits 2 with a usage that names served" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const o = try runTool(ar, dir, &.{});
    try t.expectEqual(@as(u8, 2), o.code);
    try t.expectEqualStrings("", o.stdout);
    try t.expect(std.mem.indexOf(u8, o.stderr, "       release_staged_verify served --stage <beta|prod> --staged <dir> --out <dir> [--attempts <n>] [--delay <seconds>]\n") != null);
}
