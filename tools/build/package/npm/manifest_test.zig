//! package.json: the source manifest stamped (the version on the package and
//! its optional dependencies, `private` dropped when stamped and kept when
//! not, every other key in place, written as JSON.stringify writes it), and
//! refused by its exact message when the source is not the development
//! manifest, names another package or licence, has no repository or another
//! repository.url, names another platform or one for a package with none,
//! has no usable `files` list, has an install script, holds a number that is
//! not an integer, or is not a JSON object; the package.json read back
//! refused for another version, an optional dependency at another version,
//! and `private` where the stamp says otherwise; which paths npm packs for a
//! `files` list; and the text written for strings, empty and nested values.

const std = @import("std");
const diag = @import("native_policy").diag;
const manifest = @import("manifest.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const main_want = manifest.Want{ .name = "@komira-ai/komira", .version = fixture.version, .stamped = true, .license = "Apache-2.0" };

fn refusal(a: Alloc, source: []const u8, want: manifest.Want) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, manifest.stamp(a, &d, source, want));
    return d.msg;
}

/// The main fixture's source manifest with `from` replaced by `to` (once).
fn edited(a: Alloc, from: []const u8, to: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, fixture.main_manifest, from) orelse return error.NotInFixture;
    return std.mem.concat(a, u8, &.{ fixture.main_manifest[0..at], to, fixture.main_manifest[at + from.len ..] });
}

test "stamped: the version on the package and its optional dependencies, private dropped, every other key in place" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const s = try manifest.stamp(a, &d, fixture.main_manifest, main_want);
    try t.expectEqualStrings(fixture.main_stamped, s.bytes);
    try t.expectEqual(@as(usize, 3), s.files.len);
    try t.expectEqualStrings("NOTICE", s.files[2]);
}

test "unstamped: version 0.0.0 and private kept, so npm refuses to publish it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    var want = main_want;
    want.version = "0.0.0";
    want.stamped = false;
    const s = try manifest.stamp(a, &d, fixture.main_manifest, want);
    try t.expectEqualStrings(fixture.main_manifest, s.bytes);
    _ = try manifest.checkWritten(a, &d, s.bytes, want);
}

test "the source is the development manifest: version 0.0.0, private, optional dependencies at 0.0.0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("manifest: the source manifest's version is 0.1.3; the rule stamps the version, so the source says 0.0.0", try refusal(a, try edited(a, "\"version\": \"0.0.0\"", "\"version\": \"0.1.3\""), main_want));
    try t.expectEqualStrings("manifest: the source manifest has no `version` string", try refusal(a, try edited(a, "\"version\": \"0.0.0\"", "\"version\": 1"), main_want));
    const not_private = "manifest: the source manifest is not `\"private\": true`; the rule drops it from a stamped package, so no unstamped one is published";
    try t.expectEqualStrings(not_private, try refusal(a, try edited(a, "\"private\": true,\n", ""), main_want));
    try t.expectEqualStrings(not_private, try refusal(a, try edited(a, "\"private\": true", "\"private\": false"), main_want));
    try t.expectEqualStrings("manifest: the source manifest's optional dependency @komira-ai/komira-linux-x64-gnu is not at 0.0.0; the rule stamps it with the package's version", try refusal(a, try edited(a, "-gnu\": \"0.0.0\"", "-gnu\": \"^0.1.0\""), main_want));
    try t.expectEqualStrings("manifest: the manifest's `optionalDependencies` is not an object", try refusal(a, try edited(a, "\"optionalDependencies\": {\n    \"@komira-ai/komira-linux-x64-gnu\": \"0.0.0\"\n  }", "\"optionalDependencies\": []"), main_want));
}

test "name and licence are the rule's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var other = main_want;
    other.name = "@komira-ai/other";
    try t.expectEqualStrings("manifest: the manifest names the package @komira-ai/komira, not @komira-ai/other", try refusal(a, fixture.main_manifest, other));
    other = main_want;
    other.license = "MIT";
    try t.expectEqualStrings("manifest: the manifest's licence is `Apache-2.0`, not the rule's `MIT`", try refusal(a, fixture.main_manifest, other));
    try t.expectEqualStrings("manifest: the manifest has no `name` string", try refusal(a, try edited(a, "\"name\": \"@komira-ai/komira\"", "\"nam\": \"x\""), main_want));
    try t.expectEqualStrings("manifest: the manifest has no `license` string", try refusal(a, try edited(a, "\"license\": \"Apache-2.0\"", "\"licence\": \"Apache-2.0\""), main_want));
}

