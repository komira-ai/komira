//! The shipped cov_zig executable as a process (README.md#tests): `zig test`
//! of this file, run as a build action by `:cov_zig_exe_test`, a validation
//! of `:cov_zig`. The cases in cov_zig_test.zig call the program's `entry`
//! in-process over a stand-in zig; these run the executable the public
//! target hands out (the zig_test's `env_tools`, paths in the environment:
//! COV_ZIG, DEBUG_RELOCATE, PINNED_ZIG the pinned zig's directory, and
//! COV_ZIG_STUB the stand-in zig of cov_zig_test.zig; without them every
//! case fails) as a child process, with an environment built here, from a
//! link directory like `:cov_link`'s, and check what `main` adds (the
//! command line taken from argv[1..] and getcwd, $PWD and $BUCK_SCRATCH_PATH
//! read from the process's environment, the exec of a command that does not
//! link, the messages on stderr and none on stdout, `entry`'s status as the
//! exit status) and the pinned zig end to end.

const std = @import("std");
const elf = @import("cov_zig_elf.zig").elf;

const TGT = "x86_64-linux-gnu.2.34";

/// The path of a tool the test runs, from the environment variable `name`,
/// which the zig_test's `env_tools` sets. A run without it fails loudly; it
/// never passes unchecked.
fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the tool cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}
const HELLO = "int value(int x) {\n    return x + 1;\n}\nint main(void) {\n    return value(-1);\n}\n";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// What `link/real` is: the pinned zig's directory, a directory whose `zig`
/// is the stand-in (cov_zig_stub.zig), or nothing.
const Real = enum { zig, stub, none };

