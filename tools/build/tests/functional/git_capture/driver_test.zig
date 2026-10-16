//! The process behaviour of capture (src/tests/conformance/komira_git_protocol_conformance/
//! capture.zig) as the ssh of a git client: it runs the service the command names on the path
//! it quotes, passes the bytes each way, records conn<n>.req and conn<n>.resp in $KGC_CAPTURE
//! (n counting up) and nothing when that is unset, exits 0 whatever the server did, and
//! refuses a command that is not git's upload-pack or receive-pack.
const std = @import("std");
const t = std.testing;

const Res = struct { code: u8, stdout: []const u8, stderr: []const u8 };

fn shim(a: std.mem.Allocator, capture_dir: ?[]const u8, command: []const u8, input: []const u8) !Res {
    const capture = try std.process.getEnvVarOwned(a, "CAPTURE");
    const probe = try std.process.getEnvVarOwned(a, "PROBE");
    var env = std.process.EnvMap.init(a);
    try env.put("KGC_SHIM_GIT", probe);
    if (capture_dir) |d| try env.put("KGC_CAPTURE", d);
    var child = std.process.Child.init(&.{ capture, "-o", "SendEnv=GIT_PROTOCOL", "localhost", command }, a);
    child.env_map = &env;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    try child.stdin.?.writeAll(input);
    child.stdin.?.close();
    child.stdin = null;
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try child.collectOutput(&out, &err, 1 << 20);
    const term = try child.wait();
    return .{ .code = switch (term) {
        .Exited => |c| c,
        else => 255,
    }, .stdout = out.items, .stderr = err.items };
}

fn dir(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const d = try std.fs.path.join(a, &.{ work, name });
    try std.fs.cwd().makePath(d);
    return d;
}

fn read(a: std.mem.Allocator, d: []const u8, name: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ d, name }), 1 << 20);
}

test "the server's bytes are the client's response, both directions are recorded, connections count up" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dir(a, "record");
    const r1 = try shim(a, d, "git-upload-pack '/r/a b.git'", "0014command=ls-refs\n");
    try t.expectEqual(@as(u8, 0), r1.code);
    try t.expectEqualStrings("service=upload-pack path=/r/a b.git\n0014command=ls-refs\n", r1.stdout);
    try t.expectEqualStrings("0014command=ls-refs\n", try read(a, d, "conn1.req"));
    try t.expectEqualStrings(r1.stdout, try read(a, d, "conn1.resp"));
    const r2 = try shim(a, d, "git-receive-pack '/d'", "second");
    try t.expectEqualStrings("service=receive-pack path=/d\nsecond", r2.stdout);
    try t.expectEqualStrings("second", try read(a, d, "conn2.req"));
    try t.expectEqualStrings(r2.stdout, try read(a, d, "conn2.resp"));
}

test "with no capture directory nothing is recorded; a failing server still exits 0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dir(a, "norecord");
    const r = try shim(a, null, "git-upload-pack '/x'", "die");
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("service=upload-pack path=/x\ndie", r.stdout);
    var dd = try std.fs.cwd().openDir(d, .{ .iterate = true });
    defer dd.close();
    var it = dd.iterate();
    try t.expect((try it.next()) == null);
}

test "a command that is not upload-pack or receive-pack is refused and no server is started" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dir(a, "refuse");
    const r = try shim(a, d, "rm '/x'", "");
    try t.expect(r.code != 0);
    try t.expectEqualStrings("", r.stdout);
    var dd = try std.fs.cwd().openDir(d, .{ .iterate = true });
    defer dd.close();
    var it = dd.iterate();
    try t.expect((try it.next()) == null);
}
