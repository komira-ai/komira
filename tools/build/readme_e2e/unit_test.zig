//! Unit tests of readme_e2e: the package reader, the plan and lock readers
//! and writers, the command line. (The commands themselves, over real
//! files and processes, are the scenarios: scenario.zig.)

const std = @import("std");
const conda = @import("conda.zig");
const plan = @import("plan.zig");
const cli = @import("cli.zig");
const verify = @import("verify.zig");
const offline = @import("offline.zig");
const native = @import("native.zig");
const take = @import("take.zig");
const fix = @import("fixture.zig");

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

fn expectCorrupt(bytes: []const u8, want: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var why: []const u8 = "";
    try std.testing.expectError(error.Corrupt, conda.read(ar.allocator(), bytes, &why));
    if (std.mem.indexOf(u8, why, want) == null) {
        std.debug.print("reason `{s}` has no `{s}`\n", .{ why, want });
        return error.TestUnexpectedResult;
    }
}

// ---- conda.zig ----------------------------------------------------------------

test "a package named <namespace>/<name> is read: its files under the import name, with their bytes, in archive order" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try fix.package(a, "example/good", "1.2.3", "mojo1.0.0_0", "the mojoc", &.{});
    var why: []const u8 = "";
    const files = try conda.read(a, bytes, &why);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("lib/mojo/good.mojoc", files[0].name);
    try std.testing.expectEqualStrings("the mojoc", files[0].bytes);
    try std.testing.expectEqualStrings("lib/mojo/good.mopm.json", files[1].name);
    try std.testing.expectEqualStrings("the mojoc", conda.find(files, "lib/mojo/good.mojoc").?);
    try std.testing.expect(conda.find(files, "lib/mojo/other.mojoc") == null);
}

test "a native library at lib/<soname> is a payload path" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const tar = try fix.tarOf(a, &.{.{ .name = "lib/libnative.a", .bytes = "archive" }});
    const bytes = try fix.condaOf(a, "mojo-good-1.0.0-mojo1.0.0_0", tar);
    var why: []const u8 = "";
    const files = try conda.read(a, bytes, &why);
    try std.testing.expectEqualStrings("archive", conda.find(files, "lib/libnative.a").?);
}

test "the source of a shipped program at lib/mojo/<package>.bins/<program>.mojo is a payload path" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const tar = try fix.tarOf(a, &.{
        .{ .name = "lib/mojo/good.bins/run_2.mojo", .bytes = "def main(): pass" },
        .{ .name = "lib/mojo/good.mojoc", .bytes = "the mojoc" },
    });
    const bytes = try fix.condaOf(a, "mojo-good-1.0.0-mojo1.0.0_0", tar);
    var why: []const u8 = "";
    const files = try conda.read(a, bytes, &why);
    try std.testing.expectEqualStrings("def main(): pass", conda.find(files, "lib/mojo/good.bins/run_2.mojo").?);
}

test "a path outside lib/mojo/<file>, a program source and lib/<file> is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "bin/tool", "etc/passwd", "lib/mojo/../../x", "lib/a/b/c", "lib/.hidden", "lib/", "/lib/x", "lib/x\\y", "libx/y", "lib/other/x.mojoc" } ++ [_][]const u8{ "lib/mojo/x.bins/Run.mojo", "lib/mojo/x.bins/a-b.mojo", "lib/mojo/x.bins/run.sh", "lib/mojo/x.bins/.mojo", "lib/mojo/.bins/run.mojo", "lib/mojo/x/run.mojo", "lib/other/x.bins/run.mojo", "lib/mojo/x.bins/a/run.mojo", "lib/x.bins/run.mojo", "lib/mojo/x.bins/run.mojo/y" };
    for (bad) |name| {
        const tar = try fix.tarOf(a, &.{.{ .name = name, .bytes = "x" }});
        const bytes = try fix.condaOf(a, "mojo-good-1.0.0-mojo1.0.0_0", tar);
        try expectCorrupt(bytes, "not a path a mopm package holds");
    }
}

test "a symbolic link, a name twice, a deflated member, a missing payload and garbage are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectCorrupt(try fix.condaOf(a, "s", try fix.tarWithLink(a, "lib/mojo/x.mojoc", "/etc/passwd")), "not a regular file");
    const twice = try fix.tarOf(a, &.{ .{ .name = "lib/mojo/x.mojoc", .bytes = "1" }, .{ .name = "lib/mojo/x.mojoc", .bytes = "2" } });
    try expectCorrupt(try fix.condaOf(a, "s", twice), "appears twice");
    try expectCorrupt(try fix.condaDeflated(a, "s"), "only stored (0) is supported");
    try expectCorrupt("", "no pkg-*.tar.zst member");
    try expectCorrupt("not a zip at all, but long enough to hold a header", "no pkg-*.tar.zst member");
    const whole = try fix.package(a, "example/good", "1.2.3", "mojo1.0.0_0", "m", &.{});
    try expectCorrupt(whole[0 .. whole.len - 40], "runs past the end");
    try expectCorrupt(try fix.condaOf(a, "s", "this is not a zstd frame"), "payload");
}

