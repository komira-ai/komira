//! Unit tests of node_act's pure parts.
//! Its process behaviour (the four subcommands, their messages and exit
//! statuses, the environment node is run in) is tests//functional/node_act;
//! the node rules' targets run through it too.
const std = @import("std");
const A = @import("node_act.zig");
const t = std.testing;

test "keepDist and isFile" {
    try t.expect(A.keepDist("bin/node"));
    try t.expect(A.keepDist("LICENSE"));
    try t.expect(A.keepDist("include/node"));
    try t.expect(A.keepDist("include/node/v8.h"));
    try t.expect(!A.keepDist("bin/node2"));
    try t.expect(!A.keepDist("include/node2/x"));
    try t.expect(!A.keepDist("include"));
    try t.expect(!A.keepDist("lib/node_modules/npm"));
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("d");
    {
        const f = try tmp.dir.createFile("x", .{});
        defer f.close();
        try f.chmod(0o755);
        const g = try tmp.dir.createFile("y", .{});
        defer g.close();
        try g.chmod(0o644);
    }
    try tmp.dir.symLink("x", "lx", .{});
    try t.expect(A.isFile(tmp.dir, "x", true));
    try t.expect(!A.isFile(tmp.dir, "y", true));
    try t.expect(A.isFile(tmp.dir, "y", false));
    try t.expect(!A.isFile(tmp.dir, "d", false));
    try t.expect(!A.isFile(tmp.dir, "missing", false));
    try t.expect(A.isFile(tmp.dir, "lx", true));
}

test "sri: the shape, and the digest the base64 holds as hex" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try A.sriShape("sha512-AAAA");
    try t.expectError(error.NotSha512, A.sriShape("sha512-"));
    try t.expectError(error.NotSha512, A.sriShape("sha256-AAAA"));
    try t.expectError(error.NotSha512, A.sriShape("xsha512-AAAA"));
    try t.expectError(error.NotSha512, A.sriShape(""));
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash("abc", &digest, .{});
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(64));
    _ = std.base64.standard.Encoder.encode(b64, &digest);
    const sri = try std.fmt.allocPrint(a, "sha512-{s}", .{b64});
    const hex = try A.sriHex(a, sri);
    try t.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), hex);
    try t.expectEqualStrings("0" ** 128, try A.sriHex(a, "sha512-" ++ "A" ** 86 ++ "=="));
    try t.expectEqualStrings("", try A.sriHex(a, "sha512-!!!!"));
}

test "environments: the tests' fixed five, and the library path alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try A.testEnv(a, "/s", "/libs");
    try t.expectEqual(@as(u32, 5), env.count());
    try t.expectEqualStrings("C", env.get("LC_ALL").?);
    try t.expectEqualStrings("UTC0", env.get("TZ").?);
    try t.expectEqualStrings("/s/home", env.get("HOME").?);
    try t.expectEqualStrings("/s/tmp", env.get("TMPDIR").?);
    try t.expectEqualStrings("/libs/lib", env.get("LD_LIBRARY_PATH").?);
    const e2 = try A.libsEnv(a, "/libs");
    try t.expectEqual(@as(u32, 1), e2.count());
    try t.expectEqualStrings("/libs/lib", e2.get("LD_LIBRARY_PATH").?);
}
