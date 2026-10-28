//! The cases of release_beta_version (release_beta_version.zig). Each test is a defect the
//! beta stage would otherwise carry into the registry: a version the registry refuses for
//! good, a pin `mopm stage` rejects, a manifest damaged by the edit, or a half-rewritten
//! workspace.
const std = @import("std");
const rbv = @import("release_beta_version.zig");
const t = std.testing;

const NEW = "0.1.999";

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn manifest(a: std.mem.Allocator, name: []const u8, version: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "{s}"
        \\description = "a library"
        \\mojo = ["1.0.0"]
        \\
        \\[targets]
        \\lib = {{ path = "src/{s}" }}
        \\{s}
    , .{ name, version, name, extra });
}

fn rewrite(a: std.mem.Allocator, text: []const u8, members: []const rbv.Member) !rbv.Rewritten {
    var why: []const u8 = "";
    return rbv.rewriteManifest(a, &why, "mopm.toml", text, members, NEW);
}

/// The refusal text of `r`, which must be a refusal.
fn refusedWith(why: *const []const u8, r: anytype, needle: []const u8) !void {
    if (r) |_| return error.TestExpectedRefusal else |e| {
        try t.expect(e == error.Refused);
        if (std.mem.indexOf(u8, why.*, needle) == null) {
            std.debug.print("refusal was '{s}', wanted '{s}'\n", .{ why.*, needle });
            return error.TestWrongRefusal;
        }
    }
}

const SIBLING = [_]rbv.Member{.{ .name = "sib", .version = "0.1.0" }};

test "the package version is replaced and every other byte of the file is kept" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text = "# header\n[package]\nname = \"x\"\nversion   =   \"0.1.0\"   # the release\ndescription = \"d\"\n\n[package.metadata]\nversion = \"9.9.9\"\n\n[targets]\nlib = { path = \"src/x\" }\n";
    const r = try rewrite(a, text, &.{});
    try t.expect(r.version_changed);
    try t.expectEqual(@as(usize, 0), r.pins_changed);
    try t.expectEqualStrings("# header\n[package]\nname = \"x\"\nversion   =   \"0.1.999\"   # the release\ndescription = \"d\"\n\n[package.metadata]\nversion = \"9.9.9\"\n\n[targets]\nlib = { path = \"src/x\" }\n", r.text);
}

test "a file with CRLF line ends and no final newline keeps both" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try rewrite(a, "[package]\r\nname = \"x\"\r\nversion = \"0.1.4\"\r\n[targets]\r\nlib = { path = \"s\" }", &.{});
    try t.expectEqualStrings("[package]\r\nname = \"x\"\r\nversion = \"0.1.999\"\r\n[targets]\r\nlib = { path = \"s\" }", r.text);
}

test "an exact pin on a member, in each spelling mopm reads, takes the new number" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const deps =
        \\[dependencies]
        \\sib = "=0.1.0"
        \\
        \\[dev-dependencies]
        \\sib = { version = "=0.1.0", path = "../sib" }
        \\
    ;
    const r = try rewrite(a, try manifest(a, "x", "0.1.0", deps), &SIBLING);
    try t.expectEqual(@as(usize, 2), r.pins_changed);
    try t.expect(std.mem.indexOf(u8, r.text, "sib = \"=0.1.999\"\n") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "sib = { version = \"=0.1.999\", path = \"../sib\" }\n") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "=0.1.0") == null);

    const table =
        \\[dependencies.sib]
        \\path = "../sib"
        \\version = "= 0.1.0"
        \\
    ;
    const r2 = try rewrite(a, try manifest(a, "x", "0.1.0", table), &SIBLING);
    try t.expectEqual(@as(usize, 1), r2.pins_changed);
    try t.expect(std.mem.indexOf(u8, r2.text, "version = \"= 0.1.999\"\n") != null);
}

test "only the exact comparator of a range is rewritten; ranges that already take 0.1.x stay as written" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const mixed = try rewrite(a, try manifest(a, "x", "0.1.0", "[dependencies]\nsib = \">=0.1, =0.1.0\"\n"), &SIBLING);
    try t.expect(std.mem.indexOf(u8, mixed.text, "sib = \">=0.1, =0.1.999\"\n") != null);
    for ([_][]const u8{ "^0.1", "0.1", "~0.1.0", ">=0.1.0, <0.2.0", "*", "0.1.*", "=0.1", "^0.1.0" }) |req| {
        const line = try std.fmt.allocPrint(a, "[dependencies]\nsib = \"{s}\"\n", .{req});
        const r = try rewrite(a, try manifest(a, "x", "0.1.0", line), &SIBLING);
        try t.expectEqual(@as(usize, 0), r.pins_changed);
        try t.expect(std.mem.indexOf(u8, r.text, line) != null);
    }
}