test "a package is unpacked below a directory, and not over a file that is there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const files = try conda.read(a, try fix.package(a, "example/good", "1.2.3", "mojo1.0.0_0", "bytes", &.{}), &why);
    try conda.extract(tmp.dir, files);
    const got = try tmp.dir.readFileAlloc(a, "lib/mojo/good.mojoc", 100);
    try std.testing.expectEqualStrings("bytes", got);
    try std.testing.expectError(error.PathAlreadyExists, conda.extract(tmp.dir, files));
}

// ---- plan.zig -----------------------------------------------------------------

const plan_text =
    \\{ "version": 2, "members": [
    \\  { "name": "acme/http_core", "version": "0.4.0", "action": "upload",
    \\    "manifest_sha256": "aa", "future_key": 7,
    \\    "files": [ { "subdir": "noarch", "filename": "mojo-acme.http_core-0.4.0-mojo1.0.0_0.conda", "sha256": "bb", "size": 12345 } ],
    \\    "readme": "acme/http_core/README.md" },
    \\  { "name": "acme/http_client", "version": "0.4.0", "action": "skip", "reason": "already published with these bytes" } ] }
;

test "a plan is read, its unknown keys ignored, and written the same way twice" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const p = try plan.parsePlan(a, plan_text, &why);
    try std.testing.expectEqual(@as(usize, 2), p.members.len);
    try std.testing.expectEqualStrings("acme/http_core/README.md", p.member("acme/http_core").?.readme.?);
    try std.testing.expectEqual(@as(u64, 12345), p.members[0].files[0].size);
    try std.testing.expect(p.member("acme/nobody") == null);
    const once = try plan.renderPlan(a, p);
    const again = try plan.renderPlan(a, try plan.parsePlan(a, once, &why));
    try std.testing.expectEqualStrings(once, again);
    try std.testing.expect(std.mem.indexOf(u8, once, "future_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, once, "null") == null);
}

test "a plan that is not one the reader takes is refused with the reason" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { text: []const u8, why: []const u8 }{
        .{ .text = "{\"version\": 1, \"members\": []}", .why = "plan.json: version 1, and only 2 is read" },
        .{ .text = "{\"version\": 3, \"members\": []}", .why = "plan.json: version 3, and only 2 is read" },
        .{ .text = "{\"version\": 2, \"members\": [{\"name\":\"x/a\",\"version\":\"1.0.0\",\"action\":\"upload\"},{\"name\":\"x/a\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .why = "x/a is a member twice" },
        .{ .text = "{\"version\": 2, \"members\": [{\"name\":\"x/a\",\"version\":\"1.0.0\",\"action\":\"publish\"}]}", .why = "action publish" },
        .{ .text = "{\"version\": 2, \"members\": [{\"name\":\"\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .why = "no name or version" },
        .{ .text = "{\"version\": 2, \"members\": [{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .why = "plan.json: member a has no namespace: a name is <namespace>/<name>" },
        .{ .text = "not json", .why = "plan.json" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        try std.testing.expectError(error.Invalid, plan.parsePlan(a, c.text, &why));
        try std.testing.expect(std.mem.indexOf(u8, why, c.why) != null);
    }
}

const lock_text =
    \\{ "lock_version": 3, "mojo": ["1.0.0"], "toolchain": {}, "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    { "name": "komira-ai/app", "version": "1.0.0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/komira-ai/",
    \\      "artifacts": { "1.0.0": { "build": "mojo1.0.0_0", "url": "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", "sha256": "cc", "size": 9 } },
    \\      "deps": ["komira-ai/lib"] },
    \\    { "name": "komira-ai/local", "version": "0.0.1", "source": "path" } ] }
;

fn lockRefusal(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, plan.parseLock(a, text, &why));
    return why;
}

test "a version 3 lock row of a namespaced package gives the .conda file name and the import name" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const l = try plan.parseLock(a, lock_text, &why);
    try std.testing.expectEqual(@as(usize, 2), l.packages.len);
    const app = l.find("komira-ai/app").?;
    const art = app.artifact("1.0.0").?;
    try std.testing.expectEqualStrings("mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", art.filename());
    try std.testing.expectEqualStrings("mojo1.0.0_0", art.build);
    try std.testing.expectEqualStrings("app", plan.importName(app.name));
    try std.testing.expect(app.artifact("1.1.0") == null);
    try std.testing.expect(!app.isPath());
    try std.testing.expectEqualStrings("komira-ai/lib", app.deps[0]);
    // A path package has no file, and a bare name is not found by its import name.
    try std.testing.expect(l.find("komira-ai/local").?.isPath());
    try std.testing.expect(l.find("app") == null);
}

