//! The shipped cov_branch executable's `link` as a process: `zig test` of
//! this file, run as a build action by `:cov_branch_link_exe_test`, a
//! validation of `:cov_branch_tool` (what the branch coverage directories
//! take). The cases in cov_branch_link_test.zig call the subcommand
//! in-process with stand-in steps; these run the executable the public
//! target hands out (module `exes`, the `zig_test`'s `exes`) as a child,
//! over a stand-in busybox, lld and zig (cov_branch_link_stub.zig, each a
//! symbolic link to it that records its arguments and environment), and
//! check what only a process shows: the command line taken from argv, the
//! scratch directory taken from BUCK_SCRATCH_PATH, the environment each
//! step gets, both output streams of a step in the log a failure prints,
//! messages on stderr and none on stdout, the exit status, a program that
//! cannot be executed, and a failing write of stderr.

const std = @import("std");
const exes = @import("exes");
const br = @import("bounded_run.zig");
const testing = std.testing;

const ELF = "\x7fELF\x02\x01\x01\x00binary";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const Box = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",

    /// A directory holding what a link action is given: the stand-ins
    /// bb/busybox, link/lld/bin/lld and zig/zig, the profile runtime, the
    /// compiler's runtime library and a bitcode file. zig writes an ELF file.
    fn init() !Box {
        var b = Box{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        const al = b.arena.allocator();
        b.root = try b.tmp.dir.realpathAlloc(al, ".");
        const stub = try std.fs.cwd().realpathAlloc(al, exes.stub);
        for ([_][]const u8{ "bb/busybox", "link/lld/bin/lld", "zig/zig" }) |s| {
            try b.tmp.dir.makePath(std.fs.path.dirname(s).?);
            try b.tmp.dir.symLink(stub, s, .{});
        }
        try b.put("link/llvm/runtime/libclang_rt.profile-x86_64.a", "!<arch>\n");
        try b.put("tc/lib/libKGENCompilerRTShared.so", "\x7fELF");
        try b.put("test_one.bc", "BC\xc0\xde\x35\x14");
        try b.put("zig/stub_out", ELF);
        return b;
    }

    fn deinit(self: *Box) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Box) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn put(self: *Box, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(path, data);
    }

    fn p(self: *Box, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.root, rel }) catch unreachable;
    }

    fn read(self: *Box, rel: []const u8) ?[]const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), rel, 1 << 20) catch null;
    }

    fn exists(self: *Box, rel: []const u8) bool {
        self.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }

    /// `cov_branch link` with the box's inputs, relative to the box, as the
    /// rule gives them, then `extra`.
    fn linkArgs(self: *Box, extra: []const []const u8) ![]const []const u8 {
        var v = std.ArrayList([]const u8).init(self.a());
        try v.appendSlice(&.{ "link", "--busybox", "bb/busybox", "--compiler", "tc", "--zig", "zig", "--target", "x86_64-linux-gnu.2.28", "--lld", "link/lld/bin/lld", "--runtime", "link/llvm/runtime/libclang_rt.profile-x86_64.a", "--bitcode", "test_one.bc", "--out", "out/test_one" });
        try v.appendSlice(extra);
        return v.toOwnedSlice();
    }

    /// Runs the shipped executable in the box with `args` and the
    /// environment `env` (NAME, VALUE pairs; nothing else is inherited).
    fn run(self: *Box, args: []const []const u8, env: []const [2][]const u8) !Run {
        const al = self.a();
        try self.tmp.dir.makePath("out");
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(try std.fs.cwd().realpathAlloc(al, exes.cov_branch));
        try argv.appendSlice(args);
        var map = std.process.EnvMap.init(al);
        for (env) |e| try map.put(e[0], e[1]);
        const r = try std.ChildProcess.run(.{ .allocator = al, .argv = argv.items, .cwd_dir = self.tmp.dir, .env_map = &map, .max_output_bytes = 1 << 20 });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => {
                std.debug.print("cov_branch did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

const ENV = [_][2][]const u8{ .{ "BUCK_SCRATCH_PATH", "scr" }, .{ "FOO", "bar" }, .{ "LC_ALL", "fr_FR.UTF-8" }, .{ "PATH", "/usr/bin" } };

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

fn hasLine(text: ?[]const u8, line: []const u8) !void {
    var it = std.mem.splitScalar(u8, text orelse "", '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return;
    std.debug.print("no line '{s}' in:\n{s}\n", .{ line, text orelse "(no file)" });
    return error.TestUnexpectedResult;
}

fn lacksLine(text: ?[]const u8, line: []const u8) !void {
    var it = std.mem.splitScalar(u8, text orelse "", '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) {
        std.debug.print("a line '{s}' in:\n{s}\n", .{ line, text.? });
        return error.TestUnexpectedResult;
    };
}

test "a link as a process: argv, BUCK_SCRATCH_PATH, each step's command line and environment, the binary, silence, exit 0" {
    var b = try Box.init();
    defer b.deinit();
    const r = try b.run(try b.linkArgs(&.{ "--", "lib/libadd.a", "-lpthread" }), &ENV);
    try expect("link", r, 0, "");
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings(ELF, b.read("out/test_one").?);
    const k = b.p("scr/cov_branch_link");
    try testing.expect(!b.exists("scr/cov_branch_link"));

    try testing.expectEqualStrings(try std.fmt.allocPrint(b.a(), "--install\n-s\n{s}/bin\n", .{k}), b.read("bb/argv").?);
    try testing.expectEqualStrings(try std.fmt.allocPrint(b.a(),
        \\-flavor
        \\gnu
        \\-r
        \\-m
        \\elf_x86_64
        \\{s}
        \\-o
        \\{s}/pg.o
        \\--lto-O0
        \\--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>
        \\
    , .{ b.p("test_one.bc"), k }), b.read("link/lld/bin/argv").?);
    try testing.expectEqualStrings(try std.fmt.allocPrint(b.a(),
        \\cc
        \\-target
        \\x86_64-linux-gnu.2.28
        \\-Wl,--strip-debug
        \\-Wl,--enable-new-dtags
        \\-Wl,-rpath,$ORIGIN/lib
        \\{s}/pg.o
        \\{s}
        \\-o
        \\{s}
        \\-Wl,--gc-sections
        \\-lm
        \\-Wl,--whole-archive
        \\{s}
        \\-Wl,--no-whole-archive
        \\lib/libadd.a
        \\-lpthread
        \\
    , .{ k, b.p("tc/lib/libKGENCompilerRTShared.so"), b.p("out/test_one"), b.p("link/llvm/runtime/libclang_rt.profile-x86_64.a") }), b.read("zig/argv").?);

    // The install: this tool's environment as given.
    const bb_env = b.read("bb/env");
    try hasLine(bb_env, "LC_ALL=fr_FR.UTF-8");
    try hasLine(bb_env, "PATH=/usr/bin");
    // lld and zig: the scratch's directories and LC_ALL=C, the rest kept.
    for ([_][]const u8{ "link/lld/bin/env", "zig/env" }) |f| {
        const env = b.read(f);
        try hasLine(env, try std.fmt.allocPrint(b.a(), "PATH={s}/bin", .{k}));
        try hasLine(env, try std.fmt.allocPrint(b.a(), "HOME={s}/home", .{k}));
        try hasLine(env, try std.fmt.allocPrint(b.a(), "TMPDIR={s}/tmp", .{k}));
        try hasLine(env, try std.fmt.allocPrint(b.a(), "ZIG_GLOBAL_CACHE_DIR={s}/zig-global", .{k}));
        try hasLine(env, try std.fmt.allocPrint(b.a(), "ZIG_LOCAL_CACHE_DIR={s}/zig-local", .{k}));
        try hasLine(env, "LC_ALL=C");
        try hasLine(env, "FOO=bar");
        try hasLine(env, "BUCK_SCRATCH_PATH=scr");
        try lacksLine(env, "LC_ALL=fr_FR.UTF-8");
        try lacksLine(env, "PATH=/usr/bin");
        try testing.expectEqual(@as(usize, 8), std.mem.count(u8, env.?, "\n"));
    }
}

test "the scratch directory: .cov_branch_link without BUCK_SCRATCH_PATH, an absolute one as given" {
    {
        var b = try Box.init();
        defer b.deinit();
        const r = try b.run(try b.linkArgs(&.{}), &.{});
        try expect("no scratch", r, 0, "");
        try hasLine(b.read("link/lld/bin/argv"), b.p(".cov_branch_link/pg.o"));
        try testing.expect(!b.exists(".cov_branch_link"));
    }
    {
        var b = try Box.init();
        defer b.deinit();
        const abs = b.p("elsewhere");
        const r = try b.run(try b.linkArgs(&.{}), &.{.{ "BUCK_SCRATCH_PATH", abs }});
        try expect("absolute scratch", r, 0, "");
        try hasLine(b.read("link/lld/bin/argv"), b.p("elsewhere/cov_branch_link/pg.o"));
    }
}

test "lld failing: exit 1, its stdout and stderr in the log printed, zig not run, the scratch kept" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("link/lld/bin/stub_rc", "1");
    try b.put("link/lld/bin/say", "cannot read the bitcode");
    const r = try b.run(try b.linkArgs(&.{}), &ENV);
    try expect("lld fails", r, 1, "BRANCH COVERAGE LINK FAILED: lld could not instrument test_one.bc (pgo-instr-gen)\n--- log:\n");
    try expect("lld fails", r, 1, "stdout: cannot read the bitcode\n");
    try expect("lld fails", r, 1, "stderr: cannot read the bitcode\n");
    try testing.expect(!b.exists("zig/argv"));
    try testing.expect(b.exists("scr/cov_branch_link/log"));
}

test "zig failing, an output that is not ELF, or one holding the working directory: exit 1, each named" {
    {
        var b = try Box.init();
        defer b.deinit();
        try b.put("zig/stub_rc", "3");
        try b.put("zig/say", "ld.lld: error: undefined symbol: komira_example_add");
        const r = try b.run(try b.linkArgs(&.{}), &ENV);
        try expect("zig fails", r, 1, "BRANCH COVERAGE LINK FAILED: zig could not link the instrumented test with the profile runtime\n--- log:\nstdout: ld.lld: error: undefined symbol: komira_example_add\n");
    }
    {
        var b = try Box.init();
        defer b.deinit();
        try b.put("zig/stub_out", "#!/bin/sh\n");
        const r = try b.run(try b.linkArgs(&.{}), &ENV);
        try expect("not ELF", r, 1, "BRANCH COVERAGE LINK FAILED: the link wrote no ELF file\n");
    }
    {
        var b = try Box.init();
        defer b.deinit();
        try b.put("zig/stub_out", try std.fmt.allocPrint(b.a(), "{s}\x00{s}/zig_cc.c\x00", .{ ELF, b.root }));
        const r = try b.run(try b.linkArgs(&.{}), &ENV);
        try expect("holds the directory", r, 1, try std.fmt.allocPrint(b.a(), "BRANCH COVERAGE LINK FAILED: the binary holds this action's directory {s}: {s}/zig_cc.c \n", .{ b.root, b.root }));
    }
}

test "a bitcode that is not, an lld that cannot be executed: exit 1" {
    {
        var b = try Box.init();
        defer b.deinit();
        try b.put("test_one.bc", "\x7fELF\x02");
        const r = try b.run(try b.linkArgs(&.{}), &ENV);
        try expect("not bitcode", r, 1, "BRANCH COVERAGE LINK FAILED: test_one.bc is not LLVM bitcode\n");
        try testing.expect(!b.exists("link/lld/bin/argv"));
    }
    {
        var b = try Box.init();
        defer b.deinit();
        try b.tmp.dir.deleteFile("link/lld/bin/lld");
        try b.put("link/lld/bin/lld", "not a program");
        const r = try b.run(try b.linkArgs(&.{}), &ENV);
        try expect("lld not executable", r, 1, "lld could not instrument test_one.bc (pgo-instr-gen)\n--- log:\nbounded_run: cannot run ");
    }
}

test "usage errors and missing inputs: exit 2" {
    var b = try Box.init();
    defer b.deinit();
    try expect("no subcommand", try b.run(&.{}, &ENV), 2, "cov_branch: no subcommand");
    try expect("unknown subcommand", try b.run(&.{"lnk"}, &ENV), 2, "cov_branch: unknown subcommand lnk");
    try expect("no flags", try b.run(&.{"link"}, &ENV), 2, "cov_branch link: usage error: --busybox is missing");
    try expect("unknown flag", try b.run(try b.linkArgs(&.{ "--env", "A=1" }), &ENV), 2, "cov_branch link: usage error: unknown argument --env");
    try b.tmp.dir.deleteFile("tc/lib/libKGENCompilerRTShared.so");
    const r = try b.run(try b.linkArgs(&.{}), &ENV);
    try expect("missing input", r, 2, try std.fmt.allocPrint(b.a(), "cov_branch link: {s} is missing or empty\n", .{b.p("tc/lib/libKGENCompilerRTShared.so")}));
    try testing.expect(!b.exists("bb/argv"));
}

test "stderr that cannot be written: the exit status is the link's all the same" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("zig/stub_rc", "1");
    const a = b.a();
    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(try std.fs.cwd().realpathAlloc(a, exes.cov_branch));
    try argv.appendSlice(&.{ "link", "--busybox", b.p("bb/busybox"), "--compiler", b.p("tc"), "--zig", b.p("zig"), "--target", "t", "--lld", b.p("link/lld/bin/lld"), "--runtime", b.p("link/llvm/runtime/libclang_rt.profile-x86_64.a"), "--bitcode", b.p("test_one.bc"), "--out", b.p("test_one") });
    const env = [_][]const u8{try std.fmt.allocPrint(a, "BUCK_SCRATCH_PATH={s}", .{b.p("scr")})};
    const out = b.p("stdout");
    const red = try br.run(a, .{ .argv = argv.items, .env = &env, .stdout_path = out, .stderr_path = "/dev/full" });
    try testing.expectEqual(@as(u8, 1), red.shellStatus());
    try b.tmp.dir.deleteFile("zig/stub_rc");
    try b.tmp.dir.deleteTree("scr");
    const green = try br.run(a, .{ .argv = argv.items, .env = &env, .stdout_path = "/dev/full", .stderr_path = "/dev/full" });
    try testing.expectEqual(@as(u8, 0), green.shellStatus());
    try testing.expectEqualStrings("", b.read("stdout").?);
}
