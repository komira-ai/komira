//! The release set's cases (release/ci/release_lib/set_json.zig), run as part
//! of //release/ci/tests:test_release. Each names the defect it would catch.
//!
//! The hash and the release.json text are held to GOLDENS TAKEN FROM THE
//! WRITER THIS REPLACES (the retired release machine's BUILD step): the
//! values below are the golden vectors of its own tests, computed outside
//! the language it was written in, over the same rows. A change to the
//! header, the line format, the separator, the sort, the hash, the key order
//! or the escaping breaks them, and so the compatibility with every reader
//! of the old files.
const std = @import("std");
const lib = @import("release_lib");
const t = std.testing;

const set_json = lib.set_json;

const REV = "0123456789abcdef0123456789abcdef01234567";
const PLAT = "linux-x86_64";
const A = "a" ** 64;
const B = "b" ** 64;
const C = "c" ** 64;

// the old writer's golden vector: three members, any order
const HASH_GOLDEN = "7a85e80aabbb553803809d3c2b516b8eaaeae467668051498fbeb82790682efe";
// the old writer's golden for two members (komira metapackage, komira_hash)
const SET_GOLDEN = "c5e97905a05bcab80064d0b583b4f963ea55cdc03ebc73959a623dc0dfbf941c";

fn member(name: []const u8, kind: []const u8, sha: []const u8, version: []const u8, build: []const u8) set_json.Member {
    return .{
        .name = name,
        .version = version,
        .build = build,
        .kind = kind,
        .platform = PLAT,
        .subdir = "linux-64",
        .artifact_type = "CONDA",
        .sha256 = sha,
    };
}

fn three() [3]set_json.Member {
    return .{
        member("komira_hash", "library", A, "1.0.0", "h01234567_7"),
        member("komira_name_registry", "library", B, "1.0.0", "h01234567_7"),
        member("komira", "metapackage", C, "1.0.0", "h01234567_7"),
    };
}

test "the set hash is the old writer's golden, and does not depend on the order members arrive in" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = three();
    try t.expectEqualStrings(HASH_GOLDEN, try set_json.setHash(a, REV, PLAT, &m));
    // every permutation
    const perms = [_][3]usize{ .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } };
    for (perms) |p| {
        const base = three();
        const shuffled = [3]set_json.Member{ base[p[0]], base[p[1]], base[p[2]] };
        try t.expectEqualStrings(HASH_GOLDEN, try set_json.setHash(a, REV, PLAT, &shuffled));
    }
}

test "the hashed text is a header line then the member lines sorted bytewise: a prefix name sorts first" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = three();
    const tail = "\tlinux-x86_64\t1.0.0\th01234567_7\tlinux-64\tCONDA\t";
    const want = "release_set\t2\t" ++ REV ++ "\tlinux-x86_64\n" ++
        "komira" ++ tail ++ C ++ "\n" ++
        "komira_hash" ++ tail ++ A ++ "\n" ++
        "komira_name_registry" ++ tail ++ B ++ "\n";
    try t.expectEqualStrings(want, try set_json.setHashText(a, REV, PLAT, &m));
}

test "any one field, the revision and the platform change the hash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = three();
    const h0 = try set_json.setHash(a, REV, PLAT, &base);
    var other_rev = REV.*;
    other_rev[0] = 'f';
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, &other_rev, PLAT, &base)));
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, REV, "linux-arm64", &base)));
    var v = three();
    v[1].version = "1.0.1";
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, REV, PLAT, &v)));
    var b = three();
    b[1].build = "h01234567_8";
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, REV, PLAT, &b)));
    var s = three();
    s[1].sha256 = A;
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, REV, PLAT, &s)));
    var n = three();
    n[1].name = "komira_name_registrz";
    try t.expect(!std.mem.eql(u8, h0, try set_json.setHash(a, REV, PLAT, &n)));
}

fn doc(comptime rows: []const u8) []const u8 {
    return "{\"format\":\"kci.release_set\",\"members\":[" ++ rows ++
        "],\"platform\":\"linux-x86_64\",\"produced_by\":{\"attempt\":1,\"run_id\":\"gh-1\"}," ++
        "\"revision\":\"" ++ REV ++ "\",\"schema_version\":2,\"set_hash\":\"" ++ SET_GOLDEN ++ "\"}\n";
}

