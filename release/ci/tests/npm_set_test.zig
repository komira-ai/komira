//! The cases of npm_set.json (release/ci/npm_smoke/set.zig), part of //release/ci/tests:test_npm_smoke. The
//! digests are vectors computed outside Zig (Python's hashlib over the same bytes), so a wrong hash, a wrong
//! base64 alphabet or missing padding fails them.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const h = @import("npm_testing.zig");
const t = std.testing;

const set = lib.set;

const MAIN_SHA = "8bc05bd6a91214b3dc6a3f7a1d5215d883cdd36ecbbf4d96227711a6ffc1ad00";
const MAIN_SRI = "sha512-diE/OX+DUO12yAHC8R03P9djzFzztm5Y92fG02tCjCA5v8RWpN7l3clwyS1G+pVXnBur05tx+c6AInN/wVbEPA==";
const LINUX_SHA = "37944e380afd274a0a94b9b2153ed067511392c830642f9c9291b861c474f8fa";
const LINUX_SRI = "sha512-LtT0FlofyOyx8ZU419cz0vQPyNS8ZUWlzzER6xuVTTdez86rozluCOo0/BLSn5V7ICBhDTcloiurJqftGbCDMg==";
const DARWIN_SHA = "dbb64aa182064ee0a6f4c49b88f8ae805167baa82cbd9c28c225409f52323d83";
const DARWIN_SRI = "sha512-fYvgub/HuXxVfO9gR6JIF18Xi/m6KFlos/gcpYSNu41xl75usNZbw95gHaN3XiF/wTI4buP/CFlpe5u8KEuTOA==";

/// npm_set.json of the main package and the linux-x64 package at 0.1.7, as `render` must write it.
pub const GOLDEN =
    \\{
    \\  "main": "@komira-ai/komira",
    \\  "version": "0.1.7",
    \\  "packages": [
    \\    {"name": "@komira-ai/komira-linux-x64-gnu", "version": "0.1.7", "file": "komira-ai-komira-linux-x64-gnu-0.1.7.tgz", "sha256": "37944e380afd274a0a94b9b2153ed067511392c830642f9c9291b861c474f8fa", "integrity": "sha512-LtT0FlofyOyx8ZU419cz0vQPyNS8ZUWlzzER6xuVTTdez86rozluCOo0/BLSn5V7ICBhDTcloiurJqftGbCDMg=="},
    \\    {"name": "@komira-ai/komira", "version": "0.1.7", "file": "komira-ai-komira-0.1.7.tgz", "sha256": "8bc05bd6a91214b3dc6a3f7a1d5215d883cdd36ecbbf4d96227711a6ffc1ad00", "integrity": "sha512-diE/OX+DUO12yAHC8R03P9djzFzztm5Y92fG02tCjCA5v8RWpN7l3clwyS1G+pVXnBur05tx+c6AInN/wVbEPA=="}
    \\  ]
    \\}
    \\
;

fn input(a: std.mem.Allocator, name: []const u8, version: []const u8) !set.Input {
    return .{ .name = name, .path = try std.fmt.allocPrint(a, "/out/{s}", .{try set.tarballName(a, name, version)}), .bytes = try h.tarball(a, name) };
}

fn expectBuildRefused(a: std.mem.Allocator, main: []const u8, inputs: []const set.Input, stamped: bool, want: []const u8) !void {
    var why: []const u8 = "";
    try t.expectError(error.Refused, set.build(a, &why, main, inputs, stamped));
    try t.expectEqualStrings(want, why);
}

fn expectParseRefused(a: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    var why: []const u8 = "";
    try t.expectError(error.Refused, set.parse(a, &why, "npm_set.json", text));
    try t.expectEqualStrings(want, why);
}

test "the digests are npm's: sha256 as lowercase hex, and the integrity sha512- and the padded standard base64 of the SHA-512" {
    try t.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &lib.common.sha256Hex(""));
    try t.expectEqualStrings("sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==", &lib.common.integrity(""));
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &lib.common.sha256Hex("abc"));
    try t.expectEqualStrings("sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==", &lib.common.integrity("abc"));
}

