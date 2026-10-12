//! The git commands bisect runs, all with `-C <repo>` (or `-C <worktree>`).
//! Nothing here changes a ref, the index or the main working tree: the only
//! writes are `worktree add --detach` and `worktree remove`, whose metadata
//! git keeps under its own directory and deletes on removal.
const std = @import("std");

pub const Git = struct {
    a: std.mem.Allocator,
    git: []const u8,
    repo: []const u8,
    env: *const std.process.EnvMap,
    /// The stderr of the last command that failed, for the message.
    last_err: []const u8 = "",

    pub const Run = struct { code: ?u8, stdout: []const u8, stderr: []const u8 };

    pub fn runIn(self: *Git, dir: []const u8, args: []const []const u8) !Run {
        var argv = std.ArrayList([]const u8).init(self.a);
        try argv.appendSlice(&.{ self.git, "-C", dir });
        try argv.appendSlice(args);
        const r = std.ChildProcess.run(.{
            .allocator = self.a,
            .argv = argv.items,
            .env_map = self.env,
            .max_output_bytes = 1 << 28,
        }) catch |e| {
            self.last_err = try std.fmt.allocPrint(self.a, "cannot run {s}: {s}", .{ self.git, @errorName(e) });
            return error.Git;
        };
        const code: ?u8 = switch (r.term) {
            .Exited => |c| c,
            else => null,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// Runs `git -C <dir> <args>` and returns its stdout, or error.Git
    /// with `last_err` set when it does not exit 0.
    pub fn outputIn(self: *Git, dir: []const u8, args: []const []const u8) ![]const u8 {
        const r = try self.runIn(dir, args);
        if (r.code == null or r.code.? != 0) {
            self.last_err = try std.fmt.allocPrint(self.a, "git {s} failed: {s}", .{ args[0], std.mem.trim(u8, r.stderr, " \r\n") });
            return error.Git;
        }
        return r.stdout;
    }

    pub fn output(self: *Git, args: []const []const u8) ![]const u8 {
        return self.outputIn(self.repo, args);
    }

    /// The commit `rev` names, as a full id; null when it names none.
    pub fn commit(self: *Git, rev: []const u8) !?[]const u8 {
        const spec = try std.fmt.allocPrint(self.a, "{s}^{{commit}}", .{rev});
        const r = try self.runIn(self.repo, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", spec });
        if (r.code == null or r.code.? != 0) return null;
        return try self.a.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n"));
    }

    /// Whether `ancestor` is an ancestor of `of` (or the same commit).
    pub fn isAncestor(self: *Git, ancestor: []const u8, of: []const u8) !bool {
        const r = try self.runIn(self.repo, &.{ "merge-base", "--is-ancestor", ancestor, of });
        if (r.code) |c| {
            if (c == 0) return true;
            if (c == 1) return false;
        }
        self.last_err = try std.fmt.allocPrint(self.a, "git merge-base --is-ancestor failed: {s}", .{std.mem.trim(u8, r.stderr, " \r\n")});
        return error.Git;
    }

    /// The first-parent commits after `good` up to `bad`, oldest first; the
    /// last one is `bad`.
    pub fn firstParents(self: *Git, good: []const u8, bad: []const u8) ![]const []const u8 {
        const range = try std.fmt.allocPrint(self.a, "{s}..{s}", .{ good, bad });
        const out = try self.output(&.{ "rev-list", "--first-parent", "--reverse", range });
        var list = std.ArrayList([]const u8).init(self.a);
        var it = std.mem.tokenizeAny(u8, out, " \r\n");
        while (it.next()) |c| try list.append(c);
        return list.toOwnedSlice();
    }

    pub fn subject(self: *Git, c: []const u8) ![]const u8 {
        const out = try self.output(&.{ "log", "-1", "--format=%s", c });
        return std.mem.trim(u8, out, " \r\n");
    }

    pub fn worktreeAdd(self: *Git, path: []const u8, c: []const u8) !void {
        _ = try self.output(&.{ "worktree", "add", "--detach", "--quiet", path, c });
    }

    pub fn worktreeRemove(self: *Git, path: []const u8) !void {
        _ = try self.output(&.{ "worktree", "remove", "--force", path });
    }

    pub fn submodules(self: *Git, path: []const u8) !void {
        _ = try self.outputIn(path, &.{ "submodule", "update", "--init", "--recursive" });
    }
};
