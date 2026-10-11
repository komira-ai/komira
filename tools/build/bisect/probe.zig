//! One probe: the given targets built at one commit, in a worktree of its
//! own.
//!
//! `git worktree add --detach <work-dir>/probe-<id12> <commit>` (the object
//! store is shared; no branch or ref is made), the `--copy` files copied in,
//! `git submodule update --init` with `--submodules`, then buck2 run from
//! the worktree: `root --kind project` must print the worktree (else its
//! daemon would be another project's), then `<verb> --build-report ...`,
//! then `kill`, and the worktree is removed. No `--isolation-dir`: each
//! worktree is its own project, and the default isolation dir keeps output
//! paths, and so cache hits, the same across worktrees.
const std = @import("std");
const classify = @import("classify.zig");
const Git = @import("git.zig").Git;

pub const Config = struct {
    a: std.mem.Allocator,
    git: *Git,
    /// The repository's root (absolute): where the `--copy` files are read.
    repo: []const u8,
    /// Absolute; holds the probe worktrees and logs/.
    work_dir: []const u8,
    buck2: []const u8,
    verb: classify.Verb,
    buck2_args: []const []const u8,
    targets: []const []const u8,
    copies: []const []const u8,
    submodules: bool,
    timeout_s: u32,
    /// The environment buck2 runs with: this process's, without BUCK*
    /// variables (an outer buck2's would be taken by the inner client).
    env: *const std.process.EnvMap,
};

pub const Attempt = struct {
    classified: classify.Classified,
    /// null: killed at the timeout, or by a signal; also when buck2 never ran.
    exit: ?u8,
    seconds: u64,
    /// The last lines of buck2's stderr (or why buck2 did not run), for an
    /// infra outcome.
    tail: []const u8,
};

pub const Exec = struct { exit: ?u8, timed_out: bool, stdout: []const u8, stderr: []const u8 };

