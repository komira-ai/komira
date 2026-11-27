//! The package: the main package and the linux-x64 platform package are
//! written with package.json stamped and every file under package/, sorted,
//! native libraries 0755 and the rest 0644, the same bytes twice and from
//! files given in another order; and refused before anything is written,
//! each by its exact message, for a file the manifest's `files` does not name
//! (a stray file), a native directory missing a Mojo runtime library, a
//! manifest whose repository.url is not komira's, a path it cannot carry or
//! one given twice, a member over 90 MB, a native library in a package with
//! no platform, and a library over the platform's glibc floor. The file name
//! is npm pack's.

const std = @import("std");
const diag = @import("native_policy").diag;
const npm = @import("npm.zig");
const tarball = @import("tarball.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

fn refusal(a: Alloc, in: npm.Input) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, npm.build(a, &d, in));
    return d.msg;
}

fn names(a: Alloc, ms: []const tarball.Member) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (ms) |m| try out.appendSlice(a, try std.fmt.allocPrint(a, "{s} {o}\n", .{ m.name, m.mode }));
    return out.toOwnedSlice(a);
}

test "the main package: package.json stamped, every file under package/ in order, 0644; the same bytes twice and from another order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const in = try fixture.mainInput(a);
    const z = try npm.build(a, &d, in);
    const got = try tarball.read(a, &d, z);
    try t.expectEqualStrings(
        \\package/LICENSE 644
        \\package/NOTICE 644
        \\package/dist/index.d.ts 644
        \\package/dist/index.js 644
        \\package/package.json 644
        \\
    , try names(a, got));
    try t.expectEqualStrings(fixture.main_stamped, got[4].data);
    try t.expectEqualStrings("komira notice\n", got[1].data);

    var reversed = in;
    const files = try a.dupe(npm.File, in.files);
    std.mem.reverse(npm.File, files);
    reversed.files = files;
    try t.expectEqualSlices(u8, z, try npm.build(a, &d, reversed));
    try t.expectEqualSlices(u8, z, try npm.build(a, &d, in));
}

test "the platform package: the addon and the native directory pass the native policy, written 0755" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const got = try tarball.read(a, &d, try npm.build(a, &d, try fixture.platformInput(a)));
    try t.expectEqualStrings(
        \\package/LICENSE 644
        \\package/MODULAR_LICENSE 644
        \\package/NOTICE 644
        \\package/komira_addon.node 755
        \\package/native/lib/libAsyncRTRuntimeGlobals.so 755
        \\package/native/lib/libKGENCompilerRTShared.so 755
        \\package/native/lib/libMSupportGlobals.so 755
        \\package/native/lib/libkomira_fs_native.so.1 755
        \\package/native/libkomira.so 755
        \\package/package.json 644
        \\
    , try names(a, got));
}

test "files: a file the manifest's files list does not name is refused, so no stray file ships" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.mainInput(a);
    in.files = try std.mem.concat(a, npm.File, &.{ in.files, &.{.{ .path = "dist/index.ts", .data = "export {};\n" }} });
    try t.expectEqualStrings("files: the package carries dist/index.ts, which the manifest's `files` does not name, so npm pack would leave it out", try refusal(a, in));
    var plat = try fixture.platformInput(a);
    plat.files = try std.mem.concat(a, npm.File, &.{ plat.files, &.{.{ .path = "build.log", .data = "" }} });
    try t.expectEqualStrings("files: the package carries build.log, which the manifest's `files` does not name, so npm pack would leave it out", try refusal(a, plat));
}

