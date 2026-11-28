//! The cases of `release_staged_verify expect` (plan_expect.zig), //tools/build/ci:plan_expect_unit. Each case is
//! a plan `mopm stage` could write that is not the set the release builds, and that `verify`, `smoke` and `add`
//! would pass because they read the plan: a member without its osx-arm64 file, a plan with no osx-arm64 file at
//! all, a package left out, a member nobody expects, a file for a subdir a package does not build for, two files
//! for one subdir; and an expectation that could let such a plan through (empty, a name that is not a full
//! name, a name twice, no subdir, a subdir twice or not a plain name). The last cases run on the expectation
//! //release:mopm_plan_expectation writes from the release's own package lists (the zig_test's `data`).
const std = @import("std");
const pe = @import("plan_expect.zig");
const rbf = @import("release_beta_fetch.zig");
const t = std.testing;

const SHA = "a" ** 64;

/// One member of a plan under test: its full name, the subdirs it has a file in, and the Mojo versions it has a
/// build for in each of them (one file per pair).
const M = struct { name: []const u8, subdirs: []const []const u8, mojos: []const []const u8 = &.{"1.1.0"} };

const TWO = &[_][]const u8{ "1.1.0", "1.2.0" };

const BOTH = &[_][]const u8{ "linux-64", "osx-arm64" };
const LINUX = &[_][]const u8{"linux-64"};
const MAC = &[_][]const u8{"osx-arm64"};

/// The expectation of three packages: ns/a and ns/b on both platforms, ns/c (excluded from the macOS build)
/// on linux-64 only.
const EXPECT =
    \\{"members":[
    \\ {"name":"ns/a","subdirs":["linux-64","osx-arm64"]},
    \\ {"name":"ns/b","subdirs":["linux-64","osx-arm64"]},
    \\ {"name":"ns/c","subdirs":["linux-64"]}
    \\]}
;

/// A `plan.json` (version 2, as `mopm stage` writes it) with one file per subdir of each member.
fn planJson(a: std.mem.Allocator, members: []const M) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    try w.writer.writeAll("{\"version\":2,\"members\":[");
    for (members, 0..) |m, i| {
        const slash = std.mem.indexOfScalar(u8, m.name, '/').?;
        const dotted = try std.fmt.allocPrint(a, "{s}.{s}", .{ m.name[0..slash], m.name[slash + 1 ..] });
        try w.writer.print("{s}{{\"name\":\"{s}\",\"version\":\"0.1.9\",\"action\":\"upload\",\"readme\":\"{s}/README.md\",\"files\":[", .{ if (i == 0) "" else ",", m.name, m.name });
        var j: usize = 0;
        for (m.subdirs) |s| for (m.mojos) |v| {
            try w.writer.print("{s}{{\"subdir\":\"{s}\",\"filename\":\"mojo-{s}-0.1.9-mojo{s}_0.conda\",\"sha256\":\"{s}\",\"size\":1}}", .{ if (j == 0) "" else ",", s, dotted, v, SHA });
            j += 1;
        };
        try w.writer.writeAll("]}");
    }
    try w.writer.writeAll("]}");
    return w.written();
}

fn plan(a: std.mem.Allocator, members: []const M) !rbf.Plan {
    var why: []const u8 = "";
    return rbf.parsePlan(a, &why, try planJson(a, members));
}

fn expectation(a: std.mem.Allocator, text: []const u8) !pe.Expectation {
    var why: []const u8 = "";
    return pe.parseExpectation(a, &why, text);
}

