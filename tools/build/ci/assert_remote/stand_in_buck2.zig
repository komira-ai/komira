//! A stand-in for `./buck2` in the cases of the buck2-farm action
//! (//:buck2_farm_cases):
//!
//!     stand_in_buck2 <subcommand> <run>...
//!
//! Each `<run>` is a recorded buck2 output, `<log>` (then exit 0),
//! `<log>@<code>` (then exit <code>) or `<log>@sig<n>` (then end by signal
//! <n>, as a killed buck2 does). The n-th call in a directory plays the
//! n-th run: it appends `<subcommand>` to `stand_in_buck2.calls` in the
//! working directory (the case counts its lines), prints the log and exits
//! as told. A call past the last run prints that and exits 99. It runs
//! nothing.
const std = @import("std");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 3) return 2;
    const runs = args[2..];

    const calls_path = "stand_in_buck2.calls";
    const before = std.fs.cwd().readFileAlloc(a, calls_path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const n = std.mem.count(u8, before, "\n");
    var calls = try std.fs.cwd().createFile(calls_path, .{ .truncate = false });
    defer calls.close();
    try calls.seekFromEnd(0);
    try calls.writeAll(args[1]);
    try calls.writeAll("\n");

    if (n >= runs.len) {
        try std.fs.File.stderr().writeAll("stand_in_buck2: called once more than the case has runs\n");
        return 99;
    }
    const run = runs[n];
    var path: []const u8 = run;
    var code: u8 = 0;
    var signal: ?u8 = null;
    if (std.mem.lastIndexOfScalar(u8, run, '@')) |at| {
        const end = run[at + 1 ..];
        if (std.mem.startsWith(u8, end, "sig")) {
            if (std.fmt.parseInt(u8, end[3..], 10)) |sig| {
                path = run[0..at];
                signal = sig;
            } else |_| {}
        } else if (std.fmt.parseInt(u8, end, 10)) |c| {
            path = run[0..at];
            code = c;
        } else |_| {}
    }
    const log = try std.fs.cwd().readFileAlloc(a, path, 1 << 24);
    try std.fs.File.stdout().writeAll(log);
    if (signal) |sig| {
        try std.posix.raise(sig);
        return 98; // a signal that does not end the process
    }
    return code;
}
