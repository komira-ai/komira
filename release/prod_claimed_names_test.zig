//! The cases of //release:prod_claimed_names_cases, a `zig_test` run as a build action.
//!
//! release.yml publishes every release member to the prod registry on every push to main, and the
//! registry creates a package name only for its claimed owner, so a member whose name is not
//! claimed there fails `prod-stage` and turns main red. The pull request check cannot write to the
//! live registry (and does not read it), so the claimed names are committed in
//! release/prod_claimed_names.txt and this test holds the members to them. What it catches:
//!  - a member of PACKAGES (release/readme_e2e/packages.bzl: every src/<name> with a mopm.toml,
//!    which //:readme_e2e_complete holds to the files) that the list does not hold: refused,
//!    naming the package and saying to claim it first and then add it to the file;
//!  - a list that is not sorted, holds a name twice, or holds a line that is no package name,
//!    so a merge cannot leave it unreadable;
//!  - a list holding a name no member has: a deleted or renamed member leaves its line behind,
//!    so the file cannot drift from the release (a name still claimed on prod stays claimed;
//!    removing the line costs nothing);
//!  - an empty PACKAGES, or an empty list, which would make the check vacuous.
//! The cases plant each defect in the text of the real files and expect the exact message.

const std = @import("std");
const t = std.testing;

const FILE = "release/prod_claimed_names.txt";

/// The package names of `PACKAGES = { ... }` in packages.bzl.
fn members(ar: std.mem.Allocator, bzl: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var inside = false;
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "PACKAGES = {")) {
            inside = true;
            continue;
        }
        if (!inside) continue;
        if (std.mem.startsWith(u8, line, "}")) break;
        const s = std.mem.trim(u8, line, " \t");
        if (s.len < 2 or s[0] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse continue;
        try out.append(ar, s[1..end]);
    }
    return out.toOwnedSlice(ar);
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

/// Null when the list is well formed and holds exactly the members; else the refusal.
fn check(ar: std.mem.Allocator, bzl: []const u8, list: []const u8) !?[]const u8 {
    const want = try members(ar, bzl);
    if (want.len == 0) return "PACKAGES of release/readme_e2e/packages.bzl holds no package: the check would be vacuous";
    var have = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!isName(line)) return try std.fmt.allocPrint(ar, "{s}: \"{s}\" is not a package name (lowercase letters, digits and underscores, one per line)", .{ FILE, line });
        if (have.items.len > 0) {
            const prev = have.items[have.items.len - 1];
            if (std.mem.eql(u8, prev, line)) return try std.fmt.allocPrint(ar, "{s}: {s} is listed twice", .{ FILE, line });
            if (std.mem.order(u8, prev, line) != .lt) return try std.fmt.allocPrint(ar, "{s}: {s} is not in sorted order (it follows {s})", .{ FILE, line, prev });
        }
        try have.append(ar, line);
    }
    if (have.items.len == 0) return try std.fmt.allocPrint(ar, "{s} holds no name: the check would be vacuous", .{FILE});
    for (want) |name| {
        if (!contains(have.items, name)) return try std.fmt.allocPrint(
            ar,
            "{s} is a member of the release and is not in {s}: claim it on the prod registry first, then add it to {s}",
            .{ name, FILE, FILE },
        );
    }
    for (have.items) |name| {
        if (!contains(want, name)) return try std.fmt.allocPrint(
            ar,
            "{s} lists {s}, which is no release member (no src/{s}/mopm.toml in PACKAGES of release/readme_e2e/packages.bzl): delete the line",
            .{ FILE, name, name },
        );
    }
    return null;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 1 << 20);
}

fn expectRefused(ar: std.mem.Allocator, bzl: []const u8, list: []const u8, want: []const u8) !void {
    const got = (try check(ar, bzl, list)) orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "every release member is claimed on prod (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try check(ar, try read(ar, "packages.bzl"), try read(ar, "prod_claimed_names.txt"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a member planted in PACKAGES and not in the list is refused, naming it and the fix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const bzl = try read(ar, "packages.bzl");
    const list = try read(ar, "prod_claimed_names.txt");
    const planted = try std.mem.replaceOwned(u8, ar, bzl, "PACKAGES = {\n", "PACKAGES = {\n    \"komira_planted_unclaimed\": \"0.1.0\",\n");
    try t.expect(!std.mem.eql(u8, planted, bzl));
    try expectRefused(ar, planted, list, "komira_planted_unclaimed is a member of the release and is not in release/prod_claimed_names.txt: claim it on the prod registry first, then add it to release/prod_claimed_names.txt");
}

test "a name dropped from the list is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const bzl = try read(ar, "packages.bzl");
    const list = try read(ar, "prod_claimed_names.txt");
    const dropped = try std.mem.replaceOwned(u8, ar, list, "komira_json\n", "");
    try t.expect(!std.mem.eql(u8, dropped, list));
    try expectRefused(ar, bzl, dropped, "komira_json is a member of the release and is not in");
}

test "a list that is unsorted, repeats a name, holds junk or a stale name is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const bzl = "PACKAGES = {\n    \"a_one\": \"0.1.0\",\n    \"b_two\": \"0.1.0\",\n}\n";
    try t.expect((try check(ar, bzl, "# c\na_one\nb_two\n")) == null);
    try expectRefused(ar, bzl, "b_two\na_one\n", "a_one is not in sorted order (it follows b_two)");
    try expectRefused(ar, bzl, "a_one\na_one\nb_two\n", "a_one is listed twice");
    try expectRefused(ar, bzl, "a_one\nB-two\n", "\"B-two\" is not a package name");
    try expectRefused(ar, bzl, "a_one\nb_two\nc_old\n", "c_old, which is no release member");
}

test "an empty list or empty PACKAGES is refused, not passed vacuously" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(ar, "PACKAGES = {\n}\n", "a\n", "holds no package");
    try expectRefused(ar, "PACKAGES = {\n    \"a\": \"1\",\n}\n", "# only a comment\n", "holds no name");
}
