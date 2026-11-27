//! The cases of //release:npm_names_cases, a `zig_test` run as a build action.
//!
//! release/npm_names.txt lists the npm packages of a release, the names the owner creates on npm with
//! their trusted publisher before anything is published, and this test holds it equal to the sets the build
//! makes: the names in //release:npm_packages[npm_set.json] (built unstamped here, as the pull request
//! builds it), the record npm.yml publishes from when the macOS install test did not pass, together with
//! the names of //release:npm_packages_macos_arm64 (the set it publishes when that test passed), which is
//! built on the farm's macOS workers alone, so here its names are //release:npm_macos_arm64_names, written
//! from the list release/BUCK gives that set. What it catches:
//!  - a package in a set that the list does not hold (a platform package added to a set without its line):
//!    refused, naming it, so the list cannot fall behind what npm.yml would publish;
//!  - a name in the list that no set holds (a package dropped from the sets, or a typo): refused, naming it;
//!  - a list that is not sorted, holds a name twice, or holds a line that is no package name of the scope,
//!    so a merge cannot leave it unreadable;
//!  - an empty list, or a set with no package, which would make the check vacuous.
//! The cases write each defect into the text of the real files and expect the exact message.

const std = @import("std");
const t = std.testing;

const FILE = "release/npm_names.txt";
const SCOPE = "@komira-ai/";

fn isName(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, SCOPE)) return false;
    const rest = s[SCOPE.len..];
    if (rest.len == 0 or rest[0] == '-' or rest[rest.len - 1] == '-') return false;
    for (rest) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

/// The names of the packages of npm_set.json, or null when it holds no list of named packages.
fn setNames(ar: std.mem.Allocator, json: []const u8) !?[]const []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, ar, json, .{}) catch return null;
    if (root != .object) return null;
    const packages = root.object.get("packages") orelse return null;
    if (packages != .array) return null;
    var out = std.ArrayList([]const u8).empty;
    for (packages.array.items) |p| {
        if (p != .object) return null;
        const name = p.object.get("name") orelse return null;
        if (name != .string) return null;
        try out.append(ar, name.string);
    }
    return try out.toOwnedSlice(ar);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const SETS = "//release:npm_packages or //release:npm_packages_macos_arm64";

/// Null when the list is well formed and holds exactly the names of the sets (each the text of an
/// npm_set.json, or of the names of one); else the refusal.
fn check(ar: std.mem.Allocator, sets: []const []const u8, list: []const u8) !?[]const u8 {
    var all = std.ArrayList([]const u8).empty;
    for (sets) |json| {
        const names = (try setNames(ar, json)) orelse return "npm_set.json is not an object with a list of named packages";
        if (names.len == 0) return "npm_set.json holds no package: the check would be vacuous";
        for (names) |n| {
            if (!contains(all.items, n)) try all.append(ar, n);
        }
    }
    const want = all.items;
    var have = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!isName(line)) return try std.fmt.allocPrint(ar, "{s}: \"{s}\" is not a package name of {s} (lowercase letters, digits and inner hyphens, one per line)", .{ FILE, line, SCOPE });
        if (have.items.len > 0) {
            const prev = have.items[have.items.len - 1];
            if (std.mem.eql(u8, prev, line)) return try std.fmt.allocPrint(ar, "{s}: {s} is listed twice", .{ FILE, line });
            if (std.mem.order(u8, prev, line) != .lt) return try std.fmt.allocPrint(ar, "{s}: {s} is not in sorted order (it follows {s})", .{ FILE, line, prev });
        }
        try have.append(ar, line);
    }
    if (have.items.len == 0) return try std.fmt.allocPrint(ar, "{s} holds no name: the check would be vacuous", .{FILE});
    for (want) |name| {
        if (!contains(have.items, name)) return try std.fmt.allocPrint(ar, "{s} is a package of {s} and is not in {s}: add it, and create it on npm with its trusted publisher before the first publish", .{ name, SETS, FILE });
    }
    for (have.items) |name| {
        if (!contains(want, name)) return try std.fmt.allocPrint(ar, "{s} lists {s}, which is no package of {s}: remove the line, or add the package to a set", .{ FILE, name, SETS });
    }
    return null;
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 1 << 20);
}

