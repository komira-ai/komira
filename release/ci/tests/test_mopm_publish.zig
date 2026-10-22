//! The cases of release/ci/mopm_publish.zig (release_lib/mopm_publish.zig),
//! part of the zig_test //release/ci/tests:test_release, run as a build action:
//! building the tool is running them. mopm is a fake that records every argv
//! it is given and answers as the real mopm 0.0.20 does (the `would upload`
//! lines of its dry run and the registry's own refusal text are copied from
//! it), so a case can say what was and was not run. Each case names the defect
//! it would catch.
//!
//! - the dry run's line is read exactly (one linux-64 file, its sha256), and a
//!   file name of another shape has no compiler.
//! - what would be uploaded must be the built package: a different sha256 or
//!   file name is a failure and nothing is published (a publish of bytes the
//!   tests never ran).
//! - DRY-RUN MODE NEVER PUBLISHES: no argv without `--dry-run` is run (the
//!   defect: the always-on job on a push to main uploading).
//! - publish mode runs the dry run first, then the publish with the registry,
//!   manifest and `.mojoc` of the package; a version the registry has is
//!   skipped (a re-run is safe) and any other refusal is a failure (a skip
//!   that swallowed every error would report a green publish that sent
//!   nothing).
//! - the set and src/ name the same packages, both ways.
const std = @import("std");
const lib = @import("release_lib");
const t = std.testing;

const mp = lib.mopm_publish;

const SHA = "ffa371ebf98317460b99ffae9ab39d2fb510de3c647a76b812fb14d6bf8b9308";
const OTHER_SHA = "3bfcc9156325733b6688eea91a368a1e78673ca1a0923816897caa85922114ba";
const FILE = "mojo-komira_json-0.1.0-mojo1.0.0_0.conda";

const DRY_OK = "would upload linux-64/" ++ FILE ++ " (122381 bytes, sha256 " ++ SHA ++ ")\n" ++
    "would commit mojo-komira_json 0.1.0 (manifest_sha256 " ++ OTHER_SHA ++ ")\n" ++
    "would send a readme of 4395 bytes\ndry run: nothing was sent\n";

const EXISTS = "mopm: 'komira_json' 0.1.0 already exists (sha256 " ++ SHA ++ "); versions are immutable.\n";

/// Records every argv; answers a dry run (an argv with `--dry-run`) and a
/// publish from two scripted answers.
const Fake = struct {
    dry: mp.RunOut,
    real: mp.RunOut,
    calls: std.ArrayList([]const []const u8) = .empty,

    pub fn run(self: *Fake, a: std.mem.Allocator, argv: []const []const u8) anyerror!mp.RunOut {
        try self.calls.append(a, argv);
        return if (has(argv, "--dry-run")) self.dry else self.real;
    }

    fn realCalls(self: *const Fake) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (!has(c, "--dry-run")) n += 1;
        }
        return n;
    }
};

fn has(argv: []const []const u8, word: []const u8) bool {
    for (argv) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn ok(stdout: []const u8) mp.RunOut {
    return .{ .code = 0, .stdout = stdout, .stderr = "" };
}

const PKG = mp.Package{ .name = "komira_json", .mojoc = "set/komira_json/komira_json.mojoc", .conda_file = FILE, .conda_sha256 = SHA };

fn opts(dry_run: bool) mp.Options {
    return .{ .mopm = "/bin/mopm", .registry = "gamma", .repo = "/repo", .dry_run = dry_run };
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "the compiler comes from the file name of this package and no other shape" {
    try t.expectEqualStrings("1.0.0", mp.compilerOf("komira_json", FILE).?);
    // another package's file
    try t.expect(mp.compilerOf("komira_encoding", FILE) == null);
    // a name that only starts like the package
    try t.expect(mp.compilerOf("komira", FILE) == null);
    // not a _0 build, no compiler part, a compiler that is not a version
    try t.expect(mp.compilerOf("komira_json", "mojo-komira_json-0.1.0-mojo1.0.0_1.conda") == null);
    try t.expect(mp.compilerOf("komira_json", "mojo-komira_json-0.1.0_0.conda") == null);
    try t.expect(mp.compilerOf("komira_json", "mojo-komira_json-0.1.0-mojo1.0.0-rc_0.conda") == null);
    try t.expect(mp.compilerOf("komira_json", "komira_json-0.1.0-mojo1.0.0_0.conda") == null);
}

test "the dry run's one linux-64 line is read, and anything else is not a line" {
    const w = mp.parseWouldUpload(DRY_OK).?;
    try t.expectEqualStrings(FILE, w.file);
    try t.expectEqualStrings(SHA, w.sha256);
    try t.expect(mp.parseWouldUpload("dry run: nothing was sent\n") == null);
    // two files: these packages ship one
    try t.expect(mp.parseWouldUpload(DRY_OK ++ DRY_OK) == null);
    // another subdir
    try t.expect(mp.parseWouldUpload("would upload noarch/x.conda (1 bytes, sha256 " ++ SHA ++ ")\n") == null);
    // truncated
    try t.expect(mp.parseWouldUpload("would upload linux-64/x.conda (1 bytes, sha256 " ++ SHA) == null);
}

test "the registry's refusal of a version it has is recognised, and a lookalike is not" {
    try t.expect(mp.alreadyExists(EXISTS));
    try t.expect(!mp.alreadyExists("mopm: 'komira_json' is already taken.\n"));
    try t.expect(!mp.alreadyExists("mopm: not logged in to gamma; run 'mopm login' or set MOPM_TOKEN\n"));
    // the phrase without the immutability: some other refusal
    try t.expect(!mp.alreadyExists("mopm: the upload already exists in the queue\n"));
}

test "dry-run mode runs only dry runs and sends nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = Fake{ .dry = ok(DRY_OK), .real = .{ .code = 1, .stdout = "", .stderr = "PUBLISHED" } };
    const r = mp.publishOne(a, opts(true), PKG, &f);
    try t.expect(r == .dry_run_ok);
    try t.expectEqual(@as(usize, 1), f.calls.items.len);
    try t.expectEqual(@as(usize, 0), f.realCalls());
}

test "publish mode dry-runs first, then publishes with the package's registry, manifest and mojoc" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = Fake{ .dry = ok(DRY_OK), .real = ok("published mojo-komira_json 0.1.0\n") };
    const r = mp.publishOne(a, opts(false), PKG, &f);
    try t.expect(r == .published);
    try t.expectEqual(@as(usize, 2), f.calls.items.len);
    try t.expect(has(f.calls.items[0], "--dry-run"));
    const real = f.calls.items[1];
    try t.expect(!has(real, "--dry-run"));
    try t.expectEqualStrings("/bin/mopm", real[0]);
    try t.expectEqualStrings("publish", real[1]);
    try t.expect(has(real, "1.0.0"));
    try t.expect(has(real, "linux-64=set/komira_json/komira_json.mojoc"));
    try t.expect(has(real, "/repo/src/komira_json/mopm.toml"));
    try t.expect(has(real, "gamma"));
}

