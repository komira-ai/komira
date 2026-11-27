//! The cases of the smoke (release/ci/npm_smoke/smoke.zig), part of //release/ci/tests:test_npm_smoke, with an
//! npm and a node in memory (npm_testing.zig) that write the lock npm would: the project it makes, the exact
//! commands, the install tried again while the registry lags, every check of the lock, and the query's answer.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const h = @import("npm_testing.zig");
const t = std.testing;

const NODE = "/tools/node/bin/node";
const NPM = "/tools/npm";
const INSTALL = NODE ++ " " ++ NPM ++ "/bin/npm-cli.js install --ignore-scripts --engine-strict " ++ h.NPM_FLAGS;
const QUERY = NODE ++ " smoke.mjs";

const MANIFEST =
    \\{
    \\  "name": "komira-npm-smoke",
    \\  "private": true,
    \\  "dependencies": {
    \\    "@komira-ai/komira": "0.1.7"
    \\  }
    \\}
    \\
;

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    set: lib.set.Set = undefined,
    work: []const u8 = "",
    pause: h.CountingPause = .{},

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn opts(self: *Case, attempts: u32) lib.smoke.Options {
        return .{ .tools = .{ .node = NODE, .npm = NPM, .work = self.work }, .attempts = attempts, .delay_ms = 30_000, .pause = self.pause.pause() };
    }
};

fn setUp(c: *Case) !void {
    c.set = try h.writeSet(c.a(), &c.tmp, "set", "0.1.7");
    c.work = try std.fs.path.join(c.a(), &.{ try h.path(c.a(), &c.tmp, "."), "work" });
}

/// Runs the smoke with `fake`; the refusal, or null when it held.
fn smokeWith(c: *Case, fake: *h.FakeNpm, attempts: u32, log: *std.Io.Writer.Allocating) !?[]const u8 {
    var why: []const u8 = "";
    lib.smoke.run(c.a(), &why, fake.runner(), c.opts(attempts), c.set, &log.writer) catch |e| switch (e) {
        error.Refused => return why,
        else => return e,
    };
    return null;
}

fn expectLockRefused(c: *Case, lock: []const u8, want: []const u8) !void {
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.smoke.checkLock(c.a(), &why, c.set, lock));
    try t.expectEqualStrings(want, why);
}

test "the smoke installs the set's version into an empty project from the registry, holds the lock to the set and runs SELECT 1" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .lock = try h.goodLock(c.a(), c.set) };
    var log = std.Io.Writer.Allocating.init(c.a());
    try t.expect((try smokeWith(&c, &fake, 5, &log)) == null);
    // the install and then the query, with nothing between them, both in the project
    try h.expectCalls(&.{ INSTALL, QUERY }, fake.calls.items);
    try h.expectCalls(&.{ "W/project", "W/project" }, fake.cwds.items);
    try t.expectEqualStrings(MANIFEST, try h.readAll(c.a(), &c.tmp, "work/project/package.json"));
    try t.expectEqualStrings(lib.smoke.program, try h.readAll(c.a(), &c.tmp, "work/project/smoke.mjs"));
    try t.expectEqualStrings("", try h.readAll(c.a(), &c.tmp, "work/npmrc"));
    try t.expectEqual(@as(usize, 0), c.pause.times);
    try t.expectEqualStrings("npm_smoke: @komira-ai/komira@0.1.7 from the registry: the lock holds the set's integrity, and SELECT 1 answered 1\n", log.written());
}

test "the program imports the package by its name and prints its version, the column names and the value" {
    try t.expect(std.mem.startsWith(u8, lib.smoke.program, "import { Session, version } from \"@komira-ai/komira\";\n"));
    try t.expect(std.mem.indexOf(u8, lib.smoke.program, "session.sql(\"SELECT 1 AS n\")") != null);
    try t.expect(std.mem.indexOf(u8, lib.smoke.program, "console.log(`${version} ${names} ${table.getChild(\"n\")?.get(0)}`);") != null);
    try t.expect(std.mem.indexOf(u8, lib.smoke.program, "await session[Symbol.asyncDispose]();") != null);
}

