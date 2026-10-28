//! The shipped cov_branch executable as a process: `zig test` of this file,
//! run as a build action by `:cov_branch_exe_test`, a validation of
//! `:cov_branch_tool`. The unit tests (cov_branch_annotate_test.zig) call
//! `annotate` in-process with a stand-in Runner; these run the executable the
//! public target hands out (its path in the environment as COV_BRANCH, and
//! that of the stand-in lld and llvm-profdata of cov_branch_annotate_stub.zig
//! as COV_BRANCH_STUB, the `zig_test`'s `env_tools`) as a child process, with
//! an environment built by the test, and check what the process adds: the command line taken from
//! argv, the working directory and $BUCK_SCRATCH_PATH from the process, the
//! environment lld and llvm-profdata get, the programs run by their paths,
//! a program that cannot start, the exit status, messages on stderr and none
//! on stdout, and a stderr whose writes fail. Without COV_BRANCH or
//! COV_BRANCH_STUB every case fails: none passes without running the
//! executable.

const std = @import("std");
const fx = @import("cov_branch_annotate_fixture.zig");
const posix = std.posix;

/// The path of a tool under test, from the environment variable `name`,
/// which the zig_test's `env_tools` sets. A run without it fails loudly; it
/// never passes unchecked.
fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the executable cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// A temporary directory holding `tc/lld/bin/lld` and
/// `tc/llvm/bin/llvm-profdata` (each the stand-in), `scratch/`, and the
/// working directory `wd/` with inputs that pass every check under `in/`.
const Dir = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    wd: std.fs.Dir,
    cwd: []const u8,
    env: std.process.EnvMap,

    fn init() !*Dir {
        const d = try std.testing.allocator.create(Dir);
        d.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{}), .root = "", .wd = undefined, .cwd = "", .env = undefined };
        const al = d.arena.allocator();
        d.root = try d.tmp.dir.realpathAlloc(al, ".");
        const stub = try tool(al, "COV_BRANCH_STUB");
        try d.tmp.dir.makePath("tc/lld/bin");
        try d.tmp.dir.makePath("tc/llvm/bin");
        try d.tmp.dir.symLink(stub, "tc/lld/bin/lld", .{});
        try d.tmp.dir.symLink(stub, "tc/llvm/bin/llvm-profdata", .{});
        try d.tmp.dir.makePath("scratch");
        try d.tmp.dir.makePath("wd/in");
        try d.tmp.dir.makePath("wd/out");
        d.wd = try d.tmp.dir.openDir("wd", .{});
        d.cwd = try d.wd.realpathAlloc(al, ".");
        try d.wd.writeFile(.{ .sub_path = "in/test_one.bc", .data = try fx.bitcode(al, "body") });
        try d.wd.writeFile(.{ .sub_path = "in/test_one.profdata", .data = "indexed" });
        try d.wd.writeFile(.{ .sub_path = "in/test_one", .data = try fx.binary(al, &fx.FNS) });
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/llvm/bin/llvm-profdata.stdout", .data = try fx.show(al, &fx.FNS) });
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld.stderr", .data = try std.mem.concat(al, u8, &.{ try fx.missing(al, "unrun"), try fx.dump(al, &fx.FNS) }) });
        // The child's environment is built here: it does not inherit
        // COV_BRANCH or anything else of the test's.
        d.env = std.process.EnvMap.init(std.heap.page_allocator);
        try d.env.put("BUCK_SCRATCH_PATH", try d.path("scratch"));
        try d.env.put("LC_ALL", "fr_FR.UTF-8");
        try d.env.put("TMPDIR", "/elsewhere");
        try d.env.put("PATH", "/nonexistent");
        try d.env.put("ZED", "1");
        return d;
    }

    fn deinit(self: *Dir) void {
        self.env.deinit();
        self.wd.close();
        self.tmp.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }

    fn a(self: *Dir) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn path(self: *Dir, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.a(), &.{ self.root, rel });
    }

    /// `annotate`'s flags, every path relative to the working directory.
    fn args(_: *Dir) []const []const u8 {
        return &.{ "annotate", "--lld", "../tc/lld/bin/lld", "--profdata", "../tc/llvm/bin/llvm-profdata", "--bitcode", "in/test_one.bc", "--profile", "in/test_one.profdata", "--binary", "in/test_one", "--out", "out/test_one.ll" };
    }

    /// The shipped executable with `argv` in the working directory.
    fn run(self: *Dir, argv: []const []const u8) !Run {
        var full = std.ArrayList([]const u8).empty;
        try full.append(self.a(), try tool(self.a(), "COV_BRANCH"));
        try full.appendSlice(self.a(), argv);
        const r = try std.process.Child.run(.{
            .allocator = self.a(),
            .argv = full.items,
            .cwd_dir = self.wd,
            .env_map = &self.env,
            .max_output_bytes = 1 << 20,
        });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => {
                std.debug.print("cov_branch did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// What the stand-in recorded as `name` (`<name>.argv`, `.env`), one
    /// entry per line.
    fn recorded(self: *Dir, rel: []const u8) ![]const []const u8 {
        const t = try self.tmp.dir.readFileAlloc(self.a(), rel, 1 << 20);
        var v = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, t, '\n');
        while (it.next()) |l| try v.append(self.a(), l);
        return v.toOwnedSlice(self.a());
    }

    fn exists(self: *Dir, rel: []const u8) bool {
        self.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }
};

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

fn has(list: []const []const u8, e: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, e)) return true;
    return false;
}

