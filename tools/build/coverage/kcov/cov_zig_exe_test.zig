//! The shipped cov_zig executable as a process (README.md#tests): `zig test`
//! of this file, run as a build action by `:cov_zig_exe_test`, a validation
//! of `:cov_zig`. The cases in cov_zig_test.zig call the program's `entry`
//! in-process over a stand-in zig; these run the executable the public
//! target hands out (module `exes`: `cov_zig`, `debug_relocate` and `zig`,
//! the pinned zig's directory) as a child process from a link directory
//! like `:cov_link`'s, and check what `main` adds (the command line taken
//! from argv[1..] and getcwd, $PWD and $BUCK_SCRATCH_PATH read, the exec of
//! a command that does not link, the messages on stderr and none on stdout,
//! `entry`'s status as the exit status) and the pinned zig end to end.

const std = @import("std");
const exes = @import("exes");

const TGT = "x86_64-linux-gnu.2.34";
const HELLO = "int value(int x) {\n    return x + 1;\n}\nint main(void) {\n    return value(-1);\n}\n";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// A temporary directory holding `link/` (zig: the shipped cov_zig;
/// debug_relocate; real/: the pinned zig's directory, unless `real` is
/// false), the zig caches under `scratch/`, and the working directory `wd/`.
const Dir = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    wd: std.fs.Dir,
    cwd: []const u8,
    env: std.process.EnvMap,

    fn init(real: bool) !Dir {
        var d = Dir{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{}), .root = "", .wd = undefined, .cwd = "", .env = undefined };
        const a = d.arena.allocator();
        d.root = try d.tmp.dir.realpathAlloc(a, ".");
        try d.tmp.dir.makePath("link");
        try d.tmp.dir.symLink(try std.fs.cwd().realpathAlloc(a, exes.cov_zig), "link/zig", .{});
        try d.tmp.dir.symLink(try std.fs.cwd().realpathAlloc(a, exes.debug_relocate), "link/debug_relocate", .{});
        if (real) try d.tmp.dir.symLink(try std.fs.cwd().realpathAlloc(a, exes.zig), "link/real", .{});
        try d.tmp.dir.makePath("wd");
        try d.tmp.dir.makePath("scratch/home");
        d.wd = try d.tmp.dir.openDir("wd", .{});
        d.cwd = try d.wd.realpathAlloc(a, ".");
        // The zig caches live in the scratch directory, outside the working
        // directory, as in a build action, and $PWD is the working directory.
        d.env = std.process.EnvMap.init(a);
        const scratch = try d.path("scratch");
        try d.env.put("BUCK_SCRATCH_PATH", scratch);
        try d.env.put("ZIG_GLOBAL_CACHE_DIR", try d.path("scratch/zig-global"));
        try d.env.put("ZIG_LOCAL_CACHE_DIR", try d.path("scratch/zig-local"));
        try d.env.put("HOME", try d.path("scratch/home"));
        try d.env.put("PWD", d.cwd);
        return d;
    }

    fn deinit(self: *Dir) void {
        self.wd.close();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn path(self: *Dir, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, rel });
    }

    /// Runs `exe` (a path under the temporary directory) with `args` in the
    /// working directory.
    fn run(self: *Dir, exe: []const u8, args: []const []const u8) !Run {
        const a = self.arena.allocator();
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(try self.path(exe));
        try argv.appendSlice(args);
        const r = try std.ChildProcess.run(.{
            .allocator = a,
            .argv = argv.items,
            .cwd_dir = self.wd,
            .env_map = &self.env,
            .max_output_bytes = 1 << 20,
        });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => {
                std.debug.print("{s} did not exit: {any}; stderr:\n{s}\n", .{ exe, r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    fn file(self: *Dir, name: []const u8) ![]const u8 {
        return self.wd.readFileAlloc(self.arena.allocator(), name, 1 << 26);
    }
};

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn placeholder(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const p = try a.alloc(u8, dir.len);
    @memset(p, '_');
    p[0] = '/';
    return p;
}

// 15. The pinned zig, end to end, as a Mojo link uses it: a C file compiled
// with line tables (-g, -c: passed through, main's exec), then linked
// through cov_zig with -Wl,--strip-debug. The binary keeps .debug_line,
// holds the placeholder of the working directory and not the directory, and
// has no compressed section (debug_relocate, which refuses one, rewrites
// nothing in a copy).
// 16. The same link through the pinned zig directly, as a release build
// runs it: no .debug_line. So case 15's line tables are cov_zig's doing.
test "15, 16. pinned zig: the link keeps .debug_line, relocated; zig alone strips it" {
    var d = try Dir.init(true);
    defer d.deinit();
    const a = d.arena.allocator();
    try d.wd.writeFile("hello.c", HELLO);
    try expect("pinned zig, compile", try d.run("link/zig", &.{ "cc", "-target", TGT, "-g", "-c", "hello.c", "-o", "hello.o" }), 0, "");
    try expect("pinned zig, link", try d.run("link/zig", &.{ "cc", "-target", TGT, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "hello.o", "-o", "hello" }), 0, "");
    const hello = try d.file("hello");
    try std.testing.expect(has(hello, ".debug_line"));
    try std.testing.expect(has(hello, try placeholder(a, d.cwd)));
    try std.testing.expect(!has(hello, d.cwd));
    try d.wd.writeFile("hello.copy", hello);
    const copy = try d.run("link/debug_relocate", &.{ "hello.copy", "/nonexistent/directory/name" });
    if (copy.code != 0) {
        std.debug.print("pinned zig: debug_relocate refused the binary (a compressed section?), exit {d}; stderr:\n{s}\n", .{ copy.code, copy.stderr });
        return error.TestUnexpectedResult;
    }

    try expect("pinned zig, release", try d.run("link/real/zig", &.{ "cc", "-target", TGT, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "hello.o", "-o", "hello_release" }), 0, "");
    try std.testing.expect(!has(try d.file("hello_release"), ".debug_line"));
}

test "refusal: exit 1, the refusal on stderr, nothing on stdout" {
    var d = try Dir.init(true);
    defer d.deinit();
    const r = try d.run("link/zig", &.{ "cc", "hello.o", "-O2", "-o", "hello" });
    try expect("refusal", r, 1, "cov_zig: a link with the optimization level -O2 is refused");
    if (d.file("hello")) |_| {
        std.debug.print("refusal: an output was written\n", .{});
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "bad usage: real/zig cannot be run, exit 2" {
    var d = try Dir.init(false);
    defer d.deinit();
    const r = try d.run("link/zig", &.{ "ar", "rcs", "lib.a" });
    try expect("bad usage", r, 2, "cov_zig: cannot run ");
}
