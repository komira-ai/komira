//! `gate step`: runs one build step of one mutant and records how it ended
//! (S1-S6 of docs/design/zig_gate_runner.md; tools/build/mojo/mutation.bzl;
//! the statuses are read by `mutate score`, coverage/mutate/mutate/score.mojo).
//!
//!   gate step --status S --limit-s N [--after F]... [--infra-exit N]... -- COMMAND...
//!
//! The first line of S is one of
//!
//!   skipped          the first line of an --after file is not `ok`: the
//!                    command did not run
//!   ok               the command exited 0
//!   timeout <N>      the command was still running after N s: its process
//!                    group was sent SIGTERM, then 2 s later SIGKILL
//!   fail <status>    the command exited <status>, not 0, within its limit
//!
//! and the last 60 lines of the command's output follow. A status named by
//! --infra-exit (when the step did not time out) is a failure of the
//! machine, not of the mutant: the tool prints the output and exits with
//! that status, so the action fails and is not cached.
//!
//! Each argument that starts with @MUT_SCRATCH@ has that prefix replaced by
//! a directory private to this run ($BUCK_SCRATCH_PATH/mut_step, or
//! `.mut_step.XXXXXX` under the working directory without one), which also
//! holds the command's log. After a run or a skip, every `-o <path>` of the
//! command that does not exist is created empty.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const util = @import("util.zig");
const supervise = @import("supervise.zig");

pub const scratch_token = "@MUT_SCRATCH@";

fn usage(comptime fmt: []const u8, a: anytype) u8 {
    util.err("mut_step: " ++ fmt ++ "\n", a);
    return 2;
}

/// The first line of `path` (busybox `head -n 1` in a command
/// substitution); null when it cannot be read.
fn firstLine(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf = std.ArrayList(u8).init(alloc);
    var b: [512]u8 = undefined;
    while (true) {
        const n = f.read(&b) catch return null;
        if (n == 0) break;
        if (std.mem.indexOfScalar(u8, b[0..n], '\n')) |nl| {
            buf.appendSlice(b[0..nl]) catch return null;
            break;
        }
        buf.appendSlice(b[0..n]) catch return null;
    }
    return buf.items;
}

pub fn main(alloc: std.mem.Allocator, argv: []const []const u8) u8 {
    return run(alloc, argv) catch |e| {
        util.err("mut_step: {s}\n", .{@errorName(e)});
        return 2;
    };
}