const Watch = struct {
    pid: std.posix.pid_t,
    deadline_ms: i64,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn loop(w: *Watch) void {
        while (!w.done.load(.acquire)) {
            if (std.time.milliTimestamp() >= w.deadline_ms) {
                w.fired.store(true, .release);
                std.posix.kill(w.pid, std.posix.SIG.KILL) catch {};
                return;
            }
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
};

/// Runs argv in `cwd`, killing it at `timeout_s`.
pub fn exec(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, env: *const std.process.EnvMap, timeout_s: u32) !Exec {
    var child = std.ChildProcess.init(argv, a);
    child.cwd = cwd;
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var watch = Watch{ .pid = child.id, .deadline_ms = std.time.milliTimestamp() + @as(i64, timeout_s) * 1000 };
    const thread = try std.Thread.spawn(.{}, Watch.loop, .{&watch});
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    const collected = child.collectOutput(&out, &err, 1 << 28);
    const term = child.wait();
    watch.done.store(true, .release);
    thread.join();
    try collected;
    const t = try term;
    const fired = watch.fired.load(.acquire);
    const code: ?u8 = switch (t) {
        .Exited => |c| c,
        else => null,
    };
    return .{ .exit = if (fired) null else code, .timed_out = fired, .stdout = out.items, .stderr = err.items };
}

/// The last `n` lines of `s`, at most 2 KiB.
pub fn tail(s: []const u8, n: usize) []const u8 {
    const trimmed = std.mem.trimRight(u8, s, " \r\n");
    var start = trimmed.len;
    var lines: usize = 0;
    while (start > 0) {
        if (trimmed[start - 1] == '\n') {
            lines += 1;
            if (lines == n) break;
        }
        start -= 1;
    }
    if (trimmed.len - start > classify.MAX_EXCERPT_BYTES) start = trimmed.len - classify.MAX_EXCERPT_BYTES;
    while (start < trimmed.len and (trimmed[start] & 0xC0) == 0x80) start += 1;
    return trimmed[start..];
}

/// The buck2 to run in `worktree`: a relative path with a slash is the
/// worktree's own (`./buck2`, the wrapper that commit pins); an absolute
/// path, or a bare name looked up on PATH, is used as given.
pub fn buck2For(a: std.mem.Allocator, buck2: []const u8, worktree: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(buck2) or std.mem.indexOfScalar(u8, buck2, '/') == null) return buck2;
    return std.fs.path.join(a, &.{ worktree, buck2 });
}

pub const ProbeError = error{ Git, NotOwnProject };

/// Builds the targets at `commit` once. error.Git: the worktree could not be
/// made or removed (bisect stops). error.NotOwnProject: buck2 takes the
/// worktree for part of another project (bisect stops; nothing was killed).
/// `why` says which.
pub fn attempt(cfg: Config, commit: []const u8, n: usize, why: *[]const u8) !Attempt {
    const a = cfg.a;
    const id = commit[0..@min(12, commit.len)];
    const wt = try std.fmt.allocPrint(a, "{s}/probe-{s}", .{ cfg.work_dir, id });
    const logs = try std.fmt.allocPrint(a, "{s}/logs", .{cfg.work_dir});
    try std.fs.cwd().makePath(logs);
    const report_path = try std.fmt.allocPrint(a, "{s}/{s}-{d}.build_report.json", .{ logs, id, n });
    const log_path = try std.fmt.allocPrint(a, "{s}/{s}-{d}.buck2.log", .{ logs, id, n });
    std.fs.deleteFileAbsolute(report_path) catch {};

    const started = std.time.milliTimestamp();
    cfg.git.worktreeAdd(wt, commit) catch {
        why.* = cfg.git.last_err;
        return error.Git;
    };
    const res = run(cfg, wt, report_path, log_path, why);
    // The worktree goes whatever happened in it.
    cfg.git.worktreeRemove(wt) catch {
        why.* = cfg.git.last_err;
        return error.Git;
    };
    var at = try res;
    at.seconds = @intCast(@divTrunc(std.time.milliTimestamp() - started, 1000));
    return at;
}

fn run(cfg: Config, wt: []const u8, report_path: []const u8, log_path: []const u8, why: *[]const u8) !Attempt {
    const a = cfg.a;
    for (cfg.copies) |rel| {
        const from = try std.fs.path.join(a, &.{ cfg.repo, rel });
        const to = try std.fs.path.join(a, &.{ wt, rel });
        if (std.fs.path.dirname(to)) |d| try std.fs.cwd().makePath(d);
        try std.fs.copyFileAbsolute(from, to, .{});
    }
    if (cfg.submodules) {
        cfg.git.submodules(wt) catch {
            return infraAttempt(a, null, cfg.git.last_err);
        };
    }
    const buck2 = try buck2For(a, cfg.buck2, wt);

    // The worktree must be its own project root: otherwise buck2 would build
    // (and `kill` would stop) the daemon of the project around it.
    const root = exec(a, &.{ buck2, "root", "--kind", "project" }, wt, cfg.env, 120) catch |e| {
        return infraAttempt(a, null, try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ buck2, @errorName(e) }));
    };
    if (root.exit == null or root.exit.? != 0) return infraAttempt(a, root.exit, tail(root.stderr, 20));
    const real = try std.fs.realpathAlloc(a, wt);
    const got = std.mem.trim(u8, root.stdout, " \r\n");
    if (!std.mem.eql(u8, got, real)) {
        why.* = try std.fmt.allocPrint(a, "buck2 takes the probe worktree {s} for part of the project at {s}; give a --work-dir outside any buck2 project", .{ real, got });
        return error.NotOwnProject;
    }

    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ buck2, @tagName(cfg.verb), "--build-report", report_path });
    try argv.appendSlice(cfg.buck2_args);
    try argv.appendSlice(cfg.targets);
    const b = exec(a, argv.items, wt, cfg.env, cfg.timeout_s) catch |e| {
        _ = exec(a, &.{ buck2, "kill" }, wt, cfg.env, 120) catch {};
        return infraAttempt(a, null, try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ buck2, @errorName(e) }));
    };
    _ = exec(a, &.{ buck2, "kill" }, wt, cfg.env, 120) catch {};
    writeLog(log_path, argv.items, b) catch {};

    const report_bytes: ?[]const u8 = std.fs.cwd().readFileAlloc(a, report_path, 1 << 28) catch null;
    const c = try classify.classify(a, b.exit, cfg.verb, report_bytes, cfg.targets);
    var t = tail(b.stderr, 20);
    if (b.timed_out) t = try std.fmt.allocPrint(a, "killed at --timeout-s {d}\n{s}", .{ cfg.timeout_s, t });
    if (c.outcome == .infra and c.reason.len > 0) t = try std.fmt.allocPrint(a, "{s}\n{s}", .{ c.reason, t });
    return .{ .classified = c, .exit = b.exit, .seconds = 0, .tail = t };
}

fn infraAttempt(a: std.mem.Allocator, exit: ?u8, msg: []const u8) !Attempt {
    _ = a;
    return .{ .classified = .{ .outcome = .infra, .reason = msg }, .exit = exit, .seconds = 0, .tail = msg };
}

fn writeLog(path: []const u8, argv: []const []const u8, b: Exec) !void {
    var f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    const w = f.writer();
    try w.writeAll("argv:");
    for (argv) |x| try w.print(" {s}", .{x});
    if (b.exit) |e| try w.print("\nexit: {d}\n", .{e}) else try w.writeAll("\nexit: killed or signalled\n");
    try w.print("---- stdout\n{s}\n---- stderr\n{s}\n", .{ b.stdout, b.stderr });
}