test "a tarball's name is npm pack's, and its version is read back only from its own package's name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("komira-ai-komira-0.1.7.tgz", try set.tarballName(a, h.MAIN, "0.1.7"));
    try t.expectEqualStrings("komira-ai-komira-linux-x64-gnu-0.0.0.tgz", try set.tarballName(a, h.LINUX, "0.0.0"));
    try t.expectEqualStrings("0.1.7", (try set.versionOfFile(a, h.MAIN, "komira-ai-komira-0.1.7.tgz")).?);
    try t.expectEqualStrings("0.1.12", (try set.versionOfFile(a, h.LINUX, "komira-ai-komira-linux-x64-gnu-0.1.12.tgz")).?);
    // the main package's prefix is a prefix of the platform package's file: not its file
    try t.expect((try set.versionOfFile(a, h.MAIN, "komira-ai-komira-linux-x64-gnu-0.1.7.tgz")) == null);
    try t.expect((try set.versionOfFile(a, h.MAIN, "komira-ai-komira-.tgz")) == null);
    try t.expect((try set.versionOfFile(a, h.MAIN, "komira-ai-komira-0.1.7.tar")) == null);
    try t.expect((try set.versionOfFile(a, h.MAIN, "komira-ai-komira-0.1.07.tgz")) == null);
    try t.expect((try set.versionOfFile(a, h.MAIN, "komira-ai-komira-0.1.tgz")) == null);
    try t.expect((try set.versionOfFile(a, h.MAIN, "other-0.1.7.tgz")) == null);
}

test "names and versions: the scope and lowercase letters, digits and inner hyphens; three numbers without leading zeros" {
    try t.expect(set.isName("@komira-ai/komira"));
    try t.expect(set.isName("@komira-ai/komira-linux-x64-gnu"));
    try t.expect(!set.isName("komira"));
    try t.expect(!set.isName("@komira-ai/"));
    try t.expect(!set.isName("@komira-ai/Komira"));
    try t.expect(!set.isName("@komira-ai/-komira"));
    try t.expect(!set.isName("@komira-ai/komira-"));
    try t.expect(!set.isName("@komira-ai/kom\"ira"));
    try t.expect(!set.isName("@other/komira"));
    try t.expect(set.isVersion("0.0.0"));
    try t.expect(set.isVersion("0.1.7"));
    try t.expect(set.isVersion("10.20.30"));
    try t.expect(!set.isVersion("0.1"));
    try t.expect(!set.isVersion("0.1.7.1"));
    try t.expect(!set.isVersion("0.01.7"));
    try t.expect(!set.isVersion("0.1.x"));
    try t.expect(!set.isVersion("0..7"));
    try t.expect(!set.isVersion(""));
}

test "the set of the tarballs is written as the golden: platform packages by name, the main package last" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    // given main first: the set still publishes it last
    const s = try set.build(a, &why, h.MAIN, &.{ try input(a, h.MAIN, "0.1.7"), try input(a, h.LINUX, "0.1.7") }, true);
    try t.expectEqualStrings(GOLDEN, try set.render(a, s));
    try t.expect(s.stamped());
    // a second platform package sorts before linux, and the main package stays last
    const three = try set.build(a, &why, h.MAIN, &.{ try input(a, h.LINUX, "0.1.7"), try input(a, h.MAIN, "0.1.7"), try input(a, h.DARWIN, "0.1.7") }, true);
    try t.expectEqual(@as(usize, 3), three.packages.len);
    try t.expectEqualStrings(h.DARWIN, three.packages[0].name);
    try t.expectEqualStrings(DARWIN_SHA, three.packages[0].sha256);
    try t.expectEqualStrings(DARWIN_SRI, three.packages[0].integrity);
    try t.expectEqualStrings(h.LINUX, three.packages[1].name);
    try t.expectEqualStrings(LINUX_SHA, three.packages[1].sha256);
    try t.expectEqualStrings(LINUX_SRI, three.packages[1].integrity);
    try t.expectEqualStrings(h.MAIN, three.packages[2].name);
    try t.expectEqualStrings(MAIN_SHA, three.packages[2].sha256);
    try t.expectEqualStrings(MAIN_SRI, three.packages[2].integrity);
    // what a pull request builds: unstamped, accepted without --require-stamped
    const pr = try set.build(a, &why, h.MAIN, &.{ try input(a, h.MAIN, "0.0.0"), try input(a, h.LINUX, "0.0.0") }, false);
    try t.expect(!pr.stamped());
    try t.expectEqualStrings("0.0.0", pr.version);
}

