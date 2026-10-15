//! `kpin update` for Cargo: the sizes file from a verified download of each
//! linked `.crate`, through the real HTTP client against a registry on
//! loopback. Every test is named for the defect it catches.

const std = @import("std");
const fetch = @import("fetch.zig");
const fx = @import("fixtures.zig");
const main = @import("main.zig");
const registry = @import("registry.zig");
const t = std.testing;

const lock_text = @embedFile("cargo_fixture/Cargo.lock");
const metadata_text = @embedFile("cargo_fixture/metadata.json");
const target = "x86_64-unknown-linux-gnu";

/// The linked crates of the fixture workspace (cc and tempfile are not).
const linked = [_][]const u8{ "foo-bar/foo-bar-1.0.0", "http/http-0.2.12", "http/http-1.1.0", "libc/libc-0.2.150", "lzma-sys/lzma-sys-0.1.0", "my-derive/my-derive-0.3.0", "serde/serde-1.0.100" };

const Env = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    routes: []registry.Route,
    reg: *registry.Registry,
    http: fetch.HttpFetcher,

    /// `body` is what every linked crate's route serves; the lock pins `fx.ABC_SHA256`.
    fn init(body: []const u8) !*Env {
        const self = try t.allocator.create(Env);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        const al = self.ar.allocator();
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try self.tmp.dir.realpathAlloc(al, ".");
        var lock: []const u8 = lock_text;
        for ("abcdef123") |c| {
            const h = try al.alloc(u8, 64);
            @memset(h, c);
            lock = try std.mem.replaceOwned(u8, al, lock, h, fx.ABC_SHA256);
        }
        try self.tmp.dir.writeFile("Cargo.lock", lock);
        try self.tmp.dir.writeFile("metadata.json", metadata_text);
        var routes = std.ArrayListUnmanaged(registry.Route){};
        for (linked) |l| try routes.append(al, .{ .path = try std.fmt.allocPrint(al, "/crates/{s}.crate", .{l}), .body = body });
        // Never fetched: a build-dependency.
        try routes.append(al, .{ .path = "/crates/cc/cc-1.0.0.crate", .body = body });
        self.routes = routes.items;
        self.reg = try registry.Registry.start(al, self.routes);
        self.http = .{ .allocator = al };
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

    fn read(self: *Env, name: []const u8) []const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), name, 1 << 20) catch @panic("read");
    }

    const Run = struct { code: u8, out: []const u8, err: []const u8 };

    fn update(self: *Env, extra: []const []const u8) Run {
        var argv = std.ArrayListUnmanaged([]const u8){};
        const base = std.fmt.allocPrint(self.a(), "http://127.0.0.1:{d}/crates", .{self.reg.port}) catch @panic("oom");
        argv.appendSlice(self.a(), &.{ "update", "--no-pins", "--allow-http-loopback", "--cargo-lock", self.path("Cargo.lock"), "--metadata", self.path("metadata.json"), "--sizes", self.path("sizes.txt"), "--target", target, "--crates-base", base }) catch @panic("oom");
        argv.appendSlice(self.a(), extra) catch @panic("oom");
        var out = std.ArrayList(u8).init(self.a());
        var err = std.ArrayList(u8).init(self.a());
        const code = main.run(self.a(), argv.items, out.writer().any(), err.writer().any(), &self.http);
        return .{ .code = code, .out = out.items, .err = err.items };
    }

    fn hits(self: *Env, name: []const u8) usize {
        return self.reg.hitsOf(std.fmt.allocPrint(self.a(), "/crates/{s}.crate", .{name}) catch @panic("oom"));
    }
};

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "the sizes are the bytes kpin downloaded: one sorted line per linked crate, none for a build-dependency" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    const r = e.update(&.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings(
        \\foo-bar-1.0.0.crate 3
        \\http-0.2.12.crate 3
        \\http-1.1.0.crate 3
        \\libc-0.2.150.crate 3
        \\lzma-sys-0.1.0.crate 3
        \\my-derive-0.3.0.crate 3
        \\serde-1.0.100.crate 3
        \\
    , e.read("sizes.txt"));
    try t.expectEqual(@as(usize, 0), e.hits("cc/cc-1.0.0"));
    try t.expect(has(r.out, "fetched 7 crates"));
}

