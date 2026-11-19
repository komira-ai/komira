//! The cases of //release:artifacts_layout_cases, a `zig_test` run as a build action.
//!
//! `mopm stage --artifacts <dir>` reads each member's library at `<dir>/<subdir>/<namespace>/<name>.mojoc`
//! and each `[native.<id>]` archive at `<dir>/<subdir>/<namespace>/<name>.native/lib<id>.a`; from mopm
//! 0.0.113 on it reads no other layout, and a library without the namespace directory is a member with
//! "no build artifact". These cases hold the files of the built //release:mopm_artifacts (linux-64),
//! and the paths //release:mopm_darwin_libs (osx-arm64, not built here) lists in its sub-target
//! `[layout]`, to the package list (release/readme_e2e/packages.bzl: `NAMESPACE`, `PACKAGES`) and the
//! declared natives (`native_ids.json`):
//!  - the built linux-64 directory is exactly one library per package and one archive per declared
//!    native, under the namespace; the osx-arm64 layout is exactly one library per package not in
//!    `DARWIN_EXCLUDED` (darwin_libs.bzl), under the namespace;
//!  - a library or archive without the namespace directory, under another namespace or another subdir,
//!    a missing member, a missing archive, a path for no package, and an empty layout are each refused,
//!    naming the path.

const std = @import("std");
const t = std.testing;

/// What the layouts are held to: the namespace and package names of packages.bzl, and the declared native ids.
const Release = struct {
    namespace: []const u8,
    packages: []const []const u8,
    /// `{package: [id, ...]}` of native_ids.json; a package with no entry, or an empty list, has no native.
    natives: std.json.ObjectMap,
    /// The packages darwin_libs.bzl leaves out of the macOS build (`DARWIN_EXCLUDED`).
    darwin_excluded: []const []const u8 = &.{},
};

/// `NAMESPACE` and the keys of `PACKAGES` of packages.bzl.
fn parsePackages(ar: std.mem.Allocator, bzl: []const u8) !struct { namespace: []const u8, packages: []const []const u8 } {
    var namespace: ?[]const u8 = null;
    var packages = std.ArrayList([]const u8){};
    var in_packages = false;
    var lines = std.mem.splitScalar(u8, bzl, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "NAMESPACE = \"")) {
            const rest = line["NAMESPACE = \"".len..];
            namespace = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return error.BadNamespaceLine];
        } else if (std.mem.eql(u8, line, "PACKAGES = {")) {
            in_packages = true;
        } else if (in_packages and std.mem.eql(u8, line, "}")) {
            in_packages = false;
        } else if (in_packages and std.mem.startsWith(u8, line, "    \"")) {
            const rest = line[5..];
            try packages.append(ar, rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return error.BadPackageLine]);
        }
    }
    return .{ .namespace = namespace orelse return error.NoNamespace, .packages = packages.items };
}

/// The keys of `DARWIN_EXCLUDED` of darwin_libs.bzl: `DARWIN_EXCLUDED = {}`, or one `    "<name>": ...` line per entry.
fn parseDarwinExcluded(ar: std.mem.Allocator, bzl: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var seen = false;
    var inside = false;
    var lines = std.mem.splitScalar(u8, bzl, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "DARWIN_EXCLUDED = {}")) {
            seen = true;
        } else if (std.mem.eql(u8, line, "DARWIN_EXCLUDED = {")) {
            seen = true;
            inside = true;
        } else if (inside and std.mem.eql(u8, line, "}")) {
            inside = false;
        } else if (inside and std.mem.startsWith(u8, line, "    \"")) {
            const rest = line[5..];
            try out.append(ar, rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return error.BadExcludedLine]);
        }
    }
    if (!seen or inside) return error.NoDarwinExcluded;
    return out.items;
}

