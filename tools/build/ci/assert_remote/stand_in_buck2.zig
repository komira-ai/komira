//! A stand-in for `./buck2` in the cases of the buck2-farm action
//! (//:buck2_farm_cases):
//!
//!     stand_in_buck2 <subcommand> <run>...
//!     stand_in_buck2 kill
//!
//! Each `<run>` is a recorded buck2 output and how the call ends:
//!   * `<log>` (then exit 0), `<log>@<code>` (then exit <code>) or
//!     `<log>@sig<n>` (then end by signal <n>, as a killed buck2 does);
//!   * `<log>@hang`: then connect to the farm, send a request and wait for an
//!     answer that never comes, as buck2 does on a dead connection (on SIGINT
//!     it ends, as buck2 does); `<log>@hang-stubborn` waits the same with
//!     SIGINT ignored, so only SIGKILL ends it. Either gives up after
//!     `hang_limit_ms` and exits 99, so a case whose watchdog never acts fails
//!     instead of hanging;
//!   * `<log>@farm<n>-<code>`: then connect to the farm, send a request, read
//!     `<n>` bytes of its answers and exit <code>, as buck2 does with an action
//!     that runs long on a live farm.
//! The farm is the `engine_address` of the machine buckconfig under `$HOME`,
//! as buck2 reads it. The n-th call in a directory plays the n-th run: it
//! appends `<subcommand>` to `stand_in_buck2.calls` in the working directory
//! (the case counts its lines), prints the log and ends as told. A call past
//! the last run prints that and exits 99. `kill` (buck2's command that stops
//! its daemon) plays no run: it appends a line to `stand_in_buck2.kills` and
//! exits 0. It runs nothing.
const std = @import("std");
const farm_wait = @import("farm_wait.zig");

/// The longest a hanging call waits for the watchdog, in milliseconds.
const hang_limit_ms = 120_000;

const Then = union(enum) {
    code: u8,
    signal: u8,
    hang: struct { stubborn: bool },
    farm: struct { bytes: usize, code: u8 },
};

/// How a `<run>` ends, after its last `@`, or null when it names none.
fn parseThen(end: []const u8) ?Then {
    if (std.mem.eql(u8, end, "hang")) return .{ .hang = .{ .stubborn = false } };
    if (std.mem.eql(u8, end, "hang-stubborn")) return .{ .hang = .{ .stubborn = true } };
    if (std.mem.startsWith(u8, end, "sig")) {
        const sig = std.fmt.parseInt(u8, end[3..], 10) catch return null;
        return .{ .signal = sig };
    }
    if (std.mem.startsWith(u8, end, "farm")) {
        const dash = std.mem.indexOfScalar(u8, end, '-') orelse return null;
        const bytes = std.fmt.parseInt(usize, end[4..dash], 10) catch return null;
        const code = std.fmt.parseInt(u8, end[dash + 1 ..], 10) catch return null;
        return .{ .farm = .{ .bytes = bytes, .code = code } };
    }
    const code = std.fmt.parseInt(u8, end, 10) catch return null;
    return .{ .code = code };
}

/// A connection to the farm the machine buckconfig names, with a request sent on it.
fn connectToFarm(a: std.mem.Allocator) !std.net.Stream {
    const home = try std.process.getEnvVarOwned(a, "HOME");
    const path = try std.fs.path.join(a, &.{ home, ".buckconfig.d", "farm.buckconfig" });
    const farm = try farm_wait.parseConfig(try std.fs.cwd().readFileAlloc(a, path, 1 << 20));
    const stream = try std.net.tcpConnectToHost(a, farm.host, farm.port);
    try stream.writeAll("execute\n");
    return stream;
}

fn appendLine(path: []const u8, line: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
    try f.writeAll("\n");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "kill")) {
        try appendLine("stand_in_buck2.kills", "kill");
        try std.fs.File.stdout().writeAll("stand_in_buck2: the daemon is stopped\n");
        return 0;
    }
    if (args.len < 3) return 2;
    const runs = args[2..];

    const calls_path = "stand_in_buck2.calls";
    const before = std.fs.cwd().readFileAlloc(a, calls_path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    const n = std.mem.count(u8, before, "\n");
    try appendLine(calls_path, args[1]);

    if (n >= runs.len) {
        try std.fs.File.stderr().writeAll("stand_in_buck2: called once more than the case has runs\n");
        return 99;
    }
    const run = runs[n];
    var path: []const u8 = run;
    var then: Then = .{ .code = 0 };
    if (std.mem.lastIndexOfScalar(u8, run, '@')) |at| {
        if (parseThen(run[at + 1 ..])) |t| {
            path = run[0..at];
            then = t;
        }
    }
    const log = try std.fs.cwd().readFileAlloc(a, path, 1 << 24);
    try std.fs.File.stdout().writeAll(log);
    switch (then) {
        .code => |c| return c,
        .signal => |sig| {
            try std.posix.raise(sig);
            return 98; // a signal that does not end the process
        },
        .hang => |h| {
            if (h.stubborn) {
                const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
                std.posix.sigaction(std.posix.SIG.INT, &ignore, null);
            }
            const stream = try connectToFarm(a);
            defer stream.close();
            var fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, hang_limit_ms) == 0) {
                try std.fs.File.stderr().writeAll("stand_in_buck2: still waiting on the farm; nothing ended this run\n");
                return 99;
            }
            try std.fs.File.stderr().writeAll("stand_in_buck2: the farm answered a run that waits on a dead connection\n");
            return 97;
        },
        .farm => |f| {
            const stream = try connectToFarm(a);
            defer stream.close();
            var got: usize = 0;
            var buf: [256]u8 = undefined;
            while (got < f.bytes) {
                const k = try stream.read(buf[0..@min(buf.len, f.bytes - got)]);
                if (k == 0) {
                    try std.fs.File.stderr().writeAll("stand_in_buck2: the farm closed the connection\n");
                    return 96;
                }
                got += k;
            }
            return f.code;
        },
    }
}