fn expectLines(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("got {d} difference(s), want {d}:\n", .{ got.len, want.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestWrongDifferences;
    }
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

/// The expectation refused with exactly `want`.
fn refusedExpectation(text: []const u8, want: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var why: []const u8 = "";
    if (pe.parseExpectation(ar.allocator(), &why, text)) |_| return error.TestExpectedRefusal else |e| {
        try t.expect(e == error.Refused);
        try t.expectEqualStrings(want, why);
    }
}

// ---- the plan against the expectation --------------------------------------------------------

test "a plan with every member on every platform its package builds for has no difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a member without its osx-arm64 file is a difference naming the package and the subdir" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = LINUX }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{"ns/b: no file for osx-arm64"}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a plan with no osx-arm64 file at all names every package that builds for macOS" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = LINUX }, .{ .name = "ns/b", .subdirs = LINUX }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{ "ns/a: no file for osx-arm64", "ns/b: no file for osx-arm64" }, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a member without its linux-64 file is a difference too" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = MAC }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{"ns/a: no file for linux-64"}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a package of the expectation that is not a member of the plan is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{"ns/b: not a member of the plan (expected on linux-64, osx-arm64)"}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a member of the plan that the expectation does not name is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX }, .{ .name = "ns/extra", .subdirs = BOTH } });
    try expectLines(&.{"ns/extra: a member of the plan that the expectation does not name"}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a member under another namespace is not the expected package: both sides are named" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "other/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{
        "ns/b: not a member of the plan (expected on linux-64, osx-arm64)",
        "other/b: a member of the plan that the expectation does not name",
    }, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "a package expected on linux-64 only (left out of the macOS build) with an osx-arm64 file is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = BOTH } });
    try expectLines(&.{"ns/c: a file for osx-arm64 (mojo-ns.c-0.1.9-mojo1.1.0_0.conda), a subdir the expectation does not allow (only linux-64)"}, try pe.differences(a, p, try expectation(a, EXPECT)));
}

test "two files of one member for one subdir is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\{"version":2,"members":[
        \\ {"name":"ns/a","version":"0.1.9","action":"upload","readme":"ns/a/README.md","files":[
        \\  {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.1.0_0.conda","sha256":"
    ++ SHA ++
        \\","size":1},
        \\  {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.1.0_1.conda","sha256":"
    ++ SHA ++
        \\","size":1}]}
        \\]}
    ;
    var why: []const u8 = "";
    const p = try rbf.parsePlan(a, &why, text);
    const exp = try expectation(a, "{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}");
    try expectLines(&.{"ns/a: 2 files for linux-64, where mopm stage packs one"}, try pe.differences(a, p, exp));
}

test "every difference is listed at once, in the expectation's order and then the plan's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/z", .subdirs = LINUX }, .{ .name = "ns/c", .subdirs = MAC }, .{ .name = "ns/b", .subdirs = LINUX } });
    try expectLines(&.{
        "ns/a: not a member of the plan (expected on linux-64, osx-arm64)",
        "ns/b: no file for osx-arm64",
        "ns/c: no file for linux-64",
        "ns/c: a file for osx-arm64 (mojo-ns.c-0.1.9-mojo1.1.0_0.conda), a subdir the expectation does not allow (only linux-64)",
        "ns/z: a member of the plan that the expectation does not name",
    }, try pe.differences(a, p, try expectation(a, EXPECT)));
}

// ---- the plan against an expectation that lists Mojo versions --------------------------------------

/// EXPECT with the two Mojo versions the release publishes: every package needs a build for each.
const EXPECT_TWO =
    \\{"mojos":["1.1.0","1.2.0"],"members":[
    \\ {"name":"ns/a","subdirs":["linux-64","osx-arm64"]},
    \\ {"name":"ns/b","subdirs":["linux-64","osx-arm64"]},
    \\ {"name":"ns/c","subdirs":["linux-64"]}
    \\]}
;

fn twoBuilds(name: []const u8, subdirs: []const []const u8) M {
    return .{ .name = name, .subdirs = subdirs, .mojos = TWO };
}

test "a plan with a build of every package for every Mojo on every platform has no difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ twoBuilds("ns/a", BOTH), twoBuilds("ns/b", BOTH), twoBuilds("ns/c", LINUX) });
    try expectLines(&.{}, try pe.differences(a, p, try expectation(a, EXPECT_TWO)));
}

test "a package without its Mojo 1.2.0 build on one platform is a difference naming the package, subdir and Mojo" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // ns/b has both builds on linux-64 but only the 1.1.0 build on osx-arm64.
    var text = std.Io.Writer.Allocating.init(a);
    const ok_a = try planJson(a, &.{ twoBuilds("ns/a", BOTH), twoBuilds("ns/c", LINUX) });
    const b_json = try std.fmt.allocPrint(a, ",{{\"name\":\"ns/b\",\"version\":\"0.1.9\",\"action\":\"upload\",\"readme\":\"ns/b/README.md\",\"files\":[" ++
        "{{\"subdir\":\"linux-64\",\"filename\":\"mojo-ns.b-0.1.9-mojo1.1.0_0.conda\",\"sha256\":\"{s}\",\"size\":1}}," ++
        "{{\"subdir\":\"linux-64\",\"filename\":\"mojo-ns.b-0.1.9-mojo1.2.0_0.conda\",\"sha256\":\"{s}\",\"size\":1}}," ++
        "{{\"subdir\":\"osx-arm64\",\"filename\":\"mojo-ns.b-0.1.9-mojo1.1.0_0.conda\",\"sha256\":\"{s}\",\"size\":1}}]}}", .{ SHA, SHA, SHA });
    try text.writer.writeAll(ok_a[0 .. ok_a.len - 2]);
    try text.writer.writeAll(b_json);
    try text.writer.writeAll("]}");
    var why: []const u8 = "";
    const p = try rbf.parsePlan(a, &why, text.written());
    try expectLines(&.{"ns/b: no file for osx-arm64 built for Mojo 1.2.0"}, try pe.differences(a, p, try expectation(a, EXPECT_TWO)));
}

