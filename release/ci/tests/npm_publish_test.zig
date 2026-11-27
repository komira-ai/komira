//! The cases of the publish (release/ci/npm_smoke/publish.zig), part of //release/ci/tests:test_npm_smoke, with
//! an npm in memory (npm_testing.zig): the exact commands and their order, a version the registry holds
//! already, one it holds with other bytes, and each failure, with what was and was not published.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const h = @import("npm_testing.zig");
const t = std.testing;

const NODE = "/tools/node/bin/node";
const NPM = "/tools/npm";

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    set: lib.set.Set = undefined,
    dir: []const u8 = "",
    work: []const u8 = "",

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn setUp(c: *Case) !void {
    c.set = try h.writeSet(c.a(), &c.tmp, "set", "0.1.7");
    c.dir = try h.path(c.a(), &c.tmp, "set");
    c.work = try std.fs.path.join(c.a(), &.{ try h.path(c.a(), &c.tmp, "."), "work" });
}

fn tools(c: *Case) lib.npm.Tools {
    return .{ .node = NODE, .npm = NPM, .work = c.work };
}

const VIEW_LINUX = NODE ++ " " ++ NPM ++ "/bin/npm-cli.js view @komira-ai/komira-linux-x64-gnu@0.1.7 dist.integrity --json " ++ h.NPM_FLAGS;
const VIEW_MAIN = NODE ++ " " ++ NPM ++ "/bin/npm-cli.js view @komira-ai/komira@0.1.7 dist.integrity --json " ++ h.NPM_FLAGS;

fn publishCall(a: std.mem.Allocator, dir: []const u8, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, NODE ++ " " ++ NPM ++ "/bin/npm-cli.js publish {s}/{s} --access public " ++ h.NPM_FLAGS, .{ dir, file });
}

test "every platform package is published before the main package, each after the registry was asked for its version" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work };
    var log = std.Io.Writer.Allocating.init(c.a());
    var why: []const u8 = "";
    try lib.publish.run(c.a(), &why, fake.runner(), tools(&c), c.set, c.dir, &log.writer);
    try h.expectCalls(&.{
        VIEW_LINUX,
        try publishCall(c.a(), c.dir, "komira-ai-komira-linux-x64-gnu-0.1.7.tgz"),
        VIEW_MAIN,
        try publishCall(c.a(), c.dir, "komira-ai-komira-0.1.7.tgz"),
    }, fake.calls.items);
    for (fake.cwds.items) |cwd| try t.expectEqualStrings("W", cwd);
    // the config files every command names exist, and are empty
    try t.expectEqualStrings("", try h.readAll(c.a(), &c.tmp, "work/npmrc"));
    try t.expectEqualStrings("", try h.readAll(c.a(), &c.tmp, "work/npmrc-global"));
    try t.expectEqualStrings(
        "npm_smoke: published @komira-ai/komira-linux-x64-gnu@0.1.7 (komira-ai-komira-linux-x64-gnu-0.1.7.tgz, " ++ "sha512-LtT0FlofyOyx8ZU419cz0vQPyNS8ZUWlzzER6xuVTTdez86rozluCOo0/BLSn5V7ICBhDTcloiurJqftGbCDMg==" ++ ")\n" ++
            "npm_smoke: published @komira-ai/komira@0.1.7 (komira-ai-komira-0.1.7.tgz, " ++ "sha512-diE/OX+DUO12yAHC8R03P9djzFzztm5Y92fG02tCjCA5v8RWpN7l3clwyS1G+pVXnBur05tx+c6AInN/wVbEPA==" ++ ")\n",
        log.written(),
    );
}

test "a package the registry does not have yet (E404) is published, and one it holds with the set's integrity is not published again" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    const linux_sri = c.set.find(h.LINUX).?.integrity;
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{
        // a re-run: the earlier attempt published the platform package
        .{ .contains = "view @komira-ai/komira-linux-x64-gnu@", .code = 0, .stdout = try std.fmt.allocPrint(c.a(), "\"{s}\"\n", .{linux_sri}) },
        // the main package was never published: the registry has no such package
        .{ .contains = "view @komira-ai/komira@", .code = 1, .stderr = "npm error code E404\nnpm error 404 Not Found - GET https://registry.npmjs.org/@komira-ai%2fkomira - Not found\n" },
    } };
    // the same E404 named only in the JSON error --json prints on stdout is absent too
    var json_404 = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{
        .{ .contains = " view ", .code = 1, .stdout = "{\n  \"error\": {\n    \"code\": \"E404\",\n    \"summary\": \"Not Found\"\n  }\n}\n" },
    } };
    var why404: []const u8 = "";
    try t.expectEqual(lib.publish.State.absent, try lib.publish.state(c.a(), &why404, json_404.runner(), tools(&c), c.set.find(h.MAIN).?));
    var log = std.Io.Writer.Allocating.init(c.a());
    var why: []const u8 = "";
    try lib.publish.run(c.a(), &why, fake.runner(), tools(&c), c.set, c.dir, &log.writer);
    try h.expectCalls(&.{ VIEW_LINUX, VIEW_MAIN, try publishCall(c.a(), c.dir, "komira-ai-komira-0.1.7.tgz") }, fake.calls.items);
    try t.expect(std.mem.startsWith(u8, log.written(), "npm_smoke: @komira-ai/komira-linux-x64-gnu@0.1.7 is on the registry with the set's integrity: not published again\n"));
}

