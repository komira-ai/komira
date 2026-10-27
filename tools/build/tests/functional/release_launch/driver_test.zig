//! The process behaviour of the validation launcher (release/validations/launch.zig):
//! it runs the command from the named root, passes the arguments through, adds
//! the run id, the attempt and a fresh private scratch directory when the caller
//! named none, and leaves what the caller named alone.
const std = @import("std");
const t = std.testing;

const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

fn run(a: std.mem.Allocator, root: []const u8, tmp: []const u8, tail: []const []const u8) !Run {
    const launch = try std.process.getEnvVarOwned(a, "LAUNCH");
    const probe = try std.process.getEnvVarOwned(a, "PROBE");
    var env = try std.process.getEnvMap(a);
    try env.put("TMPDIR", tmp);
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ launch, root, probe });
    try argv.appendSlice(a, tail);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .env_map = &env });
    return .{ .code = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    }, .stdout = r.stdout, .stderr = r.stderr };
}

fn setup(a: std.mem.Allocator, name: []const u8) !struct { root: []const u8, tmp: []const u8 } {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const root = try std.fs.path.join(a, &.{ work, name, "root" });
    const tmp = try std.fs.path.join(a, &.{ work, name, "tmp" });
    try std.fs.cwd().makePath(root);
    try std.fs.cwd().makePath(tmp);
    return .{ .root = try std.fs.cwd().realpathAlloc(a, root), .tmp = try std.fs.cwd().realpathAlloc(a, tmp) };
}

test "runs from the root with the caller's arguments, then the defaults and a fresh private scratch directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try setup(a, "defaults");
    const r = try run(a, d.root, d.tmp, &.{ "run", "--stage", "beta" });
    try t.expectEqual(@as(u8, 0), r.code);
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cwd={s}", .{d.root}), lines.next().?);
    const want = [_][]const u8{ "arg=run", "arg=--stage", "arg=beta", "arg=--run-id", "arg=local", "arg=--attempt", "arg=1", "arg=--scratch-dir" };
    for (want) |w| try t.expectEqualStrings(w, lines.next().?);
    const scratch = lines.next().?;
    try t.expect(std.mem.startsWith(u8, scratch, "arg="));
    const dir = scratch[4..];
    try t.expect(std.mem.startsWith(u8, dir, d.tmp));
    const st = try std.fs.cwd().statFile(dir);
    try t.expectEqual(std.fs.File.Kind.directory, st.kind);
    try t.expectEqual(@as(std.fs.File.Mode, 0o700), st.mode & 0o777);
}

test "arguments the caller named are not added again, and no scratch directory is made" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try setup(a, "named");
    const r = try run(a, d.root, d.tmp, &.{ "--run-id=7", "--attempt", "3", "--scratch-dir", "/s" });
    try t.expectEqual(@as(u8, 0), r.code);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "arg=")) n += 1;
    }
    try t.expectEqual(@as(usize, 5), n);
    var tmp_dir = try std.fs.cwd().openDir(d.tmp, .{ .iterate = true });
    defer tmp_dir.close();
    var it = tmp_dir.iterate();
    try t.expect((try it.next()) == null);
}

test "a root that does not exist, or a command that cannot run, exits 1 with a reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try setup(a, "refuse");
    const gone = try std.fs.path.join(a, &.{ d.root, "nosuch" });
    const r = try run(a, gone, d.tmp, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(std.mem.indexOf(u8, r.stderr, "cannot change to") != null);
    const launch = try std.process.getEnvVarOwned(a, "LAUNCH");
    const r2 = try std.process.Child.run(.{ .allocator = a, .argv = &.{ launch, d.root, "/nonexistent/kci" } });
    try t.expectEqual(@as(u8, 1), switch (r2.term) {
        .Exited => |c| c,
        else => 255,
    });
    try t.expect(std.mem.indexOf(u8, r2.stderr, "cannot run") != null);
}