test "a dependency that is not a member of the workspace is left alone, pin or not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try rewrite(a, try manifest(a, "x", "0.1.0", "[dependencies]\nelsewhere = \"=0.1.0\"\nother = { version = \"=0.1.0\" }\n"), &SIBLING);
    try t.expectEqual(@as(usize, 0), r.pins_changed);
    try t.expect(std.mem.indexOf(u8, r.text, "elsewhere = \"=0.1.0\"\nother = { version = \"=0.1.0\" }\n") != null);
}

test "a version line outside [package] is not the package version" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text = "[package]\nname = \"x\"\n\n[targets]\nversion = \"0.1.0\"\n";
    var why: []const u8 = "";
    try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", text, &.{}, NEW), "has no version");
}

test "the version to give must be 0.1.PATCH and nothing else" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try rbv.checkTarget(a, "0.1.0", &why);
    try rbv.checkTarget(a, "0.1.123456", &why);
    for ([_][]const u8{ "", "0.1", "0.1.", "0.1.0.1", "0.1.0-b123", "0.1.0+b123", "0.1.0.post123", "0.1.0.dev123", "v0.1.1", "0.1.07", "0.1.x", "0.1.-1", "0.1.1 ", "0.01.1", "0.2.1", "1.1.1", "0.0.1", "0.1.1234567890123456789" }) |v| {
        why = "";
        try refusedWith(&why, rbv.checkTarget(a, v, &why), "");
        try t.expect(why.len != 0);
    }
}

test "a pin the tool cannot read is refused, and so is a pin on a version the member does not have" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "==0.1.0", "=>0.1", "0.1.x", "^", ",", "=0.1.0,", "=0.1.0.1", "=*", ">=*", "~", "1.2.3.4", "=0.1.0-b1", "= ", "latest" }) |req| {
        const deps = try std.fmt.allocPrint(a, "[dependencies]\nsib = \"{s}\"\n", .{req});
        var why: []const u8 = "";
        try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", try manifest(a, "x", "0.1.0", deps), &SIBLING, NEW), "on sib");
    }
    var why: []const u8 = "";
    try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", try manifest(a, "x", "0.1.0", "[dependencies]\nsib = \"=0.1.3\"\n"), &SIBLING, NEW), "pinned at '=0.1.3', but the member is at 0.1.0");
    why = "";
    try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", try manifest(a, "x", "0.1.0", "[dependencies]\nsib = { version = \"=0.1.3\", path = \"../sib\" }\n"), &SIBLING, NEW), "pinned at");
}

test "a manifest the edit cannot follow is refused rather than guessed at" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { extra: []const u8, needle: []const u8 }{
        .{ .extra = "[dependencies]\nsib = [\"=0.1.0\"]\n", .needle = "not a string or a one-line table" },
        .{ .extra = "[dependencies]\nsib = {\n  version = \"=0.1.0\" }\n", .needle = "one-line table" },
        .{ .extra = "[dependencies]\nsib = { version = \"=0.1.0\"\n", .needle = "one-line table" },
        .{ .extra = "[dependencies]\nsib = \"=0.1.0\" junk\n", .needle = "plain one-line string" },
        .{ .extra = "[dependencies]\nsib = { version = \"=0.1.0\" } junk\n", .needle = "text after its table" },
        .{ .extra = "[dependencies]\nsib = { version = \"=0.1.0\", version = \"=0.1.0\" }\n", .needle = "version twice" },
        .{ .extra = "[dependencies]\nsib = { version = 3 }\n", .needle = "not a plain string" },
        .{ .extra = "[dependencies]\n\"sib\" = \"=0.1.0\"\n", .needle = "not a plain name" },
        .{ .extra = "[dependencies]\njust text\n", .needle = "dependency line" },
        .{ .extra = "[dependencies.\"sib\"]\nversion = \"=0.1.0\"\n", .needle = "form this tool does not read" },
        .{ .extra = "[ dependencies . sib ]\nversion = \"=0.1.0\"\n", .needle = "form this tool does not read" },
        .{ .extra = "[dependencies.sib.x]\nversion = \"=0.1.0\"\n", .needle = "form this tool does not read" },
        .{ .extra = "[native]\nx = \"\"\"a\nb\"\"\"\n", .needle = "multi-line string" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", try manifest(a, "x", "0.1.0", c.extra), &SIBLING, NEW), c.needle);
    }
    var why: []const u8 = "";
    try refusedWith(&why, rbv.rewriteManifest(a, &why, "m.toml", "[package]\nname = \"x\"\nversion = 0.1.0\n", &.{}, NEW), "plain one-line string");
    why = "";
    try refusedWith(&why, rbv.readIdentity(a, &why, "m.toml", "[package]\nname = \"x\"\n"), "has no version");
    why = "";
    try refusedWith(&why, rbv.readIdentity(a, &why, "m.toml", "[package]\nversion = \"0.1.0\"\n"), "has no name");
    why = "";
    try refusedWith(&why, rbv.readIdentity(a, &why, "m.toml", "[package]\nname = \"x\"\nname = \"y\"\nversion = \"0.1.0\"\n"), "set twice");
}