test "a plan built for one Mojo only names every package, platform and missing Mojo" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = try plan(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } });
    try expectLines(&.{
        "ns/a: no file for linux-64 built for Mojo 1.2.0",
        "ns/a: no file for osx-arm64 built for Mojo 1.2.0",
        "ns/b: no file for linux-64 built for Mojo 1.2.0",
        "ns/b: no file for osx-arm64 built for Mojo 1.2.0",
        "ns/c: no file for linux-64 built for Mojo 1.2.0",
    }, try pe.differences(a, p, try expectation(a, EXPECT_TWO)));
}

test "a file built for a Mojo the expectation does not list, or named for none, is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const exp = try expectation(a, "{\"mojos\":[\"1.1.0\",\"1.2.0\"],\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}");
    const p = try plan(a, &.{.{ .name = "ns/a", .subdirs = LINUX, .mojos = &.{ "1.1.0", "1.2.0", "1.3.0" } }});
    try expectLines(&.{"ns/a: a file for linux-64 (mojo-ns.a-0.1.9-mojo1.3.0_0.conda) built for no Mojo the expectation lists (only 1.1.0, 1.2.0)"}, try pe.differences(a, p, exp));
    const text =
        \\{"version":2,"members":[{"name":"ns/a","version":"0.1.9","action":"upload","readme":"ns/a/README.md","files":[
        \\ {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.1.0_0.conda","sha256":"
    ++ SHA ++
        \\","size":1},
        \\ {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.2.0_0.conda","sha256":"
    ++ SHA ++
        \\","size":1},
        \\ {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9.conda","sha256":"
    ++ SHA ++
        \\","size":1}]}
        \\]}
    ;
    var why: []const u8 = "";
    const q = try rbf.parsePlan(a, &why, text);
    try expectLines(&.{"ns/a: a file for linux-64 (mojo-ns.a-0.1.9.conda) built for no Mojo the expectation lists (only 1.1.0, 1.2.0)"}, try pe.differences(a, q, exp));
}

test "two files of one member for one subdir and Mojo is a difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\{"version":2,"members":[
        \\ {"name":"ns/a","version":"0.1.9","action":"upload","readme":"ns/a/README.md","files":[
        \\  {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.1.0_0.conda","sha256":"
    ++ SHA ++
        \\","size":1},
        \\  {"subdir":"linux-64","filename":"mojo-ns.a-0.1.9-mojo1.1.0_1.conda","sha256":"
    ++ SHA ++
        \\","size":1}]}
        \\]}
    ;
    var why: []const u8 = "";
    const p = try rbf.parsePlan(a, &why, text);
    const exp = try expectation(a, "{\"mojos\":[\"1.1.0\"],\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}");
    try expectLines(&.{"ns/a: 2 files for linux-64 built for Mojo 1.1.0, where mopm stage packs one"}, try pe.differences(a, p, exp));
}

test "mojoOf reads the Mojo version of a staged file name and nothing else" {
    try t.expectEqualStrings("1.1.0", pe.mojoOf("mojo-komira-ai.json-0.1.9-mojo1.1.0_0.conda").?);
    try t.expectEqualStrings("1.2.0", pe.mojoOf("mojo-komira-ai.json-0.1.9-mojo1.2.0_12.conda").?);
    for ([_][]const u8{ "mojo-ns.a-0.1.9.conda", "mojo-ns.a-0.1.9-mojo1.1.0_0.tar.bz2", "mojo-ns.a-0.1.9-mojo_0.conda", "mojo-ns.a-0.1.9-mojo1.1.0_.conda", "mojo-ns.a-0.1.9-mojo1.1.0.conda" }) |bad| try t.expect(pe.mojoOf(bad) == null);
}

// ---- the expectation ---------------------------------------------------------------------------

test "an expectation that names no package is refused" {
    try refusedExpectation("{\"members\":[]}", "the expectation names no package: it would let an empty plan through");
    try refusedExpectation("{}", "the expectation names no package: it would let an empty plan through");
}

test "an expectation that does not parse is refused" {
    try refusedExpectation("{\"members\":", "the expectation does not parse: UnexpectedEndOfInput");
    try refusedExpectation("{\"members\":[{\"subdirs\":[\"linux-64\"]}]}", "the expectation does not parse: MissingField");
}

test "an expectation entry that is not a full name is refused" {
    try refusedExpectation("{\"members\":[{\"name\":\"json\",\"subdirs\":[\"linux-64\"]}]}", "expectation entry 0: 'json' is not a full name <namespace>/<name>");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a/b\",\"subdirs\":[\"linux-64\"]}]}", "expectation entry 0: 'ns/a/b' is not a full name <namespace>/<name>");
}

test "an expectation that names a package twice is refused" {
    try refusedExpectation(
        "{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]},{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\",\"osx-arm64\"]}]}",
        "the expectation names ns/a twice",
    );
}

test "an expectation entry with no subdir, a subdir twice, or a subdir that is not a plain name is refused" {
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\"}]}", "the expectation gives ns/a no subdir");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[]}]}", "the expectation gives ns/a no subdir");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\",\"linux-64\"]}]}", "the expectation gives ns/a the subdir linux-64 twice");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"../x\"]}]}", "the expectation gives ns/a the subdir '../x', which is not a plain name");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"\"]}]}", "the expectation gives ns/a the subdir '', which is not a plain name");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"..\"]}]}", "the expectation gives ns/a the subdir '..', which is not a plain name");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux 64\"]}]}", "the expectation gives ns/a the subdir 'linux 64', which is not a plain name");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"a\\\\b\"]}]}", "the expectation gives ns/a the subdir 'a\\b', which is not a plain name");
    try refusedExpectation("{\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"a\\u0001b\"]}]}", "the expectation gives ns/a the subdir 'a\x01b', which is not a plain name");
}

