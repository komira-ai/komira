//! The process behaviour of the rustc launcher (tools/build/rust/rustc_launch.zig),
//! over a stand-in rustc and zig (fake.zig): what rustc is given, the
//! environment it sees, the exit statuses, the output checks, the linker shim
//! and the refusals. Each case runs the launcher with its own scratch directory
//! (BUCK_SCRATCH_PATH) inside the test's work directory, so the launcher's
//! removal of its scratch never touches the test's.
const std = @import("std");
const t = std.testing;
const a = t.allocator;

const Tools = struct {
    launch: []const u8,
    fake: []const u8,
    busybox: []const u8,
    work: []const u8,

    fn init() !Tools {
        return .{
            .launch = try std.process.getEnvVarOwned(a, "LAUNCH"),
            .fake = try std.process.getEnvVarOwned(a, "FAKE"),
            .busybox = try std.process.getEnvVarOwned(a, "BUSYBOX"),
            .work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK"),
        };
    }

    fn deinit(self: Tools) void {
        a.free(self.launch);
        a.free(self.fake);
        a.free(self.busybox);
        a.free(self.work);
    }
};

/// One launcher run: a fresh directory `case` in the work directory holding
/// the working directory `cwd`, the sysroot `sys` (bin/rustc is the stand-in)
/// and the zig directory `zig` (zig is the stand-in), and the launcher's
/// result.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    cwd: []const u8,
    sys: []const u8,
    zig: []const u8,
    log: []const u8,
    exit: u8 = 0,
    stderr: []const u8 = "",

    fn init(tools: Tools, name: []const u8) !Case {
        var arena = std.heap.ArenaAllocator.init(a);
        const al = arena.allocator();
        const dir = try std.fs.path.join(al, &.{ tools.work, name });
        const cwd = try std.fs.path.join(al, &.{ dir, "cwd" });
        const sys = try std.fs.path.join(al, &.{ dir, "sys" });
        const zig = try std.fs.path.join(al, &.{ dir, "zig" });
        try std.fs.cwd().makePath(cwd);
        try std.fs.cwd().makePath(try std.fs.path.join(al, &.{ sys, "bin" }));
        try std.fs.cwd().makePath(zig);
        try std.fs.cwd().copyFile(tools.fake, std.fs.cwd(), try std.fs.path.join(al, &.{ sys, "bin", "rustc" }), .{});
        try std.fs.cwd().copyFile(tools.fake, std.fs.cwd(), try std.fs.path.join(al, &.{ zig, "zig" }), .{});
        // Every allocation is made before the arena is copied into the result.
        const log = try std.fs.path.join(al, &.{ dir, "fake.log" });
        return .{ .arena = arena, .dir = dir, .cwd = cwd, .sys = sys, .zig = zig, .log = log };
    }

    fn deinit(self: *Case) void {
        self.arena.deinit();
    }

    /// Runs the launcher in `cwd` with `args` (after the launcher's name).
    fn run(self: *Case, tools: Tools, mode: []const u8, args: []const []const u8) !void {
        const al = self.arena.allocator();
        var env = try std.process.getEnvMap(al);
        try env.put("BUCK_SCRATCH_PATH", try std.fs.path.join(al, &.{ self.dir, "scratch" }));
        try env.put("FAKE_LOG", self.log);
        try env.put("FAKE_MODE", mode);
        try env.put("FAKE_OUT", "out.rlib");
        // What the launcher must clear, and what it must keep.
        try env.put("LD_LIBRARY_PATH", "/not/a/dir");
        try env.put("LD_PRELOAD", "/not/a/lib.so");
        try env.put("RUSTFLAGS", "-Cprefer-dynamic");
        try env.put("RUSTC_BOOTSTRAP", "1");
        try env.put("KEPT", "kept-value");
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(tools.launch);
        try argv.appendSlice(args);
        const r = try std.process.Child.run(.{ .allocator = al, .argv = argv.items, .cwd = self.cwd, .env_map = &env });
        self.exit = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        self.stderr = r.stderr;
        if (r.stderr.len > 0) std.debug.print("[launcher stderr] {s}\n", .{r.stderr});
    }

    /// The standard command line: the stand-in rustc, the stand-in zig, output `out.rlib`.
    fn standard(self: *Case, tools: Tools, mode: []const u8) !void {
        try self.run(tools, mode, &.{ tools.busybox, self.sys, self.zig, "x86_64-linux-gnu.2.34", "out.rlib", "--", "--crate-name=a", "-o", "out.rlib", "lib.rs" });
    }

    fn logText(self: *Case) ![]const u8 {
        return std.fs.cwd().readFileAlloc(self.arena.allocator(), self.log, 1 << 20);
    }

    fn expectLine(self: *Case, line: []const u8) !void {
        const text = try self.logText();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (std.mem.eql(u8, l, line)) return;
        }
        std.debug.print("no line `{s}` in:\n{s}\n", .{ line, text });
        return error.NoSuchLine;
    }

    fn lineWithPrefix(self: *Case, prefix: []const u8) ![]const u8 {
        const text = try self.logText();
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (std.mem.startsWith(u8, l, prefix)) return l[prefix.len..];
        }
        std.debug.print("no line starting `{s}` in:\n{s}\n", .{ prefix, text });
        return error.NoSuchLine;
    }
};

