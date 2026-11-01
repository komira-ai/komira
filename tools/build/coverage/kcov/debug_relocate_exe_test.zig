//! The shipped debug_relocate executable as a process (README.md#tests):
//! `zig test` of this file, run as a build action by
//! `:debug_relocate_exe_test`, a validation of `:debug_relocate`. The cases in
//! debug_relocate_test.zig call the program's `entry` in-process; these run
//! the executable the public target hands out (its path in the environment
//! as DEBUG_RELOCATE, the `zig_test`'s `env_tools`) as a child process, with
//! an empty environment, and check what `main` adds: the command line taken
//! from argv[1..], the counts written to stdout and the messages to stderr,
//! and `entry`'s status as the process's exit status, and a stdout whose
//! writes fail (EFBIG) as exit 1 with the file unchanged. Without
//! DEBUG_RELOCATE every case fails: none passes without running the
//! executable.

const std = @import("std");

const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    file: []const u8,
};

/// The path of the executable under test: DEBUG_RELOCATE, which the
/// zig_test's `env_tools` sets. A run without it fails loudly; it never
/// passes unchecked.
fn tool(a: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, "DEBUG_RELOCATE") catch {
        std.debug.print("the test target does not pass DEBUG_RELOCATE (env_tools), so the executable cannot be run\n", .{});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs the executable with `args` in a directory of its own holding `f`
/// (the bytes `bytes`), and reads back its exit status, stdout, stderr and f.
fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, bytes: []const u8, args: []const []const u8) !Run {
    {
        var f = try tmp.dir.createFile("f", .{});
        defer f.close();
        try f.writeAll(bytes);
    }
    const exe = try tool(a);
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, args);
    // The child's environment is built here, empty: it does not inherit
    // DEBUG_RELOCATE or anything else of the test's.
    var env = std.process.EnvMap.init(a);
    const r = try std.process.Child.run(.{
        .allocator = a,
        .argv = argv.items,
        .cwd_dir = tmp.dir,
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("debug_relocate did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    const file = try tmp.dir.readFileAlloc(a, "f", 1 << 20);
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr, .file = file };
}

/// Exit `code`, `out` the whole of stdout, `msg` on stderr (empty: nothing),
/// and f holding `want`.
fn expect(name: []const u8, r: Run, code: u8, out: []const u8, msg: []const u8, want: []const u8) !void {
    const err_ok = if (msg.len == 0) r.stderr.len == 0 else std.mem.indexOf(u8, r.stderr, msg) != null;
    if (r.code != code or !std.mem.eql(u8, r.stdout, out) or !err_ok) {
        std.debug.print("{s}: exit {d}, want {d} with stdout '{s}' and '{s}' on stderr; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, out, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, r.file, want)) {
        std.debug.print("{s}: the file holds the wrong bytes\n", .{name});
        return error.TestUnexpectedResult;
    }
}

test "success: exit 0, the count on stdout, nothing on stderr, the file rewritten" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, "A" ++ D ++ "/x\x00", &.{ "f", D });
    try expect("success", r, 0, "1 " ++ D ++ "\n", "", "A" ++ P ++ "/x\x00");
}

test "refusal: exit 1, the refusal on stderr, nothing on stdout, the file untouched" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = D ++ "/ok\x00" ++ D ++ "x\x00";
    const r = try run(arena.allocator(), &tmp, f, &.{ "f", D });
    try expect("refusal", r, 1, "", "debug_relocate: f: " ++ D ++ " at offset 39 is followed by byte 0x78, not '/' or NUL, so the file is left unchanged\n", f);
}

test "bad usage: exit 2, the usage line on stderr, nothing on stdout, the file untouched" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = D ++ "\x00";
    const r = try run(arena.allocator(), &tmp, f, &.{ "f", "/a/b/cd" });
    try expect("bad usage", r, 2, "", "debug_relocate: directory '/a/b/cd' is 7 bytes long, under 8\nusage: debug_relocate <file> <dir>...\n", f);
}

/// A file size limit of 512 bytes with SIGXFSZ ignored, set in the child
/// only (after fork, before exec; both survive exec), and an append-mode
/// stdout already 1024 bytes long: every write to stdout fails with EFBIG,
/// as a stdout on a full disk would. The file `f` (under 512 bytes) can
/// still be rewritten. stderr is a pipe; the parent's limits are untouched.
fn runFullStdout(a: std.mem.Allocator, tmp: *std.testing.TmpDir, bytes: []const u8, args: []const []const u8) !Run {
    const posix = std.posix;
    const linux = std.os.linux;
    {
        var f = try tmp.dir.createFile("f", .{});
        defer f.close();
        try f.writeAll(bytes);
        var o = try tmp.dir.createFile("out", .{});
        defer o.close();
        var full: [1024]u8 = @splat('o');
        try o.writeAll(&full);
    }
    const out = try posix.openat(tmp.dir.fd, "out", .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0);
    defer posix.close(out);
    const exe = try tool(a);
    const argv = try a.allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = try a.dupeZ(u8, exe);
    for (args, 1..) |arg, i| argv[i] = try a.dupeZ(u8, arg);
    const envp = try a.allocSentinel(?[*:0]const u8, 0, null);
    const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
    const limit = posix.rlimit{ .cur = 512, .max = (try posix.getrlimit(.FSIZE)).max };
    const pipe = try posix.pipe2(.{ .CLOEXEC = true });
    const pid = try posix.fork();
    if (pid == 0) {
        // The child: dup2 clears close-on-exec on fds 1 and 2.
        posix.dup2(out, 1) catch linux.exit_group(126);
        posix.dup2(pipe[1], 2) catch linux.exit_group(126);
        posix.fchdir(tmp.dir.fd) catch linux.exit_group(126);
        posix.sigaction(posix.SIG.XFSZ, &ign, null);
        posix.setrlimit(.FSIZE, limit) catch linux.exit_group(126);
        switch (posix.execveZ(argv[0].?, argv.ptr, envp.ptr)) {
            else => linux.exit_group(127),
        }
    }
    posix.close(pipe[1]);
    const rd = std.fs.File{ .handle = pipe[0] };
    defer rd.close();
    const stderr = try rd.readToEndAlloc(a, 1 << 20);
    const w = posix.waitpid(pid, 0);
    if (!posix.W.IFEXITED(w.status)) {
        std.debug.print("debug_relocate did not exit: status 0x{x}; stderr:\n{s}\n", .{ w.status, stderr });
        return error.TestUnexpectedResult;
    }
    const after = try tmp.dir.readFileAlloc(a, "out", 1 << 20);
    if (after.len != 1024) {
        std.debug.print("full stdout: the stdout file grew to {d} bytes, want 1024 (the limit did not hold)\n", .{after.len});
        return error.TestUnexpectedResult;
    }
    const file = try tmp.dir.readFileAlloc(a, "f", 1 << 20);
    return .{ .code = posix.W.EXITSTATUS(w.status), .stdout = "", .stderr = stderr, .file = file };
}

test "failed stdout: a stdout whose writes fail (EFBIG) is exit 1, the file unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = "A" ++ D ++ "/x\x00";
    const r = try runFullStdout(arena.allocator(), &tmp, f, &.{ "f", D });
    try expect("failed stdout", r, 1, "", "debug_relocate: stdout: FileTooBig; f is unchanged\n", f);
}