test "repository: a missing one, one without a url string, and another url are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = "\"repository\": {\n    \"type\": \"git\",\n    \"url\": \"https://github.com/komira-ai/komira\",\n    \"directory\": \"node\"\n  },\n";
    try t.expectEqualStrings("repository: the manifest has no `repository`, and trusted publishing needs its url to be https://github.com/komira-ai/komira", try refusal(a, try edited(a, repo, ""), main_want));
    const no_url = "repository: the manifest's `repository` is not an object with a `url` string, and trusted publishing needs its url to be https://github.com/komira-ai/komira";
    try t.expectEqualStrings(no_url, try refusal(a, try edited(a, repo, "\"repository\": \"github:komira-ai/komira\",\n"), main_want));
    try t.expectEqualStrings(no_url, try refusal(a, try edited(a, "\"url\": \"https://github.com/komira-ai/komira\"", "\"uri\": \"https://github.com/komira-ai/komira\""), main_want));
    for ([_][]const u8{ "git+https://github.com/komira-ai/komira.git", "https://github.com/komira-ai/komira/", "https://github.com/komira-ai/komira-internal", "" }) |url| {
        const src = try edited(a, "\"url\": \"https://github.com/komira-ai/komira\"", try std.fmt.allocPrint(a, "\"url\": \"{s}\"", .{url}));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "repository: the manifest's repository.url is `{s}`, not https://github.com/komira-ai/komira, which trusted publishing requires", .{url}), try refusal(a, src, main_want));
    }
}

test "platform: os, cpu and libc are exactly the platform's, and a package with no platform names none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const linux = manifest.Want{ .name = "@komira-ai/komira-linux-x64-gnu", .version = fixture.version, .stamped = true, .license = "Apache-2.0 AND LicenseRef-Modular-Proprietary", .platform = .{ .os = "linux", .cpu = "x64", .libc = "glibc" } };
    _ = try manifest.stamp(a, &d, fixture.platform_manifest, linux);
    var arm = linux;
    arm.platform.cpu = "arm64";
    try t.expectEqualStrings("platform: the manifest's `cpu` is not [\"arm64\"], the platform's", try refusal(a, fixture.platform_manifest, arm));
    var mac = linux;
    mac.platform = .{ .os = "darwin", .cpu = "x64" };
    try t.expectEqualStrings("platform: the manifest's `os` is not [\"darwin\"], the platform's", try refusal(a, fixture.platform_manifest, mac));
    var none = linux;
    none.platform = .{};
    try t.expectEqualStrings("platform: the manifest names `os`, and a package with no platform names none", try refusal(a, fixture.platform_manifest, none));
    mac.platform = .{ .os = "linux", .cpu = "x64" };
    try t.expectEqualStrings("platform: the manifest names `libc`, and a package with no platform names none", try refusal(a, fixture.platform_manifest, mac));
    const two = try std.mem.replaceOwned(u8, a, fixture.platform_manifest, "\"x64\"", "\"x64\", \"arm64\"");
    try t.expectEqualStrings("platform: the manifest's `cpu` is not [\"x64\"], the platform's", try refusal(a, two, linux));
    const missing = try std.mem.replaceOwned(u8, a, fixture.platform_manifest, "\"libc\": [\n    \"glibc\"\n  ],\n", "");
    try t.expectEqualStrings("platform: the manifest's `libc` is not [\"glibc\"], the platform's", try refusal(a, missing, linux));
}

test "files: a missing list, one that is not a list, and an entry that is not a relative path or glob are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = "\"files\": [\n    \"dist/**/*.js\",\n    \"dist/**/*.d.ts\",\n    \"NOTICE\"\n  ],\n";
    try t.expectEqualStrings("files: the manifest has no `files` list, so it does not say what npm packs", try refusal(a, try edited(a, list, ""), main_want));
    try t.expectEqualStrings("files: the manifest's `files` is not a list", try refusal(a, try edited(a, list, "\"files\": \"dist\",\n"), main_want));
    try t.expectEqualStrings("files: an entry of `files` is not a string", try refusal(a, try edited(a, "\"NOTICE\"", "7"), main_want));
    for ([_][]const u8{ "", "/dist", "./dist", "!dist/x.js", "dist/", "dist\\\\x" }) |e| {
        const src = try edited(a, "\"NOTICE\"", try std.fmt.allocPrint(a, "\"{s}\"", .{e}));
        const shown = try std.mem.replaceOwned(u8, a, e, "\\\\", "\\");
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "files: the entry `{s}` is not a relative path or glob (no leading `/`, `./` or `!`, no trailing `/`, no `\\`)", .{shown}), try refusal(a, src, main_want));
    }
    for ([_][]const u8{ "dist//x", "dist/../x", "dist/./x" }) |e| {
        const src = try edited(a, "\"NOTICE\"", try std.fmt.allocPrint(a, "\"{s}\"", .{e}));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "files: the entry `{s}` has an empty, `.` or `..` part", .{e}), try refusal(a, src, main_want));
    }
}

test "scripts: an install script is refused, another script is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    _ = try manifest.stamp(a, &d, try edited(a, "\"type\": \"module\",", "\"type\": \"module\",\n  \"scripts\": {\"test\": \"node --test\"},"), main_want);
    for ([_][]const u8{ "preinstall", "install", "postinstall" }) |k| {
        const src = try edited(a, "\"type\": \"module\",", try std.fmt.allocPrint(a, "\"type\": \"module\",\n  \"scripts\": {{\"{s}\": \"node fetch.js\"}},", .{k}));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "scripts: the manifest has a `{s}` script, and npm install is the only step: a package runs nothing at install", .{k}), try refusal(a, src, main_want));
    }
}