test "a package other than the built one is not published" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // the same name, other bytes
    var f = Fake{
        .dry = ok("would upload linux-64/" ++ FILE ++ " (1 bytes, sha256 " ++ OTHER_SHA ++ ")\n"),
        .real = ok("published\n"),
    };
    try t.expect(mp.publishOne(a, opts(false), PKG, &f) == .failed);
    try t.expectEqual(@as(usize, 0), f.realCalls());
    // other file name (another version), the same bytes
    var g = Fake{
        .dry = ok("would upload linux-64/mojo-komira_json-0.2.0-mojo1.0.0_0.conda (1 bytes, sha256 " ++ SHA ++ ")\n"),
        .real = ok("published\n"),
    };
    try t.expect(mp.publishOne(a, opts(false), PKG, &g) == .failed);
    try t.expectEqual(@as(usize, 0), g.realCalls());
    // dry run is held to the build in dry-run mode too
    var h = Fake{ .dry = ok("dry run: nothing was sent\n"), .real = ok("") };
    try t.expect(mp.publishOne(a, opts(true), PKG, &h) == .failed);
}

test "a failed dry run stops the package, with mopm's words in the message" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = Fake{ .dry = .{ .code = 1, .stdout = "", .stderr = "mopm: manifest: no such file\n" }, .real = ok("published\n") };
    const r = mp.publishOne(a, opts(false), PKG, &f);
    try t.expect(r == .failed);
    try t.expect(std.mem.indexOf(u8, r.failed, "no such file") != null);
    try t.expectEqual(@as(usize, 0), f.realCalls());
}

test "a version the registry has is skipped, in either stream, and nothing else is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var on_err = Fake{ .dry = ok(DRY_OK), .real = .{ .code = 1, .stdout = "", .stderr = EXISTS } };
    try t.expect(mp.publishOne(a, opts(false), PKG, &on_err) == .already_published);
    var on_out = Fake{ .dry = ok(DRY_OK), .real = .{ .code = 1, .stdout = EXISTS, .stderr = "" } };
    try t.expect(mp.publishOne(a, opts(false), PKG, &on_out) == .already_published);
    // a refusal that is not "exists": a failure, with the text
    var denied = Fake{ .dry = ok(DRY_OK), .real = .{ .code = 1, .stdout = "", .stderr = "mopm: not logged in to gamma\n" } };
    const r = mp.publishOne(a, opts(false), PKG, &denied);
    try t.expect(r == .failed);
    try t.expect(std.mem.indexOf(u8, r.failed, "not logged in") != null);
    // the phrase in a run that exited 0 is a publish, not a skip
    var odd = Fake{ .dry = ok(DRY_OK), .real = .{ .code = 0, .stdout = EXISTS, .stderr = "" } };
    try t.expect(mp.publishOne(a, opts(false), PKG, &odd) == .published);
}

test "a built file of another shape is refused before mopm runs" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = Fake{ .dry = ok(DRY_OK), .real = ok("") };
    var p = PKG;
    p.conda_file = "komira_json.tar.bz2";
    try t.expect(mp.publishOne(a, opts(true), p, &f) == .failed);
    try t.expectEqual(@as(usize, 0), f.calls.items.len);
}

test "the set and the packages of src/ name the same packages, both ways" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const two = [_][]const u8{ "komira_json", "komira_encoding" };
    const flipped = [_][]const u8{ "komira_encoding", "komira_json" };
    try t.expect((try mp.checkSync(a, &two, &flipped)) == null);
    // a package moved to mopm and not added to the set
    const more = [_][]const u8{ "komira_json", "komira_encoding", "komira_hash" };
    const why = (try mp.checkSync(a, &two, &more)).?;
    try t.expect(std.mem.indexOf(u8, why, "src/komira_hash has a mopm.toml") != null);
    try t.expect(std.mem.indexOf(u8, why, "komira_json") == null);
    // a package in the set whose manifest is gone
    const fewer = [_][]const u8{"komira_json"};
    const gone = (try mp.checkSync(a, &two, &fewer)).?;
    try t.expect(std.mem.indexOf(u8, gone, "komira_encoding is in //release:mopm_set") != null);
    // nothing on either side agrees
    try t.expect((try mp.checkSync(a, &fewer, &[_][]const u8{"komira_hash"})) != null);
}
