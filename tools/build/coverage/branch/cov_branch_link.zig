//! cov_branch link: links one welded test's LLVM bitcode into a test binary
//! with IR profile counters, in a build action (`mojo_cov_pgo_link`,
//! tools/build/mojo/coverage_branch.bzl; README.md, "cov_branch_link").
//!
//! usage: cov_branch link --busybox <busybox> --compiler <compiler_dir>
//!            --zig <zig_dir> --target <cc_target> --lld <lld>
//!            --runtime <profile_runtime> --bitcode <bitcode> --out <out>
//!            [-- <link tail argument>...]
//!
//!   --compiler  the Mojo compiler closure: lib/libKGENCompilerRTShared.so
//!   --zig       the Mojo toolchain's link directory (zig), the one a
//!               release test links through
//!   --lld       lld/bin/lld of the link directory (the Mojo package's LLD 24)
//!   --runtime   llvm/runtime/libclang_rt.profile-x86_64.a of the link
//!               directory (the profile runtime)
//!   --bitcode   the test's LLVM bitcode ([coverage][bc][<test>])
//!   after `--` the C libraries of the test's closure, as mojo_wrapper.sh
//!               appends them to the end of a link line, given to zig as
//!               they are (relative to the working directory)
//!
//! Steps:
//!   0. lld, the runtime, the compiler's libKGENCompilerRTShared.so, zig and
//!      the bitcode are files that are not empty (as `[ -s ]`: a symbolic
//!      link is followed), else a usage error; the bitcode starts with the
//!      bitcode magic `BC 0xC0DE`.
//!   1. lld instruments the bitcode, as an LTO link with -r at -O0 whose pass
//!      pipeline is `pgo-instr-gen,instrprof,default<O0>`: a relocatable
//!      object with IR profile counters. lld is the LLVM the Mojo compiler is
//!      built on, so the bitcode is read by its own LLVM.
//!   2. zig links that object as a release test is linked (the line zig is
//!      given when `mojo build` links through mojo_wrapper.sh's `cc` shim:
//!      the compiler's runtime library, `--gc-sections`, `-lm`,
//!      `--strip-debug`, the one run path `$ORIGIN/lib` as DT_RUNPATH, then
//!      the link tail), with the profile runtime as a whole archive. Test 47's
//!      tests//functional/coverage:link_line records both lines and fails
//!      when they differ by more than the profile runtime.
//!   3. The binary must be an ELF file and hold no path of this action (its
//!      working directory or its scratch directory).
//!
//! lld and zig run with this tool's environment but for PATH (a directory
//! of the busybox applets, `<busybox> --install -s`), HOME, TMPDIR,
//! ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR (directories of the
//! scratch) and LC_ALL=C; their output goes to <scratch>/log, whose last 40
//! lines a failure prints.
//!
//! Why --strip-debug: nothing reads the binary's debug info. What a branch
//! was in the source is read from the bitcode (the IR the profile is applied
//! to, which keeps its line tables), never from the binary; and zig's C
//! runtime objects record this action's directory as their compilation
//! directory, which the strip removes with the rest, as in a release link.
//! So no relocation (cov_zig's) is needed, and step 3 checks it.
//!
//! The scratch directory is $BUCK_SCRATCH_PATH/cov_branch_link (relative to
//! the working directory when it is relative), or .cov_branch_link in the
//! working directory without one; it is removed after a success.
//!
//! Exit status: 1 when a step fails, naming it; 2 for a usage error, a
//! missing or empty input, or a scratch directory or program this tool
//! cannot set up or start.

const std = @import("std");
const br = @import("bounded_run.zig");
const run_cmd = @import("cov_branch_run.zig");

pub const USAGE = "usage: cov_branch link --busybox B --compiler DIR --zig DIR --target T --lld F --runtime F --bitcode F --out F [-- <link tail>...]";