test "a lock of version 1 or 2 is refused naming the version it reads" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const want = "mopm.lock: lock_version {d}; mopm writes 3 for the e2e's project (a lock before namespaces is 1 or 2), and only 3 is read";
    for ([_]u32{ 1, 2 }) |v| {
        const text = try std.fmt.allocPrint(a, "{{\"lock_version\": {d}, \"packages\": []}}", .{v});
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, want, .{v}), try lockRefusal(a, text));
    }
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, want, .{4}), try lockRefusal(a, "{\"lock_version\": 4, \"packages\": []}"));
}

test "a lock row of a package without a namespace is refused naming it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bare = try std.mem.replaceOwned(u8, a, lock_text, "\"komira-ai/local\"", "\"local\"");
    try std.testing.expectEqualStrings("mopm.lock: package local has no namespace: every name of a version 3 lock is <namespace>/<name>", try lockRefusal(a, bare));
}

test "a lock row whose url is not the namespaced package file is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The version of another file, and the file name of a lock before namespaces (no `komira-ai.`).
    const wrong = try std.mem.replaceOwned(u8, a, lock_text, "mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", "mojo-komira-ai.app-9.9.9-mojo1.0.0_0.conda");
    try std.testing.expectEqualStrings("mopm.lock: komira-ai/app 1.0.0: the url https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.app-9.9.9-mojo1.0.0_0.conda does not end in mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", try lockRefusal(a, wrong));
    const old = try std.mem.replaceOwned(u8, a, lock_text, "mojo-komira-ai.app-1.0.0", "mojo-app-1.0.0");
    try std.testing.expectEqualStrings("mopm.lock: komira-ai/app 1.0.0: the url https://conda.mopm.dev/komira-ai/linux-64/mojo-app-1.0.0-mojo1.0.0_0.conda does not end in mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", try lockRefusal(a, old));
}

test "a lock is written in the order given, and read back" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    var arts: std.json.ArrayHashMap(plan.Artifact) = .{};
    try arts.map.put(a, "1.0.0", .{ .build = "mojo1.0.0_0", .url = "https://conda.mopm.dev/komira-ai/linux-64/mojo-komira-ai.app-1.0.0-mojo1.0.0_0.conda", .sha256 = "dd", .size = 5 });
    const text = try plan.renderLock(a, "1.0.0", &.{.{ .name = "komira-ai/app", .version = "1.0.0", .subdir = "linux-64", .artifacts = arts }});
    const l = try plan.parseLock(a, text, &why);
    const art = l.packages[0].artifact("1.0.0").?;
    try std.testing.expectEqualStrings("dd", art.sha256);
    try std.testing.expectEqual(@as(u64, 5), art.size);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"lock_version\": 3") != null);
}

test "a package file is mojo-<namespace>.<name>-<version>-<build>.conda, and a name without a namespace has none" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqualStrings("mojo-komira-ai.http_core-0.4.0-mojo1.0.0_0.conda", (try plan.packageFile(a, "komira-ai/http_core", "0.4.0", "mojo1.0.0_0")).?);
    for ([_][]const u8{ "http_core", "/http_core", "komira-ai/", "a/b/c" }) |bad| {
        try std.testing.expect((try plan.packageFile(a, bad, "0.4.0", "mojo1.0.0_0")) == null);
    }
}

test "the import name of a full name is the part after the slash" {
    try std.testing.expectEqualStrings("http_core", plan.importName("komira-ai/http_core"));
    const n = plan.splitName("komira-ai/http_core").?;
    try std.testing.expectEqualStrings("komira-ai", n.namespace);
    try std.testing.expectEqualStrings("http_core", n.name);
    try std.testing.expect(plan.splitName("http_core") == null);
}

test "a file name and a relative path are told from a path that leaves its directory" {
    try std.testing.expect(plan.plainName("mojo-a-1.0.0-mojo1.0.0_0.conda"));
    for ([_][]const u8{ "", ".hidden", "a/b", "a\\b", "../a" }) |s| try std.testing.expect(!plan.plainName(s));
    try std.testing.expect(plan.relativePath("pkg/README.md"));
    for ([_][]const u8{ "", "/etc/passwd", "../x", "a/../b", "a//b", "a/./b", "a\\b" }) |s| try std.testing.expect(!plan.relativePath(s));
}

