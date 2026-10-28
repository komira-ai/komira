//! Unit tests of launch.zig: which defaults are added, and that a given flag is
//! not added again. The launcher itself is exercised by `buck2 run` of a
//! validation (tests//functional/release_validations).
const std = @import("std");
const L = @import("launch.zig");
const t = std.testing;

const Fake = struct {
    made: *usize,
    pub fn make(self: Fake, _: std.mem.Allocator) ![]const u8 {
        self.made.* += 1;
        return "/scratch";
    }
};

test "names: the flag alone or with =, not a longer flag or a value" {
    try t.expect(L.names(&.{ "x", "--run-id", "7" }, "--run-id"));
    try t.expect(L.names(&.{"--run-id=7"}, "--run-id"));
    try t.expect(!L.names(&.{"--run-ids"}, "--run-id"));
    try t.expect(!L.names(&.{ "--other", "--run-id-x=1" }, "--run-id"));
    try t.expect(!L.names(&.{ "a", "b" }, "--attempt"));
}

test "withDefaults: every missing flag is appended after the caller's arguments" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var made: usize = 0;
    const out = try L.withDefaults(a, &.{ "run", "--stage", "beta" }, Fake{ .made = &made });
    const want = [_][]const u8{ "run", "--stage", "beta", "--run-id", "local", "--attempt", "1", "--scratch-dir", "/scratch" };
    try t.expectEqual(want.len, out.len);
    for (want, out) |w, o| try t.expectEqualStrings(w, o);
    try t.expectEqual(@as(usize, 1), made);
}

test "withDefaults: flags the caller gave are kept, and no scratch directory is made for them" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var made: usize = 0;
    const out = try L.withDefaults(a, &.{ "--run-id=9", "--attempt", "3", "--scratch-dir=/s" }, Fake{ .made = &made });
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqual(@as(usize, 0), made);
    const some = try L.withDefaults(a, &.{ "--attempt", "3" }, Fake{ .made = &made });
    try t.expectEqual(@as(usize, 6), some.len);
    try t.expectEqualStrings("--run-id", some[2]);
    try t.expectEqualStrings("--scratch-dir", some[4]);
    try t.expectEqual(@as(usize, 1), made);
}