/// A workspace of members in a scratch directory: (relative dir, name, version, extra lines).
const Spec = struct { dir: []const u8, name: []const u8, version: []const u8, extra: []const u8 = "" };

fn lay(a: std.mem.Allocator, d: std.fs.Dir, specs: []const Spec) !void {
    for (specs) |s| {
        try d.makePath(s.dir);
        const file = try std.fs.path.join(a, &.{ s.dir, "mopm.toml" });
        try d.writeFile(.{ .sub_path = file, .data = try manifest(a, s.name, s.version, s.extra) });
    }
}

fn read(a: std.mem.Allocator, d: std.fs.Dir, rel: []const u8) ![]u8 {
    return d.readFileAlloc(a, rel, 1 << 20);
}

const RunOut = struct { rep: rbv.Report, log: []const u8 };

fn runIn(a: std.mem.Allocator, d: std.fs.Dir, version: []const u8, why: *[]const u8) !RunOut {
    const root = try d.realpathAlloc(a, ".");
    var aw = std.Io.Writer.Allocating.init(a);
    const rep = try rbv.run(a, why, root, version, &aw.writer);
    return .{ .rep = rep, .log = aw.written() };
}

test "every member of a workspace gets the version and the pins between them follow" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try lay(a, tmp.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "b", .name = "beta", .version = "0.1.0", .extra = "[dependencies]\nalpha = { version = \"=0.1.0\", path = \"../a\" }\n" },
        .{ .dir = "deep/er/c", .name = "gamma", .version = "0.1.7", .extra = "[dependencies]\nalpha = \"=0.1.0\"\nbeta = \"^0.1\"\n" },
    });
    var why: []const u8 = "";
    const out = try runIn(a, tmp.dir, NEW, &why);
    try t.expectEqual(@as(usize, 3), out.rep.members);
    try t.expectEqual(@as(usize, 3), out.rep.versions_changed);
    try t.expectEqual(@as(usize, 2), out.rep.pins_changed);
    for ([_][]const u8{ "a", "b", "deep/er/c" }) |dir| {
        const text = try read(a, tmp.dir, try std.fs.path.join(a, &.{ dir, "mopm.toml" }));
        try t.expect(std.mem.indexOf(u8, text, "version = \"0.1.999\"\ndescription") != null);
        try t.expect(std.mem.indexOf(u8, text, "0.1.0\"") == null);
        try t.expect(std.mem.indexOf(u8, text, "0.1.7\"") == null);
    }
    const c = try read(a, tmp.dir, "deep/er/c/mopm.toml");
    try t.expect(std.mem.indexOf(u8, c, "alpha = \"=0.1.999\"\nbeta = \"^0.1\"\n") != null);
}