fn row(comptime name: []const u8, comptime kind: []const u8, comptime sha: []const u8) []const u8 {
    return "{\"artifact_type\":\"CONDA\",\"build\":\"0\",\"dir\":\"" ++ name ++ "\",\"kind\":\"" ++ kind ++
        "\",\"name\":\"" ++ name ++ "\",\"platform\":\"linux-x86_64\",\"sha256\":\"" ++ sha ++
        "\",\"subdir\":\"linux-64\",\"version\":\"0.1.7\"}";
}

test "release.json is byte-for-byte the old writer's golden, members sorted by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    // deliberately out of order: the render sorts
    const members = [_]set_json.Member{
        member("komira_hash", "library", A, "0.1.7", "0"),
        member("komira", "metapackage", C, "0.1.7", "0"),
    };
    const got = try set_json.renderReleaseJson(&ctx, .{ .revision = REV, .platform = PLAT, .run_id = "gh-1", .attempt = 1 }, &members);
    const want = comptime doc(row("komira", "metapackage", C) ++ "," ++ row("komira_hash", "library", A));
    try t.expectEqualStrings(want, got);
}

test "produced_by is in release.json and not in the hash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const members = [_]set_json.Member{
        member("komira_hash", "library", A, "0.1.7", "0"),
        member("komira", "metapackage", C, "0.1.7", "0"),
    };
    const got = try set_json.renderReleaseJson(&ctx, .{ .revision = REV, .platform = PLAT, .run_id = "gh-99", .attempt = 3 }, &members);
    try t.expect(std.mem.indexOf(u8, got, "\"produced_by\":{\"attempt\":3,\"run_id\":\"gh-99\"}") != null);
    try t.expect(std.mem.indexOf(u8, got, "\"set_hash\":\"" ++ SET_GOLDEN ++ "\"") != null);
}

fn expectRefused(ctx: *set_json.Ctx, r: anytype, needle: []const u8) !void {
    if (r) |_| {
        return error.TestExpectedRefusal;
    } else |e| {
        if (e != error.Refused) return e;
        if (std.mem.indexOf(u8, ctx.why, needle) == null) {
            std.debug.print("refusal '{s}' does not say '{s}'\n", .{ ctx.why, needle });
            return error.TestWrongRefusal;
        }
    }
}

test "the identity is refused: short revision, unreleased platform, bad run id, zero attempt" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const ok = set_json.Identity{ .revision = REV, .platform = PLAT, .run_id = "gh-1", .attempt = 1 };
    try set_json.checkIdentity(&ctx, ok);
    var id = ok;
    id.revision = REV[0..39];
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "full commit id");
    id = ok;
    id.revision = "A" ** 40;
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "full commit id");
    id = ok;
    id.platform = "darwin-arm64";
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "not a platform released");
    id = ok;
    id.run_id = "GH-1";
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "[a-z0-9_-]");
    id.run_id = "";
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "1 to 63");
    id.run_id = "a" ** 64;
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "1 to 63");
    id = ok;
    id.attempt = 0;
    try expectRefused(&ctx, set_json.checkIdentity(&ctx, id), "positive");
}

test "release.json is refused for an empty set, a name given twice and a sha that is not hex" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const id = set_json.Identity{ .revision = REV, .platform = PLAT, .run_id = "gh-1", .attempt = 1 };
    try expectRefused(&ctx, set_json.renderReleaseJson(&ctx, id, &.{}), "EMPTY");
    const twice = [_]set_json.Member{ member("komira", "metapackage", C, "1", "0"), member("komira", "library", A, "1", "0") };
    try expectRefused(&ctx, set_json.renderReleaseJson(&ctx, id, &twice), "given twice");
    const bad = [_]set_json.Member{member("komira", "metapackage", "C" ** 64, "1", "0")};
    try expectRefused(&ctx, set_json.renderReleaseJson(&ctx, id, &bad), "lowercase hex");
}

// ---- member directories on disk ----------------------------------------------

const PKG_SHA = "59381d868da89adeb813a6c459beab8c673f845e8fb7b6e2996da04efad399d7"; // sha256 of "PACKAGE-BYTES"
const OTHER_SHA = "1c55d9b826e8dfa994370e306ae8dc2e849f3e003381dc848a0b95f782c0c0e3"; // sha256 of "OTHER"