test "rustc is given the sysroot, the shim, no rust-lld, the remap and then the caller's arguments" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "args");
    defer c.deinit();
    try c.standard(tools, "ok");
    try t.expectEqual(@as(u8, 0), c.exit);
    const al = c.arena.allocator();
    const cwd = try std.fs.cwd().realpathAlloc(al, c.cwd);
    const shim = try std.fs.path.join(al, &.{ c.dir, "scratch", "komira", "cc", "cc" });
    const expected = try std.fmt.allocPrint(al,
        \\arg=--sysroot
        \\arg={s}
        \\arg=-C
        \\arg=linker={s}
        \\arg=-C
        \\arg=linker-features=-lld
        \\arg=--remap-path-prefix={s}=.
        \\arg=--crate-name=a
        \\arg=-o
        \\arg=out.rlib
        \\arg=lib.rs
        \\cwd={s}
        \\
    , .{ c.sys, shim, cwd, cwd });
    const text = try c.logText();
    try t.expect(std.mem.startsWith(u8, text, expected));
    // The output is there, and the scratch directory is gone.
    _ = try std.fs.cwd().statFile(try std.fs.path.join(al, &.{ c.cwd, "out.rlib" }));
    try t.expectError(error.FileNotFound, std.fs.cwd().statFile(try std.fs.path.join(al, &.{ c.dir, "scratch", "komira" })));
}

test "rustc's environment: private directories, the applets as PATH, the four variables cleared" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "env");
    defer c.deinit();
    try c.standard(tools, "ok");
    try t.expectEqual(@as(u8, 0), c.exit);
    const al = c.arena.allocator();
    const s = try std.fs.path.join(al, &.{ c.dir, "scratch", "komira" });
    const want = [_][2][]const u8{
        .{ "PATH", "bin" },
        .{ "HOME", "home" },
        .{ "TMPDIR", "tmp" },
        .{ "XDG_CACHE_HOME", "cache" },
        .{ "ZIG_GLOBAL_CACHE_DIR", "cache/zig-global" },
        .{ "ZIG_LOCAL_CACHE_DIR", "cache/zig-local" },
    };
    for (want) |w| {
        const line = try std.fmt.allocPrint(al, "env {s}={s}/{s}", .{ w[0], s, w[1] });
        try c.expectLine(line);
    }
    for ([_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "RUSTFLAGS", "RUSTC_BOOTSTRAP" }) |name| {
        try c.expectLine(try std.fmt.allocPrint(al, "env {s}=(unset)", .{name}));
    }
    // Anything else is inherited.
    try c.expectLine("env KEPT=kept-value");
    try c.expectLine("applet cat=yes");
}