test "sha256Hex is the digest in lower-case hex" {
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &plan.sha256Hex("abc"));
}

// ---- cli.zig ------------------------------------------------------------------

fn runCli(args: []const []const u8) !struct { code: u8, out: []const u8 } {
    const a = std.heap.page_allocator;
    var out: std.ArrayList(u8) = .empty;
    const code = try cli.execute(a, args, &out);
    return .{ .code = code, .out = out.items };
}

fn expectUsage(args: []const []const u8, want: []const u8) !void {
    const r = try runCli(args);
    try std.testing.expectEqual(@as(u8, 2), r.code);
    if (std.mem.indexOf(u8, r.out, want) == null) {
        std.debug.print("output `{s}` has no `{s}`\n", .{ r.out, want });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.indexOf(u8, r.out, "usage: readme_e2e verify") != null);
}

test "a command line that is not one is refused with exit 2 and the usage" {
    try expectUsage(&.{}, "no command");
    try expectUsage(&.{"frob"}, "unknown command frob");
    try expectUsage(&.{ "verify", "--package" }, "--package takes a value");
    try expectUsage(&.{ "verify", "--package", "a", "--package", "b" }, "--package is given twice");
    try expectUsage(&.{ "verify", "--wat", "a" }, "unknown argument --wat");
    try expectUsage(&.{ "verify", "--package", "a" }, "--version is required");
    try expectUsage(&.{ "verify", "--package", "" }, "--package is required");
    try expectUsage(&.{ "assemble", "--out", "o", "--mojo", "1.0.0" }, "at least one --member is required");
    try expectUsage(&.{ "assemble", "--mojo", "1.0.0", "--member", "a", "1.0.0" }, "--member takes NAME VERSION CONDA README");
    try expectUsage(&.{ "assemble", "--member", "a", "1.0.0", "c", "r" }, "--out is required");
    try expectUsage(&.{ "assemble", "--out", "o", "--member", "a", "1.0.0", "c", "r" }, "--mojo is required");
    try expectUsage(&.{ "assemble", "--out", "o", "--out", "p" }, "--out is given twice");
    try expectUsage(&.{ "assemble", "--bogus", "x" }, "unknown argument --bogus");
    try expectUsage(&.{"take"}, "--staged is required");
    try expectUsage(&.{ "take", "--staged", "s" }, "--out is required");
    try expectUsage(&.{ "take", "--out", "o" }, "--staged is required");
    try expectUsage(&.{ "take", "--staged" }, "--staged takes a value");
    try expectUsage(&.{ "take", "--staged", "s", "--staged", "t" }, "--staged is given twice");
    try expectUsage(&.{ "take", "--staged", "", "--out", "o" }, "--staged is required");
    try expectUsage(&.{ "take", "--staged", "s", "--wat", "o" }, "unknown argument --wat");
}

test "a failure shows the end of a program's output, not all of it" {
    const a = std.heap.page_allocator;
    try std.testing.expectEqualStrings("one\ntwo", try verify.tail(a, "one\ntwo\n", 5));
    try std.testing.expectEqualStrings("(last 2 lines)\nfour\nfive", try verify.tail(a, "one\ntwo\nthree\nfour\nfive\n\n", 2));
    try std.testing.expectEqualStrings("", try verify.tail(a, "", 3));
}

test "the compile wrapper's options get the source root, a command without them does not" {
    const a = std.heap.page_allocator;
    const wrapper = [_][]const u8{ "mojo_compile", "--compiler=c", "--", "build", "--target-cpu", "x" };
    const got = try verify.withSourceRoot(a, &wrapper, "work/src");
    try std.testing.expectEqual(@as(usize, 7), got.len);
    try std.testing.expectEqualStrings("--source-root=work/src", got[2]);
    try std.testing.expectEqualStrings("--", got[3]);
    try std.testing.expectEqualStrings("build", got[4]);
    const plain = [_][]const u8{ "fake", "compile", "build" };
    const same = try verify.withSourceRoot(a, &plain, "work/src");
    try std.testing.expectEqual(@as(usize, 3), same.len);
}

// ---- offline.zig --------------------------------------------------------------