const Layout = struct {
    dir: []const u8 = "komira_hash",
    manifest_name: []const u8 = "komira_hash",
    file: []const u8 = "komira_hash-1.0.0-h01234567_7.conda",
    file_bytes: []const u8 = "PACKAGE-BYTES",
    sha: []const u8 = PKG_SHA,
    platform: []const u8 = PLAT,
    subdir: []const u8 = "linux-64",
    md_version: []const u8 = "1.0.0",
    md_size: usize = 13,
    stamped: []const u8 = "true",
    kind: []const u8 = "library",
    artifact_type: []const u8 = "CONDA",
    extra_file: ?[]const u8 = null,
    manifest: bool = true,
};

fn writeMember(a: std.mem.Allocator, root: std.fs.Dir, l: Layout) !void {
    try root.makePath(l.dir);
    var d = try root.openDir(l.dir, .{});
    defer d.close();
    if (l.manifest) {
        try d.writeFile(.{ .sub_path = "manifest.json", .data = try std.fmt.allocPrint(a,
            \\{{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"{s}","name":"{s}","version":"1.0.0","platform":"{s}","subdir":"{s}","file":"{s}","sha256":"{s}","metadata":"metadata.json"}}
        , .{ l.artifact_type, l.manifest_name, l.platform, l.subdir, l.file, l.sha }) });
    }
    try d.writeFile(.{ .sub_path = l.file, .data = l.file_bytes });
    try d.writeFile(.{ .sub_path = "metadata.json", .data = try std.fmt.allocPrint(a,
        \\{{"build":"h01234567_7","format":"kci.conda_metadata","schema_version":1,"kind":"{s}","name":"{s}","version":"{s}","subdir":"{s}","file_name":"{s}","size":{d},"stamped":{s}}}
    , .{ l.kind, l.manifest_name, l.md_version, l.subdir, l.file, l.md_size, l.stamped }) });
    if (l.extra_file) |x| try d.writeFile(.{ .sub_path = x, .data = "x" });
}

fn verifyLayout(ctx: *set_json.Ctx, l: Layout) !set_json.Member {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMember(ctx.a, tmp.dir, l);
    return set_json.verifyMember(ctx, tmp.dir, l.dir, PLAT);
}

test "a package directory as the build leaves it is a member, with the fields release.json carries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const m = try verifyLayout(&ctx, .{});
    try t.expectEqualStrings("komira_hash", m.name);
    try t.expectEqualStrings("1.0.0", m.version);
    try t.expectEqualStrings("h01234567_7", m.build);
    try t.expectEqualStrings("library", m.kind);
    try t.expectEqualStrings(PLAT, m.platform);
    try t.expectEqualStrings("linux-64", m.subdir);
    try t.expectEqualStrings("CONDA", m.artifact_type);
    try t.expectEqualStrings(PKG_SHA, m.sha256);
}

test "an unstamped member is accepted only when the check is told the set is unstamped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator(), .require_stamped = false };
    const m = try verifyLayout(&ctx, .{ .stamped = "false" });
    try t.expectEqualStrings("komira_hash", m.name);
    // every other check still holds
    try expectRefused(&ctx, verifyLayout(&ctx, .{ .stamped = "false", .md_size = 14 }), "says size 14");
}

test "a noarch member is accepted with its own conda subdir" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const m = try verifyLayout(&ctx, .{ .platform = "noarch", .subdir = "noarch" });
    try t.expectEqualStrings("noarch", m.platform);
}