test "rustc's exit status is the launcher's, and 128 + N for a signal" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "exit");
    defer c.deinit();
    try c.standard(tools, "exit:7");
    try t.expectEqual(@as(u8, 7), c.exit);
    var d = try Case.init(tools, "signal");
    defer d.deinit();
    try d.standard(tools, "signal");
    try t.expectEqual(@as(u8, 137), d.exit);
}

test "rustc exits 0 with no output, or an empty one: exit 3" {
    const tools = try Tools.init();
    defer tools.deinit();
    for ([_][]const u8{ "none", "empty_file" }) |mode| {
        var c = try Case.init(tools, mode);
        defer c.deinit();
        try c.standard(tools, mode);
        try t.expectEqual(@as(u8, 3), c.exit);
        try t.expect(std.mem.indexOf(u8, c.stderr, "rustc exited 0 but out.rlib is missing or empty") != null);
    }
}

test "an output holding the working directory: exit 4" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "cwd");
    defer c.deinit();
    try c.standard(tools, "cwd");
    try t.expectEqual(@as(u8, 4), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "out.rlib contains this action's working directory (") != null);
}

test "a failing rustc is not checked for its output" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "failing");
    defer c.deinit();
    try c.standard(tools, "exit:1");
    try t.expectEqual(@as(u8, 1), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "missing or empty") == null);
}

test "the linker shim runs zig cc for the target, stripping debug sections, with the linker's arguments" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "link");
    defer c.deinit();
    try c.standard(tools, "link");
    try t.expectEqual(@as(u8, 0), c.exit);
    const text = try c.logText();
    const want =
        \\zig-arg=cc
        \\zig-arg=-target
        \\zig-arg=x86_64-linux-gnu.2.34
        \\zig-arg=-Wl,--strip-debug
        \\zig-arg=a.o
        \\zig-arg=-o
        \\zig-arg=a.out
        \\
    ;
    try t.expect(std.mem.indexOf(u8, text, want) != null);
    try c.expectLine("linker-exit=0");
}

test "refusals: a sysroot without rustc, a zig directory without zig, no separator, too few arguments" {
    const tools = try Tools.init();
    defer tools.deinit();
    var c = try Case.init(tools, "refuse");
    defer c.deinit();
    // A sysroot with no bin/rustc.
    const empty_sys = try std.fs.path.join(c.arena.allocator(), &.{ c.dir, "empty_sys" });
    try std.fs.cwd().makePath(empty_sys);
    try c.run(tools, "ok", &.{ tools.busybox, empty_sys, c.zig, "tgt", "out.rlib", "--", "lib.rs" });
    try t.expectEqual(@as(u8, 2), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "REFUSING: ") != null);
    try t.expect(std.mem.indexOf(u8, c.stderr, "/bin/rustc is missing") != null);
    // A zig directory with no zig.
    const empty_zig = try std.fs.path.join(c.arena.allocator(), &.{ c.dir, "empty_zig" });
    try std.fs.cwd().makePath(empty_zig);
    try c.run(tools, "ok", &.{ tools.busybox, c.sys, empty_zig, "tgt", "out.rlib", "--", "lib.rs" });
    try t.expectEqual(@as(u8, 2), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "REFUSING: link driver ") != null);
    // No `--`.
    try c.run(tools, "ok", &.{ tools.busybox, c.sys, c.zig, "tgt", "out.rlib", "lib.rs" });
    try t.expectEqual(@as(u8, 2), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "expected -- before rustc arguments") != null);
    // Too few arguments.
    try c.run(tools, "ok", &.{ tools.busybox, c.sys });
    try t.expectEqual(@as(u8, 2), c.exit);
    try t.expect(std.mem.indexOf(u8, c.stderr, "usage error") != null);
}