fn parseList(ar: std.mem.Allocator, json: []const u8) ![]const []const u8 {
    const root = (try std.json.parseFromSlice(std.json.Value, ar, json, .{})).value;
    var out = std.ArrayList([]const u8){};
    for (root.array.items) |v| try out.append(ar, v.string);
    return out.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The linux-64 directory mopm stage packs: every package's library and every declared native's archive.
fn linuxWant(ar: std.mem.Allocator, r: Release) ![]const []const u8 {
    var want = std.ArrayList([]const u8){};
    for (r.packages) |p| try want.append(ar, try std.fmt.allocPrint(ar, "linux-64/{s}/{s}.mojoc", .{ r.namespace, p }));
    var it = r.natives.iterator();
    while (it.next()) |entry| for (entry.value_ptr.array.items) |id|
        try want.append(ar, try std.fmt.allocPrint(ar, "linux-64/{s}/{s}.native/lib{s}.a", .{ r.namespace, entry.key_ptr.*, id.string }));
    return want.items;
}

/// Null when `got` (the directory's file paths) is exactly the release's linux-64 directory; otherwise the reason.
fn checkLinux(ar: std.mem.Allocator, got: []const []const u8, r: Release) !?[]const u8 {
    if (got.len == 0) return "the linux-64 layout lists no path: the check would be vacuous";
    const want = try linuxWant(ar, r);
    for (got) |path| if (!contains(want, path)) return try std.fmt.allocPrint(
        ar,
        "{s} is not a path mopm stage --artifacts reads for a member: linux-64/{s}/<name>.mojoc or linux-64/{s}/<name>.native/lib<id>.a",
        .{ path, r.namespace, r.namespace },
    );
    for (want) |path| if (!contains(got, path)) return try std.fmt.allocPrint(ar, "{s} is missing from the linux-64 layout", .{path});
    return null;
}

/// Null when `layout` (a JSON list of paths) is exactly `osx-arm64/<namespace>/<package>.mojoc` for every
/// package not in `darwin_excluded`; otherwise the reason.
fn checkDarwin(ar: std.mem.Allocator, layout: []const u8, r: Release) !?[]const u8 {
    const got = try parseList(ar, layout);
    if (got.len == 0) return "the osx-arm64 layout lists no path: the check would be vacuous";
    var want = std.ArrayList([]const u8){};
    for (r.packages) |p| if (!contains(r.darwin_excluded, p))
        try want.append(ar, try std.fmt.allocPrint(ar, "osx-arm64/{s}/{s}.mojoc", .{ r.namespace, p }));
    for (got) |path| if (!contains(want.items, path)) return try std.fmt.allocPrint(
        ar,
        "{s} is not osx-arm64/{s}/<name>.mojoc for a package of packages.bzl built for macOS",
        .{ path, r.namespace },
    );
    for (want.items) |path| if (!contains(got, path)) return try std.fmt.allocPrint(ar, "{s} is missing from the osx-arm64 layout", .{path});
    return null;
}

fn workPath(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(ar, &.{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), name });
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ar, try workPath(ar, name), 1 << 20);
}

/// The paths of the files under the directory `name`, relative to it, `/`-separated.
fn listFiles(ar: std.mem.Allocator, name: []const u8) ![]const []const u8 {
    var dir = try std.fs.cwd().openDir(try workPath(ar, name), .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(ar);
    defer walker.deinit();
    var out = std.ArrayList([]const u8){};
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        try out.append(ar, try ar.dupe(u8, entry.path));
    }
    return out.items;
}

fn realRelease(ar: std.mem.Allocator) !Release {
    const p = try parsePackages(ar, try read(ar, "packages.bzl"));
    const natives = (try std.json.parseFromSlice(std.json.Value, ar, try read(ar, "native_ids.json"), .{})).value.object;
    const excluded = try parseDarwinExcluded(ar, try read(ar, "darwin_libs.bzl"));
    return .{ .namespace = p.namespace, .packages = p.packages, .natives = natives, .darwin_excluded = excluded };
}