test "a member is refused for each way it can disagree with itself" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    const cases = [_]struct { l: Layout, says: []const u8 }{
        // a package whose bytes are not the ones its manifest hashed
        .{ .l = .{ .file_bytes = "OTHER", .md_size = 5 }, .says = "sha256 of" },
        // an empty package file
        .{ .l = .{ .file_bytes = "", .md_size = 0, .sha = OTHER_SHA }, .says = "EMPTY" },
        // a manifest named for another package than its directory
        .{ .l = .{ .manifest_name = "komira_json" }, .says = "is not the artifact's name" },
        // another platform than the release's
        .{ .l = .{ .platform = "linux-arm64", .subdir = "linux-aarch64" }, .says = "neither the release's" },
        // a subdir that is not the platform's
        .{ .l = .{ .subdir = "osx-arm64" }, .says = "conda subdir" },
        // metadata saying another version than the manifest
        .{ .l = .{ .md_version = "1.0.1" }, .says = "metadata says version" },
        // metadata saying another size than the file
        .{ .l = .{ .md_size = 14 }, .says = "says size 14" },
        // an unstamped package is never released
        .{ .l = .{ .stamped = "false" }, .says = "unstamped" },
        // a kind that is neither
        .{ .l = .{ .kind = "wheel" }, .says = "neither library nor metapackage" },
        // not a conda package
        .{ .l = .{ .artifact_type = "OCI" }, .says = "CONDA members only" },
        // a file the manifest does not name
        .{ .l = .{ .extra_file = "stray.txt" }, .says = "does not name" },
        // a file name that climbs out of the directory
        .{ .l = .{ .file = ".." }, .says = "not a file name" },
        // no manifest at all
        .{ .l = .{ .manifest = false }, .says = "no manifest.json" },
    };
    for (cases) |c| {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        // a file named `..` cannot be written: the layout stops at the manifest
        if (std.mem.eql(u8, c.l.file, "..")) {
            try tmp.dir.makePath(c.l.dir);
            var d = try tmp.dir.openDir(c.l.dir, .{});
            defer d.close();
            try d.writeFile(.{ .sub_path = "manifest.json", .data = try std.fmt.allocPrint(ctx.a,
                \\{{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"CONDA","name":"komira_hash","version":"1.0.0","platform":"linux-x86_64","subdir":"linux-64","file":"..","sha256":"{s}","metadata":"metadata.json"}}
            , .{PKG_SHA}) });
        } else {
            try writeMember(ctx.a, tmp.dir, c.l);
        }
        try expectRefused(&ctx, set_json.verifyMember(&ctx, tmp.dir, c.l.dir, PLAT), c.says);
    }
}

test "a member that is a symlink, or holds one, is refused before anything is read through it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMember(ctx.a, tmp.dir, .{ .dir = "real" });
    try tmp.dir.symLink("real", "komira_hash", .{ .is_directory = true });
    try expectRefused(&ctx, set_json.verifyMember(&ctx, tmp.dir, "komira_hash", PLAT), "symlink");

    var inner = t.tmpDir(.{ .iterate = true });
    defer inner.cleanup();
    try writeMember(ctx.a, inner.dir, .{});
    var d = try inner.dir.openDir("komira_hash", .{});
    defer d.close();
    try d.symLink("manifest.json", "link.json", .{});
    try expectRefused(&ctx, set_json.verifyMember(&ctx, inner.dir, "komira_hash", PLAT), "not a regular file");
}

test "a set is the declared members and nothing else, in the declared order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMember(ctx.a, tmp.dir, .{});
    try writeMember(ctx.a, tmp.dir, .{ .dir = "komira", .manifest_name = "komira", .kind = "metapackage", .file = "komira-1.0.0-h01234567_7.conda" });
    const names = [_][]const u8{ "komira_hash", "komira" };
    const members = try set_json.verifySet(&ctx, tmp.dir, &names, PLAT);
    try t.expectEqual(@as(usize, 2), members.len);
    try t.expectEqualStrings("komira_hash", members[0].name);
    try t.expectEqualStrings("komira", members[1].name);

    // a directory no artifact declares (a build that wrote beside its own)
    try tmp.dir.makePath("stray");
    try expectRefused(&ctx, set_json.verifySet(&ctx, tmp.dir, &names, PLAT), "which no artifact declares");
    // a declared member that is not there
    const more = [_][]const u8{ "komira_hash", "komira", "stray", "komira_json" };
    try expectRefused(&ctx, set_json.verifySet(&ctx, tmp.dir, &more, PLAT), "stray");
}

test "a declared member missing from the directory is named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var ctx = set_json.Ctx{ .a = arena.allocator() };
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeMember(ctx.a, tmp.dir, .{});
    const names = [_][]const u8{ "komira_hash", "komira_json" };
    try expectRefused(&ctx, set_json.verifySet(&ctx, tmp.dir, &names, PLAT), "komira_json");
}
