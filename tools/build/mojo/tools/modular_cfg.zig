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

/// macOS: the rendered text must hold exactly one line starting
/// `shared_libs = `, and it must be the one run path to the compiler's lib/,
/// `shared_libs = -Xlinker,-rpath,-Xlinker,<compiler>/lib;` (that run path
/// would name the action's sandbox). It is rewritten to the one run path a
/// runnable directory provides, plus `-S`, which keeps debug-map entries
/// (naming object files inside the sandbox) out of the output. Null, a
/// refusal, for anything else: a package that asks for something else is not
/// guessed at.
pub fn macosSharedLibs(alloc: std.mem.Allocator, rendered: []const u8, compiler: []const u8) !?[]u8 {
    const want = try std.fmt.allocPrint(alloc, "shared_libs = -Xlinker,-rpath,-Xlinker,{s}/lib;", .{compiler});
    var out = std.ArrayList(u8).init(alloc);
    var found: usize = 0;
    var it = std.mem.splitScalar(u8, rendered, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        if (std.mem.startsWith(u8, line, shared_libs_prefix)) {
            found += 1;
            if (!std.mem.eql(u8, line, want)) return null;
            try out.appendSlice(macos_shared_libs);
        } else {
            try out.appendSlice(line);
        }
    }
    if (found != 1) return null;
    return try out.toOwnedSlice();
}

pub const shared_libs_prefix = "shared_libs = ";
pub const macos_shared_libs = "shared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;";

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

// Catches: a shared_libs line naming the sandbox's lib/ reaching every
// built binary, or a package that asks for another run path used anyway
// (design item 10). Mutant planted: accept two shared_libs lines.
test "modular.cfg (macOS): shared_libs zero, one wrong, two, right" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const right = "shared_libs = -Xlinker,-rpath,-Xlinker,/w/tc/lib;";
    try testing.expect((try macosSharedLibs(a, "[mojo-max]\ndriver_path = /w/tc/bin/mojo\n", "/w/tc")) == null);
    try testing.expect((try macosSharedLibs(a, "[mojo-max]\nshared_libs = -Xlinker,-rpath,-Xlinker,/opt/lib;\n", "/w/tc")) == null);
    try testing.expect((try macosSharedLibs(a, "[mojo-max]\n" ++ right ++ "\n" ++ right ++ "\n", "/w/tc")) == null);
    try testing.expect((try macosSharedLibs(a, "[mojo-max]\n" ++ right ++ "x\n", "/w/tc")) == null);
    const got = (try macosSharedLibs(a, "[mojo-max]\ndriver_path = /w/tc/bin/mojo\n" ++ right ++ "\nlast = 1", "/w/tc")) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("[mojo-max]\ndriver_path = /w/tc/bin/mojo\nshared_libs = -Xlinker,-rpath,-Xlinker,@loader_path/lib,-Xlinker,-S;\nlast = 1", got);
}
