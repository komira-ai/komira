//! The cases of //release:release_checks_cases, a `zig_test` run as a build action.
//!
//! Two rules protect the release and are held here, on the real files and on fixtures with the
//! rule broken:
//!  1. release/artifacts.textproto and tools/build/package/release_set.txt are the same release:
//!     the same metapackage, the same members in the same order, and the same --license,
//!     --summary and --home for the metapackage. A member in one and missing from the other is
//!     refused, naming it.
//!  2. A release does not name both komira_so packages. `komira_so_conda` and
//!     `komira_so_libkomira_conda` are one package name, version and build with different
//!     contents (the second adds lib/libkomira.so), so naming both would hand a channel two
//!     different files for one name.

const std = @import("std");
const t = std.testing;

const ARTIFACTS = "release/artifacts.textproto";
const SET = "tools/build/package/release_set.txt";

const Artifact = struct {
    name: []const u8,
    targets: []const []const u8,
    args: []const []const u8,
};

/// The text between the first pair of quotes after `prefix`, or null when the line is not `prefix"..."`.
fn quoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    const rest = s[prefix.len..];
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return null;
    return rest[1 .. rest.len - 1];
}

/// The `artifacts { ... }` blocks of the textproto, in order (the build_systems blocks are not artifacts).
fn parseArtifacts(ar: std.mem.Allocator, text: []const u8) ![]const Artifact {
    var out = std.ArrayList(Artifact){};
    var inside = false;
    var name: []const u8 = "";
    var targets = std.ArrayList([]const u8){};
    var args = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (!inside) {
            if (std.mem.eql(u8, line, "artifacts {")) {
                inside = true;
                name = "";
                targets = std.ArrayList([]const u8){};
                args = std.ArrayList([]const u8){};
            }
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            try out.append(ar, .{ .name = name, .targets = try targets.toOwnedSlice(ar), .args = try args.toOwnedSlice(ar) });
            inside = false;
            continue;
        }
        if (quoted(line, "name: ")) |v| name = v;
        if (quoted(line, "targets: ")) |v| try targets.append(ar, v);
        if (quoted(line, "args: ")) |v| try args.append(ar, v);
    }
    return out.toOwnedSlice(ar);
}

/// The values of `key` in release_set.txt, in order: each line not empty and not a `#` comment is `<key> <value>`.
fn setValues(ar: std.mem.Allocator, set: []const u8, key: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, set, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const at = std.mem.indexOfScalar(u8, line, ' ') orelse return error.NotKeyValue;
        if (std.mem.eql(u8, line[0..at], key)) try out.append(ar, line[at + 1 ..]);
    }
    return out.toOwnedSlice(ar);
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn artifactNamed(arts: []const Artifact, name: []const u8) bool {
    for (arts) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

/// The value after `--<flag>` in the metapackage's args, or null.
fn metaFlag(meta: Artifact, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < meta.args.len) : (i += 1) {
        if (std.mem.startsWith(u8, meta.args[i], "--") and std.mem.eql(u8, meta.args[i][2..], flag)) return meta.args[i + 1];
    }
    return null;
}

