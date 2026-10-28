//! Unit tests of lock_graphs.zig: which subdirs a mopm.lock asks graphs for, and each finding. The whole check,
//! over every package of the repository, is the pull request check's `buck2 bxl tools/build/ci/lock_graphs.bxl:check`.
const std = @import("std");
const L = @import("lock_graphs.zig");
const t = std.testing;

const lock_three =
    \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-aarch64": "bb", "osx-arm64": "cc"}}}
;
const lock_one =
    \\{"toolchain": {"1.0.0": {"linux-64": "aa"}}}
;

fn findings(a: std.mem.Allocator, text: []const u8, held: []const u8) ![]const []const u8 {
    return L.check(a, .{ .label = "komira//src/komira_x:table", .mojo = "1.0.0", .lock_path = "src/komira_x/mopm.lock", .held_csv = held }, text);
}

test "a table that holds exactly the subdirs its lock records is clean, for one platform and for three" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_one, "")).len);
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_three, "linux-aarch64,osx-arm64")).len);
    // the order the table lists them in does not matter
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_three, "osx-arm64,linux-aarch64")).len);
}

test "a graph deleted from the table is a finding that names the package and the subdir" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try findings(a, lock_three, "linux-aarch64");
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "komira//src/komira_x:table") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "osx-arm64") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "holds no graph") != null);
    const g = try findings(a, lock_three, "osx-arm64");
    try t.expectEqual(@as(usize, 1), g.len);
    try t.expect(std.mem.indexOf(u8, g[0], "linux-aarch64") != null);
    // both gone: one finding each
    try t.expectEqual(@as(usize, 2), (try findings(a, lock_three, "")).len);
}

test "a graph the lock does not record is a finding" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try findings(a, lock_one, "osx-arm64");
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "holds a graph for osx-arm64") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "records no toolchain") != null);
}

test "only the Mojo version the package builds with counts" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const text =
        \\{"toolchain": {"0.9.0": {"linux-64": "aa", "osx-arm64": "cc"}, "1.0.0": {"linux-64": "aa"}}}
    ;
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), text, "")).len);
}

test "a subdir sync does not plan for is ignored, as sync ignores it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const text =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-ppc64le": "dd"}}}
    ;
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), text, "")).len);
}

test "a lock that cannot say is a finding, never a pass" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{
        "not json",
        "[1]",
        "{}",
        "{\"toolchain\": 3}",
        "{\"toolchain\": {}}",
        "{\"toolchain\": {\"1.0.0\": \"x\"}}",
    };
    for (bad) |text| {
        const f = try findings(a, text, "");
        try t.expectEqual(@as(usize, 1), f.len);
        try t.expect(std.mem.indexOf(u8, f[0], "komira//src/komira_x:table") != null);
        try t.expect(std.mem.indexOf(u8, f[0], "unusable") != null);
    }
}
