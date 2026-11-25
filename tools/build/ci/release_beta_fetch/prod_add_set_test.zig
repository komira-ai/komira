//! The cases of //tools/build/ci:prod_add_set_cases: `add_set` of prod_add.zig, the names `prod-add` installs
//! from prod, held to the release's own data.
//!
//! //release:release_packages_json writes the packages of release/readme_e2e/packages.bzl and the packages that
//! ship a native archive (the keys of `RELEASE_NATIVES` in release/BUCK). A native archive packed wrong, or a
//! `.conda` whose archive is missing, is caught after the publish only by a package `prod-add` installs, so:
//!  - every package of `RELEASE_NATIVES` is a name of `add_set`, and every name of `add_set` is a package of
//!    packages.bzl (the real files);
//!  - `add_set` without any one native package is refused, naming that package (the real files);
//!  - a name that is no package of packages.bzl, or one of another namespace, is refused, naming it;
//!  - data with no native package or no package is refused, so the check is never vacuous.

const std = @import("std");
const pa = @import("prod_add.zig");
const t = std.testing;

/// What //release:release_packages_json writes.
const Data = struct {
    namespace: []const u8,
    natives: []const []const u8,
    packages: []const []const u8,
};

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Null when `names` holds `<namespace>/<p>` for every native package `p` of `data`, and every name of `names` is
/// `<namespace>/<p>` for a package `p` of `data`; otherwise the reason, naming every package at fault.
fn check(ar: std.mem.Allocator, names: []const []const u8, data: Data) !?[]const u8 {
    if (data.natives.len == 0) return "release_packages.json lists no native package: the check would be vacuous";
    if (data.packages.len == 0) return "release_packages.json lists no package: the check would be vacuous";
    var missing = std.ArrayList([]const u8).empty;
    for (data.natives) |p| {
        const full = try std.fmt.allocPrint(ar, "{s}/{s}", .{ data.namespace, p });
        if (!contains(names, full)) try missing.append(ar, full);
    }
    if (missing.items.len != 0) return try std.fmt.allocPrint(
        ar,
        "add_set lacks {s}: each ships a native archive (RELEASE_NATIVES), and no job would install it from prod",
        .{try std.mem.join(ar, ", ", missing.items)},
    );
    var stray = std.ArrayList([]const u8).empty;
    for (names) |n| {
        const slash = std.mem.indexOfScalar(u8, n, '/');
        const ok = slash != null and std.mem.eql(u8, n[0..slash.?], data.namespace) and contains(data.packages, n[slash.? + 1 ..]);
        if (!ok) try stray.append(ar, n);
    }
    if (stray.items.len != 0) return try std.fmt.allocPrint(
        ar,
        "add_set names {s}: no package {s}/<name> of packages.bzl, so the release publishes no such package",
        .{ try std.mem.join(ar, ", ", stray.items), data.namespace },
    );
    return null;
}

fn realData(ar: std.mem.Allocator) !Data {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const text = try std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, "release_packages.json" }), 1 << 20);
    return std.json.parseFromSliceLeaky(Data, ar, text, .{});
}

fn expectRefused(ar: std.mem.Allocator, names: []const []const u8, data: Data, want: []const u8) !void {
    const got = (try check(ar, names, data)) orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, got);
}

/// A release of three packages, one of which ships a native archive.
const FIXTURE = Data{ .namespace = "komira-ai", .natives = &.{"libc"}, .packages = &.{ "json", "libc", "uuid" } };

test "every package of RELEASE_NATIVES is in add_set, and every name of add_set is a package of packages.bzl (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const data = try realData(ar);
    if (try check(ar, &pa.add_set, data)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "add_set without any one native package is refused, naming it (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const data = try realData(ar);
    for (data.natives) |p| {
        const full = try std.fmt.allocPrint(ar, "{s}/{s}", .{ data.namespace, p });
        var less = std.ArrayList([]const u8).empty;
        for (pa.add_set) |n| if (!std.mem.eql(u8, n, full)) try less.append(ar, n);
        try t.expectEqual(pa.add_set.len - 1, less.items.len);
        const want = try std.fmt.allocPrint(ar, "add_set lacks {s}: each ships a native archive (RELEASE_NATIVES), and no job would install it from prod", .{full});
        try expectRefused(ar, less.items, data, want);
    }
}

test "a list that lacks two native packages is refused, naming both" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const two = Data{ .namespace = "komira-ai", .natives = &.{ "libc", "log" }, .packages = &.{ "json", "libc", "log" } };
    try expectRefused(ar, &.{"komira-ai/json"}, two, "add_set lacks komira-ai/libc, komira-ai/log: each ships a native archive (RELEASE_NATIVES), and no job would install it from prod");
    try t.expect((try check(ar, &.{ "komira-ai/json", "komira-ai/libc", "komira-ai/log" }, two)) == null);
}

test "a name of add_set that is no package of packages.bzl, or of another namespace, is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expect((try check(ar, &.{ "komira-ai/json", "komira-ai/libc" }, FIXTURE)) == null);
    try expectRefused(ar, &.{ "komira-ai/libc", "komira-ai/gone" }, FIXTURE, "add_set names komira-ai/gone: no package komira-ai/<name> of packages.bzl, so the release publishes no such package");
    try expectRefused(ar, &.{ "komira-ai/libc", "other/json", "json" }, FIXTURE, "add_set names other/json, json: no package komira-ai/<name> of packages.bzl, so the release publishes no such package");
}

test "data with no native package or no package is refused, so the check is never vacuous" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(ar, &.{"komira-ai/json"}, .{ .namespace = "komira-ai", .natives = &.{}, .packages = &.{"json"} }, "release_packages.json lists no native package: the check would be vacuous");
    try expectRefused(ar, &.{"komira-ai/libc"}, .{ .namespace = "komira-ai", .natives = &.{"libc"}, .packages = &.{} }, "release_packages.json lists no package: the check would be vacuous");
}
