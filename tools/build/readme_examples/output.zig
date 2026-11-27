//! The exact output compare (docs/design/documentation_tests.md, piece 4):
//! what an example printed against its expected-output file, byte for byte.
//! A README example's `examples/<name>.expected_output.txt` is held so
//! (`tool compare-output`, cli.zig; tools/build/mojo/readme.bzl), as a task
//! example's `expected_output.txt` is by its wheel test
//! (python/tests/run_task_example.py), whose refusal this one's reads like.
//! No line is skipped or normalized. Pure: no I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The first line (from 1) where `got` and `want`, cut at each line feed,
/// differ, with each side's line there (null past its end); null when the
/// texts are equal byte for byte.
pub const Difference = struct { line: usize, got: ?[]const u8, want: ?[]const u8 };

pub fn firstDifference(alloc: Allocator, got: []const u8, want: []const u8) Allocator.Error!?Difference {
    if (std.mem.eql(u8, got, want)) return null;
    var have = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |l| try have.append(alloc, l);
    var wanted = std.ArrayList([]const u8).empty;
    var jt = std.mem.splitScalar(u8, want, '\n');
    while (jt.next()) |l| try wanted.append(alloc, l);
    var n: usize = 0;
    while (n < have.items.len and n < wanted.items.len and std.mem.eql(u8, have.items[n], wanted.items[n])) n += 1;
    // Unequal texts cut into unequal lists, so n is inside one of them.
    return .{
        .line = n + 1,
        .got = if (n < have.items.len) have.items[n] else null,
        .want = if (n < wanted.items.len) wanted.items[n] else null,
    };
}

fn describe(alloc: Allocator, line: ?[]const u8) Allocator.Error![]const u8 {
    const l = line orelse return "missing";
    return std.fmt.allocPrint(alloc, "\"{s}\"", .{l});
}

/// Null when `got` is `want` byte for byte. Otherwise the refusal: its
/// first line `<display>:<line>: expected "<line>", printed "<line>"`
/// (`missing` past a text's end), then both texts whole.
pub fn compare(alloc: Allocator, display: []const u8, want: []const u8, got: []const u8) Allocator.Error!?[]const u8 {
    const d = (try firstDifference(alloc, got, want)) orelse return null;
    return try std.fmt.allocPrint(alloc, "{s}:{d}: expected {s}, printed {s}\n--- {s} expected ---\n{s}--- printed ---\n{s}--- end ---\n", .{
        display, d.line, try describe(alloc, d.want), try describe(alloc, d.got), display, want, got,
    });
}