test "needed: a native directory missing one of the Mojo runtime libraries is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try fixture.nativeFiles(a);
    try t.expectEqualStrings(
        "needed: native/lib/libKGENCompilerRTShared.so needs libMSupportGlobals.so, which is not in the package, not a manylinux system library, and not in external_needed",
        try refusal(a, try fixture.platformInputOf(a, try fixture.without(a, all, "native/lib/libMSupportGlobals.so"))),
    );
    try t.expectEqualStrings(
        "needed: native/lib/libKGENCompilerRTShared.so needs libAsyncRTRuntimeGlobals.so, which is not in the package, not a manylinux system library, and not in external_needed",
        try refusal(a, try fixture.platformInputOf(a, try fixture.without(a, all, "native/lib/libAsyncRTRuntimeGlobals.so"))),
    );
    try t.expectEqualStrings(
        "needed: native/libkomira.so needs libKGENCompilerRTShared.so, which is not in the package, not a manylinux system library, and not in external_needed",
        try refusal(a, try fixture.platformInputOf(a, try fixture.without(a, all, "native/lib/libKGENCompilerRTShared.so"))),
    );
}

test "repository: a manifest whose repository.url is not komira's is refused before anything is written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.mainInput(a);
    in.manifest = try std.mem.replaceOwned(u8, a, in.manifest, "https://github.com/komira-ai/komira\"", "https://github.com/someone/komira\"");
    try t.expectEqualStrings("repository: the manifest's repository.url is `https://github.com/someone/komira`, not https://github.com/komira-ai/komira, which trusted publishing requires", try refusal(a, in));
}

test "path: package.json given as a file, a path it cannot carry and one given twice are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try fixture.mainInput(a);
    const cases = [_][2][]const u8{
        .{ "package.json", "path: package.json is the rule's own, stamped from the manifest; it is not a file to give" },
        .{ "/etc/x", "path: `/etc/x` is not a relative path" },
        .{ "", "path: `` is not a relative path" },
        .{ "dist/../x", "path: `dist/../x` has an empty, `.` or `..` part" },
        .{ "dist//x", "path: `dist//x` has an empty, `.` or `..` part" },
        .{ "dist\\x", "path: `dist\\x` holds a backslash" },
        .{ "dist/\xc3\xa9.js", "path: `dist/\xc3\xa9.js` holds a byte outside printable ASCII" },
        .{ "NOTICE", "path: `NOTICE` is given twice" },
    };
    for (cases) |c| {
        var in = base;
        in.files = try std.mem.concat(a, npm.File, &.{ base.files, &.{.{ .path = c[0], .data = "x" }} });
        try t.expectEqualStrings(c[1], try refusal(a, in));
    }
}

test "size: a member over 90 MB is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.mainInput(a);
    const big = try a.alloc(u8, npm.max_member + 1);
    @memset(big, 0);
    in.files = try std.mem.concat(a, npm.File, &.{ in.files, &.{.{ .path = "dist/big.js", .data = big }} });
    try t.expectEqualStrings("size: dist/big.js is 90000001 bytes, over the 90000000 a package member may be", try refusal(a, in));
}

test "platform: a native library in a package with no platform, and a library over the glibc floor, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in = try fixture.mainInput(a);
    in.files = try std.mem.concat(a, npm.File, &.{ in.files, &.{.{ .path = "dist/addon.js", .data = try fixture.elf(a, .{}) }} });
    try t.expectEqualStrings("platform: dist/addon.js is a native library, and a package with no platform holds none", try refusal(a, in));

    var plat = try fixture.platformInput(a);
    plat.glibc = "2.28";
    try t.expectEqualStrings("glibc: native/libkomira.so needs GLIBC_2.34, newer than the tag's glibc 2.28", try refusal(a, plat));
}

test "the file name is npm pack's: the scope's @ dropped and its / a -" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("komira-ai-komira-0.1.57.tgz", try npm.fileName(a, "@komira-ai/komira", "0.1.57"));
    try t.expectEqualStrings("komira-ai-komira-linux-x64-gnu-0.0.0.tgz", try npm.fileName(a, "@komira-ai/komira-linux-x64-gnu", "0.0.0"));
    try t.expectEqualStrings("plain-1.0.0.tgz", try npm.fileName(a, "plain", "1.0.0"));
}
