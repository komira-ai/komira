//! The process behaviour of bench_run (src/tests/helpers/komira_udf_spike_node_worker/
//! bench_run.zig): the program runs in the data directory with the arguments and then
//! the first line of the run id file, its standard output is the output file, and its
//! failure is the failure of the action.
const std = @import("std");
const t = std.testing;

const Run = struct { code: u8, stderr: []const u8 };

fn run(a: std.mem.Allocator, name: []const u8, run_id: []const u8, args: []const []const u8) !struct { r: Run, dir: []const u8 } {
    const tool = try std.process.getEnvVarOwned(a, "BENCH_RUN");
    const probe = try std.process.getEnvVarOwned(a, "PROBE");
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const dir = try std.fs.path.join(a, &.{ work, name });
    const data = try std.fs.path.join(a, &.{ dir, "data" });
    try std.fs.cwd().makePath(data);
    const id_file = try std.fs.path.join(a, &.{ dir, "run_id" });
    try std.fs.cwd().writeFile(id_file, run_id);
    const out = try std.fs.path.join(a, &.{ dir, "out.json" });
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ tool, probe, data, out, id_file });
    try argv.appendSlice(args);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd = dir });
    return .{ .r = .{ .code = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    }, .stderr = r.stderr }, .dir = dir };
}

test "the program runs in the data directory with the arguments and the run id; stdout is the output" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const res = try run(a, "ok", "run-9\nsecond line\n", &.{ "--n", "5" });
    try t.expectEqual(@as(u8, 0), res.r.code);
    const got = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ res.dir, "out.json" }), 1 << 16);
    const data = try std.fs.cwd().realpathAlloc(a, try std.fs.path.join(a, &.{ res.dir, "data" }));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cwd={s}\narg=--n\narg=5\narg=run-9\n", .{data}), got);
    // The program's standard error is not in the output.
    try t.expect(std.mem.indexOf(u8, got, "bench note") == null);
}

test "a failing program fails the action with its status; an empty run id file is an empty argument" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try run(a, "fail", "x\n", &.{"fail"});
    try t.expectEqual(@as(u8, 3), bad.r.code);
    const empty = try run(a, "empty", "", &.{});
    try t.expectEqual(@as(u8, 0), empty.r.code);
    const got = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ empty.dir, "out.json" }), 1 << 16);
    try t.expect(std.mem.endsWith(u8, got, "arg=\n"));
}