/// A two-package release with one native, for the refusal cases.
fn fixture(ar: std.mem.Allocator) !Release {
    const natives = (try std.json.parseFromSlice(std.json.Value, ar, "{\"libc\": [\"komira_libc_posix\"]}", .{})).value.object;
    return .{ .namespace = "komira-ai", .packages = &.{ "json", "libc" }, .natives = natives };
}

const fixture_linux_ok: []const []const u8 = &.{ "linux-64/komira-ai/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a" };

fn expectRefused(got: ?[]const u8, want: []const u8) !void {
    const reason = got orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, reason);
}

test "the built linux-64 directory is every package's library and every declared native's archive, under the namespace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try realRelease(ar);
    try t.expectEqualStrings("komira-ai", r.namespace);
    try t.expect(r.packages.len > 0);
    if (try checkLinux(ar, try listFiles(ar, "linux_artifacts"), r)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "the real osx-arm64 layout is the library of every package built for macOS, under the namespace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try checkDarwin(ar, try read(ar, "darwin_layout.json"), try realRelease(ar))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "the fixture's namespaced linux-64 layout is accepted, in any order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expectEqual(@as(?[]const u8, null), try checkLinux(ar, fixture_linux_ok, try fixture(ar)));
    const reversed: []const []const u8 = &.{ "linux-64/komira-ai/libc.native/libkomira_libc_posix.a", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/json.mojoc" };
    try t.expectEqual(@as(?[]const u8, null), try checkLinux(ar, reversed, try fixture(ar)));
}

test "a library without the namespace directory is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const flat: []const []const u8 = &.{ "linux-64/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a" };
    try expectRefused(try checkLinux(ar, flat, try fixture(ar)), "linux-64/json.mojoc is not a path mopm stage --artifacts reads for a member: linux-64/komira-ai/<name>.mojoc or linux-64/komira-ai/<name>.native/lib<id>.a");
}

test "an archive without the namespace directory is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const flat: []const []const u8 = &.{ "linux-64/komira-ai/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/libc.native/libkomira_libc_posix.a" };
    try expectRefused(try checkLinux(ar, flat, try fixture(ar)), "linux-64/libc.native/libkomira_libc_posix.a is not a path mopm stage --artifacts reads for a member: linux-64/komira-ai/<name>.mojoc or linux-64/komira-ai/<name>.native/lib<id>.a");
}

test "another namespace or another subdir is refused, naming the path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const other_ns: []const []const u8 = &.{ "linux-64/example/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a" };
    try expectRefused(try checkLinux(ar, other_ns, try fixture(ar)), "linux-64/example/json.mojoc is not a path mopm stage --artifacts reads for a member: linux-64/komira-ai/<name>.mojoc or linux-64/komira-ai/<name>.native/lib<id>.a");
    const other_subdir: []const []const u8 = &.{ "noarch/komira-ai/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a" };
    try expectRefused(try checkLinux(ar, other_subdir, try fixture(ar)), "noarch/komira-ai/json.mojoc is not a path mopm stage --artifacts reads for a member: linux-64/komira-ai/<name>.mojoc or linux-64/komira-ai/<name>.native/lib<id>.a");
}

test "a missing library or a missing declared archive is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const no_json: []const []const u8 = &.{ "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a" };
    try expectRefused(try checkLinux(ar, no_json, try fixture(ar)), "linux-64/komira-ai/json.mojoc is missing from the linux-64 layout");
    const no_archive: []const []const u8 = &.{ "linux-64/komira-ai/json.mojoc", "linux-64/komira-ai/libc.mojoc" };
    try expectRefused(try checkLinux(ar, no_archive, try fixture(ar)), "linux-64/komira-ai/libc.native/libkomira_libc_posix.a is missing from the linux-64 layout");
}