test "a version the registry holds with other bytes stops the publish before anything is published" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{
        .{ .contains = "view @komira-ai/komira-linux-x64-gnu@", .code = 0, .stdout = "\"sha512-other\"\n" },
    } };
    var log = std.Io.Writer.Allocating.init(c.a());
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.publish.run(c.a(), &why, fake.runner(), tools(&c), c.set, c.dir, &log.writer));
    try t.expectEqualStrings("@komira-ai/komira-linux-x64-gnu@0.1.7 is on the registry with the integrity \"sha512-other\", not the set's " ++
        "sha512-LtT0FlofyOyx8ZU419cz0vQPyNS8ZUWlzzER6xuVTTdez86rozluCOo0/BLSn5V7ICBhDTcloiurJqftGbCDMg==" ++
        ": npm takes a version once, so nothing is published over it", why);
    try h.expectCalls(&.{VIEW_LINUX}, fake.calls.items);
    try t.expectEqualStrings("", log.written());
}

test "a registry that cannot be asked, other than E404, stops the publish, naming the command and its stderr" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{
        .{ .contains = " view ", .code = 1, .stderr = "npm error code ECONNRESET\nnpm error network aborted\n" },
    } };
    var log = std.Io.Writer.Allocating.init(c.a());
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.publish.run(c.a(), &why, fake.runner(), tools(&c), c.set, c.dir, &log.writer));
    const want = try std.fmt.allocPrint(c.a(), "asking the registry for @komira-ai/komira-linux-x64-gnu@0.1.7 failed: {s} ended with exit status 1:\nnpm error code ECONNRESET\nnpm error network aborted", .{try std.mem.replaceOwned(u8, c.a(), VIEW_LINUX, "W", c.work)});
    try t.expectEqualStrings(want, why);
    try h.expectCalls(&.{VIEW_LINUX}, fake.calls.items);
}

test "a failed publish of a platform package leaves the main package unpublished" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var fake = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{
        .{ .contains = " publish ", .code = 1, .stderr = "npm error code E403\nnpm error 403 Forbidden - PUT https://registry.npmjs.org/@komira-ai%2fkomira-linux-x64-gnu - no trusted publisher\n" },
    } };
    var log = std.Io.Writer.Allocating.init(c.a());
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.publish.run(c.a(), &why, fake.runner(), tools(&c), c.set, c.dir, &log.writer));
    const publish_linux = try publishCall(c.a(), c.dir, "komira-ai-komira-linux-x64-gnu-0.1.7.tgz");
    try t.expect(std.mem.startsWith(u8, why, "publishing @komira-ai/komira-linux-x64-gnu@0.1.7 failed: "));
    try t.expect(std.mem.endsWith(u8, why, " ended with exit status 1:\nnpm error code E403\nnpm error 403 Forbidden - PUT https://registry.npmjs.org/@komira-ai%2fkomira-linux-x64-gnu - no trusted publisher"));
    // nothing after the failed publish ran: the main package is never asked for or published
    try h.expectCalls(&.{ VIEW_LINUX, publish_linux }, fake.calls.items);
}

test "an npm that cannot be started, or that ends on a signal, is named" {
    var c = Case{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{}) };
    defer c.arena.deinit();
    defer c.tmp.cleanup();
    try setUp(&c);
    var why: []const u8 = "";
    var log = std.Io.Writer.Allocating.init(c.a());
    var gone = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{.{ .contains = " view ", .spawn = error.FileNotFound }} };
    try t.expectError(error.Refused, lib.publish.run(c.a(), &why, gone.runner(), tools(&c), c.set, c.dir, &log.writer));
    try t.expect(std.mem.startsWith(u8, why, "asking the registry for @komira-ai/komira-linux-x64-gnu@0.1.7: cannot run " ++ NODE ++ " "));
    try t.expect(std.mem.endsWith(u8, why, ": FileNotFound"));
    var killed = h.FakeNpm{ .alloc = c.a(), .work = c.work, .rules = &.{.{ .contains = " publish ", .code = null }} };
    try t.expectError(error.Refused, lib.publish.run(c.a(), &why, killed.runner(), tools(&c), c.set, c.dir, &log.writer));
    try t.expect(std.mem.indexOf(u8, why, " ended with no exit status (a signal):\n(nothing on stderr)") != null);
}
