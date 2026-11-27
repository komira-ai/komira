//! `expect-failure`: whether a run failed the way a fixture says it must
//! (cli.zig runs the command; this judges what it did). Pure: no I/O.
//!
//! A run fails as expected when it exits with a status other than 0 and its
//! output (stdout, then stderr) holds the expected text. A run that passes,
//! one that fails without the text, and one killed by a signal or stopped
//! are each refused, with the reason and the end of the output. The build
//! uses it to prove a README example that should fail does fail, naming its
//! file and line (tools/build/mojo/readme.bzl,
//! `mojo_readme_example_failure`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How the command ended.
pub const End = union(enum) {
    exited: u32,
    signal: u32,
    /// Stopped, or ended in a way the platform does not say.
    other,
};

/// How a child that ended with `term` ended.
pub fn endOf(term: std.process.Child.Term) End {
    return switch (term) {
        .Exited => |c| .{ .exited = c },
        .Signal => |s| .{ .signal = s },
        else => .other,
    };
}

/// The last `n` lines of `text`.
pub fn tail(text: []const u8, n: usize) []const u8 {
    var i = text.len;
    // A final line feed ends the last line; it does not start one.
    if (i > 0 and text[i - 1] == '\n') i -= 1;
    var seen: usize = 0;
    while (i > 0) {
        i -= 1;
        if (text[i] == '\n') {
            seen += 1;
            if (seen == n) return text[i + 1 ..];
        }
    }
    return text;
}

/// The lines of output a refusal shows.
pub const SHOWN = 40;

/// Why the run that ended `end`, printing `output`, did not fail as
/// expected (with `want` in its output), or null when it did.
pub fn judge(alloc: Allocator, end: End, output: []const u8, want: []const u8) Allocator.Error!?[]const u8 {
    switch (end) {
        .exited => |code| {
            if (code == 0) {
                return try std.fmt.allocPrint(alloc, "the run passed (exit 0); it must fail with `{s}` in its output. Its output ends:\n{s}", .{ want, tail(output, SHOWN) });
            }
            if (std.mem.indexOf(u8, output, want) != null) return null;
            return try std.fmt.allocPrint(alloc, "the run failed (exit {d}) but its output does not hold `{s}`. Its output ends:\n{s}", .{ code, want, tail(output, SHOWN) });
        },
        .signal => |s| return try std.fmt.allocPrint(alloc, "the run was killed by signal {d}; it must exit non-zero with `{s}` in its output. Its output ends:\n{s}", .{ s, want, tail(output, SHOWN) }),
        .other => return try std.fmt.allocPrint(alloc, "the run stopped without exiting; it must exit non-zero with `{s}` in its output", .{want}),
    }
}