test "an expectation with a Mojo version that is not digits and dots, or listed twice, is refused" {
    try refusedExpectation("{\"mojos\":[\"1.1.0\",\"1.1.0\"],\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}", "the expectation gives the Mojo version 1.1.0 twice");
    try refusedExpectation("{\"mojos\":[\"\"],\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}", "the expectation gives the Mojo version '', which is not digits and dots");
    try refusedExpectation("{\"mojos\":[\"1.1.0-rc1\"],\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"]}]}", "the expectation gives the Mojo version '1.1.0-rc1', which is not digits and dots");
}

test "an expectation with a field it does not know is read: the format grows by adding fields" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const exp = try expectation(ar.allocator(), "{\"note\":1,\"members\":[{\"name\":\"ns/a\",\"subdirs\":[\"linux-64\"],\"extra\":true}]}");
    try t.expectEqual(@as(usize, 1), exp.members.len);
}

// ---- the command line ----------------------------------------------------------------------------

fn sink() std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(t.allocator);
}

/// A staged directory holding `plan_text` as plan.json, and the expectation EXPECT beside it.
fn stageDir(tmp: *t.TmpDir, plan_text: []const u8) !void {
    try tmp.dir.makePath("staged");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = plan_text });
    try tmp.dir.writeFile(.{ .sub_path = "expect.json", .data = EXPECT });
}

fn tmpPath(a: std.mem.Allocator, tmp: *t.TmpDir, rel: []const u8) ![]const u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

test "expect on the command line: exit 0 and the counts of members, files and files per subdir" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageDir(&tmp, try planJson(a, &.{ .{ .name = "ns/a", .subdirs = BOTH }, .{ .name = "ns/b", .subdirs = BOTH }, .{ .name = "ns/c", .subdirs = LINUX } }));
    var out = sink();
    defer out.deinit();
    var err = sink();
    defer err.deinit();
    const args = [_][]const u8{ "--staged", try tmpPath(a, &tmp, "staged"), "--expect", try tmpPath(a, &tmp, "expect.json") };
    try t.expectEqual(@as(u8, 0), try pe.cliExpect(a, &args, &out.writer, &err.writer));
    try t.expectEqualStrings("release_staged_verify: plan.json stages every package of the expectation, each with one file for every subdir (and every Mojo version) it requires and none other: 3 member(s), 5 file(s) (linux-64 3, osx-arm64 2)\n", out.written());
    try t.expectEqualStrings("", err.written());
}

