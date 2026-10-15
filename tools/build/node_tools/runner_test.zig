const std = @import("std");
const runner = @import("runner.zig");

const base = runner.Spec{
    .tree = "/t",
    .modules = "/m",
    .node = "/n",
    .libs = "/l",
    .package = "p",
    .program = "node_modules/.bin/x",
    .args = &.{},
    .env = &.{},
    .out_dir = null,
    .scratch = "/s",
};

test "buildEnv: the fixed environment and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = try runner.buildEnv(arena.allocator(), base);
    try std.testing.expectEqual(@as(u32, 6), env.count());
    try std.testing.expectEqualStrings("C", env.get("LC_ALL").?);
    try std.testing.expectEqualStrings("UTC0", env.get("TZ").?);
    try std.testing.expectEqualStrings("/s/home", env.get("HOME").?);
    try std.testing.expectEqualStrings("/s/tmp", env.get("TMPDIR").?);
    try std.testing.expectEqualStrings("/n/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/l/lib", env.get("LD_LIBRARY_PATH").?);
    // The host's environment never reaches node: this process has a PATH of its own.
    try std.testing.expect(env.get("NODE_OPTIONS") == null and env.get("NODE_PATH") == null and env.get("AWS_ACCESS_KEY_ID") == null);
}

test "buildEnv: the target's variables are added and may not be inherited from anywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var spec = base;
    spec.env = &.{ .{ "CDK_DEFAULT_REGION", "us-east-1" }, .{ "TZ", "Europe/Paris" } };
    var env = try runner.buildEnv(arena.allocator(), spec);
    try std.testing.expectEqualStrings("us-east-1", env.get("CDK_DEFAULT_REGION").?);
    try std.testing.expectEqualStrings("Europe/Paris", env.get("TZ").?);
    try std.testing.expectEqual(@as(u32, 7), env.count());
}

test "scratchDir: buck2's private directory, relative or absolute, or one of the working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/root/.komira_action", try runner.scratchDir(a, "/root", null));
    try std.testing.expectEqualStrings("/root/.komira_action", try runner.scratchDir(a, "/root", ""));
    try std.testing.expectEqualStrings("/root/buck-out/tmp/x/komira", try runner.scratchDir(a, "/root", "buck-out/tmp/x"));
    try std.testing.expectEqualStrings("/abs/tmp/komira", try runner.scratchDir(a, "/root", "/abs/tmp"));
}

test "copyTree: files writable in the copy, executable only where the source was" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/lib/deep");
    try tmp.dir.makePath("dst");
    {
        const f = try tmp.dir.createFile("src/lib/deep/a.txt", .{ .mode = 0o444 });
        f.close();
        const g = try tmp.dir.createFile("src/run.sh", .{ .mode = 0o555 });
        g.close();
    }
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try runner.copyTree(a, src, dst);
    const st1 = try dst.statFile("lib/deep/a.txt");
    const st2 = try dst.statFile("run.sh");
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(st1.mode & 0o777)));
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st2.mode & 0o777)));
}
