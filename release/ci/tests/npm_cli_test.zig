//! The cases of npm_smoke's command line (release/ci/npm_smoke/cli.zig), part of //release/ci/tests:test_npm_smoke:
//! the exit status (0, 1 or 2), what is printed, what is appended to the output file, and that a usage error
//! or a refused set reaches no command.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const h = @import("npm_testing.zig");
const set_test = @import("npm_set_test.zig");
const t = std.testing;

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    pause: h.CountingPause = .{},

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn p(self: *Case, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.a(), &.{ try h.path(self.a(), &self.tmp, "."), rel });
    }

    fn exec(self: *Case, fake: *h.FakeNpm, args: []const []const u8) !h.Result {
        return h.exec(self.a(), args, fake, &self.pause);
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
};

fn newCase() Case {
    return .{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
}

fn expectUsage(c: *Case, args: []const []const u8, first_line: []const u8) !void {
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const r = try c.exec(&fake, args);
    try t.expectEqual(@as(u8, 2), r.code);
    try t.expectEqualStrings("", r.out);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "{s}\n{s}", .{ first_line, lib.cli.usage }), r.err);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "a usage error exits 2 with the reason and the usage, before anything is read or run" {
    var c = newCase();
    defer c.deinit();
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const none = try c.exec(&fake, &.{});
    try t.expectEqual(@as(u8, 2), none.code);
    try t.expectEqualStrings(lib.cli.usage, none.err);
    const unknown = try c.exec(&fake, &.{"stage"});
    try t.expectEqual(@as(u8, 2), unknown.code);
    try t.expectEqualStrings(lib.cli.usage, unknown.err);

    try expectUsage(&c, &.{ "gate", "--file", "f", "--github-output", "o", "--token", "x" }, "npm_smoke: unknown argument --token");
    try expectUsage(&c, &.{ "gate", "--file", "f" }, "npm_smoke: --github-output is missing");
    try expectUsage(&c, &.{ "gate", "--file", "f", "--file", "g", "--github-output", "o" }, "npm_smoke: --file is given twice");
    try expectUsage(&c, &.{ "gate", "--file" }, "npm_smoke: --file needs a value");
    try expectUsage(&c, &.{ "set", "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "true", "--out", "o" }, "npm_smoke: --package is missing");
    try expectUsage(&c, &.{ "set", "--main", h.MAIN, "--require-stamped", "true", "--out", "o", "--package", "x=y" }, "npm_smoke: --main-optional is missing");
    try expectUsage(&c, &.{ "set", "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "yes", "--out", "o", "--package", "x=y" }, "npm_smoke: --require-stamped is true or false, not yes");
    try expectUsage(&c, &.{ "set", "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "true", "--out", "o", "--package", "x" }, "npm_smoke: --package is <name>=<tarball>, not x");
    try expectUsage(&c, &.{ "verify", "--set", "s", "--dir", "d" }, "npm_smoke: --github-output is missing");
    try expectUsage(&c, &.{ "publish", "--set", "s", "--dir", "d", "--node", "n", "--npm", "m" }, "npm_smoke: --work is missing");
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "/n", "--npm", "/m", "--work", "/w", "--attempts", "0" }, "npm_smoke: --attempts is a number from 1 to 20");
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "/n", "--npm", "/m", "--work", "/w", "--attempts", "21" }, "npm_smoke: --attempts is a number from 1 to 20");
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "/n", "--npm", "/m", "--work", "/w", "--delay", "301" }, "npm_smoke: --delay is a number of seconds from 0 to 300");
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "/n", "--npm", "/m", "--work", "/w", "--delay", "-1" }, "npm_smoke: --delay is a number of seconds from 0 to 300");
    // npm runs in the work directory: a relative path there would name another file
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "/n", "--npm", "/m", "--work", "w" }, "npm_smoke: --work is an absolute path, not w");
    try expectUsage(&c, &.{ "smoke", "--set", "s", "--node", "bin/node", "--npm", "/m", "--work", "/w" }, "npm_smoke: --node is an absolute path, not bin/node");
    try expectUsage(&c, &.{ "publish", "--set", "s", "--dir", "set", "--node", "/n", "--npm", "/m", "--work", "/w" }, "npm_smoke: --dir is an absolute path, not set");
    try expectUsage(&c, &.{ "publish", "--set", "s", "--dir", "/set", "--node", "/n", "--npm", "m", "--work", "/w" }, "npm_smoke: --npm is an absolute path, not m");
}