test "a set is refused when a package is not the scope's, given twice, at another version, not npm pack's file, or the main package is missing or alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try input(a, h.MAIN, "0.1.7");
    const l = try input(a, h.LINUX, "0.1.7");
    try expectBuildRefused(a, h.MAIN, &.{}, true, "no package: a set holds the main package at least");
    try expectBuildRefused(a, h.MAIN, &.{ m, .{ .name = "left-pad", .path = "/out/left-pad-0.1.7.tgz", .bytes = "" } }, true, "\"left-pad\" is not a package name of @komira-ai/");
    try expectBuildRefused(a, h.MAIN, &.{ m, l, l }, true, "@komira-ai/komira-linux-x64-gnu is given twice");
    try expectBuildRefused(a, h.MAIN, &.{ m, try input(a, h.LINUX, "0.1.8") }, true, "@komira-ai/komira is at 0.1.7 and @komira-ai/komira-linux-x64-gnu at 0.1.8: every package of a set has one version");
    try expectBuildRefused(a, h.MAIN, &.{ m, .{ .name = h.LINUX, .path = "/out/komira-ai-komira-0.1.7.tgz", .bytes = "" } }, true, "komira-ai-komira-0.1.7.tgz is not a file name npm pack gives @komira-ai/komira-linux-x64-gnu (want komira-ai-komira-linux-x64-gnu-<version>.tgz)");
    try expectBuildRefused(a, h.MAIN, &.{l}, true, "the main package @komira-ai/komira is not one of the packages given");
    try expectBuildRefused(a, h.MAIN, &.{m}, true, "the main package @komira-ai/komira is the only package: a set holds a platform package at least");
    try expectBuildRefused(a, h.MAIN, &.{ try input(a, h.MAIN, "0.0.0"), try input(a, h.LINUX, "0.0.0") }, true, "the packages are unstamped (0.0.0): a release set is stamped");
}

test "a written set is read back as itself, and a key a reader does not know is ignored" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const s = try set.parse(a, &why, "npm_set.json", GOLDEN);
    try t.expectEqualStrings(GOLDEN, try set.render(a, s));
    try t.expectEqualStrings(h.MAIN, s.main);
    try t.expectEqualStrings(MAIN_SRI, s.find(h.MAIN).?.integrity);
    try t.expect(s.find(h.DARWIN) == null);
    // a later writer may add a key at the top and in a package: this reader still reads the set
    const later = try std.mem.replaceOwned(u8, a, GOLDEN, "  \"main\"", "  \"size\": 1,\n  \"main\"");
    const later2 = try std.mem.replaceOwned(u8, a, later, "{\"name\": \"@komira-ai/komira\",", "{\"bytes\": 5, \"name\": \"@komira-ai/komira\",");
    try t.expectEqualStrings(GOLDEN, try set.render(a, try set.parse(a, &why, "npm_set.json", later2)));
}

