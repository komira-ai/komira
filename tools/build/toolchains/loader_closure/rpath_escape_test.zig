//! Run path entries and links that lead out of the prefix through it.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "an $ORIGIN entry that climbs above the prefix is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "escape");
    try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libown.so.1"}, .rpath = "$ORIGIN/../lib:$ORIGIN/../../outside" });
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    try fx.expectRed(t, .{}, "the run path entry '$ORIGIN/../../outside', which leaves the prefix");
}

test "relative, empty and other-token entries are red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "lib", "relative to the working directory" },
        .{ "$ORIGIN/../lib:", "an empty run path entry" },
        .{ "$LIB", "a token other than $ORIGIN" },
        .{ "$ORIGINAL/lib", "a token other than $ORIGIN" },
    };
    for (cases, 0..) |c, i| {
        const t = try fx.Tree.init(a, try std.fmt.allocPrint(a, "escape_entry_{d}", .{i}));
        try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libown.so.1"}, .rpath = try std.fmt.allocPrint(a, "$ORIGIN/../lib:{s}", .{c[0]}) });
        try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
        try fx.expectRed(t, .{}, c[1]);
    }
}

test "a library that is a link leaving the prefix is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outside = try fx.Tree.init(a, "escape_outside");
    try outside.plant("libown.so.1", .{ .soname = "libown.so.1" });
    const t = try fx.Tree.init(a, "escape_link");
    try t.plant("bin/prog", fx.program(&.{"libown.so.1"}));
    try t.symlink(try std.fs.path.join(a, &.{ outside.dir, "libown.so.1" }), "lib/libown.so.1");
    try fx.expectRed(t, .{}, "lib/libown.so.1 resolves to ");
}