pub const Args = struct {
    busybox: []const u8,
    compiler: []const u8,
    zig: []const u8,
    target: []const u8,
    lld: []const u8,
    runtime: []const u8,
    bitcode: []const u8,
    out: []const u8,
    /// The arguments after `--`, in order.
    tail: []const []const u8,
};

const NAMES = [_][]const u8{ "--busybox", "--compiler", "--zig", "--target", "--lld", "--runtime", "--bitcode", "--out" };

/// The arguments after `link`, or the reason they are refused (a usage error).
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    var vals = [_]?[]const u8{null} ** NAMES.len;
    var i: usize = 0;
    var tail: []const []const u8 = &.{};
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--")) {
            tail = argv[i + 1 ..];
            break;
        }
        const k = for (NAMES, 0..) |n, j| {
            if (std.mem.eql(u8, n, flag)) break j;
        } else {
            why.* = try std.fmt.allocPrint(alloc, "unknown argument {s}", .{flag});
            return null;
        };
        if (i + 1 >= argv.len) {
            why.* = try std.fmt.allocPrint(alloc, "{s} needs a value", .{flag});
            return null;
        }
        if (vals[k] != null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} given twice", .{flag});
            return null;
        }
        const v = argv[i + 1];
        if (v.len == 0) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is empty", .{flag});
            return null;
        }
        vals[k] = v;
    }
    for (NAMES, vals) |n, v| {
        if (v == null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is missing", .{n});
            return null;
        }
    }
    return .{
        .busybox = vals[0].?,
        .compiler = vals[1].?,
        .zig = vals[2].?,
        .target = vals[3].?,
        .lld = vals[4].?,
        .runtime = vals[5].?,
        .bitcode = vals[6].?,
        .out = vals[7].?,
        .tail = tail,
    };
}

/// The scratch directory (module comment).
pub fn scratchDir(alloc: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]const u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fmt.allocPrint(alloc, "{s}/.cov_branch_link", .{cwd});
    if (std.fs.path.isAbsolute(s)) return std.fmt.allocPrint(alloc, "{s}/cov_branch_link", .{s});
    return std.fmt.allocPrint(alloc, "{s}/{s}/cov_branch_link", .{ cwd, s });
}

pub const BITCODE_MAGIC = [4]u8{ 0x42, 0x43, 0xc0, 0xde };
pub const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

/// lld's command line (step 1). Paths are absolute.
pub fn lldArgv(alloc: std.mem.Allocator, lld: []const u8, bc: []const u8, k: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    try v.appendSlice(&.{ lld, "-flavor", "gnu", "-r", "-m", "elf_x86_64", bc, "-o" });
    try v.append(try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k}));
    try v.appendSlice(&.{ "--lto-O0", "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>" });
    return v.toOwnedSlice();
}

/// zig's command line (step 2): `zig`, `kgen`, `rt` and `out` absolute,
/// the tail as given.
pub fn zigArgv(alloc: std.mem.Allocator, zig: []const u8, target: []const u8, k: []const u8, kgen: []const u8, out: []const u8, rt: []const u8, tail: []const []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    try v.appendSlice(&.{ zig, "cc", "-target", target, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib" });
    try v.append(try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k}));
    try v.appendSlice(&.{ kgen, "-o", out, "-Wl,--gc-sections", "-lm", "-Wl,--whole-archive", rt, "-Wl,--no-whole-archive" });
    try v.appendSlice(tail);
    return v.toOwnedSlice();
}

