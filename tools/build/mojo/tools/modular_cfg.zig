//! modular_cfg: the compiler's `share/max/modular.cfg`, rendered for one
//! action. Every `@@MOJO_TOOLCHAIN_ROOT@@` becomes the absolute compiler
//! directory, so no absolute path is part of the action key; a token left
//! after rendering is a refusal (mojo_compile.zig, exit 2).

const std = @import("std");

pub const token = "@@MOJO_TOOLCHAIN_ROOT@@";

/// `text` with every occurrence of `token` replaced by `root`, literally.
pub fn render(alloc: std.mem.Allocator, text: []const u8, root: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, text, token, root);
}

pub fn holdsToken(text: []const u8) bool {
    return std.mem.indexOf(u8, text, token) != null;
}

/// The rendered text, or null when a token survives rendering.
pub fn renderChecked(alloc: std.mem.Allocator, text: []const u8, root: []const u8) !?[]u8 {
    const out = try render(alloc, text, root);
    if (holdsToken(out)) return null;
    return out;
}

const testing = std.testing;

// Catches: a toolchain path left as the token (the compiler would look for
// its libraries under a literal `@@...@@` directory).
test "modular.cfg: every token replaced by the compiler directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = (try renderChecked(arena.allocator(), "[max]\nroot = @@MOJO_TOOLCHAIN_ROOT@@\nlib = @@MOJO_TOOLCHAIN_ROOT@@/lib;@@MOJO_TOOLCHAIN_ROOT@@\n", "/w/tc")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("[max]\nroot = /w/tc\nlib = /w/tc/lib;/w/tc\n", got);
    const plain = (try renderChecked(arena.allocator(), "no token\n", "/w/tc")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("no token\n", plain);
}

// Catches: a rendering that leaves a token unrendered and is used anyway.
// Mutant planted: skip the surviving-token check.
test "modular.cfg: a token surviving rendering is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A compiler directory spelled with the token renders one back.
    try testing.expect((try renderChecked(arena.allocator(), "root = @@MOJO_TOOLCHAIN_ROOT@@\n", "/w/@@MOJO_TOOLCHAIN_ROOT@@")) == null);
    try testing.expect(holdsToken("x@@MOJO_TOOLCHAIN_ROOT@@"));
    try testing.expect(!holdsToken("x@@MOJO_TOOLCHAIN_ROOT@"));
}