fn count(list: []const []const u8, p: []const u8) usize {
    var n: usize = 0;
    for (list) |x| n += @intFromBool(std.mem.startsWith(u8, x, p));
    return n;
}

test "a passing annotation: exit 0, no message, the dump written, the scratch removed; the programs' command lines and environment" {
    var d = try Dir.init();
    defer d.deinit();
    const r = try d.run(d.args());
    try expect("pass", r, 0, "");
    try std.testing.expectEqualStrings("", r.stderr);
    try std.testing.expectEqualStrings(try fx.dump(d.a(), &fx.FNS), try d.wd.readFileAlloc(d.a(), "out/test_one.ll", 1 << 20));
    try std.testing.expect(!d.exists("scratch/cov_branch_annotate"));

    const k = try d.path("scratch/cov_branch_annotate");
    const at = struct {
        fn f(dd: *Dir, rel: []const u8) ![]const u8 {
            return std.fmt.allocPrint(dd.a(), "{s}/{s}", .{ dd.cwd, rel });
        }
    }.f;
    const show = try d.recorded("tc/llvm/bin/llvm-profdata.argv");
    const want_show = [_][]const u8{ try at(d, "../tc/llvm/bin/llvm-profdata"), "show", "--all-functions", try at(d, "in/test_one.profdata") };
    try std.testing.expectEqual(want_show.len, show.len);
    for (want_show, show) |w, g| try std.testing.expectEqualStrings(w, g);
    const lld = try d.recorded("tc/lld/bin/lld.argv");
    try std.testing.expectEqualStrings(try at(d, "../tc/lld/bin/lld"), lld[0]);
    try std.testing.expectEqualStrings(try at(d, "in/test_one.bc"), lld[6]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(d.a(), "{s}/use.o", .{k}), lld[8]);
    try std.testing.expect(has(lld, try std.fmt.allocPrint(d.a(), "-pgo-test-profile-file={s}", .{try at(d, "in/test_one.profdata")})));
    try std.testing.expect(has(lld, "--lto-newpm-passes=pgo-instr-use"));
    for ([_][]const u8{ "tc/llvm/bin/llvm-profdata.env", "tc/lld/bin/lld.env" }) |f| {
        const env = try d.recorded(f);
        try std.testing.expect(has(env, try std.fmt.allocPrint(d.a(), "PATH={s}/bin", .{k})));
        try std.testing.expect(has(env, try std.fmt.allocPrint(d.a(), "TMPDIR={s}/tmp", .{k})));
        try std.testing.expect(has(env, "LC_ALL=C"));
        try std.testing.expect(has(env, "ZED=1"));
        try std.testing.expect(has(env, try std.fmt.allocPrint(d.a(), "BUCK_SCRATCH_PATH={s}", .{try d.path("scratch")})));
        try std.testing.expectEqual(@as(usize, 1), count(env, "PATH="));
        try std.testing.expectEqual(@as(usize, 1), count(env, "TMPDIR="));
        try std.testing.expectEqual(@as(usize, 1), count(env, "LC_ALL="));
    }
}

test "the scratch directory: under a relative BUCK_SCRATCH_PATH, or in the working directory without one" {
    for ([_]?[]const u8{ "s/t", null }) |s| {
        var d = try Dir.init();
        defer d.deinit();
        if (s) |v| try d.env.put("BUCK_SCRATCH_PATH", v) else d.env.remove("BUCK_SCRATCH_PATH");
        try expect("scratch", try d.run(d.args()), 0, "");
        const k = try std.fmt.allocPrint(d.a(), "{s}/{s}", .{ d.cwd, if (s) |v| try std.fmt.allocPrint(d.a(), "{s}/cov_branch_annotate", .{v}) else ".cov_branch_annotate" });
        try std.testing.expect(has(try d.recorded("tc/lld/bin/lld.env"), try std.fmt.allocPrint(d.a(), "PATH={s}/bin", .{k})));
    }
}

test "usage errors: no subcommand, an unknown one, annotate without its flags: exit 2" {
    var d = try Dir.init();
    defer d.deinit();
    try expect("none", try d.run(&.{}), 2, "cov_branch: no subcommand");
    try expect("unknown", try d.run(&.{"frob"}), 2, "cov_branch: unknown subcommand frob");
    try expect("bare", try d.run(&.{"annotate"}), 2, "cov_branch annotate: usage error: --lld is missing");
    try std.testing.expect(!d.exists("tc/lld/bin/lld.argv"));
}

test "a missing input: exit 2, nothing run" {
    var d = try Dir.init();
    defer d.deinit();
    try d.wd.deleteFile("in/test_one");
    try expect("missing", try d.run(d.args()), 2, "cov_branch annotate: in/test_one is missing or empty");
    try std.testing.expect(!d.exists("tc/llvm/bin/llvm-profdata.argv"));
}

