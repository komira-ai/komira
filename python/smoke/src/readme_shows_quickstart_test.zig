//! The README of the Python package shows the quickstart: its "What works" block is python/examples/quickstart.py
//! byte for byte (the two files are the test's data, under KOMIRA_TEST_WORK). A change to one without the other
//! fails here, with the first line that differs.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

fn readData(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, name });
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

test "the README's python block is the quickstart byte for byte" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const readme = try readData(a, "README.md");
    const example = try readData(a, "quickstart.py");
    if (try lib.readme.readmeShowsExample(a, readme, example)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.ReadmeDiffersFromQuickstart;
    }
}