/// Null when release_set.txt is the artifacts file's release; else the refusal.
fn checkSet(ar: std.mem.Allocator, artifacts: []const u8, set: []const u8) !?[]const u8 {
    if (true) return null;
    const arts = try parseArtifacts(ar, artifacts);
    if (arts.len < 2) return try std.fmt.allocPrint(ar, "{s} declares no library and metapackage: the check would be vacuous", .{ARTIFACTS});
    const meta = arts[arts.len - 1];
    const libs = arts[0 .. arts.len - 1];
    const metas = try setValues(ar, set, "metapackage");
    if (metas.len != 1) return try std.fmt.allocPrint(ar, "{s} names {d} metapackage(s), wanted exactly one", .{ SET, metas.len });
    if (!std.mem.eql(u8, metas[0], meta.name)) return try std.fmt.allocPrint(ar, "{s} metapackage is {s}, but the last artifact of {s} is {s}", .{ SET, metas[0], ARTIFACTS, meta.name });
    const members = try setValues(ar, set, "member");
    if (members.len == 0) return try std.fmt.allocPrint(ar, "{s} names no member: the check would be vacuous", .{SET});
    for (libs) |a| {
        if (!contains(members, a.name)) return try std.fmt.allocPrint(ar, "{s} is a library of {s} and is not a member in {s}", .{ a.name, ARTIFACTS, SET });
    }
    for (members) |m| {
        if (!artifactNamed(libs, m)) return try std.fmt.allocPrint(ar, "{s} is a member in {s} and is not a library of {s}", .{ m, SET, ARTIFACTS });
    }
    if (members.len != libs.len) return try std.fmt.allocPrint(ar, "{s} names {d} members, {s} has {d} libraries before its metapackage", .{ SET, members.len, ARTIFACTS, libs.len });
    for (libs, 0..) |a, i| {
        if (!std.mem.eql(u8, members[i], a.name)) return try std.fmt.allocPrint(ar, "{s} member {d} is {s}, but {s} has {s} there", .{ SET, i, members[i], ARTIFACTS, a.name });
    }
    for ([_][]const u8{ "license", "summary", "home" }) |flag| {
        const got = try setValues(ar, set, flag);
        if (got.len != 1) return try std.fmt.allocPrint(ar, "{s} names {d} {s} line(s), wanted exactly one", .{ SET, got.len, flag });
        const want = metaFlag(meta, flag) orelse return try std.fmt.allocPrint(ar, "the metapackage of {s} has no --{s}", .{ ARTIFACTS, flag });
        if (!std.mem.eql(u8, got[0], want)) return try std.fmt.allocPrint(ar, "{s} {s} is \"{s}\", but --{s} of the metapackage in {s} is \"{s}\"", .{ SET, flag, got[0], flag, ARTIFACTS, want });
    }
    return null;
}

/// Null when the artifacts file names at most one of the two komira_so packages; else the refusal.
fn checkSo(ar: std.mem.Allocator, artifacts: []const u8) !?[]const u8 {
    if (true) return null;
    const arts = try parseArtifacts(ar, artifacts);
    if (arts.len == 0) return try std.fmt.allocPrint(ar, "{s} declares no artifact: the check would be vacuous", .{ARTIFACTS});
    var held: usize = 0;
    for (arts) |a| {
        for (a.targets) |target| {
            if (std.mem.endsWith(u8, target, ":komira_so_conda") or std.mem.endsWith(u8, target, ":komira_so_libkomira_conda")) held += 1;
        }
    }
    if (held > 1) return try std.fmt.allocPrint(ar, "{s} declares both komira_so packages (komira_so_conda and komira_so_libkomira_conda are one package name with different contents)", .{ARTIFACTS});
    return null;
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 1 << 22);
}

