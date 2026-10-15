//! The commands end to end: real files in a scratch directory, `main.run`,
//! and a registry on loopback for `update`. Every test is named for the
//! defect it catches.

const std = @import("std");
const fetch = @import("fetch.zig");
const fx = @import("fixtures.zig");
const main = @import("main.zig");
const registry = @import("registry.zig");
const t = std.testing;

const Run = struct { code: u8, out: []const u8, err: []const u8 };

const Env = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    reg: *registry.Registry,
    http: fetch.HttpFetcher,

    fn init(routes: []registry.Route) !*Env {
        const self = try t.allocator.create(Env);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try self.tmp.dir.realpathAlloc(self.ar.allocator(), ".");
        self.reg = try registry.Registry.start(self.ar.allocator(), routes);
        self.http = .{ .allocator = self.ar.allocator() };
        return self;
    }

    fn deinit(self: *Env) void {
        self.reg.stop();
        self.tmp.cleanup();
        self.ar.deinit();
        t.allocator.destroy(self);
    }

    fn a(self: *Env) std.mem.Allocator {
        return self.ar.allocator();
    }

    fn path(self: *Env, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.dir, name }) catch @panic("oom");
    }

    fn write(self: *Env, name: []const u8, data: []const u8) void {
        self.tmp.dir.writeFile(name, data) catch @panic("write");
    }

    fn read(self: *Env, name: []const u8) []const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), name, 1 << 20) catch @panic("read");
    }

    fn kpin(self: *Env, cmd: []const []const u8) Run {
        var argv = std.ArrayListUnmanaged([]const u8){};
        argv.appendSlice(self.a(), cmd) catch @panic("oom");
        argv.appendSlice(self.a(), &.{ "--pins", self.path("pins.toml"), "--lock", self.path("pins.lock.bzl"), "--npm", self.path("package-lock.json") }) catch @panic("oom");
        var out = std.ArrayList(u8).init(self.a());
        var err = std.ArrayList(u8).init(self.a());
        const ow = out.writer();
        const ew = err.writer();
        const code = main.run(self.a(), argv.items, ow.any(), ew.any(), &self.http);
        return .{ .code = code, .out = out.items, .err = err.items };
    }

    fn pkgLock(self: *Env, entries: []const fx.NpmEntry) void {
        self.write("package-lock.json", fx.packageLock(self.a(), entries) catch @panic("oom"));
    }

    fn entry(self: *Env, name: []const u8, sri: []const u8) fx.NpmEntry {
        const p = std.fmt.allocPrint(self.a(), "node_modules/{s}", .{name}) catch @panic("oom");
        const u = std.fmt.allocPrint(self.a(), "http://127.0.0.1:{d}/{s}.tgz", .{ self.reg.port, name }) catch @panic("oom");
        return .{ .path = p, .version = "1.0.0", .resolved = u, .integrity = sri };
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// package-lock.json entries must be https, which the loopback registry is not,
// so `update`'s npm side is tested in update_test.zig (it takes parsed packages)
// and here the npm cases start from a lock written by hand.

const tool_toml =
    \\[tool]
    \\version = "1.0.0"
    \\url = "http://127.0.0.1:PORT/tool-{version}-{platform}.bin"
    \\[tool.platform.linux-x86_64]
    \\
;

fn toolToml(e: *Env) []const u8 {
    return std.mem.replaceOwned(u8, e.a(), tool_toml, "PORT", std.fmt.allocPrint(e.a(), "{d}", .{e.reg.port}) catch @panic("oom")) catch @panic("oom");
}

const npm_entry = fx.NpmEntry{ .path = "node_modules/left-pad", .version = "1.3.0", .resolved = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .integrity = fx.ABC_SRI512 };

/// A project with one pin, pinned by `update` from the registry.
fn project(e: *Env) !void {
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 0), r.code);
}