test "a set is refused unless every field is one build could have written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = struct {
        fn edit(ar: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
            const out = try std.mem.replaceOwned(u8, ar, GOLDEN, from, to);
            try t.expect(!std.mem.eql(u8, out, GOLDEN));
            return out;
        }
    };
    try expectParseRefused(a, "not json", "npm_set.json is not an npm set (SyntaxError): it is an object of main, version and packages, each package an object of name, version, file, sha256 and integrity");
    try expectParseRefused(a, try r.edit(a, "\"file\": \"komira-ai-komira-0.1.7.tgz\", ", ""), "npm_set.json is not an npm set (MissingField): it is an object of main, version and packages, each package an object of name, version, file, sha256 and integrity");
    try expectParseRefused(a, try r.edit(a, "\"version\": \"0.1.7\",\n", "\"version\": \"0.1\",\n"), "npm_set.json: \"0.1\" is not a version");
    try expectParseRefused(a, try r.edit(a, "\"main\": \"@komira-ai/komira\"", "\"main\": \"komira\""), "npm_set.json: main \"komira\" is not a package name of @komira-ai/");
    try expectParseRefused(a, "{\"main\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"packages\": []}", "npm_set.json holds 0 package(s): a set holds the main package and a platform package at least");
    try expectParseRefused(a, try r.edit(a, "{\"name\": \"@komira-ai/komira-linux-x64-gnu\"", "{\"name\": \"@komira-ai/Linux\""), "npm_set.json: \"@komira-ai/Linux\" is not a package name of @komira-ai/");
    try expectParseRefused(a, try r.edit(a, "\"version\": \"0.1.7\", \"file\": \"komira-ai-komira-0.1.7.tgz\"", "\"version\": \"0.1.8\", \"file\": \"komira-ai-komira-0.1.8.tgz\""), "npm_set.json: @komira-ai/komira is at 0.1.8, not the set's 0.1.7");
    try expectParseRefused(a, try r.edit(a, "\"file\": \"komira-ai-komira-0.1.7.tgz\"", "\"file\": \"../komira-ai-komira-0.1.7.tgz\""), "npm_set.json: the file of @komira-ai/komira is ../komira-ai-komira-0.1.7.tgz, not komira-ai-komira-0.1.7.tgz");
    try expectParseRefused(a, try r.edit(a, MAIN_SHA, "8BC05BD6A91214B3DC6A3F7A1D5215D883CDD36ECBBF4D96227711A6FFC1AD00"), "npm_set.json: the sha256 of @komira-ai/komira is not 64 lowercase hex characters");
    try expectParseRefused(a, try r.edit(a, MAIN_SHA, MAIN_SHA[0..63]), "npm_set.json: the sha256 of @komira-ai/komira is not 64 lowercase hex characters");
    // not sha512, not padded, not base64, too short
    try expectParseRefused(a, try r.edit(a, "\"integrity\": \"sha512-diE", "\"integrity\": \"sha256-diE"), "npm_set.json: the integrity of @komira-ai/komira is not sha512- and the base64 of 64 bytes");
    try expectParseRefused(a, try r.edit(a, "c6AInN/wVbEPA==", "c6AInN/wVbEPA"), "npm_set.json: the integrity of @komira-ai/komira is not sha512- and the base64 of 64 bytes");
    try expectParseRefused(a, try r.edit(a, "c6AInN/wVbEPA==", "c6AInN/wVbEP*=="), "npm_set.json: the integrity of @komira-ai/komira is not sha512- and the base64 of 64 bytes");
    try expectParseRefused(a, try r.edit(a, MAIN_SRI, "sha512-AA=="), "npm_set.json: the integrity of @komira-ai/komira is not sha512- and the base64 of 64 bytes");
    // the order: the main package last, the platform packages sorted, no name twice
    const main_first = try std.fmt.allocPrint(a, "{{\"main\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"packages\": [{{\"name\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira-linux-x64-gnu\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-linux-x64-gnu-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}]}}", .{ MAIN_SHA, MAIN_SRI, LINUX_SHA, LINUX_SRI });
    try expectParseRefused(a, main_first, "npm_set.json: the main package @komira-ai/komira is not last: it is published after every platform package");
    const two_platforms = try std.fmt.allocPrint(a, "{{\"main\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"packages\": [{{\"name\": \"@komira-ai/komira-linux-x64-gnu\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-linux-x64-gnu-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira-darwin-arm64\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-darwin-arm64-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}]}}", .{ LINUX_SHA, LINUX_SRI, DARWIN_SHA, DARWIN_SRI });
    try expectParseRefused(a, two_platforms, "npm_set.json: the last package is @komira-ai/komira-darwin-arm64, not the main package @komira-ai/komira: the main package is published last");
    const unsorted = try std.fmt.allocPrint(a, "{{\"main\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"packages\": [{{\"name\": \"@komira-ai/komira-linux-x64-gnu\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-linux-x64-gnu-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira-darwin-arm64\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-darwin-arm64-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}]}}", .{ LINUX_SHA, LINUX_SRI, DARWIN_SHA, DARWIN_SRI, MAIN_SHA, MAIN_SRI });
    try expectParseRefused(a, unsorted, "npm_set.json: the platform packages are not sorted by name (@komira-ai/komira-darwin-arm64 follows @komira-ai/komira-linux-x64-gnu)");
    const twice = try std.fmt.allocPrint(a, "{{\"main\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"packages\": [{{\"name\": \"@komira-ai/komira-linux-x64-gnu\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-linux-x64-gnu-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira-linux-x64-gnu\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-linux-x64-gnu-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}, {{\"name\": \"@komira-ai/komira\", \"version\": \"0.1.7\", \"file\": \"komira-ai-komira-0.1.7.tgz\", \"sha256\": \"{s}\", \"integrity\": \"{s}\"}}]}}", .{ LINUX_SHA, LINUX_SRI, LINUX_SHA, LINUX_SRI, MAIN_SHA, MAIN_SRI });
    try expectParseRefused(a, twice, "npm_set.json: @komira-ai/komira-linux-x64-gnu is listed twice");
}

