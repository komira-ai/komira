const std = @import("std");
const platform = @import("platform.zig");

fn list(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, a, text, .{})).value;
}

test "ok: no list, an empty list and a list naming the platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(platform.ok(null, "linux"));
    try std.testing.expect(platform.ok(try list(a, "[]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[\"linux\"]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[\"darwin\",\"linux\"]"), "linux"));
}

test "ok: a list that does not name the platform refuses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!platform.ok(try list(a, "[\"darwin\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"arm64\"]"), "x64"));
}

test "ok: a refusal list allows the rest and a refused platform stays refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(platform.ok(try list(a, "[\"!win32\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"!linux\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"linux\",\"!linux\"]"), "linux"));
}
