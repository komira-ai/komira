//! Unit test of bench_run.zig's run id reader. The program's process behaviour (the
//! working directory, the argument order, the output file, the exit status) is
//! tests//functional/bench_run.
const std = @import("std");
const B = @import("bench_run.zig");
const t = std.testing;

test "firstLine: up to the first newline, the whole text without one, empty for an empty file" {
    try t.expectEqualStrings("run-7", B.firstLine("run-7\nsecond\n"));
    try t.expectEqualStrings("run-7", B.firstLine("run-7"));
    try t.expectEqualStrings("", B.firstLine(""));
    try t.expectEqualStrings("", B.firstLine("\nrun"));
}