/// `base` with PATH, HOME, TMPDIR, ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR
/// and LC_ALL replaced by the scratch's (module comment).
pub fn childEnv(alloc: std.mem.Allocator, base: []const []const u8, k: []const u8) ![]const []const u8 {
    const set = [_][]const u8{ "PATH", "HOME", "TMPDIR", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LC_ALL" };
    const val = [_][]const u8{ "/bin", "/home", "/tmp", "/zig-global", "/zig-local" };
    var v = std.ArrayList([]const u8).init(alloc);
    outer: for (base) |e| {
        for (set) |n| {
            if (e.len > n.len and std.mem.startsWith(u8, e, n) and e[n.len] == '=') continue :outer;
        }
        try v.append(e);
    }
    for (val, 0..) |s, j| try v.append(try std.fmt.allocPrint(alloc, "{s}={s}{s}", .{ set[j], k, s }));
    try v.append("LC_ALL=C");
    return v.toOwnedSlice();
}

/// `[ -s path ]`: a file (a symbolic link followed) of size above 0.
pub fn nonEmpty(path: []const u8) bool {
    const st = std.posix.fstatat(std.fs.cwd().fd, path, 0) catch return false;
    return st.size > 0;
}

/// The first 4 bytes of `path`, fewer if it is shorter, none if it cannot
/// be read.
pub fn head4(path: []const u8, buf: *[4]u8) []const u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return buf[0..0];
    defer f.close();
    const n = f.readAll(buf) catch return buf[0..0];
    return buf[0..n];
}

/// `strings -n 4 | grep -F needle | head -n 3 | tr '\n' ' '`: the first
/// three runs of at least 4 printable bytes (0x20 to 0x7e, or a tab) that
/// hold `needle`, each followed by a space.
pub fn stringsWith(alloc: std.mem.Allocator, bytes: []const u8, needle: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    var found: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len and found < 3) : (i += 1) {
        const printable = i < bytes.len and ((bytes[i] >= 0x20 and bytes[i] < 0x7f) or bytes[i] == '\t');
        if (printable) continue;
        const run = bytes[start..i];
        if (run.len >= 4 and std.mem.indexOf(u8, run, needle) != null) {
            try out.appendSlice(run);
            try out.append(' ');
            found += 1;
        }
        start = i + 1;
    }
    return out.toOwnedSlice();
}

/// The last `n` lines of `text` (`tail -n N`).
pub fn lastLines(text: []const u8, n: usize) []const u8 {
    if (text.len == 0) return text;
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var seen: usize = 0;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            seen += 1;
            if (seen == n) return text[i..];
        }
    }
    return text;
}

fn red(alloc: std.mem.Allocator, err: *std.ArrayList(u8), k: []const u8, msg: []const u8) !u8 {
    const w = err.writer();
    try w.print("BRANCH COVERAGE LINK FAILED: {s}\n", .{msg});
    const log_path = try std.fmt.allocPrint(alloc, "{s}/log", .{k});
    if (std.fs.cwd().readFileAlloc(alloc, log_path, 1 << 30)) |log| {
        try w.writeAll("--- log:\n");
        const last = lastLines(log, 40);
        try w.writeAll(last);
        if (last.len > 0 and last[last.len - 1] != '\n') try w.writeByte('\n');
    } else |_| {}
    return 1;
}

