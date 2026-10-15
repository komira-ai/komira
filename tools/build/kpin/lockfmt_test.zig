//! The lock's one rendering: golden, canonical order, round trip, and that
//! nothing outside the safe character sets is ever written.

const std = @import("std");
const fx = @import("fixtures.zig");
const lockfmt = @import("lockfmt.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const golden = @embedFile("example.lock.bzl");

fn example() lockfmt.Lock {
    const Files = struct {
        const list = [_]lockfmt.File{
            .{ .platform = "linux-x86_64", .url = "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", .sha256 = "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", .size = 45480516 },
            .{ .platform = "linux-aarch64", .url = "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz", .sha256 = fx.ABC_SHA256, .size = 3 },
        };
        const pins = [_]lockfmt.LockPin{.{ .name = "zig", .version = "0.12.0", .files = &list }};
        const npm = [_]lockfmt.Npm{
            .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
            .{ .key = "@scope/pkg@2.0.1", .name = "@scope/pkg", .version = "2.0.1", .url = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
        };
    };
    return .{ .pins = &Files.pins, .npm = &Files.npm };
}

test "render is the committed golden (which Buck2 also loads: BUCK)" {
    const text = try lockfmt.render(t.allocator, example());
    defer t.allocator.free(text);
    try t.expectEqualStrings(golden, text);
}

test "render does not depend on the order entries were built in" {
    const lock = example();
    const rev_files = [_]lockfmt.File{ lock.pins[0].files[1], lock.pins[0].files[0] };
    const rev_pins = [_]lockfmt.LockPin{.{ .name = "zig", .version = "0.12.0", .files = &rev_files }};
    const rev_npm = [_]lockfmt.Npm{ lock.npm[1], lock.npm[0] };
    const a = try lockfmt.render(t.allocator, lock);
    defer t.allocator.free(a);
    const b = try lockfmt.render(t.allocator, .{ .pins = &rev_pins, .npm = &rev_npm });
    defer t.allocator.free(b);
    try t.expectEqualStrings(a, b);
}

test "the empty lock" {
    const text = try lockfmt.render(t.allocator, .{});
    defer t.allocator.free(text);
    try t.expect(std.mem.endsWith(u8, text, "PINS = {}\n\nNPM = {}\n"));
}

test "parse reads what render wrote" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const lock = try lockfmt.parse(ar.allocator(), golden, &d);
    try t.expectEqual(@as(usize, 1), lock.pins.len);
    try t.expectEqual(@as(usize, 2), lock.pins[0].files.len);
    try t.expectEqual(@as(u64, 45480516), lockfmt.findFile(lock.pins[0], "linux-x86_64").?.size);
    try t.expectEqualStrings(fx.ABC_SRI512, lock.findNpm("left-pad@1.3.0").?.sri512);
    const again = try lockfmt.render(ar.allocator(), lock);
    try t.expectEqualStrings(golden, again);
}

test "render refuses a value that could be code: a quote, a backslash, a newline, a space" {
    const bad_urls = [_][]const u8{
        "https://h/x\", \"pwn\": \"y",
        "https://h/x\\",
        "https://h/x\ny",
        "https://h/x y",
        "ftp://h/x",
        "https://",
    };
    for (bad_urls) |u| {
        const files = [_]lockfmt.File{.{ .platform = "p", .url = u, .sha256 = fx.ABC_SHA256, .size = 1 }};
        const pins = [_]lockfmt.LockPin{.{ .name = "a", .version = "1", .files = &files }};
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &pins }));
    }
    const files = [_]lockfmt.File{.{ .platform = "p", .url = "https://h/x", .sha256 = fx.ABC_SHA256, .size = 1 }};
    const bad_names = [_][]const u8{ "a\"b", "A", "a b", "" };
    for (bad_names) |n| {
        const pins = [_]lockfmt.LockPin{.{ .name = n, .version = "1", .files = &files }};
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &pins }));
    }
    // A sha256 must be 64 lower-case hex digits; a sha512 SRI is not one.
    const f2 = [_]lockfmt.File{.{ .platform = "p", .url = "https://h/x", .sha256 = fx.ABC_SRI512, .size = 1 }};
    const p2 = [_]lockfmt.LockPin{.{ .name = "a", .version = "1", .files = &f2 }};
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &p2 }));
    // npm: a key that is not name@version, a sha256 where the sri512 goes.
    var n = example().npm[0];
    n.key = "other@1.3.0";
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
    n = example().npm[0];
    n.sri512 = fx.ABC_SHA256;
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
    n = example().npm[0];
    n.sha256 = fx.ABC_SRI512;
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
}

test "render refuses a duplicate key" {
    const lock = example();
    const dup = [_]lockfmt.Npm{ lock.npm[0], lock.npm[0] };
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &dup }));
}

fn parseFails(text: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, lockfmt.parse(ar.allocator(), text, &d));
    try t.expect(d.count() > 0);
}

test "parse refuses a lock that is not what render writes" {
    try parseFails("KPIN_LOCK_VERSION = 2\nPINS = {}\nNPM = {}\n");
    try parseFails("PINS = {}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {}\nNPM = {}\nEVIL = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\": {\"version\": \"1\", \"files\": {}, \"extra\": \"x\"}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\": {\"version\": \"1\", \"files\": {\"p\": {\"url\": \"https://h/x\", \"sha256\": \"zz\", \"size\": 1}}}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {}\nNPM = {\"a@1\": {\"name\": \"a\"}}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\\\"\": {}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\n");
}
