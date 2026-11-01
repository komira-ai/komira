const std = @import("std");
const sri = @import("sri.zig");

// The npm integrity of an empty file is the best-known sha512 SRI.
const EMPTY = "sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==";

test "of: the sha512 of known bytes, in npm's form" {
    const got = try sri.of(std.testing.allocator, "");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(EMPTY, got);
}

test "of: one byte of difference is a different integrity" {
    const a = try sri.of(std.testing.allocator, "abc");
    defer std.testing.allocator.free(a);
    const b = try sri.of(std.testing.allocator, "abd");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "wellFormed: only sha512 of 64 bytes in base64" {
    try std.testing.expect(sri.wellFormed(EMPTY));
    try std.testing.expect(!sri.wellFormed("sha1-AAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expect(!sri.wellFormed("sha512-"));
    try std.testing.expect(!sri.wellFormed("sha512-AAAA"));
    try std.testing.expect(!sri.wellFormed("xsha512-" ++ EMPTY["sha512-".len..]));
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 86 ++ "=!"));
}
