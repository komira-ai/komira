//! driver_kit: what the driver tests of the Zig action tools share (a driver
//! test is a `zig_test` with `exec_tools`: the tool under test is a built
//! executable it runs by absolute path, `KOMIRA_TEST_WORK` is its writable
//! directory). A test makes a `Ctx` per case: a directory of its own under
//! the work directory, helpers to lay files out and read them back, and `run`,
//! which runs the tool in that directory and returns its exit status and output.
//!
//! The zig 0.12 / 0.15 common subset (see tools/build/act_util/util.zig).

const std = @import("std");

pub const Result = struct { code: u8, stdout: []const u8, stderr: []const u8 };

pub const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    /// The tool under test (its absolute path).
    tool: []const u8,
    /// This case's directory: the tool's working directory.
    dir: []const u8,

    /// A case `name` for the tool named by the environment variable `tool_env`
    /// (an `exec_tools` name of the driver test).
    pub fn init(name: []const u8, tool_env: []const u8) !Ctx {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const al = arena.allocator();
        const work = try std.process.getEnvVarOwned(al, "KOMIRA_TEST_WORK");
        const dir = try std.fs.path.join(al, &.{ work, name });
        std.fs.cwd().deleteTree(dir) catch {};
        try std.fs.cwd().makePath(dir);
        const tool = try std.process.getEnvVarOwned(al, tool_env);
        return .{ .arena = arena, .tool = tool, .dir = dir };
    }

    pub fn deinit(self: *Ctx) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Ctx) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Another tool of the driver test, by its `exec_tools` name.
    pub fn env(self: *Ctx, name: []const u8) ![]const u8 {
        return std.process.getEnvVarOwned(self.alloc(), name);
    }

    /// `name` in this case's directory (absolute).
    pub fn path(self: *Ctx, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.alloc(), &.{ self.dir, name });
    }

    pub fn mkdir(self: *Ctx, name: []const u8) !void {
        try std.fs.cwd().makePath(try self.path(name));
    }

    pub fn write(self: *Ctx, name: []const u8, data: []const u8, perm: std.fs.File.Mode) !void {
        const p = try self.path(name);
        if (std.fs.path.dirname(p)) |parent| try std.fs.cwd().makePath(parent);
        const f = try std.fs.cwd().createFile(p, .{ .mode = perm });
        defer f.close();
        try f.writeAll(data);
        // createFile's mode is masked by the umask.
        try f.chmod(perm);
    }

    pub fn read(self: *Ctx, name: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(self.alloc(), try self.path(name), 1 << 24);
    }

    pub fn exists(self: *Ctx, name: []const u8) bool {
        std.fs.cwd().access(self.path(name) catch return false, .{}) catch return false;
        return true;
    }

    pub fn mode(self: *Ctx, name: []const u8) !std.fs.File.Mode {
        const st = try std.fs.cwd().statFile(try self.path(name));
        return st.mode & 0o777;
    }

    /// Runs the tool with `argv_tail` in this case's directory. `extra_env`
    /// (name, value) pairs are added to the environment, which is ours
    /// otherwise.
    pub fn run(self: *Ctx, argv_tail: []const []const u8, extra_env: []const [2][]const u8) !Result {
        return self.runTool(self.tool, argv_tail, extra_env);
    }

    pub fn runTool(self: *Ctx, tool: []const u8, argv_tail: []const []const u8, extra_env: []const [2][]const u8) !Result {
        const al = self.alloc();
        var e = try std.process.getEnvMap(al);
        for (extra_env) |kv| try e.put(kv[0], kv[1]);
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(tool);
        try argv.appendSlice(argv_tail);
        const r = try std.process.Child.run(.{ .allocator = al, .argv = argv.items, .cwd = self.dir, .env_map = &e, .max_output_bytes = 1 << 22 });
        return .{
            .code = switch (r.term) {
                .Exited => |c| c,
                else => 255,
            },
            .stdout = r.stdout,
            .stderr = r.stderr,
        };
    }
};

/// Whether `hay` holds `needle`.
pub fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}
