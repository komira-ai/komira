//! The TOML subset: what it reads, and that each refusal names its line.

const std = @import("std");
const toml = @import("toml.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "tables, strings, integers, comments; a # inside a string is text" {
    var ar = arena();
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const tables = try toml.parse(ar.allocator(),
        \\# a comment
        \\[zig]            # trailing
        \\version = "0.12.0"
        \\url = "https://x/y#frag"
        \\
        \\[zig.platform.linux-x86_64]
        \\size = 42
    , &d);
    try t.expectEqual(@as(usize, 2), tables.len);
    try t.expectEqualStrings("zig", tables[0].path);
    try t.expectEqualStrings("https://x/y#frag", tables[0].get("url").?.value.string);
    try t.expectEqual(@as(u64, 42), tables[1].get("size").?.value.int);
    try t.expectEqual(@as(usize, 0), d.count());
}

fn refuses(text: []const u8, needle: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Parse, toml.parse(ar.allocator(), text, &d));
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

test "refusals name the line" {
    try refuses("[a]\nk = \"v\\n\"\n", "line 2");
    try refuses("[a]\nk = \"v\n", "line 2");
    try refuses("[a]\nk = [1, 2]\n", "line 2");
    try refuses("[a]\nk = -1\n", "line 2");
    try refuses("k = \"v\"\n", "line 1");
    try refuses("[a]\n[a]\n", "line 2");
    try refuses("[a]\nk = 1\nk = 2\n", "line 3");
    try refuses("[a..b]\n", "line 1");
    try refuses("[a\n", "line 1");
    try refuses("[a]\nnot a line\n", "line 2");
}