test "a directory holds the set when it holds exactly its tarballs and npm_set.json, each with the recorded bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const s = try h.writeSet(a, &tmp, "set", "0.1.7");
    const dir = try h.path(a, &tmp, "set");
    var why: []const u8 = "";
    try set.verifyDir(a, &why, s, dir);
    // the set as loaded from the directory is the one written
    try t.expectEqualStrings(GOLDEN, try set.render(a, try set.load(a, &why, try h.path(a, &tmp, "set/npm_set.json"))));

    // a file the set does not name
    try tmp.dir.writeFile(.{ .sub_path = "set/stray.tgz", .data = "x" });
    try t.expectError(error.Refused, set.verifyDir(a, &why, s, dir));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s} holds stray.tgz, which is no file of the set", .{dir}), why);
    try tmp.dir.deleteFile("set/stray.tgz");

    // other bytes under a tarball's name
    try tmp.dir.writeFile(.{ .sub_path = "set/komira-ai-komira-0.1.7.tgz", .data = "abc" });
    try t.expectError(error.Refused, set.verifyDir(a, &why, s, dir));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/komira-ai-komira-0.1.7.tgz has the sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad, not the set's " ++ MAIN_SHA, .{dir}), why);

    // a tarball missing
    try tmp.dir.deleteFile("set/komira-ai-komira-0.1.7.tgz");
    try t.expectError(error.Refused, set.verifyDir(a, &why, s, dir));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot read the tarball {s}/komira-ai-komira-0.1.7.tgz: FileNotFound", .{dir}), why);

    // no directory, no set file
    try t.expectError(error.Refused, set.verifyDir(a, &why, s, try h.path(a, &tmp, "none")));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot open the set's directory {s}: FileNotFound", .{try h.path(a, &tmp, "none")}), why);
    try t.expectError(error.Refused, set.load(a, &why, try h.path(a, &tmp, "none/npm_set.json")));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot read the set {s}: FileNotFound", .{try h.path(a, &tmp, "none/npm_set.json")}), why);
}