fn run(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    var status: ?[]const u8 = null;
    var limit_s: ?[]const u8 = null;
    var go = true;
    var infra = std.ArrayList([]const u8).init(alloc);
    var i: usize = 0;
    while (i < argv.len and !std.mem.eql(u8, argv[i], "--")) : (i += 2) {
        const flag = argv[i];
        const has_value = i + 1 < argv.len;
        if (std.mem.eql(u8, flag, "--status")) {
            if (!has_value or status != null) return usage("usage error", .{});
            status = argv[i + 1];
        } else if (std.mem.eql(u8, flag, "--limit-s")) {
            if (!has_value or limit_s != null) return usage("usage error", .{});
            limit_s = argv[i + 1];
            if (util.positiveStrict(argv[i + 1]) == null) return usage("limit '{s}' is not a positive number of seconds", .{argv[i + 1]});
        } else if (std.mem.eql(u8, flag, "--after")) {
            if (!has_value) return usage("--after needs a status file", .{});
            const first = firstLine(alloc, argv[i + 1]) orelse {
                util.err("mut_step: cannot read {s}\n", .{argv[i + 1]});
                return 1;
            };
            if (!std.mem.eql(u8, first, "ok")) go = false;
        } else if (std.mem.eql(u8, flag, "--infra-exit")) {
            if (!has_value) return usage("--infra-exit needs a status", .{});
            const v = argv[i + 1];
            var ok = v.len > 0;
            for (v) |c| {
                if (c < '0' or c > '9') ok = false;
            }
            if (!ok) return usage("--infra-exit {s} is not a status", .{v});
            try infra.append(v);
        } else {
            return usage("unknown argument {s}", .{flag});
        }
    }
    if (status == null or limit_s == null) return usage("usage error", .{});
    if (i + 1 >= argv.len) return usage("expected -- and a command", .{});
    const limit = util.positiveStrict(limit_s.?).?;

    const here = try util.actionDir(alloc);
    const scratch = blk: {
        const b = std.posix.getenv("BUCK_SCRATCH_PATH") orelse "";
        if (b.len == 0) break :blk try util.makeTempDir(alloc, here, ".mut_step.");
        const s = try std.fmt.allocPrint(alloc, "{s}/mut_step", .{try util.abs(alloc, here, b)});
        try std.fs.cwd().makePath(s);
        break :blk s;
    };

    var cmd = std.ArrayList([]const u8).init(alloc);
    for (argv[i + 1 ..]) |a| {
        if (std.mem.startsWith(u8, a, scratch_token)) {
            try cmd.append(try std.fmt.allocPrint(alloc, "{s}{s}", .{ scratch, a[scratch_token.len..] }));
        } else try cmd.append(a);
    }

    const st = status.?;
    if (!go) {
        try writeFile(st, "skipped\n");
        try ensureOutputs(cmd.items);
        return 0;
    }

    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{scratch});
    const log_fd = try util.createLog(log);
    const path = try resolve(alloc, cmd.items[0]);
    var env = std.ArrayList([]const u8).init(alloc);
    for (std.os.environ) |e| try env.append(std.mem.span(e));
    const o = try supervise.run(alloc, .{
        .path = (try alloc.dupeZ(u8, path)).ptr,
        .argv = (try util.zList(alloc, cmd.items)).ptr,
        .envp = (try util.zList(alloc, env.items)).ptr,
        .stdout_fd = log_fd,
        .stderr_fd = log_fd,
        .limit = .{ .term_kill_ms = limit * 1000 },
    });
    posix.close(log_fd);
    if (o.signal != 0) return 128 +| o.signal;
    if (o.timer_failed) {
        util.err("mut_step: the clock could not be read, so the step could not be bounded\n", .{});
        return 2;
    }

    var line: []const u8 = undefined;
    if (o.limit_hit) {
        line = try std.fmt.allocPrint(alloc, "timeout {s}\n", .{limit_s.?});
    } else if (o.status == 0) {
        line = "ok\n";
    } else {
        const rc_s = try std.fmt.allocPrint(alloc, "{d}", .{o.status});
        for (infra.items) |n| {
            if (std.mem.eql(u8, n, rc_s)) {
                util.err("mut_step: the step exited {d}, a failure of the machine it ran on, not of the mutant; failing the action so that it is not cached\n", .{o.status});
                util.writeTail(2, log, 60);
                return o.status;
            }
        }
        line = try std.fmt.allocPrint(alloc, "fail {d}\n", .{o.status});
    }
    try writeFile(st, line);
    {
        const f = try std.fs.cwd().openFile(st, .{ .mode = .write_only });
        defer f.close();
        try f.seekFromEnd(0);
        util.writeTail(f.handle, log, 60);
    }
    try ensureOutputs(cmd.items);
    return 0;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

/// The program `name` names: itself when it holds a `/`, else the first
/// executable in $PATH (as setsid's execvp finds it).
fn resolve(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    const path = std.posix.getenv("PATH") orelse return name;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        const cand = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ if (d.len == 0) "." else d, name });
        std.posix.access(cand, std.posix.X_OK) catch continue;
        return cand;
    }
    return name;
}

/// Every `-o <path>` of the command that does not exist, created empty with
/// its parent directories, so the action's declared outputs exist.
fn ensureOutputs(cmd: []const []const u8) !void {
    var prev: []const u8 = "";
    for (cmd) |a| {
        if (std.mem.eql(u8, prev, "-o")) {
            if (std.fs.cwd().statFile(a)) |_| {} else |_| {
                if (std.fs.path.dirname(a)) |d| try std.fs.cwd().makePath(d);
                const f = try std.fs.cwd().createFile(a, .{});
                f.close();
            }
        }
        prev = a;
    }
}
