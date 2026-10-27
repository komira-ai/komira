//! The runner: every buck2 command a scenario issues.
//!
//! It adds `--isolation-dir selftest_<scenario>` to every command in the
//! checkout (a scratch tree is its own project root and uses the default
//! isolation dir), and `-c komira_selftest.inner=true` to every command that
//! reads the build configuration. It captures the exit status, stdout and
//! stderr of each command into a log file under the scenario's log
//! directory (its argv and working directory are written before it starts, so
//! a command that never ends is named in the log directory; the build action
//! that runs the scenario has the time limit), and stops every
//! daemon it started (`buck2 [--isolation-dir ...] kill`) when the scenario
//! ends, failed or not.
const std = @import("std");
const whatran = @import("whatran.zig");

pub const INNER_KEY = "komira_selftest.inner=true";

pub const Opts = struct {
    /// `section.key=value` pairs, each passed as `-c <pair>`.
    cfg: []const []const u8 = &.{},
    target_platforms: ?[]const u8 = null,
    /// Whether the command takes `-c` (`kill`, `log` and `root` do not).
    configured: bool = true,
    /// A scratch tree's root; null is the checkout, under the isolation dir.
    cwd: ?[]const u8 = null,
    /// Whether the daemon this command reaches is stopped at the end (`kill` itself is not tracked).
    track: bool = true,
};

pub const Result = struct {
    /// The exit status, or null when the command was killed or signalled.
    exit: ?u8,
    stdout: []const u8,
    stderr: []const u8,
    log: []const u8,

    pub fn ok(r: Result) bool {
        return r.exit != null and r.exit.? == 0;
    }
};

const Daemon = struct { cwd: ?[]const u8 };

/// The argv of one inner command: buck2, the isolation dir (in the
/// checkout), the subcommand and its words, then the inner key and the `-c`
/// pairs and target platforms, all before a `--` the words may hold.
pub fn argv(a: std.mem.Allocator, buck2: []const u8, isolation_dir: ?[]const u8, words: []const []const u8, opts: Opts) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.append(a, buck2);
    if (isolation_dir) |d| try out.appendSlice(a, &.{ "--isolation-dir", d });
    var split = words.len;
    for (words, 0..) |w, i| {
        if (std.mem.eql(u8, w, "--")) {
            split = i;
            break;
        }
    }
    try out.appendSlice(a, words[0..split]);
    if (opts.configured) {
        try out.appendSlice(a, &.{ "-c", INNER_KEY });
        for (opts.cfg) |c| try out.appendSlice(a, &.{ "-c", c });
        if (opts.target_platforms) |p| try out.appendSlice(a, &.{ "--target-platforms", p });
    }
    try out.appendSlice(a, words[split..]);
    return out.toOwnedSlice(a);
}