test "a refusal: exit 1 with its message, no dump written, the scratch kept" {
    var d = try Dir.init();
    defer d.deinit();
    try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld.stderr", .data = try std.mem.concat(d.a(), u8, &.{ "lld: warning: ld-temp.o: function control flow change detected (hash mismatch) main Hash = 1\n", try fx.dump(d.a(), &fx.FNS) }) });
    try expect("mismatch", try d.run(d.args()), 1, "BRANCH COVERAGE ANNOTATE FAILED: lld reported 1 diagnostic(s) applying the profile: lld: warning: ld-temp.o: function control flow change detected (hash mismatch)");
    try std.testing.expect(!d.exists("wd/out/test_one.ll"));
    try std.testing.expect(d.exists("scratch/cov_branch_annotate/err"));
}

test "llvm-profdata or lld failing: exit 1, lld's last lines on stderr" {
    {
        var d = try Dir.init();
        defer d.deinit();
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/llvm/bin/llvm-profdata.exit", .data = "3" });
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/llvm/bin/llvm-profdata.stderr", .data = "error: bad profile\n" });
        try expect("show", try d.run(d.args()), 1, "BRANCH COVERAGE ANNOTATE FAILED: llvm-profdata show failed on in/test_one.profdata: error: bad profile");
    }
    {
        var d = try Dir.init();
        defer d.deinit();
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld.exit", .data = "1" });
        try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld.stderr", .data = "ld.lld: error: cannot open profile\n" });
        try expect("lld", try d.run(d.args()), 1, "ld.lld: error: cannot open profile\nBRANCH COVERAGE ANNOTATE FAILED: lld could not apply the profile in/test_one.profdata to in/test_one.bc (pgo-instr-use)\n");
    }
}

test "lld's stdout is its own: what it writes there is refused, and this tool's stdout stays empty" {
    var d = try Dir.init();
    defer d.deinit();
    try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld.stdout", .data = "stray\n" });
    try expect("stdout", try d.run(d.args()), 1, "lld wrote to its standard output: stray");
}

test "a program that cannot start: exit 1, the reason on stderr" {
    var d = try Dir.init();
    defer d.deinit();
    // Not executable, not empty: the input check passes, execve does not.
    try d.tmp.dir.deleteFile("tc/lld/bin/lld");
    try d.tmp.dir.writeFile(.{ .sub_path = "tc/lld/bin/lld", .data = "not a program" });
    const r = try d.run(d.args());
    try expect("noexec", r, 1, "lld could not apply the profile");
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot run") != null);
}

/// The executable with `argv`, its stderr a file opened read-only, so that
/// every write to it fails (EBADF); stdout /dev/null. Its exit status.
fn runFailingStderr(d: *Dir, argv: []const []const u8) !u8 {
    const a = d.a();
    try d.tmp.dir.writeFile(.{ .sub_path = "ro", .data = "" });
    const ro = try posix.open(try d.path("ro"), .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(ro);
    const nul = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(nul);
    var full = std.ArrayList(?[*:0]const u8).empty;
    try full.append(a, try a.dupeZ(u8, try tool(a, "COV_BRANCH")));
    for (argv) |x| try full.append(a, try a.dupeZ(u8, x));
    try full.append(a, null);
    var envp = std.ArrayList(?[*:0]const u8).empty;
    var it = d.env.iterator();
    while (it.next()) |e| try envp.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }, 0));
    try envp.append(a, null);
    const cwd = try a.dupeZ(u8, d.cwd);
    const pid = try posix.fork();
    if (pid == 0) {
        posix.dup2(nul, 1) catch std.os.linux.exit_group(126);
        posix.dup2(ro, 2) catch std.os.linux.exit_group(126);
        posix.chdirZ(cwd) catch std.os.linux.exit_group(126);
        const argz: [*:null]const ?[*:0]const u8 = @ptrCast(full.items.ptr);
        const envz: [*:null]const ?[*:0]const u8 = @ptrCast(envp.items.ptr);
        posix.execveZ(full.items[0].?, argz, envz) catch {};
        std.os.linux.exit_group(127);
    }
    const st = posix.waitpid(pid, 0).status;
    if (!posix.W.IFEXITED(st)) return error.TestUnexpectedResult;
    return posix.W.EXITSTATUS(st);
}

test "a stderr whose writes fail does not change the exit status" {
    var d = try Dir.init();
    defer d.deinit();
    try d.wd.writeFile(.{ .sub_path = "in/test_one.bc", .data = "not bitcode" });
    try std.testing.expectEqual(@as(u8, 1), try runFailingStderr(d, d.args()));
    try std.testing.expectEqual(@as(u8, 2), try runFailingStderr(d, &.{"annotate"}));
    try d.wd.writeFile(.{ .sub_path = "in/test_one.bc", .data = try fx.bitcode(d.a(), "body") });
    try std.testing.expectEqual(@as(u8, 0), try runFailingStderr(d, d.args()));
    try std.testing.expect(d.exists("wd/out/test_one.ll"));
}
