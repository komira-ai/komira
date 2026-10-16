//! Unit tests of llvm_branch.zig: which links `unpack` follows and refuses, the
//! members it writes, and the readers of llvm-nm, llvm-profdata and merge-log
//! output the checks decide by. The program itself runs on the real pinned
//! packages (//tools/build/toolchains/llvm_branch:lld24, :llvm23 and the three
//! checks).
const std = @import("std");
const L = @import("llvm_branch.zig");
const t = std.testing;

const Entry = struct { name: []const u8, kind: u8, data: []const u8 = "", link: []const u8 = "", mode: u32 = 0o644 };

fn octal(dst: []u8, v: u64) void {
    @memset(dst, '0');
    var i: usize = dst.len - 1;
    dst[i] = 0;
    var x = v;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
        if (x == 0) break;
    }
}

fn tarOf(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (entries) |e| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..e.name.len], e.name);
        octal(h[100..108], e.mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], e.data.len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = e.kind;
        @memcpy(h[157 .. 157 + e.link.len], e.link);
        @memcpy(h[257..263], "ustar\x00");
        @memcpy(h[263..265], "00");
        var sum: u32 = 0;
        for (h) |b| sum += b;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(&h);
        try out.appendSlice(e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(0, pad);
    }
    try out.appendNTimes(0, 1024);
    return out.toOwnedSlice();
}

const Fx = struct {
    tmp: std.testing.TmpDir,
    pkg: []u8,
    out: []u8,

    fn init(a: std.mem.Allocator) !Fx {
        var tmp = t.tmpDir(.{ .iterate = true });
        try tmp.dir.makePath("pkg");
        try tmp.dir.makePath("out");
        const root = try tmp.dir.realpathAlloc(a, ".");
        return .{ .tmp = tmp, .pkg = try std.fs.path.join(a, &.{ root, "pkg" }), .out = try std.fs.path.join(a, &.{ root, "out" }) };
    }

    fn put(self: *Fx, a: std.mem.Allocator, pkg: []const u8, entries: []const Entry) !void {
        const name = try std.fmt.allocPrint(a, "pkg/{s}.tar", .{pkg});
        try self.tmp.dir.writeFile(name, try tarOf(a, entries));
    }

    fn run(self: *Fx, a: std.mem.Allocator, specs: []const []const u8, msg: *std.ArrayList(u8)) !usize {
        return L.extractMembers(a, self.pkg, self.out, specs, msg);
    }
};

test "unpack: a regular member is written with its executable bit; nothing else is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.put(a, "mojo", &.{
        .{ .name = "bin/lld", .kind = '0', .data = "ELF", .mode = 0o755 },
        .{ .name = "lib/other", .kind = '0', .data = "x" },
    });
    var msg = std.ArrayList(u8).init(a);
    try t.expectEqual(@as(usize, 1), try fx.run(a, &.{"bin/lld=mojo/bin/lld"}, &msg));
    var d = try fx.tmp.dir.openDir("out", .{ .iterate = true });
    defer d.close();
    const st = try d.statFile("bin/lld");
    try t.expect(st.mode & 0o111 != 0);
    try t.expectEqualStrings("ELF", try d.readFileAlloc(a, "bin/lld", 100));
    var n: usize = 0;
    var w = try d.walk(a);
    while (try w.next()) |e| {
        if (e.kind != .directory) n += 1;
    }
    try t.expectEqual(@as(usize, 1), n);
}

test "unpack: a link is followed within the package, as many as seven hops" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.put(a, "libs", &.{
        .{ .name = "lib/libz.so.1", .kind = '2', .link = "libz.so.1.3" },
        .{ .name = "lib/libz.so.1.3", .kind = '0', .data = "zlib", .mode = 0o755 },
        .{ .name = "lib/a", .kind = '2', .link = "b" },
        .{ .name = "lib/b", .kind = '2', .link = "c" },
        .{ .name = "lib/c", .kind = '2', .link = "d" },
        .{ .name = "lib/d", .kind = '2', .link = "e" },
        .{ .name = "lib/e", .kind = '2', .link = "f" },
        .{ .name = "lib/f", .kind = '2', .link = "g" },
        .{ .name = "lib/g", .kind = '2', .link = "h" },
        .{ .name = "lib/h", .kind = '2', .link = "i" },
        .{ .name = "lib/i", .kind = '0', .data = "end" },
    });
    var msg = std.ArrayList(u8).init(a);
    try t.expectEqual(@as(usize, 1), try fx.run(a, &.{"lib/libz.so.1=libs/lib/libz.so.1"}, &msg));
    var d = try fx.tmp.dir.openDir("out", .{});
    defer d.close();
    try t.expectEqualStrings("zlib", try d.readFileAlloc(a, "lib/libz.so.1", 100));
    // a -> b -> ... -> h -> i is 8 links: refused.
    try t.expectError(error.Unpack, fx.run(a, &.{"x=libs/lib/a"}, &msg));
    try t.expectEqualStrings("lib/a: more than 8 links", msg.items);
}

