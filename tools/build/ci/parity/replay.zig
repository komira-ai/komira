//! The stand-in for buck2 and git in a parity case (runner.zig). The runner
//! puts this one binary at `./buck2`, `.parity/bin/buck2` and
//! `.parity/bin/git` of the tree the subject runs in, and every call the
//! subject makes lands here, in that tree's root.
//!
//! A call is answered from `.parity/transcript` (format.zig's transcript,
//! resolved by the runner): the entry with the same program basename and the
//! same arguments, byte for byte. A call made again gets the next entry with
//! that argv, in transcript order. The answer is the entry's stdout and
//! stderr, then its exit code, or the entry's signal raised on this process.
//!
//! Every call is appended to `.parity/calls` (format.zig's log). A call the
//! transcript cannot answer is logged as `unrecorded`, says so on stderr and
//! exits 99; the runner fails the case on it whatever the subject prints.
const std = @import("std");
const format = @import("format.zig");

const transcript_path = ".parity/transcript";
const log_path = ".parity/calls";
const exit_unrecorded = 99;
const exit_broken = 98;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("replay: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(exit_broken);
}

fn appendLog(line: []const u8) void {
    var f = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch |e| die("cannot open {s}: {s}", .{ log_path, @errorName(e) });
    defer f.close();
    f.seekFromEnd(0) catch |e| die("cannot append to {s}: {s}", .{ log_path, @errorName(e) });
    f.writeAll(line) catch |e| die("cannot append to {s}: {s}", .{ log_path, @errorName(e) });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const raw = try std.process.argsAlloc(a);
    var argv = try a.alloc([]const u8, raw.len);
    for (raw, 0..) |x, k| argv[k] = x;
    argv[0] = std.fs.path.basename(raw[0]);

    var diag = format.Diag{};
    const text = std.fs.cwd().readFileAlloc(a, transcript_path, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ transcript_path, @errorName(e) });
    const entries = format.parseTranscript(a, text, .{}, &diag) catch die("{s} line {d}: {s}", .{ transcript_path, diag.line, diag.msg });
    const log_text = std.fs.cwd().readFileAlloc(a, log_path, 1 << 28) catch "";
    const log = format.parseLog(a, log_text, &diag) catch die("{s} line {d}: {s}", .{ log_path, diag.line, diag.msg });

    const k = format.answerIndex(entries, argv, format.priorCalls(log, argv)) orelse {
        appendLog(try format.logLine(a, false, argv));
        std.io.getStdErr().writer().print("replay: unrecorded call: {s}\n", .{try format.quoteArgv(a, argv)}) catch {};
        std.process.exit(exit_unrecorded);
    };
    appendLog(try format.logLine(a, true, argv));
    const e = entries[k];
    try std.io.getStdOut().writeAll(e.stdout);
    try std.io.getStdErr().writeAll(e.stderr);
    switch (e.end) {
        .exit => |v| std.process.exit(v),
        .signal => |s| {
            std.posix.raise(s) catch {};
            die("signal {d} did not end the process", .{s});
        },
    }
}