test "set writes npm_set.json for the tarballs given, the main package last" {
    var c = newCase();
    defer c.deinit();
    const inputs = try h.writeTarballs(c.a(), &c.tmp, "in", &.{ h.MAIN, h.LINUX }, "0.1.7");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const out = try c.p("npm_set.json");
    const r = try c.exec(&fake, &.{
        "set",       "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "true", "--out", out,
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.MAIN, inputs[0].path }),
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.LINUX, inputs[1].path }),
    });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("npm_smoke: the set of 2 packages at 0.1.7, @komira-ai/komira last\n", r.out);
    try t.expectEqualStrings(set_test.GOLDEN, try h.readAll(c.a(), &c.tmp, "npm_set.json"));
}

test "set refuses an unstamped set when it must be stamped, and a tarball it cannot read, with exit 1 and an annotation" {
    var c = newCase();
    defer c.deinit();
    const inputs = try h.writeTarballs(c.a(), &c.tmp, "in", &.{ h.MAIN, h.LINUX }, "0.0.0");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const args = [_][]const u8{
        "set",       "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "true", "--out", try c.p("npm_set.json"),
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.MAIN, inputs[0].path }),
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.LINUX, inputs[1].path }),
    };
    const r = try c.exec(&fake, &args);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("npm_smoke: FAILED: the packages are unstamped (0.0.0): a release set is stamped\n", r.err);
    try t.expectEqualStrings("::error title=npm::the packages are unstamped (0.0.0): a release set is stamped\n", r.out);
    try t.expect(!h.exists(&c.tmp, "npm_set.json"));
    // the same tarballs make a set of a pull request
    var unstamped = args;
    unstamped[6] = "false";
    try t.expectEqual(@as(u8, 0), (try c.exec(&fake, &unstamped)).code);

    const gone = try c.exec(&fake, &.{ "set", "--main", h.MAIN, "--main-optional", h.LINUX, "--require-stamped", "false", "--out", try c.p("x.json"), "--package", "@komira-ai/komira=/nowhere/komira-ai-komira-0.1.7.tgz" });
    try t.expectEqual(@as(u8, 1), gone.code);
    try t.expectEqualStrings("npm_smoke: FAILED: cannot read the tarball /nowhere/komira-ai-komira-0.1.7.tgz: FileNotFound\n", gone.err);
}

test "set refuses, with exit 1 and no record, a main package that names a platform package the set does not hold" {
    var c = newCase();
    defer c.deinit();
    const inputs = try h.writeTarballs(c.a(), &c.tmp, "in", &.{ h.MAIN, h.LINUX }, "0.1.7");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    // The set without the macOS package (its install test did not pass), and a main package that names it.
    const r = try c.exec(&fake, &.{
        "set",       "--main", h.MAIN, "--main-optional", try std.fmt.allocPrint(c.a(), "{s},{s}", .{ h.DARWIN, h.LINUX }), "--require-stamped", "true", "--out", try c.p("npm_set.json"),
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.MAIN, inputs[0].path }),
        "--package", try std.fmt.allocPrint(c.a(), "{s}={s}", .{ h.LINUX, inputs[1].path }),
    });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("npm_smoke: FAILED: the main package @komira-ai/komira names @komira-ai/komira-darwin-arm64 as an optional dependency, which is no platform package of the set: npm would find nothing to install for it\n", r.err);
    try t.expect(!h.exists(&c.tmp, "npm_set.json"));
}

test "gate appends publish=false or publish=true after what the output file held" {
    var c = newCase();
    defer c.deinit();
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    try c.tmp.dir.writeFile(.{ .sub_path = "off.txt", .data = "# the go\npublish: off\n" });
    try c.tmp.dir.writeFile(.{ .sub_path = "on.txt", .data = "publish: on\n" });
    try c.tmp.dir.writeFile(.{ .sub_path = "out", .data = "earlier=1\n" });
    const off = try c.exec(&fake, &.{ "gate", "--file", try c.p("off.txt"), "--github-output", try c.p("out") });
    try t.expectEqual(@as(u8, 0), off.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "npm_smoke: {s} says publish: off: the publish job and the smoke are skipped\n", .{try c.p("off.txt")}), off.out);
    const on = try c.exec(&fake, &.{ "gate", "--file", try c.p("on.txt"), "--github-output", try c.p("out") });
    try t.expectEqual(@as(u8, 0), on.code);
    try t.expectEqualStrings("earlier=1\npublish=false\npublish=true\n", try h.readAll(c.a(), &c.tmp, "out"));

    // a gate that cannot be read, or says neither, fails the step and writes no output
    try c.tmp.dir.writeFile(.{ .sub_path = "bad.txt", .data = "publish: maybe\n" });
    const bad = try c.exec(&fake, &.{ "gate", "--file", try c.p("bad.txt"), "--github-output", try c.p("out2") });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "::error title=npm::{s}:1: \"publish: maybe\" is neither `publish: off` nor `publish: on` (nor a comment)\n", .{try c.p("bad.txt")}), bad.out);
    try t.expect(!h.exists(&c.tmp, "out2"));
    const missing = try c.exec(&fake, &.{ "gate", "--file", try c.p("none.txt"), "--github-output", try c.p("out2") });
    try t.expectEqual(@as(u8, 1), missing.code);
    // an output file that cannot be written
    const unwritable = try c.exec(&fake, &.{ "gate", "--file", try c.p("on.txt"), "--github-output", try c.p("no/such/dir/out") });
    try t.expectEqual(@as(u8, 1), unwritable.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "npm_smoke: FAILED: cannot write --github-output {s}: FileNotFound\n", .{try c.p("no/such/dir/out")}), unwritable.err);
}