test "an install that fails while the registry catches up is tried again, the pause between attempts, and refused after the last" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    const lag = h.Rule{ .contains = " install ", .code = 1, .stderr = "npm error code ETARGET\nnpm error notarget No matching version found for @komira-ai/komira@0.1.7.\n", .times = 2 };
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .lock = try h.goodLock(c.a(), c.set), .rules = &.{lag} };
    var log = std.Io.Writer.Allocating.init(c.a());
    try t.expect((try smokeWith(&c, &fake, 5, &log)) == null);
    try h.expectCalls(&.{ INSTALL, INSTALL, INSTALL, QUERY }, fake.calls.items);
    try t.expectEqual(@as(usize, 2), c.pause.times);
    try t.expectEqual(@as(u64, 60_000), c.pause.ms);
    try t.expect(std.mem.startsWith(u8, log.written(), "npm_smoke: installing @komira-ai/komira@0.1.7 from the registry: attempt 1 of 5 failed, trying again in 30 s\n" ++
        "npm_smoke: installing @komira-ai/komira@0.1.7 from the registry: attempt 2 of 5 failed, trying again in 30 s\n"));

    // a registry that never serves the version: refused after the last attempt, with no pause after it and no query
    var c2 = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c2.arena.deinit();
    defer c2.tmp.cleanup();
    try setUp(&c2);
    var never = h.FakeNpm{ .alloc = c2.a(), .work = c2.work, .rules = &.{.{ .contains = " install ", .code = 1, .stderr = lag.stderr }} };
    var log2 = std.Io.Writer.Allocating.init(c2.a());
    const why = (try smokeWith(&c2, &never, 3, &log2)).?;
    try t.expect(std.mem.startsWith(u8, why, "installing @komira-ai/komira@0.1.7 from the registry (attempt 3 of 3) failed: "));
    try t.expect(std.mem.endsWith(u8, why, " ended with exit status 1:\nnpm error code ETARGET\nnpm error notarget No matching version found for @komira-ai/komira@0.1.7."));
    try h.expectCalls(&.{ INSTALL, INSTALL, INSTALL }, never.calls.items);
    try t.expectEqual(@as(usize, 2), c2.pause.times);
}

test "a work directory that is not empty is refused before any command" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    try c.tmp.dir.makePath("work");
    try c.tmp.dir.writeFile(.{ .sub_path = "work/left.txt", .data = "x" });
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work };
    var log = std.Io.Writer.Allocating.init(c.a());
    const why = (try smokeWith(&c, &fake, 5, &log)).?;
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "--work {s} is not empty", .{c.work}), why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "a query that fails or prints anything but the set's version, n and 1 is refused, both texts shown" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var older = h.FakeNpm{ .alloc = c.a(), .work = c.work, .lock = try h.goodLock(c.a(), c.set), .query_output = "0.1.6 n 1\n" };
    var log = std.Io.Writer.Allocating.init(c.a());
    try t.expectEqualStrings("the query printed \"0.1.6 n 1\n\", not \"0.1.7 n 1\n\"", (try smokeWith(&c, &older, 5, &log)).?);

    var c2 = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c2.arena.deinit();
    defer c2.tmp.cleanup();
    try setUp(&c2);
    var throws = h.FakeNpm{ .alloc = c2.a(), .work = c2.work, .lock = try h.goodLock(c2.a(), c2.set), .rules = &.{
        .{ .contains = " smoke.mjs", .code = 1, .stderr = "LibraryLoadError: libkomira.so: cannot open shared object file\n" },
    } };
    try t.expectEqualStrings("the query failed: " ++ QUERY ++ " ended with exit status 1:\nLibraryLoadError: libkomira.so: cannot open shared object file", (try smokeWith(&c2, &throws, 5, &log)).?);
}