test "the offline registry serves its configuration and refuses and remembers everything else" {
    const a = std.heap.page_allocator;
    const reg = try offline.Registry.start(&.{});
    const base = try reg.url(a);
    try std.testing.expect(std.mem.startsWith(u8, base, "http://127.0.0.1:"));

    const config = try offline.get(a, base, "/index/config.json");
    try std.testing.expectEqual(@as(u16, 200), config.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, config.body, .{});
    const o = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), o.get("index_version").?.integer);
    try std.testing.expectEqual(@as(usize, 2), o.get("index_versions").?.array.items.len);
    // Every URL the configuration names is this server, so mopm's other requests come back here.
    const own = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{reg.port});
    try std.testing.expect(std.mem.startsWith(u8, o.get("api_url").?.string, own));
    try std.testing.expect(std.mem.startsWith(u8, o.get("api_v2_url").?.string, own));
    try std.testing.expect(std.mem.startsWith(u8, o.get("channel_url").?.string, own));

    for ([_][]const u8{ "/index/v2/ko/mi/komira-ai/ghost", "/channel/linux-64/repodata.json", "/index/config.json/", "/" }) |target| {
        const r = try offline.get(a, base, target);
        try std.testing.expectEqual(@as(u16, 403), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"offline\"") != null);
    }
    reg.stop();
    const refused = try reg.refused(a);
    try std.testing.expectEqual(@as(usize, 4), refused.len);
    try std.testing.expectEqualStrings("GET /index/v2/ko/mi/komira-ai/ghost", refused[0]);
    try std.testing.expectEqualStrings("GET /channel/linux-64/repodata.json", refused[1]);
    try std.testing.expectEqualStrings("GET /index/config.json/", refused[2]);
    try std.testing.expectEqualStrings("GET /", refused[3]);
}

/// `METHOD target` sent to a loopback registry, for the methods `offline.get` does not send; the status.
fn sendStatus(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8) !u16 {
    const stream = try std.net.tcpConnectToAddress(try std.net.Address.parseIp4("127.0.0.1", port));
    defer stream.close();
    try stream.writeAll(try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ method, target, port }));
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (n < 12) {
        const got = try stream.read(buf[n..]);
        if (got == 0) break;
        n += got;
    }
    if (n < 12) return error.BadAnswer;
    return std.fmt.parseInt(u16, buf[9..12], 10);
}

test "the index of each member the staged set uploads is answered 404 package_not_found, every time, and never remembered" {
    const a = std.heap.page_allocator;
    const staged = [_][]const u8{ "komira-ai/json", "ab/x1" };
    const reg = try offline.Registry.start(&staged);
    const base = try reg.url(a);
    // mopm 0.0.138 asks for a staged package's index while it resolves, and again to compare the
    // registry's record with the set: both asks get the same answer.
    for ([_][]const u8{ "/index/v2/ko/mi/komira-ai/json", "/index/v2/ab/__/ab/x1", "/index/v2/ko/mi/komira-ai/json" }) |target| {
        const r = try offline.get(a, base, target);
        try std.testing.expectEqual(@as(u16, 404), r.status);
        try std.testing.expectEqualStrings("{\"error\":{\"code\":\"package_not_found\",\"message\":\"the README e2e's registry holds no version of a package the staged set uploads: the set is where it comes from\",\"hint\":\"take it from the staged set\"}}", r.body);
    }
    _ = try offline.get(a, base, "/index/config.json");
    reg.stop();
    try std.testing.expectEqual(@as(usize, 0), (try reg.refused(a)).len);
}

test "beside staged members, every request but their index GETs and the configuration is still refused and remembered" {
    const a = std.heap.page_allocator;
    const staged = [_][]const u8{"komira-ai/json"};
    const reg = try offline.Registry.start(&staged);
    const base = try reg.url(a);
    // A package the set lacks (one whose name only starts like a member's, and one of another
    // namespace), the namespace's directory, the member's path with a trailing slash or a query,
    // and the member's channel and file: none is the index of a staged member.
    const gets = [_][]const u8{
        "/index/v2/ko/mi/komira-ai/jsonx",
        "/index/v2/ex/am/example/json",
        "/index/v2/ko/mi/komira-ai/",
        "/index/v2/ko/mi/komira-ai/json/",
        "/index/v2/ko/mi/komira-ai/json?v=2",
        "/channel/komira-ai/linux-64/repodata.json",
        "/channel/komira-ai/linux-64/mojo-komira-ai.json-0.1.1-mojo1.1.0_0.conda",
    };
    for (gets) |target| {
        const r = try offline.get(a, base, target);
        try std.testing.expectEqual(@as(u16, 403), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"offline\"") != null);
    }
    // The member's index asked with another method than GET.
    try std.testing.expectEqual(@as(u16, 403), try sendStatus(a, reg.port, "HEAD", "/index/v2/ko/mi/komira-ai/json"));
    try std.testing.expectEqual(@as(u16, 403), try sendStatus(a, reg.port, "POST", "/index/v2/ko/mi/komira-ai/json"));
    reg.stop();
    const refused = try reg.refused(a);
    try std.testing.expectEqual(@as(usize, gets.len + 2), refused.len);
    for (gets, refused[0..gets.len]) |target, line| {
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "GET {s}", .{target}), line);
    }
    try std.testing.expectEqualStrings("HEAD /index/v2/ko/mi/komira-ai/json", refused[gets.len]);
    try std.testing.expectEqualStrings("POST /index/v2/ko/mi/komira-ai/json", refused[gets.len + 1]);
}

