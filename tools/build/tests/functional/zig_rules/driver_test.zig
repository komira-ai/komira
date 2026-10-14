// What a zig_test given exec_tools and data promises a driver: built tools by
// absolute path, fixtures in a writable directory with their executable bits,
// HOME, TMPDIR and the caches in the action's scratch, and loopback.
const std = @import("std");
const a = std.testing.allocator;

fn env(name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name);
}

test "a built tool is run by its absolute path" {
    const app = try env("APP");
    defer a.free(app);
    try std.testing.expect(std.fs.path.isAbsolute(app));
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{app} });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings("42 ReleaseSafe\n", r.stdout);
}

test "a directory tool is the directory" {
    const zig = try env("ZIG");
    defer a.free(zig);
    try std.testing.expect(std.fs.path.isAbsolute(zig));
    const exe = try std.fs.path.join(a, &.{ zig, "zig" });
    defer a.free(exe);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ exe, "version" } });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings("0.12.0\n", r.stdout);
}

test "data is copied into a writable directory, executable bits kept" {
    const work = try env("KOMIRA_TEST_WORK");
    defer a.free(work);
    var dir = try std.fs.openDirAbsolute(work, .{});
    defer dir.close();
    const note = try dir.readFileAlloc(a, "fixtures/note.txt", 1 << 10);
    defer a.free(note);
    try std.testing.expectEqualStrings("note\n", note);
    const inner = try dir.readFileAlloc(a, "fixtures/dir/inner.txt", 1 << 10);
    defer a.free(inner);
    try std.testing.expectEqualStrings("inner\n", inner);
    const probe = try dir.statFile("fixtures/exec_probe");
    try std.testing.expect(probe.mode & 0o100 != 0);
    const plain = try dir.statFile("fixtures/note.txt");
    try std.testing.expect(plain.mode & 0o100 == 0);
    // Writable: a fixture is changed in place, and a file is created.
    const f = try dir.openFile("fixtures/note.txt", .{ .mode = .write_only });
    f.close();
    try dir.writeFile("fixtures/dir/created.txt", "new\n");
}

test "HOME, TMPDIR and the caches are in the action's scratch" {
    const work = try env("KOMIRA_TEST_WORK");
    defer a.free(work);
    const scratch = std.fs.path.dirname(work).?;
    for ([_][]const u8{ "HOME", "TMPDIR", "XDG_CACHE_HOME", "ZIG_GLOBAL_CACHE_DIR" }) |name| {
        const v = try env(name);
        defer a.free(v);
        if (!std.mem.startsWith(u8, v, scratch) or v.len == scratch.len) {
            std.debug.print("{s}={s} is not under {s}\n", .{ name, v, scratch });
            return error.NotInScratch;
        }
        try std.fs.cwd().makePath(v);
        var d = try std.fs.cwd().openDir(v, .{});
        defer d.close();
        try d.writeFile("probe", "x");
    }
}

test "loopback works" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    var client = try std.net.tcpConnectToAddress(try std.net.Address.parseIp("127.0.0.1", port));
    defer client.close();
    var conn = try server.accept();
    defer conn.stream.close();
    try client.writeAll("ping");
    var buf: [4]u8 = undefined;
    try conn.stream.reader().readNoEof(&buf);
    try std.testing.expectEqualStrings("ping", &buf);
}
