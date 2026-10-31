//! The case of snappy's committed snappy-stubs-public.h, //third_party/snappy:stubs_cases: a `zig_test` run
//! as a build action. The subjects are the committed header and snappy's own snappy-stubs-public.h.in out of
//! the pinned archive (the zig_test's `data`, under KOMIRA_TEST_WORK).
//!
//! Why a test: the `native_library` of this package takes the header as a file of the package (it cannot
//! stage a header another rule generates), so it is committed. The header is what CMake's configure_file
//! writes from the template for the pinned release on a platform with <sys/uio.h>: the template with the four
//! substitutions of `:src` (the BUCK file's `substitutions`). A pin that moves to a release with another
//! template, or a header edited by hand, differs from that and fails here.

const std = @import("std");
const t = std.testing;

fn readData(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ w, name }), 1 << 20);
}

const Sub = struct { from: []const u8, to: []const u8 };

// The same four as the `substitutions` of `:src` in BUCK.
const subs = [_]Sub{
    .{ .from = "${HAVE_SYS_UIO_H_01}", .to = "1" },
    .{ .from = "${PROJECT_VERSION_MAJOR}", .to = "1" },
    .{ .from = "${PROJECT_VERSION_MINOR}", .to = "2" },
    .{ .from = "${PROJECT_VERSION_PATCH}", .to = "2" },
};

test "the committed snappy-stubs-public.h is the template with the four substitutions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var text: []const u8 = try readData(ar, "snappy-stubs-public.h.in");
    for (subs) |s| text = try std.mem.replaceOwned(u8, ar, text, s.from, s.to);
    try t.expect(std.mem.indexOf(u8, text, "${") == null);
    const committed = try readData(ar, "snappy-stubs-public.h");
    try t.expectEqualStrings(text, committed);
}

test "the substitutions here are those of :src in the BUCK file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const buck = try readData(ar, "BUCK");
    for (subs) |s| {
        const want = try std.fmt.allocPrint(ar, "\"{s}\": \"{s}\",", .{ s.from, s.to });
        try t.expect(std.mem.indexOf(u8, buck, want) != null);
    }
}