test "the configuration request alone is not a refusal" {
    const a = std.heap.page_allocator;
    const reg = try offline.Registry.start(&.{});
    const base = try reg.url(a);
    _ = try offline.get(a, base, "/index/config.json");
    reg.stop();
    try std.testing.expectEqual(@as(usize, 0), (try reg.refused(a)).len);
}

test "a package's index is asked for at v2/<aa>/<bb>/<namespace>/<name>, from the namespace, short ones padded with underscores" {
    const a = std.heap.page_allocator;
    try std.testing.expectEqualStrings("/index/v2/ko/mi/komira-ai/json", try offline.indexTarget(a, "komira-ai/json"));
    try std.testing.expectEqualStrings("/index/v2/ab/__/ab/x1", try offline.indexTarget(a, "ab/x1"));
    try std.testing.expectEqualStrings("/index/v2/ex/am/example/ghost", try offline.indexTarget(a, "example/ghost"));
}

test "a registry that is not a loopback URL is not asked" {
    try std.testing.expectError(error.NotLoopback, offline.get(std.heap.page_allocator, "https://api.mopm.dev", "/index/config.json"));
}

// ---- native.zig ---------------------------------------------------------------

fn words(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    return native.shellWords(a, line);
}

test "shell words: bare, single-quoted, and a quote inside a word" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const got = try words(a, "MODULAR_HOME=/p/share/max /p/bin/mojo build 'a b' x'y z'w 'it'\\''s' ''\n");
    try std.testing.expectEqual(@as(usize, 7), got.len);
    try std.testing.expectEqualStrings("MODULAR_HOME=/p/share/max", got[0]);
    try std.testing.expectEqualStrings("a b", got[3]);
    try std.testing.expectEqualStrings("xy zw", got[4]);
    try std.testing.expectEqualStrings("it's", got[5]);
    try std.testing.expectEqualStrings("", got[6]);
}

test "shell words: an unterminated quote is refused" {
    var ar = arena();
    defer ar.deinit();
    try std.testing.expectError(error.Unterminated, words(ar.allocator(), "mojo 'build"));
}

test "link words: what stands between build and -o" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const got = native.linkWords(try words(a, "MODULAR_HOME=/p/share/max /p/bin/mojo build -Xlinker /p/lib/libx.a -Xlinker -rpath -Xlinker /p/lib -o out m.mojo")).?;
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("-Xlinker", got[0]);
    try std.testing.expectEqualStrings("/p/lib/libx.a", got[1]);
    try std.testing.expectEqualStrings("/p/lib", got[5]);
    // Not a build command, or no -o: nothing to take.
    try std.testing.expect(native.linkWords(try words(a, "/p/bin/mojo run m.mojo")) == null);
    try std.testing.expect(native.linkWords(try words(a, "/p/bin/mojo build m.mojo")) == null);
}

test "unlinked: a static archive by path, a shared library by -l, and the one left out" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const natives = [_]native.Native{
        .{ .package = "p", .soname = "libx.a", .kind = "static" },
        .{ .package = "p", .soname = "liby.so.1" },
        .{ .package = "q", .soname = "libz.a", .kind = "static" },
    };
    const left = try native.unlinked(a, &natives, &.{ "-Xlinker", "/e/lib/mojo/../libx.a", "-Ly", "-ly" });
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("q ships the native library libz.a (static) and mopm's link command does not link it", left[0]);
    // A longer name that merely ends the same way is not the library.
    const decoy = try native.unlinked(a, natives[0..1], &.{ "/e/lib/libxx.a", "/e/lib/otherlibx.a", "-lxx" });
    try std.testing.expectEqual(@as(usize, 1), decoy.len);
}

test "collect: the declarations of a lock entry and of metadata, once each" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const meta = try plan.parseMetadata(a, "{\"name\":\"p\",\"native\":[{\"id\":\"x\",\"soname\":\"libx.a\",\"kind\":\"static\",\"static_file\":\"../libx.a\"}]}", &why);
    var out: std.ArrayList(native.Native) = .empty;
    try native.collect(a, "p", meta.native, &out, &why);
    try native.collect(a, "p", meta.native, &out, &why);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("static", out.items[0].kind);
    const bad = try plan.parseMetadata(a, "{\"name\":\"p\",\"native\":[{\"id\":\"x\"}]}", &why);
    try std.testing.expectError(error.Invalid, native.collect(a, "p", bad.native, &out, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "names no soname") != null);
}