test "usage errors are exit 2 and print the usage" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    const none = e.kpin(&.{});
    try t.expectEqual(@as(u8, 2), none.code);
    try t.expect(contains(none.err, "usage: kpin"));
    try t.expectEqual(@as(u8, 2), e.kpin(&.{"frobnicate"}).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "lock", "--bogus" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "lock", "--verify" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "check", "--only", "x" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "update", "--max-bytes", "x" }).code);
}

test "lock and check are offline: no hash anywhere is exit 1, and nothing is written" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "kpin update"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("pins.lock.bzl", .{}));
    try t.expectEqual(@as(u8, 1), e.kpin(&.{"check"}).code);
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}

test "update, then lock and check agree; lock rewrites nothing" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const u = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 0), u.code);
    try t.expect(contains(u.out, "fetched 1"));
    const first = e.read("pins.lock.bzl");
    try t.expect(contains(first, fx.ABC_SHA256));
    const l = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 0), l.code);
    try t.expect(contains(l.out, "up to date"));
    try t.expectEqualStrings(first, e.read("pins.lock.bzl"));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // check never touched the network.
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}

test "MUTANT stale lock accepted: a lock with an entry the inputs no longer ask for fails check" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // The input drops the pin; the lock still has it.
    e.write("pins.toml", "");
    const r = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "stale"));
    // A hand-added blank line is stale too: the lock is what kpin writes, byte for byte.
    e.write("pins.toml", toolToml(e));
    const lock = e.read("pins.lock.bzl");
    e.write("pins.lock.bzl", std.fmt.allocPrint(e.a(), "{s}\n", .{lock}) catch @panic("oom"));
    try t.expectEqual(@as(u8, 1), e.kpin(&.{"check"}).code);
    // `lock` repairs it.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqualStrings(lock, e.read("pins.lock.bzl"));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
}

test "a version bump without update is stale, not silently re-hashed" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const bumped = std.mem.replaceOwned(u8, e.a(), toolToml(e), "1.0.0", "1.0.1") catch @panic("oom");
    e.write("pins.toml", bumped);
    const r = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "kpin update"));
}

test "MUTANT changed hash for an unchanged version accepted: a hash edited in the lock is exit 3 against the base" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const good = e.read("pins.lock.bzl");
    e.write("base.lock.bzl", good);
    const evil = try fx.sha256Hex(e.a(), "evil");
    const edited = std.mem.replaceOwned(u8, e.a(), good, fx.ABC_SHA256, evil) catch @panic("oom");
    e.write("pins.lock.bzl", edited);
    // On its own the edited lock is self-consistent: inputs and lock agree.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // Against the lock of the merge base it is an alarm.
    const r = e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") });
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(contains(r.err, "ALARM"));
    try t.expect(contains(r.err, evil));
    // Regenerating does not make it go away.
    try t.expectEqual(@as(u8, 3), e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") }).code);
    // An honest bump (another version) against the same base is not an alarm.
    e.write("pins.lock.bzl", good);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") }).code);
}

test "MUTANT changed hash for an unchanged version accepted: package-lock.json with new integrity for a locked version is exit 3, from lock and from check" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    e.pkgLock(&.{npm_entry});
    const sha = fx.ABC_SHA256;
    const lock = std.fmt.allocPrint(e.a(),
        \\KPIN_LOCK_VERSION = 1
        \\
        \\PINS = {{}}
        \\
        \\NPM = {{
        \\    "left-pad@1.3.0": {{
        \\        "name": "left-pad",
        \\        "version": "1.3.0",
        \\        "url": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
        \\        "sri512": "{s}",
        \\        "sha256": "{s}",
        \\        "size": 3,
        \\    }},
        \\}}
        \\
    , .{ fx.ABC_SRI512, sha }) catch @panic("oom");
    e.write("pins.lock.bzl", lock);
    // Not byte-identical to what kpin writes (no header), so check says stale, but
    // `lock` accepts the inputs and rewrites it with the header.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // The registry now claims other bytes for 1.3.0.
    var changed = npm_entry;
    changed.integrity = try fx.sri512(e.a(), fx.ABD);
    e.pkgLock(&.{changed});
    const l = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 3), l.code);
    try t.expectEqual(@as(u8, 3), e.kpin(&.{"check"}).code);
    // The lock was not rewritten to the new bytes.
    try t.expect(contains(e.read("pins.lock.bzl"), fx.ABC_SRI512));
}