test "verify holds the downloaded directory to its set and to the set built from the same stamp, and appends the version" {
    var c = newCase();
    defer c.deinit();
    _ = try h.writeSet(c.a(), &c.tmp, "got", "0.1.7");
    _ = try h.writeSet(c.a(), &c.tmp, "built", "0.1.7");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const r = try c.exec(&fake, &.{ "verify", "--set", try c.p("got/npm_set.json"), "--dir", try c.p("got"), "--github-output", try c.p("out"), "--built", try c.p("built/npm_set.json") });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("version=0.1.7\n", try h.readAll(c.a(), &c.tmp, "out"));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "npm_smoke: {s} holds the 2 tarballs of {s} at 0.1.7, each with its sha256 and integrity\n", .{ try c.p("got"), try c.p("got/npm_set.json") }), r.out);

    // the set the job built differs: another version, or other bytes of one package
    _ = try h.writeSet(c.a(), &c.tmp, "newer", "0.1.8");
    const newer = try c.exec(&fake, &.{ "verify", "--set", try c.p("got/npm_set.json"), "--dir", try c.p("got"), "--github-output", try c.p("out2"), "--built", try c.p("newer/npm_set.json") });
    try t.expectEqual(@as(u8, 1), newer.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "npm_smoke: FAILED: the set {s} is not the set built from the same stamp ({s}): the version is 0.1.7, and 0.1.8 was built\n", .{ try c.p("got/npm_set.json"), try c.p("newer/npm_set.json") }), newer.err);
    try t.expect(!h.exists(&c.tmp, "out2"));
    try c.tmp.dir.writeFile(.{ .sub_path = "built/komira-ai-komira-0.1.7.tgz", .data = "abc" });
    var why: []const u8 = "";
    const inputs = try h.writeTarballs(c.a(), &c.tmp, "built", &.{h.LINUX}, "0.1.7");
    const rebuilt = try lib.set.build(c.a(), &why, h.MAIN, &.{ inputs[0], .{ .name = h.MAIN, .path = try c.p("built/komira-ai-komira-0.1.7.tgz"), .bytes = "abc" } }, true);
    try c.tmp.dir.writeFile(.{ .sub_path = "built/npm_set.json", .data = try lib.set.render(c.a(), rebuilt) });
    const other = try c.exec(&fake, &.{ "verify", "--set", try c.p("got/npm_set.json"), "--dir", try c.p("got"), "--github-output", try c.p("out2"), "--built", try c.p("built/npm_set.json") });
    try t.expectEqual(@as(u8, 1), other.code);
    try t.expect(std.mem.endsWith(u8, other.err, ": @komira-ai/komira has the sha256 8bc05bd6a91214b3dc6a3f7a1d5215d883cdd36ecbbf4d96227711a6ffc1ad00, and ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad was built\n"));

    // a tarball changed after the set was written
    try c.tmp.dir.writeFile(.{ .sub_path = "got/komira-ai-komira-linux-x64-gnu-0.1.7.tgz", .data = "abc" });
    const changed = try c.exec(&fake, &.{ "verify", "--set", try c.p("got/npm_set.json"), "--dir", try c.p("got"), "--github-output", try c.p("out2") });
    try t.expectEqual(@as(u8, 1), changed.code);
    try t.expect(std.mem.indexOf(u8, changed.err, "komira-ai-komira-linux-x64-gnu-0.1.7.tgz has the sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad, not the set's ") != null);
}