test "a package with a static native holds its archive at lib/<soname>, declared by the metadata" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try fix.packageWith(a, "example/nat", "1.0.0", "mojo1.0.0_0", "mojoc", &.{}, &.{.{ .soname = "libnat_c.a", .bytes = "archive" }});
    var why: []const u8 = "";
    const files = try conda.read(a, bytes, &why);
    try std.testing.expectEqualStrings("archive", conda.find(files, "lib/libnat_c.a").?);
    const meta = try plan.parseMetadata(a, conda.find(files, "lib/mojo/nat.mopm.json").?, &why);
    try std.testing.expectEqual(@as(usize, 1), meta.native.len);
    // declared and not shipped: the metadata names it, the package lacks the file
    const bare = try fix.packageWith(a, "example/nat", "1.0.0", "mojo1.0.0_0", "mojoc", &.{}, &.{.{ .soname = "libnat_c.a", .bytes = "archive", .ship = false }});
    const bare_files = try conda.read(a, bare, &why);
    try std.testing.expect(conda.find(bare_files, "lib/libnat_c.a") == null);
    try std.testing.expect(conda.find(bare_files, "lib/mojo/nat.mopm.json") != null);
}

test "for the toolchain's linker: the push-state and pop-state pairs go, every other argument stays in order" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const got = try native.forZigLinker(a, &.{ "-Xlinker", "--push-state", "-Xlinker", "--no-as-needed", "-Xlinker", "/p/lib/libx.a", "-Xlinker", "--pop-state", "-Xlinker", "-rpath", "-Xlinker", "/p/lib" });
    const want = [_][]const u8{ "-Xlinker", "--no-as-needed", "-Xlinker", "/p/lib/libx.a", "-Xlinker", "-rpath", "-Xlinker", "/p/lib" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    // an archive that happens to be named like the option is not dropped
    const kept = try native.forZigLinker(a, &.{ "/p/lib/--pop-state", "-Xlinker" });
    try std.testing.expectEqual(@as(usize, 2), kept.len);
}

// ---- take.zig -----------------------------------------------------------------

/// `readme_e2e take --staged <tmp>/staged --out <tmp>/out`, run in `tmp`.
fn runTake(a: std.mem.Allocator, tmp: std.fs.Dir) !struct { code: u8, out: []const u8, staged: []const u8, dest: []const u8 } {
    const root = try tmp.realpathAlloc(a, ".");
    const staged = try std.fs.path.join(a, &.{ root, "staged" });
    const dest = try std.fs.path.join(a, &.{ root, "out" });
    var out: std.ArrayList(u8) = .empty;
    const code = try cli.execute(a, &.{ "take", "--staged", staged, "--out", dest }, &out);
    return .{ .code = code, .out = out.items, .staged = staged, .dest = dest };
}

/// Every entry below `dir`, `<path> <kind> <bytes of a file>`, sorted.
fn listing(a: std.mem.Allocator, dir: std.fs.Dir) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var w = try dir.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        const bytes = if (e.kind == .file) try dir.readFileAlloc(a, e.path, 1 << 20) else "";
        try lines.append(a, try std.fmt.allocPrint(a, "{s} {s} {s}", .{ e.path, @tagName(e.kind), bytes }));
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lt);
    return std.mem.join(a, "\n", lines.items);
}

test "take copies every file of the set to the same path with the same bytes, and nothing else" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("staged/linux-64");
    try tmp.dir.makePath("staged/acme/http/empty");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = "{\"version\": 2}" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/mojo-acme.http-0.1.7-mojo1.0.0_0.conda", .data = "PK\x00\x01\xff" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/acme/http/README.md", .data = "# http\n" });
    const r = try runTake(a, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "readme_e2e take: 3 file(s), 26 bytes, from {s}\n", .{r.staged}), r.out);
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    try std.testing.expectEqualStrings(
        "acme directory \nacme/http directory \nacme/http/README.md file # http\n\nacme/http/empty directory \nlinux-64 directory \nlinux-64/mojo-acme.http-0.1.7-mojo1.0.0_0.conda file PK\x00\x01\xff\nplan.json file {\"version\": 2}",
        try listing(a, out),
    );
}

test "take of an empty set writes an empty directory, so verify fails it at phase staged as before" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("staged");
    const r = try runTake(a, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "readme_e2e take: 0 file(s), 0 bytes, from {s}\n", .{r.staged}), r.out);
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    try std.testing.expectEqualStrings("", try listing(a, out));
}

