//! Unit tests of readme_e2e: the package reader, the plan and lock readers
//! and writers, the command line. (The commands themselves, over real
//! files and processes, are the scenarios: scenario.zig.)

const std = @import("std");
const conda = @import("conda.zig");
const plan = @import("plan.zig");
const cli = @import("cli.zig");
const verify = @import("verify.zig");
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

test "a package is read: its files, with their bytes, in archive order" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try fix.package(a, "good", "1.2.3", "mojo1.0.0_0", "the mojoc", &.{});
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

test "a path outside lib/mojo/<file> and lib/<file> is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "bin/tool", "etc/passwd", "lib/mojo/../../x", "lib/a/b/c", "lib/.hidden", "lib/", "/lib/x", "lib/x\\y", "libx/y", "lib/other/x.mojoc" };
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
    const whole = try fix.package(a, "good", "1.2.3", "mojo1.0.0_0", "m", &.{});
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
    const files = try conda.read(a, try fix.package(a, "good", "1.2.3", "mojo1.0.0_0", "bytes", &.{}), &why);
    try conda.extract(tmp.dir, files);
    const got = try tmp.dir.readFileAlloc(a, "lib/mojo/good.mojoc", 100);
    try std.testing.expectEqualStrings("bytes", got);
    try std.testing.expectError(error.PathAlreadyExists, conda.extract(tmp.dir, files));
}

// ---- plan.zig -----------------------------------------------------------------

const plan_text =
    \\{ "version": 1, "members": [
    \\  { "name": "http_core", "version": "0.4.0", "action": "upload",
    \\    "manifest_sha256": "aa", "future_key": 7,
    \\    "files": [ { "subdir": "noarch", "filename": "mojo-http_core-0.4.0-mojo1.0.0_0.conda", "sha256": "bb", "size": 12345 } ],
    \\    "readme": "http_core/README.md" },
    \\  { "name": "http_client", "version": "0.4.0", "action": "skip", "reason": "already published with these bytes" } ] }
;

test "a plan is read, its unknown keys ignored, and written the same way twice" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const p = try plan.parsePlan(a, plan_text, &why);
    try std.testing.expectEqual(@as(usize, 2), p.members.len);
    try std.testing.expectEqualStrings("http_core/README.md", p.member("http_core").?.readme.?);
    try std.testing.expectEqual(@as(u64, 12345), p.members[0].files[0].size);
    try std.testing.expect(p.member("nobody") == null);
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
        .{ .text = "{\"version\": 2, \"members\": []}", .why = "version 2" },
        .{ .text = "{\"version\": 1, \"members\": [{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\"},{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .why = "a is a member twice" },
        .{ .text = "{\"version\": 1, \"members\": [{\"name\":\"a\",\"version\":\"1.0.0\",\"action\":\"publish\"}]}", .why = "action publish" },
        .{ .text = "{\"version\": 1, \"members\": [{\"name\":\"\",\"version\":\"1.0.0\",\"action\":\"upload\"}]}", .why = "no name or version" },
        .{ .text = "not json", .why = "plan.json" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        try std.testing.expectError(error.Invalid, plan.parsePlan(a, c.text, &why));
        try std.testing.expect(std.mem.indexOf(u8, why, c.why) != null);
    }
}

const lock_text =
    \\{ "lock_version": 1, "toolchain": { "mojo": "1.0.0" }, "channels": ["https://conda.mopm.dev/"],
    \\  "packages": [
    \\    { "name": "app", "version": "1.0.0", "build": "mojo1.0.0_0", "subdir": "linux-64", "channel": "https://conda.mopm.dev/",
    \\      "url": "https://conda.mopm.dev/linux-64/mojo-app-1.0.0-mojo1.0.0_0.conda", "sha256": "cc", "size": 9, "mojo": "1.0.0", "deps": ["lib"] },
    \\    { "name": "local", "version": "0.0.1", "source": "path" } ] }
;

test "a version 1 lock is read, a path package has no file" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const l = try plan.parseLock(a, lock_text, &why);
    try std.testing.expectEqual(@as(usize, 2), l.packages.len);
    const app = l.find("app").?;
    try std.testing.expectEqualStrings("mojo-app-1.0.0-mojo1.0.0_0.conda", app.filename());
    try std.testing.expect(!app.isPath());
    try std.testing.expect(l.find("local").?.isPath());
    try std.testing.expectEqualStrings("lib", app.deps[0]);
}

test "a lock of version 2, or whose url is not the package's file, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try std.testing.expectError(error.Invalid, plan.parseLock(a, "{\"lock_version\": 2, \"packages\": []}", &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "lock_version 2") != null);
    const wrong = try std.mem.replaceOwned(u8, a, lock_text, "mojo-app-1.0.0-mojo1.0.0_0.conda", "mojo-app-9.9.9-mojo1.0.0_0.conda");
    try std.testing.expectError(error.Invalid, plan.parseLock(a, wrong, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "does not end in mojo-app-1.0.0-mojo1.0.0_0.conda") != null);
}

test "a lock is written in the order given, and read back" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const text = try plan.renderLock(a, "1.0.0", &.{.{ .name = "app", .version = "1.0.0", .build = "mojo1.0.0_0", .subdir = "linux-64", .url = "https://conda.mopm.dev/linux-64/mojo-app-1.0.0-mojo1.0.0_0.conda", .sha256 = "dd", .size = 5, .mojo = "1.0.0" }});
    const l = try plan.parseLock(a, text, &why);
    try std.testing.expectEqualStrings("dd", l.packages[0].sha256);
    try std.testing.expectEqual(@as(u64, 5), l.packages[0].size);
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