test "not JSON, not an object, a duplicated key and a number that is not an integer are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("manifest: the source manifest is not JSON (SyntaxError)", try refusal(a, "{\"name\" \"x\"}", main_want));
    try t.expectEqualStrings("manifest: the source manifest is not a JSON object", try refusal(a, "[]", main_want));
    try t.expectEqualStrings("manifest: the source manifest is not JSON (DuplicateField)", try refusal(a, try edited(a, "\"type\": \"module\",", "\"type\": \"module\",\n  \"type\": \"commonjs\","), main_want));
    try t.expectEqualStrings("manifest: the manifest holds a number that is not an integer", try refusal(a, try edited(a, "\"type\": \"module\",", "\"type\": \"module\",\n  \"x\": 1.5,"), main_want));
}

test "the package.json read back: another version, an optional dependency at another version, and private against the stamp are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const files = try manifest.checkWritten(a, &d, fixture.main_stamped, main_want);
    try t.expectEqual(@as(usize, 3), files.len);

    const other = try std.mem.replaceOwned(u8, a, fixture.main_stamped, "\"version\": \"0.1.57\"", "\"version\": \"0.1.58\"");
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, other, main_want));
    try t.expectEqualStrings("version: the package.json's version is 0.1.58, not the stamp's 0.1.57", d.msg);
    const dep = try std.mem.replaceOwned(u8, a, fixture.main_stamped, "-gnu\": \"0.1.57\"", "-gnu\": \"0.1.56\"");
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, dep, main_want));
    try t.expectEqualStrings("version: the package.json's optional dependency @komira-ai/komira-linux-x64-gnu is not at the package's version 0.1.57", d.msg);
    const kept = try std.mem.replaceOwned(u8, a, fixture.main_stamped, "\"version\": \"0.1.57\",", "\"version\": \"0.1.57\",\n  \"private\": false,");
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, kept, main_want));
    try t.expectEqualStrings("version: the stamped package.json keeps `private`, so npm would not publish it", d.msg);
    const url = try std.mem.replaceOwned(u8, a, fixture.main_stamped, "komira-ai/komira\",\n    \"directory", "komira-ai/fork\",\n    \"directory");
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, url, main_want));
    try t.expectEqualStrings("repository: the manifest's repository.url is `https://github.com/komira-ai/fork`, not https://github.com/komira-ai/komira, which trusted publishing requires", d.msg);
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, "{\"name\": \"x\"", main_want));
    try t.expectEqualStrings("manifest: the package's package.json is not JSON (UnexpectedEndOfInput)", d.msg);

    var dev = main_want;
    dev.version = "0.0.0";
    dev.stamped = false;
    const unstamped = try std.mem.replaceOwned(u8, a, fixture.main_manifest, "  \"private\": true,\n", "");
    try t.expectError(error.Refused, manifest.checkWritten(a, &d, unstamped, dev));
    try t.expectEqualStrings("version: the unstamped package.json is not `\"private\": true`, so npm would publish a development package", d.msg);
}

test "packs: package.json and a top README or licence always; a path, a directory or a glob of `files`; nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_][]const u8{ "dist/**/*.js", "native", "NOTICE", "lib/*.d.ts" };
    for ([_][]const u8{
        "package.json",   "README.md",           "readme",               "LICENSE",      "Licence.txt",
        "dist/index.js",  "dist/a/b/c.js",       "native/libkomira.so",  "native/lib/x", "NOTICE",
        "lib/index.d.ts",
    }) |p| try t.expect(try manifest.packs(a, &files, p));
    for ([_][]const u8{
        "dist/index.d.ts", "docs/README.md", "LICENSES", "nativex/y", "NOTICE.md",
        "lib/a/b.d.ts",    "dist.js",        "x",
    }) |p| {
        if (try manifest.packs(a, &files, p)) {
            std.debug.print("packed, and should not be: {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
    try t.expect(try manifest.entryPacks(a, "n?tive", "native/x"));
    try t.expect(try manifest.entryPacks(a, "**", "any/path"));
    try t.expect(!try manifest.entryPacks(a, "dist/*.js", "dist/a/b.js"));
}

test "render: strings escaped as JSON.stringify escapes them, empty and nested values indented by two" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const obj = try manifest.parse(a, &d, "x", "{\"s\": \"q\\\"b\\\\n\\nr\\rt\\tb\\bf\\fu\\u0001\\u001f\\u00e9\", \"e\": {}, \"l\": [], \"n\": [1, [true, null], {\"k\": -2}]}");
    try t.expectEqualStrings(
        \\{
        \\  "s": "q\"b\\n\nr\rt\tb\bf\fu\u0001\u001fé",
        \\  "e": {},
        \\  "l": [],
        \\  "n": [
        \\    1,
        \\    [
        \\      true,
        \\      null
        \\    ],
        \\    {
        \\      "k": -2
        \\    }
        \\  ]
        \\}
        \\
    , try manifest.render(a, .{ .object = obj }));
}