/// Steps 0 to 3 (module comment). Messages go to `err`; returns the exit status.
pub fn linkAll(alloc: std.mem.Allocator, a: Args, where: run_cmd.Where, runner: run_cmd.Runner, err: *std.ArrayList(u8)) !u8 {
    const cwd = where.cwd;
    const k = where.k;
    const bb = try run_cmd.abs(alloc, cwd, a.busybox);
    const lld = try run_cmd.abs(alloc, cwd, a.lld);
    const rt = try run_cmd.abs(alloc, cwd, a.runtime);
    const kgen = try std.fmt.allocPrint(alloc, "{s}/lib/libKGENCompilerRTShared.so", .{try run_cmd.abs(alloc, cwd, a.compiler)});
    const zig = try std.fmt.allocPrint(alloc, "{s}/zig", .{try run_cmd.abs(alloc, cwd, a.zig)});
    const bc = try run_cmd.abs(alloc, cwd, a.bitcode);
    const out = try run_cmd.abs(alloc, cwd, a.out);

    // 0. The inputs, each a file that is not empty (`[ -s ]`; else a usage
    // error), before the scratch directory exists.
    for ([_][]const u8{ lld, rt, kgen, zig, bc }) |f| {
        if (!nonEmpty(f)) {
            try err.writer().print("cov_branch link: {s} is missing or empty\n", .{f});
            return 2;
        }
    }

    const bin = try std.fmt.allocPrint(alloc, "{s}/bin", .{k});
    for ([_][]const u8{ bin, try std.fmt.allocPrint(alloc, "{s}/home", .{k}), try std.fmt.allocPrint(alloc, "{s}/tmp", .{k}) }) |d| {
        std.fs.cwd().makePath(d) catch |e| {
            try err.writer().print("cov_branch link: cannot make {s}: {s}\n", .{ d, @errorName(e) });
            return 2;
        };
    }
    const inst = runner.runFn(runner.ptr, alloc, .{ .argv = &.{ bb, "--install", "-s", bin }, .env = where.env }) catch |e| {
        try err.writer().print("cov_branch link: cannot run {s}: {s}\n", .{ bb, @errorName(e) });
        return 2;
    };
    if (inst.shellStatus() != 0) {
        try err.writer().print("cov_branch link: {s} --install -s {s} failed (exit {d})\n", .{ bb, bin, inst.shellStatus() });
        return 2;
    }
    const env = try childEnv(alloc, where.env, k);
    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{k});

    var magic: [4]u8 = undefined;
    if (!std.mem.eql(u8, head4(bc, &magic), &BITCODE_MAGIC)) {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "{s} is not LLVM bitcode", .{a.bitcode}));
    }

    // 1. Instrument.
    const l = runner.runFn(runner.ptr, alloc, .{ .argv = try lldArgv(alloc, lld, bc, k), .env = env, .stdout_path = log, .stderr_to_stdout = true }) catch |e| {
        try err.writer().print("cov_branch link: cannot run {s}: {s}\n", .{ lld, @errorName(e) });
        return 2;
    };
    if (l.shellStatus() != 0) {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "lld could not instrument {s} (pgo-instr-gen)", .{a.bitcode}));
    }

    // 2. Link, as mojo_wrapper.sh's cc shim links a release test.
    const z = runner.runFn(runner.ptr, alloc, .{ .argv = try zigArgv(alloc, zig, a.target, k, kgen, out, rt, a.tail), .env = env, .stdout_path = log, .stderr_to_stdout = true }) catch |e| {
        try err.writer().print("cov_branch link: cannot run {s}: {s}\n", .{ zig, @errorName(e) });
        return 2;
    };
    if (z.shellStatus() != 0) {
        return red(alloc, err, k, "zig could not link the instrumented test with the profile runtime");
    }

    // 3. An ELF file holding no path of this action.
    if (!std.mem.eql(u8, head4(out, &magic), &ELF_MAGIC)) {
        return red(alloc, err, k, "the link wrote no ELF file");
    }
    const bytes = std.fs.cwd().readFileAlloc(alloc, out, 1 << 32) catch |e| {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "cannot read the binary {s}: {s}", .{ out, @errorName(e) }));
    };
    for ([_][]const u8{ cwd, k }) |d| {
        if (std.mem.indexOf(u8, bytes, d) != null) {
            return red(alloc, err, k, try std.fmt.allocPrint(alloc, "the binary holds this action's directory {s}: {s}", .{ d, try stringsWith(alloc, bytes, d) }));
        }
    }
    std.fs.cwd().deleteTree(k) catch {};
    return 0;
}

/// `cov_branch link <argv>`: parses, then links. Returns the exit status;
/// messages go to `err`.
pub fn cli(alloc: std.mem.Allocator, argv: []const []const u8, where: run_cmd.Where, runner: run_cmd.Runner, err: *std.ArrayList(u8)) !u8 {
    var why: []const u8 = "";
    const a = (try parseArgs(alloc, argv, &why)) orelse {
        try err.writer().print("cov_branch link: usage error: {s}\n{s}\n", .{ why, USAGE });
        return 2;
    };
    return linkAll(alloc, a, where, runner, err);
}