test "verify, publish and smoke refuse an unstamped set before any command" {
    var c = newCase();
    defer c.deinit();
    _ = try h.writeSet(c.a(), &c.tmp, "pr", "0.0.0");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = "/nowhere" };
    const set_path = try c.p("pr/npm_set.json");
    const want = try std.fmt.allocPrint(c.a(), "npm_smoke: FAILED: {s} is unstamped (0.0.0): only a release set is verified, published or smoked\n", .{set_path});
    const verify = try c.exec(&fake, &.{ "verify", "--set", set_path, "--dir", try c.p("pr"), "--github-output", try c.p("out") });
    try t.expectEqual(@as(u8, 1), verify.code);
    try t.expectEqualStrings(want, verify.err);
    const publish = try c.exec(&fake, &.{ "publish", "--set", set_path, "--dir", try c.p("pr"), "--node", "/n", "--npm", "/m", "--work", try c.p("w") });
    try t.expectEqual(@as(u8, 1), publish.code);
    try t.expectEqualStrings(want, publish.err);
    const smoke = try c.exec(&fake, &.{ "smoke", "--set", set_path, "--node", "/n", "--npm", "/m", "--work", try c.p("w") });
    try t.expectEqual(@as(u8, 1), smoke.code);
    try t.expectEqualStrings(want, smoke.err);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try t.expect(!h.exists(&c.tmp, "out"));
}

test "publish holds the directory to the set before it asks the registry anything, then publishes in the set's order" {
    var c = newCase();
    defer c.deinit();
    _ = try h.writeSet(c.a(), &c.tmp, "set", "0.1.7");
    const work = try c.p("w");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = work };
    try c.tmp.dir.writeFile(.{ .sub_path = "set/extra.tgz", .data = "x" });
    const args = [_][]const u8{ "publish", "--set", try c.p("set/npm_set.json"), "--dir", try c.p("set"), "--node", "/n/node", "--npm", "/m", "--work", work };
    const stray = try c.exec(&fake, &args);
    try t.expectEqual(@as(u8, 1), stray.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "npm_smoke: FAILED: {s} holds extra.tgz, which is no file of the set\n", .{try c.p("set")}), stray.err);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);

    try c.tmp.dir.deleteFile("set/extra.tgz");
    const ok = try c.exec(&fake, &args);
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqual(@as(usize, 4), fake.calls.items.len);
    try t.expect(std.mem.indexOf(u8, fake.calls.items[1], " publish ") != null and std.mem.indexOf(u8, fake.calls.items[1], "komira-ai-komira-linux-x64-gnu-0.1.7.tgz") != null);
    try t.expect(std.mem.indexOf(u8, fake.calls.items[3], " publish ") != null and std.mem.endsWith(u8, fake.calls.items[3], "komira-ai-komira-0.1.7.tgz --access public " ++ h.NPM_FLAGS));

    // a publish that fails is exit 1 with the annotation, escaped to one line
    var failing = h.FakeNpm{ .alloc = c.a(), .work = work, .rules = &.{.{ .contains = " publish ", .code = 1, .stderr = "npm error code E403\nnpm error 100% refused\n" }} };
    const failed = try c.exec(&failing, &args);
    try t.expectEqual(@as(u8, 1), failed.code);
    try t.expect(std.mem.startsWith(u8, failed.out, "::error title=npm::publishing @komira-ai/komira-linux-x64-gnu@0.1.7 failed: "));
    try t.expect(std.mem.endsWith(u8, failed.out, " ended with exit status 1:%0Anpm error code E403%0Anpm error 100%25 refused\n"));
}

test "smoke runs the install and the query from the command line, the attempts and delay as given" {
    var c = newCase();
    defer c.deinit();
    const s = try h.writeSet(c.a(), &c.tmp, "set", "0.1.7");
    const work = try c.p("w");
    var fake = h.FakeNpm{ .alloc = c.a(), .work = work, .lock = try h.goodLock(c.a(), s), .rules = &.{.{ .contains = " install ", .code = 1, .times = 1 }} };
    const r = try c.exec(&fake, &.{ "smoke", "--set", try c.p("set/npm_set.json"), "--node", "/n/node", "--npm", "/m", "--work", work, "--attempts", "2", "--delay", "7" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 1), c.pause.times);
    try t.expectEqual(@as(u64, 7000), c.pause.ms);
    try t.expectEqual(@as(usize, 3), fake.calls.items.len);
    try t.expectEqualStrings("/n/node smoke.mjs", fake.calls.items[2]);

    // the defaults: five attempts, 30 seconds apart
    var c2 = newCase();
    defer c2.deinit();
    const s2 = try h.writeSet(c2.a(), &c2.tmp, "set", "0.1.7");
    const work2 = try c2.p("w");
    var never = h.FakeNpm{ .alloc = c2.a(), .work = work2, .lock = try h.goodLock(c2.a(), s2), .rules = &.{.{ .contains = " install ", .code = 1 }} };
    const r2 = try c2.exec(&never, &.{ "smoke", "--set", try c2.p("set/npm_set.json"), "--node", "/n/node", "--npm", "/m", "--work", work2 });
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expectEqual(@as(usize, 5), never.calls.items.len);
    try t.expectEqual(@as(usize, 4), c2.pause.times);
    try t.expectEqual(@as(u64, 120_000), c2.pause.ms);
}