test "a second run with the same version changes nothing and writes nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try lay(a, tmp.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "b", .name = "beta", .version = "0.1.0", .extra = "[dependencies]\nalpha = \"=0.1.0\"\n" },
    });
    var why: []const u8 = "";
    _ = try runIn(a, tmp.dir, NEW, &why);
    const first_a = try read(a, tmp.dir, "a/mopm.toml");
    const first_b = try read(a, tmp.dir, "b/mopm.toml");
    const again = try runIn(a, tmp.dir, NEW, &why);
    try t.expectEqual(@as(usize, 2), again.rep.members);
    try t.expectEqual(@as(usize, 0), again.rep.versions_changed);
    try t.expectEqual(@as(usize, 0), again.rep.pins_changed);
    try t.expectEqualStrings("", again.log);
    try t.expectEqualStrings(first_a, try read(a, tmp.dir, "a/mopm.toml"));
    try t.expectEqualStrings(first_b, try read(a, tmp.dir, "b/mopm.toml"));
    // a later push moves the same workspace on, and the pins with it
    const later = try runIn(a, tmp.dir, "0.1.1000", &why);
    try t.expectEqual(@as(usize, 2), later.rep.versions_changed);
    try t.expectEqual(@as(usize, 1), later.rep.pins_changed);
    try t.expect(std.mem.indexOf(u8, try read(a, tmp.dir, "b/mopm.toml"), "alpha = \"=0.1.1000\"\n") != null);
}

test "one refused member leaves every manifest as it was" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try lay(a, tmp.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "b", .name = "beta", .version = "0.2.0" },
    });
    const before = try read(a, tmp.dir, "a/mopm.toml");
    var why: []const u8 = "";
    try refusedWith(&why, runIn(a, tmp.dir, NEW, &why), "not in 0.1.x");
    try t.expectEqualStrings(before, try read(a, tmp.dir, "a/mopm.toml"));

    // a bad pin in the last member, after the first was already computed
    var tmp2 = t.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try lay(a, tmp2.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "b", .name = "beta", .version = "0.1.0", .extra = "[dependencies]\nalpha = \"==0.1.0\"\n" },
    });
    const before2 = try read(a, tmp2.dir, "a/mopm.toml");
    why = "";
    try refusedWith(&why, runIn(a, tmp2.dir, NEW, &why), "alpha");
    try t.expectEqualStrings(before2, try read(a, tmp2.dir, "a/mopm.toml"));
}

test "a bad version, a duplicate name, a non-version and an empty workspace are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var why: []const u8 = "";
    try refusedWith(&why, runIn(a, tmp.dir, NEW, &why), "no members");
    try lay(a, tmp.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "b", .name = "alpha", .version = "0.1.0" },
    });
    why = "";
    try refusedWith(&why, runIn(a, tmp.dir, NEW, &why), "both the package alpha");
    var tmp2 = t.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try lay(a, tmp2.dir, &.{.{ .dir = "a", .name = "alpha", .version = "0.1.0-b1" }});
    why = "";
    try refusedWith(&why, runIn(a, tmp2.dir, NEW, &why), "not MAJOR.MINOR.PATCH");
    why = "";
    try refusedWith(&why, runIn(a, tmp2.dir, "0.1.0+b123", &why), "not MAJOR.MINOR.PATCH");
    const a_text = try read(a, tmp2.dir, "a/mopm.toml");
    try t.expect(std.mem.indexOf(u8, a_text, "0.1.0-b1") != null);
}

test "members are found as mopm stage finds them: not under a member, not in hidden or build directories" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try lay(a, tmp.dir, &.{
        .{ .dir = "a", .name = "alpha", .version = "0.1.0" },
        .{ .dir = "a/vendored/inner", .name = "inner", .version = "0.9.0" },
        .{ .dir = ".hidden/h", .name = "hid", .version = "0.9.0" },
        .{ .dir = "buck-out/o", .name = "out", .version = "0.9.0" },
        .{ .dir = "node_modules/n", .name = "nm", .version = "0.9.0" },
        .{ .dir = "zig-out/z", .name = "zo", .version = "0.9.0" },
        .{ .dir = "zig-cache/z", .name = "zc", .version = "0.9.0" },
    });
    var why: []const u8 = "";
    const out = try runIn(a, tmp.dir, NEW, &why);
    try t.expectEqual(@as(usize, 1), out.rep.members);
    for ([_][]const u8{ "a/vendored/inner", ".hidden/h", "buck-out/o", "node_modules/n", "zig-out/z", "zig-cache/z" }) |dir| {
        const text = try read(a, tmp.dir, try std.fs.path.join(a, &.{ dir, "mopm.toml" }));
        try t.expect(std.mem.indexOf(u8, text, "0.9.0") != null);
    }
}