/// A temporary directory holding `link/` (zig: the shipped cov_zig;
/// debug_relocate; real/ as `real` says), the zig caches under `scratch/`,
/// and the working directory `wd/`.
const Dir = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    wd: std.fs.Dir,
    cwd: []const u8,
    env: std.process.EnvMap,

    fn init(real: Real) !Dir {
        var d = Dir{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{}), .root = "", .wd = undefined, .cwd = "", .env = undefined };
        const a = d.arena.allocator();
        d.root = try d.tmp.dir.realpathAlloc(a, ".");
        try d.tmp.dir.makePath("link");
        try d.tmp.dir.symLink(try tool(a, "COV_ZIG"), "link/zig", .{});
        try d.tmp.dir.symLink(try tool(a, "DEBUG_RELOCATE"), "link/debug_relocate", .{});
        switch (real) {
            .zig => try d.tmp.dir.symLink(try tool(a, "PINNED_ZIG"), "link/real", .{}),
            .stub => {
                try d.tmp.dir.makePath("link/real");
                try d.tmp.dir.symLink(try tool(a, "COV_ZIG_STUB"), "link/real/zig", .{});
            },
            .none => {},
        }
        try d.tmp.dir.makePath("wd");
        try d.tmp.dir.makePath("scratch/home");
        d.wd = try d.tmp.dir.openDir("wd", .{});
        d.cwd = try d.wd.realpathAlloc(a, ".");
        // The zig caches live in the scratch directory, outside the working
        // directory, as in a build action, and $PWD is the working directory.
        // Not the arena's allocator: `d` is returned by value, and the map
        // would keep a pointer to this frame's copy of the arena.
        d.env = std.process.EnvMap.init(std.heap.page_allocator);
        const scratch = try d.path("scratch");
        try d.env.put("BUCK_SCRATCH_PATH", scratch);
        try d.env.put("ZIG_GLOBAL_CACHE_DIR", try d.path("scratch/zig-global"));
        try d.env.put("ZIG_LOCAL_CACHE_DIR", try d.path("scratch/zig-local"));
        try d.env.put("HOME", try d.path("scratch/home"));
        try d.env.put("PWD", d.cwd);
        return d;
    }

    fn deinit(self: *Dir) void {
        self.env.deinit();
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

    /// An ELF file with a .debug_line section holding `payload` and a NUL,
    /// then `tail`, as what the stand-in copies to the link's output.
    fn fixture(self: *Dir, payload: []const u8, tail: []const u8) !void {
        const a = self.arena.allocator();
        const p = try std.mem.concat(a, u8, &.{ payload, "\x00" });
        try self.tmp.dir.writeFile("fx", try std.mem.concat(a, u8, &.{ try elf(a, ".debug_line", 0, p), tail }));
        try self.tmp.dir.writeFile("link/real/stub_out", try self.path("fx"));
    }

    /// `name`, a symbolic link to the working directory, as an absolute path
    /// that is not the working directory's own (the logical spelling).
    fn viaLink(self: *Dir, name: []const u8) ![]const u8 {
        try self.tmp.dir.symLink(self.cwd, name, .{});
        const l = try self.path(name);
        try std.testing.expect(!std.mem.eql(u8, l, self.cwd));
        return l;
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
    var d = try Dir.init(.zig);
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
    var d = try Dir.init(.zig);
    defer d.deinit();
    const r = try d.run("link/zig", &.{ "cc", "hello.o", "-O2", "-o", "hello" });
    try expect("refusal", r, 1, "cov_zig: a link with the optimization level -O2 is refused");
    if (d.file("hello")) |_| {
        std.debug.print("refusal: an output was written\n", .{});
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "bad usage: real/zig cannot be run, exit 2" {
    var d = try Dir.init(.none);
    defer d.deinit();
    const r = try d.run("link/zig", &.{ "ar", "rcs", "lib.a" });
    try expect("bad usage", r, 2, "cov_zig: cannot run ");
}

// The process cases over the stand-in zig: the shipped executable reads
// $PWD and $BUCK_SCRATCH_PATH from its own environment (the unit cases hand
// them to `entry`). The working directory is the physical `wd/`; $PWD is a
// path to it through a symbolic link, as a shell that changed into it by
// that path sets it; $BUCK_SCRATCH_PATH is `scratch/`, outside it.

// 11, as a process: the output names the physical path, $PWD and the
// scratch directory; all three are relocated, exit 0.
test "process 11. logical: $PWD and $BUCK_SCRATCH_PATH from the environment relocated" {
    var d = try Dir.init(.stub);
    defer d.deinit();
    const a = d.arena.allocator();
    const l = try d.viaLink("via_link");
    const s = d.env.get("BUCK_SCRATCH_PATH").?;
    try std.testing.expect(!std.mem.startsWith(u8, s, try std.mem.concat(a, u8, &.{ d.cwd, "/" })));
    try d.env.put("PWD", l);
    try d.fixture(d.cwd, try std.mem.concat(a, u8, &.{ l, "/b.mojo\x00", s, "/zig/crt.c\x00" }));
    try expect("process logical", try d.run("link/zig", &.{ "cc", "a.o", "-o", "out" }), 0, "");
    const out = try d.file("out");
    for ([_][]const u8{ d.cwd, l, s }) |dir| {
        if (has(out, dir)) std.debug.print("process logical: the output still holds {s}\n", .{dir});
        try std.testing.expect(!has(out, dir));
    }
}

// 12, as a process: the output names only $PWD, never the physical path. It
// counts as the working directory, so the link passes: exit 0.
test "process 12. logical only: $PWD from the environment counts as the working directory" {
    var d = try Dir.init(.stub);
    defer d.deinit();
    const l = try d.viaLink("via_link2");
    try d.env.put("PWD", l);
    try d.fixture(l, "");
    try expect("process logical only", try d.run("link/zig", &.{ "cc", "a.o", "-o", "out" }), 0, "");
    const out = try d.file("out");
    try std.testing.expect(!has(out, l));
    try std.testing.expect(has(out, try placeholder(d.arena.allocator(), l)));
}

// 13, as a process: the output names only $BUCK_SCRATCH_PATH ($PWD is the
// physical path). It is relocated, but it is not the working directory, so
// the link fails: exit 1.
test "process 13. scratch only: $BUCK_SCRATCH_PATH from the environment relocated, exit 1" {
    var d = try Dir.init(.stub);
    defer d.deinit();
    const s = d.env.get("BUCK_SCRATCH_PATH").?;
    try d.fixture(try std.mem.concat(d.arena.allocator(), u8, &.{ s, "/zig/crt.c" }), "");
    try expect("process scratch only", try d.run("link/zig", &.{ "cc", "a.o", "-o", "out" }), 1, "has debug sections but holds the working directory");
    try std.testing.expect(!has(try d.file("out"), s));
}
