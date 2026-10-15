//! pins.toml's schema and the one edit kpin makes to it.

const std = @import("std");
const pins = @import("pins.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const good =
    \\# toolchains
    \\[zig]
    \\version = "0.12.0"
    \\url = "https://ziglang.org/download/{version}/zig-{platform}-{version}.tar.xz"
    \\latest_url = "https://api.example.org/zig/latest"
    \\latest_field = "tag_name"
    \\version_prefix = "v"
    \\
    \\[zig.platform.macos-aarch64]
    \\token = "macos-aarch64"
    \\
    \\[zig.platform.linux-x86_64]
    \\sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    \\size = 3
    \\
    \\[busybox]
    \\version = "1.35.0"
    \\url = "https://busybox.net/downloads/binaries/{version}-x86_64-linux-musl/busybox"
    \\[busybox.platform.any]
;

test "load: pins and platforms are sorted, tokens default to the id" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const list = try pins.load(ar.allocator(), good, &d);
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("busybox", list[0].name);
    try t.expectEqualStrings("zig", list[1].name);
    try t.expectEqualStrings("linux-x86_64", list[1].platforms[0].id);
    try t.expectEqualStrings("linux-x86_64", list[1].platforms[0].token);
    try t.expectEqual(@as(?u64, 3), list[1].platforms[0].size);
    try t.expectEqualStrings("v", list[1].version_prefix);
    try t.expectEqualStrings("any", list[0].platforms[0].id);
}

test "expand: only {version} and {platform}" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("https://h/1.0/p-linux", try pins.expand(a, "https://h/{version}/p-{platform}", "1.0", "linux"));
    try t.expectError(error.BadTemplate, pins.expand(a, "https://h/{os}", "1", "l"));
    try t.expectError(error.BadTemplate, pins.expand(a, "https://h/}", "1", "l"));
    try t.expectError(error.BadTemplate, pins.expand(a, "ftp://h/x", "1", "l"));
    // A token cannot smuggle a quote into the URL.
    try t.expectError(error.BadTemplate, pins.expand(a, "https://h/{platform}", "1", "l\"x"));
}

fn refuses(text: []const u8, needle: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, pins.load(ar.allocator(), text, &d));
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

const plat = "\n[a.platform.p]\n";

test "load refusals" {
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\n", "no [a.platform.<id>]");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\nbogus = \"1\"" ++ plat, "unknown key `bogus`");
    try refuses("[a]\nurl = \"https://h/x\"" ++ plat, "needs a version");
    try refuses("[a]\nversion = \"1\"" ++ plat, "needs a url");
    try refuses("[a]\nversion = \"1.0$\"\nurl = \"https://h/x\"" ++ plat, "unsupported characters");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/{nope}\"" ++ plat, "does not expand");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\nlatest_url = \"https://h/l\"" ++ plat, "only one of latest_url");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\n[a.platform.p]\nsha256 = \"ba78\"\nsize = 3\n", "64 lower-case hex");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\n[a.platform.p]\nsize = 3\n", "only one of sha256 and size");
    try refuses("[b.platform.p]\n", "no [b] table");
    try refuses("[A]\nversion = \"1\"\nurl = \"https://h/x\"\n", "pin name");
    try refuses("[a.other.p]\n[a]\nversion = \"1\"\nurl = \"https://h/x\"\n", "not a pin table");
}

test "setVersion rewrites only that pin's version line and keeps the rest byte for byte" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "[a]\nversion = \"1.0.0\"  # keep me\nurl = \"https://h/x\"\n\n[b]\nversion = \"2.0.0\"\n";
    const out = try pins.setVersion(a, src, "b", "2.1.0");
    try t.expectEqualStrings("[a]\nversion = \"1.0.0\"  # keep me\nurl = \"https://h/x\"\n\n[b]\nversion = \"2.1.0\"\n", out);
    const out2 = try pins.setVersion(a, src, "a", "1.0.1");
    try t.expectEqualStrings("[a]\nversion = \"1.0.1\"  # keep me\nurl = \"https://h/x\"\n\n[b]\nversion = \"2.0.0\"\n", out2);
    try t.expectError(error.NotFound, pins.setVersion(a, src, "c", "1"));
}

const head = "[a]\nversion = \"1\"\nurl = \"https://h/x\"\n";

test "load refusals: each validated field" {
    // Types: a field that must be a string is an integer.
    try refuses("[a]\nversion = 1\nurl = \"https://h/x\"" ++ plat, "must be a string");
    try refuses("[a]\nversion = \"1\"\nurl = 5" ++ plat, "must be a string");
    // latest_url / latest_field / version_prefix.
    try refuses(head ++ "latest_url = \"ftp://h/l\"\nlatest_field = \"v\"" ++ plat, "latest_url");
    try refuses(head ++ "latest_url = \"https://h/l\"\nlatest_field = \"a..b\"" ++ plat, "latest_field");
    try refuses(head ++ "latest_url = \"https://h/l\"\nlatest_field = \".a\"" ++ plat, "latest_field");
    try refuses(head ++ "version_prefix = \"v$\"" ++ plat, "version_prefix");
    // Platform: id, token, size type, sha256 charset (uppercase).
    try refuses(head ++ "[a.platform.P]\n", "platform id");
    try refuses(head ++ "[a.platform.p]\ntoken = \"l x\"\n", "token");
    try refuses(head ++ "[a.platform.p]\nsha256 = \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015AD\"\nsize = 3\n", "64 lower-case hex");
    try refuses(head ++ "[a.platform.p]\nsha256 = \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"\nsize = \"3\"\n", "must be an integer");
    try refuses(head ++ "[a.platform.p]\nbogus = 1\n", "unknown key `bogus`");
    // A url that is not http(s), and a template whose expansion has a bad character.
    try refuses("[a]\nversion = \"1\"\nurl = \"file:///x\"" ++ plat, "does not expand");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x y\"" ++ plat, "does not expand");
    try refuses("[a]\nversion = \"-1\"\nurl = \"https://h/x\"" ++ plat, "unsupported characters");
    try refuses("[a]\nversion = \"1\"\nurl = \"https://h/x\"\nversion_prefix = \"-\"" ++ plat, "version_prefix");
}

test "setVersion finds a [name] header that has a comment, as the parser does" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const out = try pins.setVersion(ar.allocator(), "[a] # toolchain\nversion = \"1.0.0\" # pinned\nurl = \"https://h/x\"\n", "a", "1.0.1");
    try t.expectEqualStrings("[a] # toolchain\nversion = \"1.0.1\" # pinned\nurl = \"https://h/x\"\n", out);
}
