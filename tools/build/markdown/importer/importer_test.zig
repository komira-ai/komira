//! A file outside markdown.zig's directory importing it by module name, as
//! the tools do (BUCK: `:importer_unit`, `deps = [":markdown"]`).

const std = @import("std");
const md = @import("markdown");

test "the module is importable by name from another directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try md.splitLines(a, "```mojo\nx\n```\n[a](a.md)\n");
    const fs = try md.fences(a, lines);
    try std.testing.expectEqual(@as(usize, 1), fs.len);
    try std.testing.expectEqualStrings("mojo", fs[0].info);
    const links = try md.relativeLinks(a, lines);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqual(@as(usize, 3), links[0].line);
    try std.testing.expectEqualStrings("a.md", links[0].target);
}