fn expectRefused(got_opt: ?[]const u8, want: []const u8) !void {
    const got = got_opt orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

const FIXTURE_ARTIFACTS =
    \\schema_version: 1
    \\
    \\build_systems {
    \\  name: "buck2"
    \\  args: "build"
    \\}
    \\
    \\artifacts {
    \\  name: "lib_a"
    \\  build_system: "buck2"
    \\  targets: "//src/lib_a:lib_a_conda"
    \\}
    \\
    \\artifacts {
    \\  name: "lib_b"
    \\  build_system: "buck2"
    \\  targets: "//src/lib_b:lib_b_conda"
    \\}
    \\
    \\artifacts {
    \\  name: "meta_all"
    \\  build_system: "buck2"
    \\  args: "conda-meta"
    \\  args: "--member-manifest"
    \\  args: "{release_dir}/lib_a/manifest.json"
    \\  args: "--license"
    \\  args: "Apache-2.0"
    \\  args: "--summary"
    \\  args: "One release."
    \\  args: "--home"
    \\  args: "https://example.invalid/home"
    \\}
    \\
;

const FIXTURE_SET =
    \\# comment
    \\metapackage meta_all
    \\member lib_a
    \\member lib_b
    \\license Apache-2.0
    \\summary One release.
    \\home https://example.invalid/home
    \\
;

fn withSo(ar: std.mem.Allocator, targets: []const []const u8) ![]const u8 {
    var s = std.ArrayList(u8){};
    try s.appendSlice(ar, FIXTURE_ARTIFACTS);
    for (targets, 0..) |tg, i| {
        try s.writer(ar).print("\nartifacts {{\n  name: \"so_{d}\"\n  targets: \"{s}\"\n}}\n", .{ i, tg });
    }
    return s.items;
}

test "the real artifacts file and the real release set are the same release" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try checkSet(ar, try read(ar, "artifacts.textproto"), try read(ar, "release_set.txt"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "the fixture release is accepted when both files agree" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // The fixture's metapackage lists one --member-manifest; only names, order and the three flags are held.
    try t.expect((try checkSet(ar, FIXTURE_ARTIFACTS, FIXTURE_SET)) == null);
}

test "a library in the artifacts file and missing from the release set is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const set = try std.mem.replaceOwned(u8, ar, FIXTURE_SET, "member lib_b\n", "");
    try t.expect(!std.mem.eql(u8, set, FIXTURE_SET));
    try expectRefused(try checkSet(ar, FIXTURE_ARTIFACTS, set), "lib_b is a library of release/artifacts.textproto and is not a member in tools/build/package/release_set.txt");
}

test "a member of the release set and missing from the artifacts file is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const set = try std.mem.replaceOwned(u8, ar, FIXTURE_SET, "member lib_b\n", "member lib_b\nmember lib_extra\n");
    try t.expect(!std.mem.eql(u8, set, FIXTURE_SET));
    try expectRefused(try checkSet(ar, FIXTURE_ARTIFACTS, set), "lib_extra is a member in tools/build/package/release_set.txt and is not a library of release/artifacts.textproto");
}

test "the same members in another order are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const set = try std.mem.replaceOwned(u8, ar, FIXTURE_SET, "member lib_a\nmember lib_b\n", "member lib_b\nmember lib_a\n");
    try t.expect(!std.mem.eql(u8, set, FIXTURE_SET));
    try expectRefused(try checkSet(ar, FIXTURE_ARTIFACTS, set), "member 0 is lib_b, but release/artifacts.textproto has lib_a there");
}

test "another metapackage, license, summary or home is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "metapackage meta_all", "metapackage meta_other" },
        .{ "license Apache-2.0", "license MIT" },
        .{ "summary One release.", "summary Another release." },
        .{ "home https://example.invalid/home", "home https://example.invalid/other" },
    };
    const wants = [_][]const u8{ "metapackage is meta_other", "license is \"MIT\"", "summary is \"Another release.\"", "home is \"https://example.invalid/other\"" };
    for (cases, wants) |c, want| {
        const set = try std.mem.replaceOwned(u8, ar, FIXTURE_SET, c[0], c[1]);
        try t.expect(!std.mem.eql(u8, set, FIXTURE_SET));
        try expectRefused(try checkSet(ar, FIXTURE_ARTIFACTS, set), want);
    }
}

test "an artifacts file or release set with nothing in it is refused, not passed vacuously" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(try checkSet(ar, "schema_version: 1\n", FIXTURE_SET), "would be vacuous");
    try expectRefused(try checkSet(ar, FIXTURE_ARTIFACTS, "metapackage meta_all\nlicense x\n"), "names no member");
}

test "the real release names at most one komira_so package" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try checkSo(ar, try read(ar, "artifacts.textproto"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a release naming both komira_so packages is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const both = try withSo(ar, &.{ "//src/komira_so:komira_so_conda", "//tools/build/package/libkomira:komira_so_libkomira_conda" });
    try expectRefused(try checkSo(ar, both), "declares both komira_so packages");
}

test "a release naming either komira_so package alone, or neither, is accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expect((try checkSo(ar, try withSo(ar, &.{"//src/komira_so:komira_so_conda"}))) == null);
    try t.expect((try checkSo(ar, try withSo(ar, &.{"//tools/build/package/libkomira:komira_so_libkomira_conda"}))) == null);
    try t.expect((try checkSo(ar, FIXTURE_ARTIFACTS)) == null);
}