test "a lock that npm did not write as the set says is refused: no main, no platform, other bytes, another version, another scope package, a nested copy, an install script" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    const a = c.a();
    const main_sri = c.set.find(h.MAIN).?.integrity;
    const linux_sri = c.set.find(h.LINUX).?.integrity;
    var why: []const u8 = "";
    // the lock of a user's install holds: the main package, this host's platform package, apache-arrow
    try lib.smoke.checkLock(a, &why, c.set, try h.goodLock(a, c.set));
    try expectLockRefused(&c, try h.lockJson(a, &.{.{ .path = "node_modules/" ++ h.LINUX, .integrity = linux_sri }}), "package-lock.json does not hold @komira-ai/komira");
    try expectLockRefused(&c, try h.lockJson(a, &.{.{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri }}), "npm installed no platform package of the set for this host (1 in the set)");
    try expectLockRefused(&c, try h.lockJson(a, &.{
        .{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri },
        .{ .path = "node_modules/" ++ h.LINUX, .integrity = main_sri },
    }), "npm installed @komira-ai/komira-linux-x64-gnu with the integrity " ++
        "sha512-diE/OX+DUO12yAHC8R03P9djzFzztm5Y92fG02tCjCA5v8RWpN7l3clwyS1G+pVXnBur05tx+c6AInN/wVbEPA==" ++
        ", not the set's " ++ "sha512-LtT0FlofyOyx8ZU419cz0vQPyNS8ZUWlzzER6xuVTTdez86rozluCOo0/BLSn5V7ICBhDTcloiurJqftGbCDMg==" ++
        ": the registry serves other bytes than were built");
    try expectLockRefused(&c, try h.lockJson(a, &.{
        .{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri, .version = "0.1.6" },
        .{ .path = "node_modules/" ++ h.LINUX, .integrity = linux_sri },
    }), "npm installed @komira-ai/komira at 0.1.6, not the set's 0.1.7");
    try expectLockRefused(&c, try h.lockJson(a, &.{
        .{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri },
        .{ .path = "node_modules/" ++ h.LINUX, .integrity = linux_sri },
        .{ .path = "node_modules/@komira-ai/komira-extra", .integrity = linux_sri },
    }), "npm installed @komira-ai/komira-extra (node_modules/@komira-ai/komira-extra), which is no package of the set");
    try expectLockRefused(&c, try h.lockJson(a, &.{
        .{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri },
        .{ .path = "node_modules/" ++ h.MAIN ++ "/node_modules/" ++ h.LINUX, .integrity = linux_sri },
    }), "npm installed @komira-ai/komira-linux-x64-gnu at node_modules/@komira-ai/komira/node_modules/@komira-ai/komira-linux-x64-gnu, not at the top of node_modules");
    try expectLockRefused(&c, try h.lockJson(a, &.{
        .{ .path = "node_modules/" ++ h.MAIN, .integrity = main_sri },
        .{ .path = "node_modules/" ++ h.LINUX, .integrity = linux_sri, .install_script = true },
    }), "package-lock.json: node_modules/@komira-ai/komira-linux-x64-gnu has an install script: the packages need none");
    // not a lock at all
    try expectLockRefused(&c, "[]", "package-lock.json is not an object");
    try expectLockRefused(&c, "{}", "package-lock.json has no packages");
    try expectLockRefused(&c, "{\"packages\": []}", "the packages of package-lock.json are not an object");
    try expectLockRefused(&c, "{\"packages\": {\"node_modules/x\": 1}}", "package-lock.json: node_modules/x is not an object");
    try expectLockRefused(&c, "{", "package-lock.json is not JSON (UnexpectedEndOfInput)");
}

test "an install that wrote no lock is refused, naming the file" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work };
    var log = std.Io.Writer.Allocating.init(c.a());
    const why = (try smokeWith(&c, &fake, 5, &log)).?;
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a(), "cannot read the lock file {s}/project/package-lock.json: FileNotFound", .{c.work}), why);
    try h.expectCalls(&.{INSTALL}, fake.calls.items);
}