test "MUTANT non-deterministic output: the order of the package-lock.json entries never reaches the lock" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    const names = [_][]const u8{ "delta", "alpha", "charlie", "bravo" };
    // Seed a lock that holds them all (as update would have written it).
    var seed = std.ArrayListUnmanaged(u8){};
    const w = seed.writer(e.a());
    try w.writeAll("KPIN_LOCK_VERSION = 1\n\nPINS = {}\n\nNPM = {\n");
    for (names) |n| try w.print("    \"{s}@1.0.0\": {{\"name\": \"{s}\", \"version\": \"1.0.0\", \"url\": \"https://r.example/{s}.tgz\", \"sri512\": \"{s}\", \"sha256\": \"{s}\", \"size\": 3}},\n", .{ n, n, n, fx.ABC_SRI512, fx.ABC_SHA256 });
    try w.writeAll("}\n");
    e.write("pins.lock.bzl", seed.items);

    var entries: [4]fx.NpmEntry = undefined;
    for (names, 0..) |n, i| entries[i] = .{ .path = std.fmt.allocPrint(e.a(), "node_modules/{s}", .{n}) catch @panic("oom"), .version = "1.0.0", .resolved = std.fmt.allocPrint(e.a(), "https://r.example/{s}.tgz", .{n}) catch @panic("oom"), .integrity = fx.ABC_SRI512 };
    e.pkgLock(&entries);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    const forward = e.read("pins.lock.bzl");
    // Same inputs in another order, from another starting lock.
    std.mem.reverse(fx.NpmEntry, &entries);
    e.pkgLock(&entries);
    e.write("pins.lock.bzl", seed.items);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqualStrings(forward, e.read("pins.lock.bzl"));
    // And the lock lists them sorted.
    const a_at = std.mem.indexOf(u8, forward, "alpha@1.0.0").?;
    const b_at = std.mem.indexOf(u8, forward, "bravo@1.0.0").?;
    const c_at = std.mem.indexOf(u8, forward, "charlie@1.0.0").?;
    const d_at = std.mem.indexOf(u8, forward, "delta@1.0.0").?;
    try t.expect(a_at < b_at and b_at < c_at and c_at < d_at);
}

test "update: a newer version moves pins.toml and the lock together" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"version\":\"1.1.0\"}" },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.1.0-linux-x86_64.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const with_latest = std.fmt.allocPrint(e.a(), "{s}", .{toolToml(e)}) catch @panic("oom");
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"http://127.0.0.1:{d}/latest\"\nlatest_field = \"version\"\n", .{e.reg.port}) catch @panic("oom");
    const src = std.mem.replaceOwned(u8, e.a(), with_latest, "[tool.platform", std.fmt.allocPrint(e.a(), "{s}[tool.platform", .{extra}) catch @panic("oom")) catch @panic("oom");
    e.write("pins.toml", src);
    e.pkgLock(&.{});
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "update", "--allow-http-loopback" }).code);
    try t.expect(contains(e.read("pins.toml"), "version = \"1.1.0\""));
    try t.expect(contains(e.read("pins.lock.bzl"), try fx.sha256Hex(e.a(), fx.ABD)));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
}

test "update that finds an alarm exits 3 and leaves pins.toml and the lock as they were" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const lock = e.read("pins.lock.bzl");
    const toml = e.read("pins.toml");
    routes[0].body = fx.ABD;
    const r = e.kpin(&.{ "update", "--allow-http-loopback", "--verify" });
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expectEqualStrings(lock, e.read("pins.lock.bzl"));
    try t.expectEqualStrings(toml, e.read("pins.toml"));
}

test "update without --allow-http-loopback refuses the plain-http registry" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{"update"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "UrlNotAllowed"));
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}