test "expect on the command line: exit 1 and every difference on stderr, nothing on stdout" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageDir(&tmp, try planJson(a, &.{ .{ .name = "ns/a", .subdirs = LINUX }, .{ .name = "ns/b", .subdirs = LINUX }, .{ .name = "ns/c", .subdirs = LINUX } }));
    var out = sink();
    defer out.deinit();
    var err = sink();
    defer err.deinit();
    const args = [_][]const u8{ "--expect", try tmpPath(a, &tmp, "expect.json"), "--staged", try tmpPath(a, &tmp, "staged") };
    try t.expectEqual(@as(u8, 1), try pe.cliExpect(a, &args, &out.writer, &err.writer));
    try t.expectEqualStrings(
        \\release_staged_verify: EXPECT FAILED: plan.json is not the set the release builds: 2 difference(s) (the expectation names 3 package(s), the plan has 3 member(s) and 3 file(s)):
        \\  ns/a: no file for osx-arm64
        \\  ns/b: no file for osx-arm64
        \\
    , err.written());
    try t.expectEqualStrings("", out.written());
}

test "expect on the command line: a missing expectation, a missing plan, an empty expectation and a plan the reader refuses exit 1" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("empty");
    try tmp.dir.makePath("bad");
    try tmp.dir.writeFile(.{ .sub_path = "bad/plan.json", .data = "{\"members\":[]}" });
    try tmp.dir.writeFile(.{ .sub_path = "expect.json", .data = EXPECT });
    try tmp.dir.writeFile(.{ .sub_path = "none.json", .data = "{\"members\":[]}" });
    try tmp.dir.makePath("good");
    try tmp.dir.writeFile(.{ .sub_path = "good/plan.json", .data = try planJson(a, &.{.{ .name = "ns/a", .subdirs = BOTH }}) });
    const Case = struct { staged: []const u8, expect: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .staged = "good", .expect = "absent.json", .want = "cannot read the expectation" },
        .{ .staged = "empty", .expect = "expect.json", .want = "plan.json: FileNotFound" },
        .{ .staged = "good", .expect = "none.json", .want = "the expectation names no package" },
        .{ .staged = "bad", .expect = "expect.json", .want = "plan.json has no member" },
    };
    for (cases) |c| {
        var out = sink();
        defer out.deinit();
        var err = sink();
        defer err.deinit();
        const args = [_][]const u8{ "--staged", try tmpPath(a, &tmp, c.staged), "--expect", try tmpPath(a, &tmp, c.expect) };
        try t.expectEqual(@as(u8, 1), try pe.cliExpect(a, &args, &out.writer, &err.writer));
        try t.expect(std.mem.startsWith(u8, err.written(), "release_staged_verify: EXPECT FAILED: "));
        if (std.mem.indexOf(u8, err.written(), c.want) == null) {
            std.debug.print("stderr was '{s}', wanted '{s}'\n", .{ err.written(), c.want });
            return error.TestWrongRefusal;
        }
    }
}

test "expect on the command line: an expectation larger than the cap is refused, naming the error" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageDir(&tmp, try planJson(a, &.{.{ .name = "ns/a", .subdirs = BOTH }}));
    const big = try a.alloc(u8, pe.max_expect_bytes + 1);
    @memset(big, ' ');
    try tmp.dir.writeFile(.{ .sub_path = "big.json", .data = big });
    var out = sink();
    defer out.deinit();
    var err = sink();
    defer err.deinit();
    const big_path = try tmpPath(a, &tmp, "big.json");
    const args = [_][]const u8{ "--staged", try tmpPath(a, &tmp, "staged"), "--expect", big_path };
    try t.expectEqual(@as(u8, 1), try pe.cliExpect(a, &args, &out.writer, &err.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "release_staged_verify: EXPECT FAILED: cannot read the expectation {s}: FileTooBig\n", .{big_path}), err.written());
}

test "expect on the command line: an error that is not a refusal (out of memory) exits 1 with its name" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageDir(&tmp, "{}");
    const args = [_][]const u8{ "--staged", try tmpPath(a, &tmp, "staged"), "--expect", try tmpPath(a, &tmp, "expect.json") };
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var out = sink();
    defer out.deinit();
    var err = sink();
    defer err.deinit();
    try t.expectEqual(@as(u8, 1), try pe.cliExpect(failing.allocator(), &args, &out.writer, &err.writer));
    try t.expectEqualStrings("release_staged_verify: EXPECT FAILED: OutOfMemory\n", err.written());
}

