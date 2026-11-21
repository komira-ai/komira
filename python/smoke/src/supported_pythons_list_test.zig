//! The real list of supported Pythons, python/supported_pythons.tsv (the test's data, under KOMIRA_TEST_WORK),
//! is one the `matrix` step of the workflows takes: every row parses, and every platform whose wheel is built on
//! every merge has a row, so its user test has a job. A list that would fail the workflow step fails here, in the
//! pull request's check, first.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

test "every row of the list parses and every platform built on every merge has a row" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, "supported_pythons.tsv" });
    const text = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
    var why: []const u8 = "";
    const rows = lib.matrix.parse(a, &why, "python/supported_pythons.tsv", text) catch |e| {
        std.debug.print("{s}\n", .{why});
        return e;
    };
    for (lib.matrix.platforms) |p| {
        _ = lib.matrix.forPlatform(a, &why, "python/supported_pythons.tsv", rows, p) catch |e| {
            std.debug.print("{s}\n", .{why});
            return e;
        };
    }
}
