//! How `assert_remote run` (farm_retry.zig) runs one buck2 command: with its
//! output copied to the job log and to the run's log as it arrives, and with
//! the watchdog (farm_watchdog.zig) on its connections to the farm, which ends
//! a run that hangs on a dead one. farm_retry.zig decides what follows a run.

const std = @import("std");
const posix = std.posix;
const farm_wait = @import("farm_wait.zig");
const farm_watchdog = @import("farm_watchdog.zig");

/// How a run ended.
pub const End = union(enum) {
    exited: u8,
    signal: u32,
    /// The watchdog ended it: a connection to the farm had heard nothing past its bound.
    cut: Cut,
};

/// A run the watchdog ended.
pub const Cut = struct {
    /// The connection that heard nothing.
    conn: farm_watchdog.Conn,
    /// How the ended process exited (128 plus the signal that ended it).
    code: u8,
};

/// Milliseconds since `start` on the monotonic clock; 0 when the clock cannot
/// be read again, so the watchdog never looks early (and, should the clock stay
/// unreadable, does not look at all).
fn msSince(start: std.time.Instant) u64 {
    const now = std.time.Instant.now() catch return 0;
    return now.since(start) / std.time.ns_per_ms;
}

/// Milliseconds from `now` to `at`, as a poll timeout.
fn msUntil(now: u64, at: u64) i32 {
    if (at <= now) return 0;
    return @intCast(@min(at - now, std.math.maxInt(i32)));
}

/// Runs `<program> kill`, which stops buck2's daemon (and with it the dead
/// connection and the action it waits on), with its output in the job log.
/// A daemon that cannot be stopped is said and passed over: the next run's
/// watchdog ends that one too, within the bound of three runs.
fn stopDaemon(a: std.mem.Allocator, program: []const u8, w: *std.Io.Writer) !void {
    try w.print("buck2-farm: stopping buck2's daemon, which holds the dead connection (`{s} kill`)\n", .{program});
    try w.flush();
    var child = std.process.Child.init(&.{ program, "kill" }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        try w.print("buck2-farm: cannot stop buck2's daemon: {s}\n", .{@errorName(e)});
        try w.flush();
        return;
    };
    switch (term) {
        .Exited => |c| if (c != 0) try w.print("buck2-farm: `{s} kill` exited {d}\n", .{ program, c }),
        else => try w.print("buck2-farm: `{s} kill` did not exit\n", .{program}),
    }
    try w.flush();
}