test "expect on the command line: an unknown flag, a flag without a value or given twice, and a missing flag exit 2" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{ "--staged", "s", "--expect", "e", "--out", "o" }, .want = "release_staged_verify: unknown argument --out\n" ++ pe.usage },
        .{ .args = &.{ "--staged", "s", "--expect" }, .want = "release_staged_verify: --expect needs one value, given once\n" },
        .{ .args = &.{ "--staged", "s", "--staged", "t", "--expect", "e" }, .want = "release_staged_verify: --staged needs one value, given once\n" },
        .{ .args = &.{ "--staged", "s" }, .want = pe.usage },
        .{ .args = &.{ "--expect", "e" }, .want = pe.usage },
        .{ .args = &.{}, .want = pe.usage },
    };
    for (cases) |c| {
        var out = sink();
        defer out.deinit();
        var err = sink();
        defer err.deinit();
        try t.expectEqual(@as(u8, 2), try pe.cliExpect(a, c.args, &out.writer, &err.writer));
        try t.expectEqualStrings(c.want, err.written());
        try t.expectEqualStrings("", out.written());
    }
}

// ---- the release's own expectation ---------------------------------------------------------------

/// The expectation //release:mopm_plan_expectation wrote from packages.bzl and darwin_libs.bzl.
fn realExpectation(a: std.mem.Allocator) !pe.Expectation {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, "mopm_plan_expectation.json" }), pe.max_expect_bytes);
    return expectation(a, text);
}

/// The plan the expectation describes: each package with one file for every subdir and Mojo it requires.
fn membersOf(a: std.mem.Allocator, exp: pe.Expectation) ![]const M {
    var out = std.ArrayList(M).empty;
    for (exp.members) |e| try out.append(a, .{ .name = e.name, .subdirs = e.subdirs, .mojos = exp.mojos });
    return out.items;
}

test "the release's expectation: every package under komira-ai, each on linux-64, sorted, for Mojo 1.1.0 and 1.2.0, and the plan it describes passes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const exp = try realExpectation(a);
    try t.expect(exp.members.len > 1);
    try t.expectEqual(@as(usize, 2), exp.mojos.len);
    for (exp.members, 0..) |e, i| {
        try t.expect(std.mem.startsWith(u8, e.name, "komira-ai/"));
        try t.expectEqualStrings("linux-64", e.subdirs[0]);
        if (i > 0) try t.expect(std.mem.lessThan(u8, exp.members[i - 1].name, e.name));
    }
    try expectLines(&.{}, try pe.differences(a, try plan(a, try membersOf(a, exp)), exp));
}

test "the release's expectation: a plan with every osx-arm64 file removed names every package that builds for macOS" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const exp = try realExpectation(a);
    var want = std.ArrayList([]const u8).empty;
    for (exp.members) |e| {
        for (e.subdirs) |s| if (std.mem.eql(u8, s, "osx-arm64")) for (exp.mojos) |v| try want.append(a, try std.fmt.allocPrint(a, "{s}: no file for osx-arm64 built for Mojo {s}", .{ e.name, v }));
    }
    try t.expect(want.items.len > 0);
    var linux_only = std.ArrayList(M).empty;
    for (exp.members) |e| try linux_only.append(a, .{ .name = e.name, .subdirs = LINUX, .mojos = exp.mojos });
    try expectLines(want.items, try pe.differences(a, try plan(a, linux_only.items), exp));
}

test "the release's expectation: a plan with every Mojo 1.2.0 file removed names every package and platform" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const exp = try realExpectation(a);
    var want = std.ArrayList([]const u8).empty;
    for (exp.members) |e| {
        for (e.subdirs) |sd| try want.append(a, try std.fmt.allocPrint(a, "{s}: no file for {s} built for Mojo {s}", .{ e.name, sd, exp.mojos[1] }));
    }
    var first_only = std.ArrayList(M).empty;
    for (exp.members) |e| try first_only.append(a, .{ .name = e.name, .subdirs = e.subdirs, .mojos = exp.mojos[0..1] });
    try expectLines(want.items, try pe.differences(a, try plan(a, first_only.items), exp));
}