test "a second run fetches nothing; --verify fetches everything again" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), e.update(&.{}).code);
    const again = e.update(&.{});
    try t.expectEqual(@as(u8, 0), again.code);
    try t.expect(has(again.out, "fetched 0 crates"));
    try t.expectEqual(@as(usize, 1), e.hits("serde/serde-1.0.100"));
    try t.expectEqual(@as(u8, 0), e.update(&.{"--verify"}).code);
    try t.expectEqual(@as(usize, 2), e.hits("serde/serde-1.0.100"));
}

test "a crate whose bytes are not the sha256 Cargo.lock pins is an alarm, and nothing is written" {
    const e = try Env.init(fx.ABD);
    defer e.deinit();
    const r = e.update(&.{});
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(has(r.err, "Cargo.lock pins sha256"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("sizes.txt", .{}));
}

test "a size that differs from the sizes file, with --verify, is an alarm" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    try e.tmp.dir.writeFile("sizes.txt", "serde-1.0.100.crate 99\n");
    const r = e.update(&.{"--verify"});
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(has(r.err, "serde-1.0.100.crate: the sizes file has 99 bytes"));
    try t.expectEqualStrings("serde-1.0.100.crate 99\n", e.read("sizes.txt"));
}

test "a missing crate is exit 1 and nothing is written" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    e.routes[2].status = 404;
    const r = e.update(&.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.err, "http-1.1.0.crate"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("sizes.txt", .{}));
}

test "the Cargo sizes need all four inputs, and --no-pins is only for them" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    var out = std.ArrayList(u8).init(e.a());
    var err = std.ArrayList(u8).init(e.a());
    const code = main.run(e.a(), &.{ "update", "--no-pins", "--sizes", e.path("sizes.txt") }, out.writer().any(), err.writer().any(), &e.http);
    try t.expectEqual(@as(u8, 1), code);
    try t.expect(has(err.items, "need --cargo-lock"));
    err.clearRetainingCapacity();
    const code2 = main.run(e.a(), &.{ "update", "--no-pins" }, out.writer().any(), err.writer().any(), &e.http);
    try t.expectEqual(@as(u8, 1), code2);
    try t.expect(has(err.items, "--no-pins is for the Cargo sizes"));
    err.clearRetainingCapacity();
    // The Cargo inputs belong to `cargo` and `update`, not to `lock`.
    try t.expectEqual(@as(u8, 2), main.run(e.a(), &.{ "lock", "--sizes", "x" }, out.writer().any(), err.writer().any(), &e.http));
}

test "the sizes it wrote are the ones kpin cargo emits" {
    const e = try Env.init(fx.ABC);
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), e.update(&.{}).code);
    try e.tmp.dir.writeFile("overrides.json", @embedFile("cargo_fixture/overrides.json"));
    var out = std.ArrayList(u8).init(e.a());
    var err = std.ArrayList(u8).init(e.a());
    const code = main.run(e.a(), &.{
        "cargo",      "--cargo-lock", e.path("Cargo.lock"), "--metadata", e.path("metadata.json"), "--overrides", e.path("overrides.json"),
        "--sizes",    e.path("sizes.txt"), "--rustc", "1.85.0", "--target", target, "--cargo-out", e.path("crates.bzl"),
    }, out.writer().any(), err.writer().any(), &e.http);
    try t.expectEqual(@as(u8, 0), code);
    try t.expect(has(e.read("crates.bzl"), "size = 3,"));
    try t.expect(!has(e.read("crates.bzl"), "size = 1148"));
}