test "unpack: refusals name the member, the link, or the package" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fx = try Fx.init(a);
    defer fx.tmp.cleanup();
    try fx.put(a, "p", &.{
        .{ .name = "up", .kind = '2', .link = "../etc/passwd" },
        .{ .name = "abs", .kind = '2', .link = "/etc/passwd" },
        .{ .name = "mid", .kind = '2', .link = "a/../../x" },
        .{ .name = "empty", .kind = '0' },
        .{ .name = "dir", .kind = '5' },
    });
    const cases = [_][2][]const u8{
        .{ "x=p/up", "up is a link to '../etc/passwd', outside its directory" },
        .{ "x=p/abs", "abs is a link to '/etc/passwd', outside its directory" },
        .{ "x=p/mid", "mid is a link to 'a/../../x', outside its directory" },
        .{ "x=p/nothere", "nothere is not a member of p" },
        .{ "x=p/empty", "p/empty is not a non-empty file" },
        .{ "x=p/dir", "p/dir is not a non-empty file" },
        .{ "x=q/m", "'x=q/m' names package 'q', which is not given" },
        .{ "x=p", "'x=p' names no member (<dest>=<package>/<member>)" },
        .{ "/x=p/up", "bad destination in '/x'" },
        .{ "a/../x=p/up", "bad destination in 'a/../x'" },
        .{ "noequals", "bad destination in 'noequals'" },
    };
    for (cases) |c| {
        var msg = std.ArrayList(u8).init(a);
        try t.expectError(error.Unpack, fx.run(a, &.{c[0]}, &msg));
        try t.expectEqualStrings(c[1], msg.items);
    }
}

test "linkContained and resolveLink" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect(L.linkContained("libz.so.1.3"));
    try t.expect(L.linkContained("sub/x"));
    try t.expect(!L.linkContained("../x"));
    try t.expect(!L.linkContained("a/../x"));
    try t.expect(!L.linkContained("a/.."));
    try t.expect(!L.linkContained("/x"));
    try t.expect(!L.linkContained(""));
    try t.expectEqualStrings("lib/libz.so.1.3", try L.resolveLink(a, "lib/libz.so.1", "libz.so.1.3"));
    try t.expectEqualStrings("x", try L.resolveLink(a, "top", "x"));
}

test "nm: classes of the lines that define a symbol; only three-field lines count" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const nm = "0000000000000010 D __llvm_profile_raw_version\n" ++
        "                 U __llvm_profile_runtime\n" ++
        "0000000000000020 W __llvm_profile_raw_version\n" ++
        "0000000000000030 T other\n";
    try t.expectEqualStrings("D W ", try L.nmClasses(a, nm, "__llvm_profile_raw_version"));
    try t.expectEqualStrings("", try L.nmClasses(a, nm, "__llvm_profile_runtime"));
    try t.expect(L.nmDefines(nm, "other"));
    try t.expect(!L.nmDefines(nm, "__llvm_profile_runtime"));
    try t.expect(!L.nmDefines(nm, "missing"));
}

test "block counts: sorted numerically across the lines, each followed by a comma" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("2,3,", try L.blockCounts(a, "Counters:\n  classify:\n    Hash: 0x1\n    Block counts: [3, 2]\n"));
    try t.expectEqualStrings("1,2,10,", try L.blockCounts(a, "  Block counts: [10, 1]\n Block counts: [2]\nBlock counts: oops\n"));
    try t.expectEqualStrings("", try L.blockCounts(a, "nothing here\n"));
}

test "merge log: the expected version of a mismatch, the first lines of a log" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("11", try L.expectedVersions(a, "error: x.profraw: raw profile version mismatch: Profile uses raw profile format version = 12; expected version = 11\n"));
    try t.expectEqualStrings("", try L.expectedVersions(a, "file header is corrupt\n"));
    try t.expectEqualStrings("3 7", try L.expectedVersions(a, "a; expected version = 3\nb; expected version = 7\nc; expected version = x\n"));
}