fn expectRefused(ar: std.mem.Allocator, sets: []const []const u8, list: []const u8, want: []const u8) !void {
    const got = (try check(ar, sets, list)) orelse {
        std.debug.print("accepted; wanted the refusal: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, got);
}

/// `text` with `from` replaced by `to`, which must change it.
fn edit(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const out = try std.mem.replaceOwned(u8, ar, text, from, to);
    try t.expect(!std.mem.eql(u8, out, text));
    return out;
}

/// The two records the target stages: the set's, and the macOS set's names.
fn realSets(ar: std.mem.Allocator) ![]const []const u8 {
    return ar.dupe([]const u8, &.{ try read(ar, "npm_set.json"), try read(ar, "npm_macos_arm64_names.json") });
}

test "the list is the sets' names (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try check(ar, try realSets(ar), try read(ar, "npm_names.txt"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a package of a set that the list does not hold is refused, naming it and the fix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const sets = try realSets(ar);
    const list = try read(ar, "npm_names.txt");
    // a second platform package in the set, its line not added
    const more = try edit(ar, sets[0], "\"packages\": [\n", "\"packages\": [\n    {\"name\": \"@komira-ai/komira-linux-arm64-gnu\"},\n");
    try expectRefused(ar, &.{ more, sets[1] }, list, "@komira-ai/komira-linux-arm64-gnu is a package of //release:npm_packages or //release:npm_packages_macos_arm64 and is not in release/npm_names.txt: add it, and create it on npm with its trusted publisher before the first publish");
    // a line of the list dropped: the linux-x64 package's, and the macOS package's, which only the macOS set holds
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira-linux-x64-gnu\n", ""), "@komira-ai/komira-linux-x64-gnu is a package of //release:npm_packages or //release:npm_packages_macos_arm64 and is not in release/npm_names.txt: add it, and create it on npm with its trusted publisher before the first publish");
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira-darwin-arm64\n", ""), "@komira-ai/komira-darwin-arm64 is a package of //release:npm_packages or //release:npm_packages_macos_arm64 and is not in release/npm_names.txt: add it, and create it on npm with its trusted publisher before the first publish");
}

test "a name in the list that no set holds is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const sets = try realSets(ar);
    const list = try read(ar, "npm_names.txt");
    try expectRefused(ar, sets, try std.fmt.allocPrint(ar, "{s}@komira-ai/komira-win32-x64\n", .{list}), "release/npm_names.txt lists @komira-ai/komira-win32-x64, which is no package of //release:npm_packages or //release:npm_packages_macos_arm64: remove the line, or add the package to a set");
    // the macOS package listed, and the macOS set's names not given: the Linux set alone does not hold it
    try expectRefused(ar, sets[0..1], list, "release/npm_names.txt lists @komira-ai/komira-darwin-arm64, which is no package of //release:npm_packages or //release:npm_packages_macos_arm64: remove the line, or add the package to a set");
}

test "a list that is not sorted, holds a name twice or a line that is no name is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const sets = try realSets(ar);
    const list = try read(ar, "npm_names.txt");
    const swapped = try edit(ar, list, "@komira-ai/komira-darwin-arm64\n@komira-ai/komira-linux-x64-gnu\n", "@komira-ai/komira-linux-x64-gnu\n@komira-ai/komira-darwin-arm64\n");
    try expectRefused(ar, sets, swapped, "release/npm_names.txt: @komira-ai/komira-darwin-arm64 is not in sorted order (it follows @komira-ai/komira-linux-x64-gnu)");
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira\n", "@komira-ai/komira\n@komira-ai/komira\n"), "release/npm_names.txt: @komira-ai/komira is listed twice");
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira\n", "komira\n"), "release/npm_names.txt: \"komira\" is not a package name of @komira-ai/ (lowercase letters, digits and inner hyphens, one per line)");
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira\n", "@komira-ai/Komira\n"), "release/npm_names.txt: \"@komira-ai/Komira\" is not a package name of @komira-ai/ (lowercase letters, digits and inner hyphens, one per line)");
    try expectRefused(ar, sets, try edit(ar, list, "@komira-ai/komira\n", "<<<<<<< HEAD\n"), "release/npm_names.txt: \"<<<<<<< HEAD\" is not a package name of @komira-ai/ (lowercase letters, digits and inner hyphens, one per line)");
}

test "an empty list, or a set with no package, is refused: the check would be vacuous" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const sets = try realSets(ar);
    const list = try read(ar, "npm_names.txt");
    try expectRefused(ar, sets, "# only comments\n\n", "release/npm_names.txt holds no name: the check would be vacuous");
    try expectRefused(ar, &.{ "{\"main\": \"@komira-ai/komira\", \"packages\": []}", sets[1] }, list, "npm_set.json holds no package: the check would be vacuous");
    try expectRefused(ar, &.{ sets[0], "{\"packages\": []}" }, list, "npm_set.json holds no package: the check would be vacuous");
    try expectRefused(ar, &.{ "not json", sets[1] }, list, "npm_set.json is not an object with a list of named packages");
}
