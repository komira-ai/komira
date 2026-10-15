//! package-lock.json v3 as kpin reads it.

const std = @import("std");
const fx = @import("fixtures.zig");
const npm = @import("npm.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

test "packages: names from the path or `name`, scoped names, once each, sorted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const json = try fx.packageLock(a, &.{
        .{ .path = "node_modules/zeta", .version = "1.0.0", .resolved = "https://registry.npmjs.org/zeta/-/zeta-1.0.0.tgz", .integrity = fx.ABC_SRI512 },
        .{ .path = "node_modules/@scope/pkg", .version = "2.0.1", .resolved = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .integrity = fx.ABC_SRI512 },
        .{ .path = "node_modules/a/node_modules/zeta", .version = "1.0.0", .resolved = "https://registry.npmjs.org/zeta/-/zeta-1.0.0.tgz", .integrity = fx.ABC_SRI512 },
        .{ .path = "node_modules/alias", .name = "real", .version = "3.0.0", .resolved = "https://registry.npmjs.org/real/-/real-3.0.0.tgz", .integrity = fx.ABC_SRI512 },
    });
    var d = Diag.init(a);
    const pkgs = try npm.read(a, "package-lock.json", json, &d);
    try t.expectEqual(@as(usize, 3), pkgs.len);
    try t.expectEqualStrings("@scope/pkg@2.0.1", pkgs[0].key);
    try t.expectEqualStrings("real@3.0.0", pkgs[1].key);
    try t.expectEqualStrings("zeta@1.0.0", pkgs[2].key);
}

test "the order of the JSON does not change the result" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const e1 = fx.NpmEntry{ .path = "node_modules/b", .version = "1.0.0", .resolved = "https://registry.npmjs.org/b/-/b-1.0.0.tgz", .integrity = fx.ABC_SRI512 };
    const e2 = fx.NpmEntry{ .path = "node_modules/a", .version = "1.0.0", .resolved = "https://registry.npmjs.org/a/-/a-1.0.0.tgz", .integrity = fx.ABC_SRI512 };
    var d = Diag.init(a);
    const x = try npm.read(a, "x", try fx.packageLock(a, &.{ e1, e2 }), &d);
    const y = try npm.read(a, "y", try fx.packageLock(a, &.{ e2, e1 }), &d);
    try t.expectEqual(x.len, y.len);
    for (x, y) |p, q| try t.expectEqualStrings(p.key, q.key);
}

fn refuses(json: []const u8, needle: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, npm.read(ar.allocator(), "package-lock.json", json, &d));
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

test "refusals" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const url = "https://registry.npmjs.org/a/-/a-1.0.0.tgz";
    try refuses("{\"lockfileVersion\":2,\"packages\":{}}", "not 3");
    try refuses("{\"packages\":{}}", "no lockfileVersion");
    try refuses("[]", "not a JSON object");
    try refuses("nope", "not valid JSON");
    // sha1 (and a sha256) integrity is refused, not converted.
    try refuses(try fx.packageLock(a, &.{.{ .path = "node_modules/a", .version = "1.0.0", .resolved = url, .integrity = "sha1-qUwiJOvKwEeCoNkDVSHyRzW37JI=" }}), "not sha512");
    try refuses(try fx.packageLock(a, &.{.{ .path = "node_modules/a", .version = "1.0.0", .resolved = url, .integrity = "sha512-AAAA" }}), "64 bytes");
    // Not https: a git or file dependency, or a downgrade.
    try refuses(try fx.packageLock(a, &.{.{ .path = "node_modules/a", .version = "1.0.0", .resolved = "http://registry.npmjs.org/a.tgz", .integrity = fx.ABC_SRI512 }}), "https");
    try refuses(try fx.packageLock(a, &.{.{ .path = "node_modules/a", .version = "1.0.0", .resolved = "git+ssh://git@github.com/x/y.git", .integrity = fx.ABC_SRI512 }}), "https");
    // A quote in a name cannot reach the lock.
    try refuses(try fx.packageLock(a, &.{.{ .path = "node_modules/a", .name = "a\\\"b", .version = "1.0.0", .resolved = url, .integrity = fx.ABC_SRI512 }}), "unsupported characters");
    // No `resolved` (and not a link or bundled).
    try refuses("{\"lockfileVersion\":3,\"packages\":{\"node_modules/a\":{\"version\":\"1.0.0\",\"integrity\":\"x\"}}}", "no `resolved`");
}

test "links and bundled entries have no tarball and are skipped" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const pkgs = try npm.read(a, "p", "{\"lockfileVersion\":3,\"packages\":{\"\":{},\"node_modules/w\":{\"resolved\":\"packages/w\",\"link\":true},\"node_modules/x/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}}}", &d);
    try t.expectEqual(@as(usize, 0), pkgs.len);
}

test "merge: two lockfiles that disagree about one version's bytes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const sri2 = try fx.sri512(a, fx.ABD);
    const l1 = [_]npm.Pkg{.{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "https://r/a.tgz", .sri512 = fx.ABC_SRI512 }};
    const l2 = [_]npm.Pkg{.{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "https://r/a.tgz", .sri512 = sri2 }};
    try t.expectError(error.Invalid, npm.merge(a, &.{ &l1, &l2 }, &d));
    try t.expect(d.count() == 1);
    // The same bytes under two URLs is fine, and the smaller URL wins whichever list is first.
    const l3 = [_]npm.Pkg{.{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "https://m/a.tgz", .sri512 = fx.ABC_SRI512 }};
    var d2 = Diag.init(a);
    const m1 = try npm.merge(a, &.{ &l1, &l3 }, &d2);
    const m2 = try npm.merge(a, &.{ &l3, &l1 }, &d2);
    try t.expectEqualStrings("https://m/a.tgz", m1[0].url);
    try t.expectEqualStrings("https://m/a.tgz", m2[0].url);
}
