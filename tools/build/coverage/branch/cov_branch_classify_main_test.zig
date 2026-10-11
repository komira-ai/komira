//! What cov_branch_classify's `main` adds (README.md#tests): bad usage (the
//! shell's case 10), and an output file whose write fails. The other case
//! files check exit 0 and 1 with their messages on stderr and nothing on
//! stdout; these check exit 2 with the message and the usage line, and a
//! write of the output that fails (EFBIG) as exit 1 with nothing written.
//! The executable reads no environment variable: the cases run it with an
//! empty environment.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

const OUT = h.OUT;
const MAP = h.MAP;
const STD = h.STD;
const IR = [_][]const u8{ "--ir", "v.ll" };
const IO = IR ++ [_][]const u8{ "--out", OUT };

const Usage = struct { args: []const []const u8, msg: []const u8 };

// 10. Bad usage exits 2, the message and the usage line on stderr, nothing
// written. Kills: a flag's check dropped (the run going on), the exit
// status of bad usage taken for a refusal's.
const usages = [_]Usage{
    .{ .args = &([_][]const u8{ "--out", OUT } ++ MAP ++ STD), .msg = "--ir is required" },
    .{ .args = &(IR ++ MAP ++ STD), .msg = "--out is required" },
    .{ .args = &(IO ++ STD), .msg = "--map is required" },
    .{ .args = &(IO ++ [_][]const u8{ "--map", h.SRC ++ "=src/pkg/" } ++ STD), .msg = "--map PREFIX '" ++ h.SRC ++ "' must end with '/'" },
    .{ .args = &(IO ++ [_][]const u8{ "--map", h.SRC ++ "/=/abs/" } ++ STD), .msg = "--map REPO '/abs/' must be empty or relative and end with '/'" },
    .{ .args = &(IO ++ MAP ++ MAP ++ STD), .msg = "--map given twice" },
    .{ .args = &(IO ++ MAP ++ STD ++ [_][]const u8{ "--frobnicate", "x" }), .msg = "unknown flag '--frobnicate'" },
    .{ .args = &(IO ++ MAP ++ STD ++ [_][]const u8{ "--exclude", "oss" }), .msg = "--exclude 'oss' must end with '/'" },
    .{ .args = &(IO ++ MAP ++ STD ++ [_][]const u8{ "--gen", "/abs" }), .msg = "--gen '/abs' must be a relative path" },
    .{ .args = &(IO ++ MAP), .msg = "--stdlib is required" },
    .{ .args = &(IO ++ MAP ++ STD ++ STD), .msg = "--stdlib given twice" },
    .{ .args = &(IO ++ MAP ++ [_][]const u8{ "--stdlib", "oss" }), .msg = "--stdlib 'oss' must end with '/'" },
};

test "10 bad usage: exit 2, the message and the usage line on stderr, nothing written" {
    for (usages) |u| {
        var c = try h.Case.init(u.msg);
        defer c.deinit();
        try c.write("v.ll", h.case_ll);
        const r = try c.exec(u.args);
        try r.exits(2);
        try r.says(try std.mem.concat(c.a(), u8, &.{ "cov_branch_classify: ", u.msg, "\nusage: cov_branch_classify --ir <test.ll> --out <file> --map <PREFIX>=<REPO>\n" }));
        try r.nothing_written();
    }
}

/// The executable run as Case.exec runs it, but with a file size limit of
/// 512 bytes and SIGXFSZ ignored, set in the child only (after fork, before
/// exec; both survive exec): the output (case.golden.info, 1127 bytes)
/// cannot be written whole, as on a full disk. stdout and stderr are pipes
/// read after the child exits (it writes little to either).
fn runLimited(c: *h.Case, args: []const []const u8) !h.Run {
    const posix = std.posix;
    const linux = std.os.linux;
    const al = c.a();
    const exe = try h.tool(al);
    const argv = try al.allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = try al.dupeZ(u8, exe);
    for (args, 1..) |arg, i| argv[i] = try al.dupeZ(u8, arg);
    const envp = try al.allocSentinel(?[*:0]const u8, 0, null);
    const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
    const limit = posix.rlimit{ .cur = 512, .max = (try posix.getrlimit(.FSIZE)).max };
    const out = try posix.pipe2(.{ .CLOEXEC = true });
    const err = try posix.pipe2(.{ .CLOEXEC = true });
    const pid = try posix.fork();
    if (pid == 0) {
        // The child: dup2 clears close-on-exec on fds 1 and 2.
        posix.dup2(out[1], 1) catch linux.exit_group(126);
        posix.dup2(err[1], 2) catch linux.exit_group(126);
        posix.fchdir(c.tmp.dir.fd) catch linux.exit_group(126);
        posix.sigaction(posix.SIG.XFSZ, &ign, null) catch linux.exit_group(126);
        posix.setrlimit(.FSIZE, limit) catch linux.exit_group(126);
        switch (posix.execveZ(argv[0].?, argv.ptr, envp.ptr)) {
            else => linux.exit_group(127),
        }
    }
    posix.close(out[1]);
    posix.close(err[1]);
    const w = posix.waitpid(pid, 0);
    const ro = std.fs.File{ .handle = out[0] };
    defer ro.close();
    const re = std.fs.File{ .handle = err[0] };
    defer re.close();
    const stdout = try ro.reader().readAllAlloc(al, 1 << 20);
    const stderr = try re.reader().readAllAlloc(al, 1 << 20);
    if (!posix.W.IFEXITED(w.status)) {
        std.debug.print("{s}: cov_branch_classify did not exit: status 0x{x}; stderr:\n{s}\n", .{ c.name, w.status, stderr });
        return error.TestUnexpectedResult;
    }
    const o = c.tmp.dir.readFileAlloc(al, OUT, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    return .{ .name = c.name, .code = posix.W.EXITSTATUS(w.status), .stdout = stdout, .stderr = stderr, .out = o };
}

// A write of the output that fails (EFBIG part way) is exit 1, the error
// named, no output and no temporary file left (the same run with no limit
// is case 1, exit 0 and the golden output). Kills: the write's error
// ignored (exit 0, no output); a partial output or its temporary file left
// in place.
test "failed write: an output whose write fails is exit 1, nothing written" {
    var c = try h.Case.init("failed write");
    defer c.deinit();
    try c.write("v.ll", h.case_ll);
    const r = try runLimited(&c, &(IO ++ MAP ++ h.EXC));
    try r.exits(1);
    try r.says("cov_branch_classify: " ++ OUT ++ ": FileTooBig; nothing written\n");
    try r.nothing_written();
    var dir = try c.tmp.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, "v.ll") or std.mem.eql(u8, e.name, "buck-out")) continue;
        std.debug.print("failed write: '{s}' was left in the directory\n", .{e.name});
        return error.TestUnexpectedResult;
    }
}