pub const Runner = struct {
    a: std.mem.Allocator,
    buck2: []const u8,
    /// The checkout's root (the scenario's working directory).
    root: []const u8,
    isolation_dir: []const u8,
    log_dir: []const u8,
    env: std.process.EnvMap,
    n: usize = 0,
    daemons: std.ArrayList(Daemon),

    pub fn init(a: std.mem.Allocator, buck2: []const u8, scenario: []const u8, log_dir: []const u8) !Runner {
        var env = try std.process.getEnvMap(a);
        // The outer `buck2 test` may export its own BUCK* variables; an inner
        // client must not take them for its own.
        var drop = std.ArrayList([]const u8).empty;
        var it = env.iterator();
        while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, "BUCK")) try drop.append(a, try a.dupe(u8, e.key_ptr.*));
        for (drop.items) |k| env.remove(k);
        return .{
            .a = a,
            // Absolute: a command in a scratch tree runs from another directory.
            .buck2 = try std.fs.cwd().realpathAlloc(a, buck2),
            .root = try std.fs.cwd().realpathAlloc(a, "."),
            .isolation_dir = try std.fmt.allocPrint(a, "selftest_{s}", .{scenario}),
            .log_dir = log_dir,
            .env = env,
            .daemons = std.ArrayList(Daemon).empty,
        };
    }

    fn remember(self: *Runner, cwd: ?[]const u8) !void {
        for (self.daemons.items) |d| {
            if (d.cwd == null and cwd == null) return;
            if (d.cwd != null and cwd != null and std.mem.eql(u8, d.cwd.?, cwd.?)) return;
        }
        try self.daemons.append(self.a, .{ .cwd = cwd });
    }

    /// Runs `buck2 <words>` (see `argv`) and captures it.
    pub fn run(self: *Runner, words: []const []const u8, opts: Opts) !Result {
        const iso: ?[]const u8 = if (opts.cwd == null) self.isolation_dir else null;
        const cmd = try argv(self.a, self.buck2, iso, words, opts);
        if (opts.track) try self.remember(opts.cwd);
        self.n += 1;
        const log = try std.fmt.allocPrint(self.a, "{s}/{d:0>3}_{s}.log", .{ self.log_dir, self.n, words[0] });

        var child = std.process.Child.init(cmd, self.a);
        child.cwd = opts.cwd orelse self.root;
        child.env_map = &self.env;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try writeHeader(cmd, child.cwd.?, log);
        try child.spawn();
        var out = std.ArrayList(u8).empty;
        var err = std.ArrayList(u8).empty;
        const collected = child.collectOutput(self.a, &out, &err, 1 << 28);
        const term = child.wait();
        try collected;
        const t = try term;
        const exit: ?u8 = switch (t) {
            .Exited => |c| c,
            else => null,
        };
        const res = Result{
            .exit = exit,
            .stdout = out.items,
            .stderr = err.items,
            .log = log,
        };
        try writeLog(cmd, child.cwd.?, res);
        return res;
    }

    /// What the log says while the command runs.
    fn writeHeader(cmd: []const []const u8, cwd: []const u8, log: []const u8) !void {
        var f = try std.fs.cwd().createFile(log, .{});
        defer f.close();
        const w = f.deprecatedWriter();
        try w.print("cwd: {s}\nargv:", .{cwd});
        for (cmd) |c| try w.print(" {s}", .{c});
        try w.writeAll("\nexit: still running\n");
    }

    fn writeLog(cmd: []const []const u8, cwd: []const u8, r: Result) !void {
        var f = try std.fs.cwd().createFile(r.log, .{});
        defer f.close();
        const w = f.deprecatedWriter();
        try w.print("cwd: {s}\nargv:", .{cwd});
        for (cmd) |c| try w.print(" {s}", .{c});
        if (r.exit) |e| {
            try w.print("\nexit: {d}\n", .{e});
        } else {
            try w.writeAll("\nexit: signalled\n");
        }
        try w.print("---- stdout\n{s}\n---- stderr\n{s}\n", .{ r.stdout, r.stderr });
    }

    /// Reads what-ran of the last command in `cwd`: fails (error) when it
    /// lists no action, or an action that did not run on the farm. Returns
    /// the number of actions it listed.
    pub fn checkWhatRan(self: *Runner, cwd: ?[]const u8, why: *[]const u8) !usize {
        const r = try self.run(&.{ "log", "what-ran" }, .{ .configured = false, .cwd = cwd });
        if (!r.ok()) {
            why.* = try std.fmt.allocPrint(self.a, "cannot read what-ran (see {s})", .{r.log});
            return error.WhatRan;
        }
        const v = whatran.read(r.stdout);
        if (v.actions == 0) {
            why.* = try std.fmt.allocPrint(self.a, "what-ran lists no action: the build matched nothing (see {s})", .{r.log});
            return error.WhatRan;
        }
        if (v.first_local) |id| {
            why.* = try std.fmt.allocPrint(self.a, "{d} of {d} actions did not run on the farm, first {s} (see {s})", .{ v.locals, v.actions, id, r.log });
            return error.WhatRan;
        }
        return v.actions;
    }

    /// Stops every daemon this runner started.
    pub fn killAll(self: *Runner) void {
        for (self.daemons.items) |d| {
            _ = self.run(&.{"kill"}, .{ .configured = false, .cwd = d.cwd, .track = false }) catch {};
        }
        self.daemons.clearRetainingCapacity();
    }
};
