//! Finding 4: a fixture's census against its expected files.

const std = @import("std");
const g = @import("grounding.zig");

const want = "surface\tcapability\tstatus\ttarget\tnote\npandas\tfilter\tfilled\t:t\ta\npolars\tfilter\tmissing\t-\tb\n";

test "equal files: no finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u8).empty;
    try std.testing.expectEqual(@as(usize, 0), try g.compare(arena.allocator(), want, want, "expect_matrix.tsv", &out));
    try std.testing.expectEqualStrings("", out.items);
}

test "one changed line: the heading, its line number, the expected and the got line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u8).empty;
    const got = "surface\tcapability\tstatus\ttarget\tnote\npandas\tfilter\tmissing\t-\ta\npolars\tfilter\tmissing\t-\tb\n";
    const n = try g.compare(arena.allocator(), got, want, "expect_matrix.tsv", &out);
    try std.testing.expectEqualStrings(
        "the census differs from expect_matrix.tsv (- expected, + got):\n" ++
            "@@ line 2 @@\n" ++
            "-pandas\tfilter\tfilled\t:t\ta\n" ++
            "+pandas\tfilter\tmissing\t-\ta\n",
        out.items,
    );
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "a missing final newline is a difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.ArrayList(u8).empty;
    const n = try g.compare(arena.allocator(), want[0 .. want.len - 1], want, "expect_matrix.tsv", &out);
    try std.testing.expect(n >= 2);
}

test "a long difference is cut at max_diff_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var big = std.ArrayList(u8).empty;
    for (0..100) |k| try big.writer(a).print("line {d}\n", .{k});
    var out = std.ArrayList(u8).empty;
    const n = try g.compare(a, big.items, "", "expect_report.txt", &out);
    try std.testing.expectEqual(@as(usize, 2 + g.max_diff_lines), n);
}