test "take follows a symbolic link to a file or a directory and writes what it points at" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("real/dir");
    try tmp.dir.writeFile(.{ .sub_path = "real/file", .data = "linked" });
    try tmp.dir.writeFile(.{ .sub_path = "real/dir/inner", .data = "inside" });
    try tmp.dir.makePath("staged");
    try tmp.dir.symLink("../real/file", "staged/plan.json", .{});
    try tmp.dir.symLink("../real/dir", "staged/linux-64", .{ .is_directory = true });
    const r = try runTake(a, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "readme_e2e take: 2 file(s), 12 bytes, from {s}\n", .{r.staged}), r.out);
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    // Regular files and a directory, not links: the copy holds no path outside it.
    try std.testing.expectEqualStrings("linux-64 directory \nlinux-64/inner file inside\nplan.json file linked", try listing(a, out));
}

fn expectTakeRefused(a: std.mem.Allocator, tmp: std.fs.Dir, want: []const u8) !void {
    const r = try runTake(a, tmp);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings(want, r.out);
}

test "take refuses a link to nothing, naming its path below the set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("staged/linux-64");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = "{}" });
    try tmp.dir.symLink("../../gone", "staged/linux-64/x.conda", .{});
    try expectTakeRefused(a, tmp.dir, "readme_e2e take: linux-64/x.conda: FileNotFound\n");
}

test "take refuses a link back to a directory above it once directories nest deeper than max_depth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("staged");
    try tmp.dir.symLink(".", "staged/loop", .{ .is_directory = true });
    var path: std.ArrayList(u8) = .empty;
    for (0..take.max_depth + 1) |i| {
        if (i > 0) try path.append(a, '/');
        try path.appendSlice(a, "loop");
    }
    try expectTakeRefused(a, tmp.dir, try std.fmt.allocPrint(a, "readme_e2e take: {s}: directories nested deeper than 16 (a link back to a directory above it?)\n", .{path.items}));
}

test "take copies directories nested exactly max_depth deep" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, "staged");
    for (0..take.max_depth) |_| try path.appendSlice(a, "/d");
    try tmp.dir.makePath(path.items);
    try path.appendSlice(a, "/f");
    try tmp.dir.writeFile(.{ .sub_path = path.items, .data = "deep" });
    const r = try runTake(a, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "readme_e2e take: 1 file(s), 4 bytes, from {s}\n", .{r.staged}), r.out);
    const got = try tmp.dir.readFileAlloc(a, try std.fmt.allocPrint(a, "out{s}", .{path.items["staged".len..]}), 100);
    try std.testing.expectEqualStrings("deep", got);
}

test "take refuses an entry that is neither a file nor a directory, naming its kind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try tmp.dir.makePath("staged");
    // A Unix socket bound in the set's directory: a file system entry, no network.
    const root = try tmp.dir.realpathAlloc(a, "staged");
    const addr = try std.net.Address.initUnix(try std.fs.path.join(a, &.{ root, "sock" }));
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    try expectTakeRefused(a, tmp.dir, "readme_e2e take: sock is a unix_domain_socket, not a file or a directory\n");
}

test "take refuses a staged set that is not there, and an output it cannot write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try expectTakeRefused(a, tmp.dir, try std.fmt.allocPrint(a, "readme_e2e take: cannot open the staged set {s}/staged: FileNotFound\n", .{root}));
    try tmp.dir.makePath("staged");
    try tmp.dir.writeFile(.{ .sub_path = "out", .data = "a file where the output goes" });
    try expectTakeRefused(a, tmp.dir, try std.fmt.allocPrint(a, "readme_e2e take: cannot write {s}/out: NotDir\n", .{root}));
}

test "a locked file is installed on the host of its own subdir or noarch only, and each host has the subdir mopm names" {
    try std.testing.expect(verify.installsOn("linux-64", "linux-64"));
    try std.testing.expect(verify.installsOn("noarch", "linux-64"));
    try std.testing.expect(!verify.installsOn("osx-arm64", "linux-64"));
    try std.testing.expect(!verify.installsOn("linux-aarch64", "linux-64"));
    try std.testing.expect(verify.installsOn("osx-arm64", "osx-arm64"));
    try std.testing.expect(!verify.installsOn("linux-64", "osx-arm64"));
    try std.testing.expectEqualStrings("linux-64", verify.hostSubdir(.linux, .x86_64).?);
    try std.testing.expectEqualStrings("linux-aarch64", verify.hostSubdir(.linux, .aarch64).?);
    try std.testing.expectEqualStrings("osx-arm64", verify.hostSubdir(.macos, .aarch64).?);
    try std.testing.expect(verify.hostSubdir(.macos, .x86_64) == null);
    try std.testing.expect(verify.hostSubdir(.windows, .x86_64) == null);
}
