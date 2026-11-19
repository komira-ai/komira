//! The cases of //release:native_ids_cases, a `zig_test` run as a build action.
//!
//! release/mopm_native_ids.bzl reads, from each release member's unit graph, the ids of the static
//! natives the member declares, and `mopm_artifacts` names each archive by them. They must be the
//! `[native.<id>]` tables of the member's own `mopm.toml`, exactly. A native unit's id in the graph is
//! `native:<package>/<id>`, and from mopm 0.0.113 on `<package>` is a full name `<namespace>/<name>`,
//! so an id read as "what follows the first `/`" keeps the package's name in it
//! (`async_api/komira_concurrency_pool_depth`). That is what these cases catch, on the real files and
//! on fixtures:
//!  - every member's ids are its manifest's `[native.<id>]` tables (the real files);
//!  - an id that still holds the package's name, an id the manifest does not declare, and a declared id
//!    that is missing are each refused, naming the package and the id;
//!  - a member with no native and no table is accepted; a table with nothing in it, and a member whose
//!    manifest is not given, are refused, so the check is never vacuous.

const std = @import("std");
const t = std.testing;

/// A member's manifest, by package name.
const Manifest = struct { package: []const u8, text: []const u8 };

/// The `<id>` of each `[native.<id>]` table header of a `mopm.toml`, in file order.
fn declaredIds(ar: std.mem.Allocator, toml: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const head = "[native.";
        if (!std.mem.startsWith(u8, line, head) or !std.mem.endsWith(u8, line, "]")) continue;
        try out.append(ar, line[head.len .. line.len - 1]);
    }
    return out.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Null when `json` (`{package: [id, ...]}`) holds, for every package, exactly the ids of its
/// manifest; otherwise the reason, naming the package and the id.
fn check(ar: std.mem.Allocator, json: []const u8, manifests: []const Manifest) !?[]const u8 {
    const root = (try std.json.parseFromSlice(std.json.Value, ar, json, .{})).value;
    const table = root.object;
    if (table.count() == 0) return "native_ids.json holds no package: the check would be vacuous";
    var it = table.iterator();
    while (it.next()) |entry| {
        const package = entry.key_ptr.*;
        var manifest: ?[]const u8 = null;
        for (manifests) |m| if (std.mem.eql(u8, m.package, package)) {
            manifest = m.text;
        };
        const text = manifest orelse return try std.fmt.allocPrint(ar, "{s} has native ids and no mopm.toml was given for it", .{package});
        const want = try declaredIds(ar, text);
        var got = std.ArrayList([]const u8){};
        for (entry.value_ptr.array.items) |v| try got.append(ar, v.string);
        for (got.items) |id| {
            if (std.mem.indexOfScalar(u8, id, '/') != null) return try std.fmt.allocPrint(
                ar,
                "{s}: the native id {s} holds a `/`: it was read with the package's name in it, not as the id after `native:<package>/`",
                .{ package, id },
            );
            if (!contains(want, id)) return try std.fmt.allocPrint(ar, "{s}: the native id {s} is no [native.{s}] of its mopm.toml", .{ package, id, id });
        }
        for (want) |id| {
            if (!contains(got.items, id)) return try std.fmt.allocPrint(ar, "{s}: its mopm.toml declares [native.{s}], and the ids read from its graph lack it", .{ package, id });
        }
    }
    return null;
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 1 << 20);
}

fn expectRefused(ar: std.mem.Allocator, json: []const u8, manifests: []const Manifest, want: []const u8) !void {
    const got = (try check(ar, json, manifests)) orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, got);
}

const POOL = "[package]\nname = \"komira-ai/async_api\"\n\n[native.komira_concurrency_pool_depth]\nsrcs = [\"native/komira_concurrency_pool_depth.c\"]\n";
const PLAIN = "[package]\nname = \"komira-ai/json\"\n";

test "every member's native ids are its mopm.toml's [native.<id>] tables (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const json = try read(ar, "native_ids.json");
    const root = (try std.json.parseFromSlice(std.json.Value, ar, json, .{})).value;
    var manifests = std.ArrayList(Manifest){};
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const package = entry.key_ptr.*;
        const path = try std.fmt.allocPrint(ar, "manifests/{s}/mopm.toml", .{package});
        try manifests.append(ar, .{ .package = package, .text = try read(ar, path) });
    }
    if (try check(ar, json, manifests.items)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a native id that still holds the package's name is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(
        ar,
        "{\"async_api\": [\"async_api/komira_concurrency_pool_depth\"]}",
        &.{.{ .package = "async_api", .text = POOL }},
        "async_api: the native id async_api/komira_concurrency_pool_depth holds a `/`: it was read with the package's name in it, not as the id after `native:<package>/`",
    );
}

test "an id the manifest does not declare is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(
        ar,
        "{\"json\": [\"stray\"]}",
        &.{.{ .package = "json", .text = PLAIN }},
        "json: the native id stray is no [native.stray] of its mopm.toml",
    );
}

test "a declared id that is missing is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(
        ar,
        "{\"async_api\": []}",
        &.{.{ .package = "async_api", .text = POOL }},
        "async_api: its mopm.toml declares [native.komira_concurrency_pool_depth], and the ids read from its graph lack it",
    );
}

test "a member with no native and no table is accepted, beside one with a native" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expect((try check(
        ar,
        "{\"async_api\": [\"komira_concurrency_pool_depth\"], \"json\": []}",
        &.{ .{ .package = "async_api", .text = POOL }, .{ .package = "json", .text = PLAIN } },
    )) == null);
}

test "an empty table, and a member whose manifest is not given, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(ar, "{}", &.{}, "native_ids.json holds no package: the check would be vacuous");
    try expectRefused(ar, "{\"json\": []}", &.{}, "json has native ids and no mopm.toml was given for it");
}
