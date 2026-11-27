//! How the driver runs the pinned npm: `<node> <npm>/bin/npm-cli.js <verb> ...`, the Node.js of
//! //third_party/node:node and the npm CLI of //third_party/node:npm (npm 11.20.0, which trusted publishing
//! needs at 11.5.1 or later under Node 22.14 or later), as the build job hands them on. Every command names the
//! public registry and config files of its own work directory, written empty, so no npmrc of the runner is
//! read and no token can come from one.
//!
//! Commands run through a `Runner`, so the cases run an npm in memory; the real one is a child process with the
//! environment of this one (the publish job's OIDC request variables among it: npm exchanges them for a
//! publish token itself).
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The registry every command names.
pub const registry = "https://registry.npmjs.org/";

/// The most of a command's stdout and stderr a run keeps.
pub const max_output_bytes: usize = 16 * 1024 * 1024;

/// How a command ended.
pub const Ran = struct {
    /// The exit status; null when the command did not exit (a signal, or stopped).
    code: ?u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Runs `argv` in `cwd`. An error is a command that could not be started or read.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran,

    pub fn run(self: Runner, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        return self.runFn(self.ctx, a, argv, cwd);
    }
};

/// The runner of the command line: a child process with the environment of this one, no stdin, and stdout and
/// stderr kept up to `max_output` bytes each (more is an error of the run).
pub const Process = struct {
    max_output: usize = max_output_bytes,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = runChild };
    }

    fn runChild(ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = self.max_output });
        const code: ?u8 = switch (r.term) {
            .Exited => |c| c,
            else => null,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

/// The pinned tools and the directory a command keeps its config and cache in.
pub const Tools = struct {
    /// The node executable.
    node: []const u8,
    /// The npm CLI's package directory (it holds bin/npm-cli.js).
    npm: []const u8,
    /// A directory of the run's own: npmrc, npmrc-global and npm-cache are made in it.
    work: []const u8,

    /// The empty config files every command names, written once before the first command.
    pub fn prepare(self: Tools, a: Allocator, why: *[]const u8) Error!void {
        std.fs.cwd().makePath(self.work) catch |e| return refuse(a, why, "cannot make --work {s}: {s}", .{ self.work, @errorName(e) });
        try common.writeFile(a, why, try std.fs.path.join(a, &.{ self.work, "npmrc" }), "");
        try common.writeFile(a, why, try std.fs.path.join(a, &.{ self.work, "npmrc-global" }), "");
    }

    /// `node <npm>/bin/npm-cli.js` and `verb`, then the registry, the config files and the cache of `work`.
    pub fn argv(self: Tools, a: Allocator, verb: []const []const u8) Error![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        try out.append(a, self.node);
        try out.append(a, try std.fs.path.join(a, &.{ self.npm, "bin", "npm-cli.js" }));
        try out.appendSlice(a, verb);
        try out.append(a, "--registry=" ++ registry);
        try out.append(a, try std.fmt.allocPrint(a, "--userconfig={s}/npmrc", .{self.work}));
        try out.append(a, try std.fmt.allocPrint(a, "--globalconfig={s}/npmrc-global", .{self.work}));
        try out.append(a, try std.fmt.allocPrint(a, "--cache={s}/npm-cache", .{self.work}));
        try out.append(a, "--no-update-notifier");
        try out.append(a, "--no-audit");
        try out.append(a, "--no-fund");
        try out.append(a, "--loglevel=warn");
        return out.toOwnedSlice(a);
    }
};

/// Runs `argv` in `cwd`; refused, naming `what` and the command, when it cannot be started.
pub fn run(a: Allocator, why: *[]const u8, runner: Runner, what: []const u8, argv: []const []const u8, cwd: []const u8) Error!Ran {
    return runner.run(a, argv, cwd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "{s}: cannot run {s}: {s}", .{ what, try std.mem.join(a, " ", argv), @errorName(e) }),
    };
}

/// The refusal of a command that ended other than with status 0: what it was, the command, how it ended and
/// the last lines of its stderr.
pub fn failed(a: Allocator, why: *[]const u8, what: []const u8, argv: []const []const u8, r: Ran) Error {
    const status = if (r.code) |c| try std.fmt.allocPrint(a, "exit status {d}", .{c}) else "no exit status (a signal)";
    return refuse(a, why, "{s} failed: {s} ended with {s}:\n{s}", .{ what, try std.mem.join(a, " ", argv), status, try common.lastLines(a, r.stderr, 12) });
}