test "a library of no package is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const extra: []const []const u8 = &.{ "linux-64/komira-ai/json.mojoc", "linux-64/komira-ai/libc.mojoc", "linux-64/komira-ai/libc.native/libkomira_libc_posix.a", "linux-64/komira-ai/ghost.mojoc" };
    try expectRefused(try checkLinux(ar, extra, try fixture(ar)), "linux-64/komira-ai/ghost.mojoc is not a path mopm stage --artifacts reads for a member: linux-64/komira-ai/<name>.mojoc or linux-64/komira-ai/<name>.native/lib<id>.a");
}

test "an empty layout is refused, not passed vacuously" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(try checkLinux(ar, &.{}, try fixture(ar)), "the linux-64 layout lists no path: the check would be vacuous");
    try expectRefused(try checkDarwin(ar, "[]", try fixture(ar)), "the osx-arm64 layout lists no path: the check would be vacuous");
}

test "an osx-arm64 library without the namespace, of no package, not a library, missing or excluded is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const ok = "[\"osx-arm64/komira-ai/json.mojoc\", \"osx-arm64/komira-ai/libc.mojoc\"]";
    try t.expectEqual(@as(?[]const u8, null), try checkDarwin(ar, ok, try fixture(ar)));
    const want_tail = " is not osx-arm64/komira-ai/<name>.mojoc for a package of packages.bzl built for macOS";
    try expectRefused(try checkDarwin(ar, "[\"osx-arm64/json.mojoc\", \"osx-arm64/komira-ai/libc.mojoc\"]", try fixture(ar)), "osx-arm64/json.mojoc" ++ want_tail);
    try expectRefused(try checkDarwin(ar, "[\"osx-arm64/komira-ai/ghost.mojoc\"]", try fixture(ar)), "osx-arm64/komira-ai/ghost.mojoc" ++ want_tail);
    try expectRefused(try checkDarwin(ar, "[\"osx-arm64/komira-ai/json.a\"]", try fixture(ar)), "osx-arm64/komira-ai/json.a" ++ want_tail);
    try expectRefused(try checkDarwin(ar, "[\"linux-64/komira-ai/json.mojoc\"]", try fixture(ar)), "linux-64/komira-ai/json.mojoc" ++ want_tail);
    try expectRefused(try checkDarwin(ar, "[\"osx-arm64/komira-ai/json.mojoc\"]", try fixture(ar)), "osx-arm64/komira-ai/libc.mojoc is missing from the osx-arm64 layout");
    var excluding = try fixture(ar);
    excluding.darwin_excluded = &.{"libc"};
    try t.expectEqual(@as(?[]const u8, null), try checkDarwin(ar, "[\"osx-arm64/komira-ai/json.mojoc\"]", excluding));
    try expectRefused(try checkDarwin(ar, ok, excluding), "osx-arm64/komira-ai/libc.mojoc" ++ want_tail);
}

test "DARWIN_EXCLUDED is read empty, with entries, and refused when absent" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expectEqual(@as(usize, 0), (try parseDarwinExcluded(ar, "DARWIN_EXCLUDED = {}\n")).len);
    const two = try parseDarwinExcluded(ar, "DARWIN_EXCLUDED = {\n    \"awslc\": \"vendored C\",\n    \"zlib\": \"vendored C\",\n}\n");
    try t.expectEqual(@as(usize, 2), two.len);
    try t.expectEqualStrings("awslc", two[0]);
    try t.expectEqualStrings("zlib", two[1]);
    try t.expectError(error.NoDarwinExcluded, parseDarwinExcluded(ar, "PACKAGES = {}\n"));
    try t.expectError(error.NoDarwinExcluded, parseDarwinExcluded(ar, "DARWIN_EXCLUDED = {\n    \"awslc\": \"x\",\n"));
}

test "packages.bzl without NAMESPACE is refused, so the real cases cannot pass on an empty namespace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.NoNamespace, parsePackages(arena.allocator(), "PACKAGES = {\n    \"json\": \"0.1.0\",\n}\n"));
}