/// Runs `argv` with stdout and stderr on one pipe, copying what it writes to
/// fd 1 and to a new file at `log` as it arrives, and waits for it. With a
/// `watchdog`, it looks at the connections to the farm every
/// `farm_watchdog.check_ms` while the run runs, and ends the run (SIGINT, then
/// SIGKILL after the watchdog's grace, then `<argv[0]> kill`) when one is
/// dead; what it does goes to `w`. A run that exits 0 all the same is a pass.
/// After SIGKILL the output is read for `farm_watchdog.after_kill_ms` more at
/// most, should something buck2 started hold the pipe open.
pub fn runTee(a: std.mem.Allocator, argv: []const [:0]const u8, log: []const u8, watchdog: ?*farm_watchdog.Watchdog, w: *std.Io.Writer) !End {
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    defer a.free(argv_z);
    for (argv, 0..) |arg, i| argv_z[i] = arg.ptr;
    const envp = try a.allocSentinel(?[*:0]const u8, std.os.environ.len, null);
    defer a.free(envp);
    for (std.os.environ, 0..) |e, i| envp[i] = e;

    var file = try std.fs.cwd().createFile(log, .{});
    defer file.close();

    const pipe = try posix.pipe2(.{ .CLOEXEC = true });
    const pid = posix.fork() catch |e| {
        posix.close(pipe[0]);
        posix.close(pipe[1]);
        return e;
    };
    if (pid == 0) {
        posix.dup2(pipe[1], 1) catch posix.exit(127);
        posix.dup2(pipe[1], 2) catch posix.exit(127);
        const err = posix.execvpeZ(argv_z[0].?, argv_z, envp);
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "assert_remote run: cannot run {s}: {s}\n", .{ argv[0], @errorName(err) }) catch "assert_remote run: cannot run the command\n";
        _ = posix.write(2, msg) catch {};
        posix.exit(127);
    }
    posix.close(pipe[1]);
    defer posix.close(pipe[0]);

    var chunk: [64 * 1024]u8 = undefined;
    var write_error: ?anyerror = null;
    var watch = watchdog;
    var cut: ?farm_watchdog.Conn = null;
    var killed = false;
    const start = try std.time.Instant.now();
    var next_look: u64 = farm_watchdog.check_ms;
    var kill_at: u64 = 0;
    var grace: u64 = 0;
    var fds = [_]posix.pollfd{.{ .fd = pipe[0], .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        const before = msSince(start);
        const timeout: i32 = if (cut != null) msUntil(before, kill_at) else if (watch != null) msUntil(before, next_look) else -1;
        if (try posix.poll(&fds, timeout) > 0) {
            const n = try posix.read(pipe[0], &chunk);
            if (n == 0) break;
            // The job log is a copy: a closed stdout must not stop the run or its log.
            writeAllFd(1, chunk[0..n]);
            if (write_error == null) file.writeAll(chunk[0..n]) catch |e| {
                write_error = e;
            };
        }
        const now = msSince(start);
        if (cut != null) {
            if (killed and now >= kill_at) break;
            if (!killed and now >= kill_at) {
                try w.print("buck2-farm: buck2 has not ended {d} s after SIGINT; ending it with SIGKILL\n", .{grace / std.time.ms_per_s});
                try w.flush();
                posix.kill(pid, posix.SIG.KILL) catch {};
                killed = true;
                kill_at = now + farm_watchdog.after_kill_ms;
            }
        } else if (watch) |wd| {
            if (now >= next_look) {
                next_look = now + farm_watchdog.check_ms;
                switch (wd.look(now)) {
                    .alive => {},
                    .dead => |c| {
                        try w.print("buck2-farm: watchdog: the connection to the farm from local port {d} has heard nothing from the farm for ", .{c.local_port});
                        try farm_watchdog.writeMs(w, c.silent_ms);
                        try w.writeAll(", past the bound of ");
                        try farm_watchdog.writeMs(w, wd.bound_ms);
                        try w.writeAll(": the farm has closed it and buck2 would wait on it for ever; ending buck2 (SIGINT)\n");
                        try w.flush();
                        posix.kill(pid, posix.SIG.INT) catch {};
                        cut = c;
                        grace = wd.grace_ms();
                        kill_at = now + grace;
                    },
                    .unreadable => |e| {
                        try w.print("buck2-farm: watchdog stopped: cannot read the runner's connections to the farm: {s}; the run goes on without it\n", .{@errorName(e)});
                        try w.flush();
                        watch = null;
                    },
                }
            }
        }
    }
    const status = posix.waitpid(pid, 0).status;
    const end: End = if (posix.W.IFEXITED(status)) .{ .exited = posix.W.EXITSTATUS(status) } else .{ .signal = posix.W.TERMSIG(status) };
    if (cut != null) try stopDaemon(a, argv[0], w);
    if (write_error) |e| return e;
    if (cut) |c| {
        // a buck2 that finished as it was ended passed; an ended run is never a 0
        if (end == .exited and end.exited == 0) return end;
        const code = exitCode(end);
        return .{ .cut = .{ .conn = c, .code = if (code == 0) 1 else code } };
    }
    return end;
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = posix.write(fd, rest) catch return;
        if (n == 0) return;
        rest = rest[n..];
    }
}

/// The exit code for a run that ended as `end`: buck2's own, or 128 plus the signal.
pub fn exitCode(end: End) u8 {
    return switch (end) {
        .exited => |c| c,
        .signal => |s| @truncate(128 +% s),
        .cut => |c| c.code,
    };
}

/// The watchdog of a run, from the farm config at `path`, or null after the
/// reason there is none is on `w`.
pub fn startWatchdog(a: std.mem.Allocator, path: []const u8, w: *std.Io.Writer) !?farm_watchdog.Watchdog {
    const text = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| {
        try w.print("buck2-farm: no watchdog on the connection to the farm: cannot read the farm config {s}: {s}\n", .{ path, @errorName(e) });
        try w.flush();
        return null;
    };
    const farm = farm_wait.parseConfig(text) catch |e| {
        try w.print("buck2-farm: no watchdog on the connection to the farm: the farm config {s} names no farm: {s}\n", .{ path, farm_wait.describeConfigError(e) });
        try w.flush();
        return null;
    };
    return farm_watchdog.Watchdog.init(a, farm.host, farm.port, farm.dead_seconds) catch |e| {
        try w.print("buck2-farm: no watchdog on the connection to the farm: the farm's address does not resolve: {s}\n", .{@errorName(e)});
        try w.flush();
        return null;
    };
}
