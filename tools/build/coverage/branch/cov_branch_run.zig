//! cov_branch run: runs one welded test's instrumented binary in a build
//! action (`mojo_cov_branch_run`, tools/build/mojo/coverage_branch.bzl),
//! through the release gate's runner with the gate's environment, and merges
//! the raw profiles it writes into an indexed profile (README.md,
//! "cov_branch_run").
//!
//! usage: cov_branch run --busybox <busybox> --gate <gate>
//!            --compiler <compiler_dir> --label <label> --profdata <llvm-profdata>
//!            --raw-version <N> --binary <test_binary> --out <profdata_out>
//!            [--env NAME=VALUE]...
//!
//!   --gate         the gate (tools/build/run), run as the release gate runs
//!                  it: `<gate> mojo --busybox <busybox> --runtime-lib
//!                  <compiler_dir>/lib --label <label> --test <test_binary>
//!                  --marker <marker> --env ...`, with no limit flag (no
//!                  memory cap, no time limit: see below)
//!   --profdata     the pinned llvm-profdata (toolchains/llvm_branch)
//!   --raw-version  the raw profile version every profile must have
//!   --binary       <root>/bin/<test> of the test's staged tree (the release
//!                  gate's: <root>/share holds its declared data)
//!   --env          the test's environment, passed to the gate as given
//!
//! Steps:
//!   1. `gate mojo` runs the test in the gate's environment (this tool's own
//!      environment, PATH replaced by an empty directory of its scratch: it
//!      sets nothing else, and the gate sets PATH itself) with one more
//!      --env, LLVM_PROFILE_FILE=<scratch>/prof/%p.profraw (an absolute path;
//!      %p is the pid, so a child the test starts writes a profile of its
//!      own). The test must pass: when it fails, so does this action, with
//!      the test's output and this tool's message, not the gate's banner
//!      (which says the release gate's test failed: that one passed).
//!   2. At least one raw profile was written there; none (the runtime was not
//!      linked, the variable did not reach the test, the test left without
//!      running its exit handlers) fails the action.
//!   3. Each raw profile starts with the 64-bit raw magic, its version is
//!      <raw_version>, and its variant flags carry the IR-instrumentation bit
//!      (0x01000000), which only the instrumenter's definition of
//!      __llvm_profile_raw_version sets (toolchains/llvm_branch/README.md,
//!      "The version coupling"): the little-endian words at bytes 0, 8 and 12.
//!   4. llvm-profdata merges them into <profdata_out>; a refusal that is
//!      LLVM's `raw profile version mismatch` says which version it expected.
//!      `llvm-profdata show` must then report IR instrumentation and exactly
//!      one `Total functions:` count, above 0. llvm-profdata runs with
//!      LC_ALL=C.
//!
//! Like the gate, it waits for the test alone (bounded_run with no limit): a
//! child still running when the test exits writes its profile after the
//! merge, or never, and its counts are not in <profdata_out>. Like the gate,
//! it has no time limit of its own: a test that hangs holds the action until
//! the executor's timeout. With no limit the test stays in this tool's
//! process group, so a kill of that group at the timeout reaches it too.
//!
//! The scratch directory is $BUCK_SCRATCH_PATH/cov_branch_run (relative to
//! the working directory when it is relative), or .cov_branch_run in the
//! working directory without one; it is removed after a success.
//!
//! Exit status: the test's when it fails (the gate's, 128 + N when signal
//! N killed it); 1 when no profile was written or one is refused; 2 for a
//! usage error, or a program this tool cannot start.

const std = @import("std");
const br = @import("bounded_run.zig");

const RULE = "==================================================================";

pub const Args = struct {
    busybox: []const u8,
    gate: []const u8,
    compiler: []const u8,
    label: []const u8,
    profdata: []const u8,
    raw_version: u32,
    binary: []const u8,
    out: []const u8,
    /// "NAME=VALUE" of each --env, in order.
    env: []const []const u8,
};

pub const USAGE = "usage: cov_branch run --busybox B --gate G --compiler DIR --label L --profdata P --raw-version N --binary F --out F [--env NAME=VALUE]...";

/// The arguments after `run`, or the reason they are refused (a usage error).
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    const names = [_][]const u8{ "--busybox", "--gate", "--compiler", "--label", "--profdata", "--raw-version", "--binary", "--out" };
    var vals = [_]?[]const u8{null} ** names.len;
    var env = std.ArrayList([]const u8).init(alloc);
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (i + 1 >= argv.len) {
            why.* = try std.fmt.allocPrint(alloc, "{s} needs a value", .{flag});
            return null;
        }
        const v = argv[i + 1];
        if (std.mem.eql(u8, flag, "--env")) {
            try env.append(v);
            continue;
        }
        const k = for (names, 0..) |n, j| {
            if (std.mem.eql(u8, n, flag)) break j;
        } else {
            why.* = try std.fmt.allocPrint(alloc, "unknown argument {s}", .{flag});
            return null;
        };
        if (vals[k] != null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} given twice", .{flag});
            return null;
        }
        if (v.len == 0) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is empty", .{flag});
            return null;
        }
        vals[k] = v;
    }
    for (names, vals) |n, v| {
        if (v == null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is missing", .{n});
            return null;
        }
    }
    const rv = vals[5].?;
    const raw = parseVersion(rv) orelse {
        why.* = try std.fmt.allocPrint(alloc, "--raw-version is '{s}', not a version", .{rv});
        return null;
    };
    return .{
        .busybox = vals[0].?,
        .gate = vals[1].?,
        .compiler = vals[2].?,
        .label = vals[3].?,
        .profdata = vals[4].?,
        .raw_version = raw,
        .binary = vals[6].?,
        .out = vals[7].?,
        .env = try env.toOwnedSlice(),
    };
}

/// A positive decimal with no leading zero (the script's `"" | 0* | *[!0-9]*`).
fn parseVersion(s: []const u8) ?u32 {
    if (s.len == 0 or s[0] == '0') return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// `p` absolute: as given, or under `cwd`.
pub fn abs(alloc: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, p });
}

/// The scratch directory (module comment).
pub fn scratchDir(alloc: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]const u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fmt.allocPrint(alloc, "{s}/.cov_branch_run", .{cwd});
    if (std.fs.path.isAbsolute(s)) return std.fmt.allocPrint(alloc, "{s}/cov_branch_run", .{s});
    return std.fmt.allocPrint(alloc, "{s}/{s}/cov_branch_run", .{ cwd, s });
}

/// The gate's command line: the release gate's (`gate mojo`, as
/// tools/build/mojo/test_runtime.bzl `gate_mojo` writes it, without a limit
/// flag), with the test's --env and then LLVM_PROFILE_FILE. Paths are
/// absolute (`k` is).
pub fn gateArgv(alloc: std.mem.Allocator, a: Args, cwd: []const u8, k: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    try v.appendSlice(&.{ try abs(alloc, cwd, a.gate), "mojo", "--busybox", try abs(alloc, cwd, a.busybox) });
    try v.appendSlice(&.{ "--runtime-lib", try std.fmt.allocPrint(alloc, "{s}/lib", .{try abs(alloc, cwd, a.compiler)}) });
    try v.appendSlice(&.{ "--label", a.label, "--test", try abs(alloc, cwd, a.binary) });
    try v.appendSlice(&.{ "--marker", try std.fmt.allocPrint(alloc, "{s}/gate.passed", .{k}) });
    for (a.env) |e| try v.appendSlice(&.{ "--env", e });
    try v.appendSlice(&.{ "--env", try std.fmt.allocPrint(alloc, "LLVM_PROFILE_FILE={s}/prof/%p.profraw", .{k}) });
    return v.toOwnedSlice();
}

/// `base` with every PATH (and LC_ALL) entry replaced: PATH=`path`, and
/// LC_ALL=C when `c_locale`.
pub fn childEnv(alloc: std.mem.Allocator, base: []const []const u8, path: []const u8, c_locale: bool) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    for (base) |e| {
        if (std.mem.startsWith(u8, e, "PATH=")) continue;
        if (c_locale and std.mem.startsWith(u8, e, "LC_ALL=")) continue;
        try v.append(e);
    }
    try v.append(try std.fmt.allocPrint(alloc, "PATH={s}", .{path}));
    if (c_locale) try v.append("LC_ALL=C");
    return v.toOwnedSlice();
}

fn banner(out: *std.ArrayList(u8), label: []const u8, msg: []const u8) !void {
    const w = out.writer();
    try w.print("{s}\nBRANCH COVERAGE RUN FAILED: {s}\n{s}\n{s}\n", .{ RULE, label, msg, RULE });
}

/// What a failed gate run prints: the gate's stderr without its banner's
/// first two lines (the first `GATED TEST FAILED: <label> (exit <rc>)` that
/// is followed by `The library's package is not produced until this test
/// passes.`; the rest, the test's output among it, is kept), then this
/// tool's banner.
pub fn gateFailure(alloc: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, rc: u8, gate_err: []const u8) !void {
    const h = try std.fmt.allocPrint(alloc, "GATED TEST FAILED: {s} (exit {d})", .{ label, rc });
    const p = "The library's package is not produced until this test passes.";
    var lines = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, gate_err, '\n');
    while (it.next()) |l| try lines.append(l);
    // A final newline ends the last line; it does not start an empty one.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    var done = false;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const l = lines.items[i];
        if (!done and std.mem.eql(u8, l, h) and i + 1 < lines.items.len and std.mem.eql(u8, lines.items[i + 1], p)) {
            done = true;
            i += 1;
            continue;
        }
        try out.appendSlice(l);
        try out.append('\n');
    }
    const msg = try std.fmt.allocPrint(alloc, "The test failed instrumented for branch coverage (exit {d}). A branch coverage run builds the test at -O0, instruments it with lld and runs it with LLVM_PROFILE_FILE set; a test that passes in the release gate and fails here fails this action, and is a bug to fix.", .{rc});
    try banner(out, label, msg);
}

pub const RAW_MAGIC: u64 = 0xff6c70726f667281;
pub const IR_BIT: u32 = 0x01000000;

/// Why the raw profile `name` with first bytes `head` is refused, or null.
pub fn checkRaw(alloc: std.mem.Allocator, name: []const u8, head: []const u8, raw: u32) !?[]const u8 {
    var b = [_]u8{0} ** 16;
    @memcpy(b[0..@min(head.len, 16)], head[0..@min(head.len, 16)]);
    const magic = std.mem.readInt(u64, b[0..8], .little);
    if (head.len < 8 or magic != RAW_MAGIC) {
        return try std.fmt.allocPrint(alloc, "{s} does not start with the 64-bit raw profile magic (got '{x:0>16}')", .{ name, magic });
    }
    const v = std.mem.readInt(u32, b[8..12], .little);
    if (head.len < 12 or v != raw) {
        return try std.fmt.allocPrint(alloc, "{s} has raw profile version {d}, not {d}, the version the pinned llvm-profdata reads (toolchains/llvm_branch/README.md, The version coupling).", .{ name, v, raw });
    }
    const flags = std.mem.readInt(u32, b[12..16], .little);
    if (head.len < 16 or flags & IR_BIT == 0) {
        return try std.fmt.allocPrint(alloc, "{s} has variant flags 0x{x:0>8}, without the IR-instrumentation bit 0x01000000: its version word is the profile runtime's default, not the instrumenter's (toolchains/llvm_branch/README.md, The version coupling).", .{ name, flags });
    }
    return null;
}

/// The first `n` lines of `text`, each that ended in a newline followed by a
/// space (`head -n N | tr '\n' ' '`).
pub fn headJoined(alloc: std.mem.Allocator, text: []const u8, n: usize) ![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    var rest = text;
    var k: usize = 0;
    while (k < n and rest.len > 0) : (k += 1) {
        if (std.mem.indexOfScalar(u8, rest, '\n')) |e| {
            try out.appendSlice(rest[0..e]);
            try out.append(' ');
            rest = rest[e + 1 ..];
        } else {
            try out.appendSlice(rest);
            rest = "";
        }
    }
    return out.toOwnedSlice();
}

/// Why a failed merge failed, from its log.
pub fn mergeRefusal(alloc: std.mem.Allocator, log: []const u8, raw: u32, n: usize) ![]const u8 {
    if (std.mem.indexOf(u8, log, "raw profile version mismatch") != null) {
        var seen = std.ArrayList([]const u8).init(alloc);
        var it = std.mem.splitScalar(u8, log, '\n');
        while (it.next()) |l| {
            const v = expectedVersion(l) orelse continue;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, v)) break;
            } else try seen.append(v);
        }
        std.mem.sort([]const u8, seen.items, {}, strLess);
        const ev = try std.mem.join(alloc, " ", seen.items);
        return std.fmt.allocPrint(alloc, "llvm-profdata refused a raw profile of version {d}: it expects {s}: {s}", .{ raw, ev, try headJoined(alloc, log, 2) });
    }
    return std.fmt.allocPrint(alloc, "llvm-profdata merge failed on {d} raw profile(s): {s}", .{ n, try headJoined(alloc, log, 3) });
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The digits after the last "; expected version = " of a line that has
/// digits after it (the script's greedy sed).
fn expectedVersion(line: []const u8) ?[]const u8 {
    const key = "; expected version = ";
    var end = line.len;
    while (std.mem.lastIndexOf(u8, line[0..end], key)) |at| {
        const s = at + key.len;
        var e = s;
        while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
        if (e > s) return line[s..e];
        if (at == 0) break;
        end = at + key.len - 1;
    }
    return null;
}

/// Why `llvm-profdata show`'s output is refused, or null.
pub fn checkShow(alloc: std.mem.Allocator, show: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, show, "Instrumentation level: IR") == null) {
        const first = if (std.mem.indexOfScalar(u8, show, '\n')) |e| show[0..e] else show;
        return try std.fmt.allocPrint(alloc, "the merged profile is not an IR-instrumentation profile: {s}", .{first});
    }
    var count: usize = 0;
    var positive = false;
    var it = std.mem.splitScalar(u8, show, '\n');
    while (it.next()) |l| {
        const key = "Total functions: ";
        if (!std.mem.startsWith(u8, l, key) or l.len == key.len) continue;
        const d = l[key.len..];
        for (d) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else {
            count += 1;
            positive = std.mem.trimLeft(u8, d, "0").len > 0;
        }
    }
    if (count != 1 or !positive) {
        // `tr '\n' ' '` of the whole output: its last newline is a space too.
        const flat = try alloc.dupe(u8, show);
        for (flat) |*c| {
            if (c.* == '\n') c.* = ' ';
        }
        return try std.fmt.allocPrint(alloc, "the merged profile has no function: {s}", .{flat});
    }
    return null;
}

/// How a step's process is run: bounded_run in the tool, a stand-in in tests.
pub const Runner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, spec: br.Spec) anyerror!br.Outcome,

    fn run(self: Runner, alloc: std.mem.Allocator, spec: br.Spec) anyerror!br.Outcome {
        return self.runFn(self.ptr, alloc, spec);
    }
};

fn realRun(_: *anyopaque, alloc: std.mem.Allocator, spec: br.Spec) anyerror!br.Outcome {
    return br.run(alloc, spec);
}

var real_ctx: u8 = 0;
pub const real_runner = Runner{ .ptr = &real_ctx, .runFn = &realRun };

pub const Where = struct {
    /// The working directory, absolute.
    cwd: []const u8,
    /// The scratch directory, absolute (scratchDir).
    k: []const u8,
    /// This tool's environment, NAME=VALUE.
    env: []const []const u8,
};

fn readAll(alloc: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 64 << 20) catch "";
}

fn readHead(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const buf = try alloc.alloc(u8, 16);
    const n = try f.readAll(buf);
    return buf[0..n];
}

/// The .profraw files under `dir`, at any depth, sorted by path.
pub fn listRaws(alloc: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var w = try d.walk(alloc);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".profraw")) continue;
        try out.append(try std.fs.path.join(alloc, &.{ dir, e.path }));
    }
    std.mem.sort([]const u8, out.items, {}, strLess);
    return out.toOwnedSlice();
}

/// Steps 1 to 4 (module comment). Messages go to `err`; returns the exit status.
pub fn runAll(alloc: std.mem.Allocator, a: Args, where: Where, runner: Runner, err: *std.ArrayList(u8)) !u8 {
    const k = where.k;
    const bin = try std.fmt.allocPrint(alloc, "{s}/bin", .{k});
    const prof = try std.fmt.allocPrint(alloc, "{s}/prof", .{k});
    try std.fs.cwd().makePath(bin);
    try std.fs.cwd().makePath(prof);

    // 1. The test, under the gate's runner.
    const gate_err = try std.fmt.allocPrint(alloc, "{s}/gate.err", .{k});
    const gate = runner.run(alloc, .{
        .argv = try gateArgv(alloc, a, where.cwd, k),
        .env = try childEnv(alloc, where.env, bin, false),
        .stderr_path = gate_err,
    }) catch |e| {
        try err.writer().print("cov_branch run: cannot run {s}: {s}\n", .{ a.gate, @errorName(e) });
        return 2;
    };
    const rc = gate.shellStatus();
    if (rc != 0) {
        try gateFailure(alloc, err, a.label, rc, readAll(alloc, gate_err));
        return rc;
    }

    // 2. The raw profiles.
    const raws = try listRaws(alloc, prof);
    if (raws.len == 0) {
        try banner(err, a.label, try std.fmt.allocPrint(alloc, "The test passed but wrote no .profraw under {s} (LLVM_PROFILE_FILE): the profile runtime did not run its exit handler, or the variable did not reach the test.", .{prof}));
        return 1;
    }

    // 3. Each one's magic, version and IR bit.
    for (raws) |f| {
        const head = readHead(alloc, f) catch "";
        if (try checkRaw(alloc, std.fs.path.basename(f), head, a.raw_version)) |why| {
            try banner(err, a.label, why);
            return 1;
        }
    }

    // 4. Merged; a version refusal named as one; then shown.
    const env = try childEnv(alloc, where.env, bin, true);
    const out = try abs(alloc, where.cwd, a.out);
    var merge = std.ArrayList([]const u8).init(alloc);
    try merge.appendSlice(&.{ a.profdata, "merge", "-o", out });
    try merge.appendSlice(raws);
    const merge_log = try std.fmt.allocPrint(alloc, "{s}/merge.log", .{k});
    const m = runner.run(alloc, .{ .argv = merge.items, .env = env, .stdout_path = merge_log, .stderr_to_stdout = true }) catch |e| {
        try err.writer().print("cov_branch run: cannot run {s}: {s}\n", .{ a.profdata, @errorName(e) });
        return 2;
    };
    if (m.shellStatus() != 0) {
        try banner(err, a.label, try mergeRefusal(alloc, readAll(alloc, merge_log), a.raw_version, raws.len));
        return 1;
    }
    const show_txt = try std.fmt.allocPrint(alloc, "{s}/show.txt", .{k});
    const s = runner.run(alloc, .{ .argv = &.{ a.profdata, "show", out }, .env = env, .stdout_path = show_txt, .stderr_to_stdout = true }) catch |e| {
        try err.writer().print("cov_branch run: cannot run {s}: {s}\n", .{ a.profdata, @errorName(e) });
        return 2;
    };
    const show = readAll(alloc, show_txt);
    if (s.shellStatus() != 0) {
        try banner(err, a.label, try std.fmt.allocPrint(alloc, "llvm-profdata show failed on the merged profile: {s}", .{try headJoined(alloc, show, 2)}));
        return 1;
    }
    if (try checkShow(alloc, show)) |why| {
        try banner(err, a.label, why);
        return 1;
    }
    std.fs.cwd().deleteTree(k) catch {};
    return 0;
}

/// `cov_branch run <argv>`: parses, checks the tools, runs. Returns the exit
/// status; messages go to `err`.
pub fn cli(alloc: std.mem.Allocator, argv: []const []const u8, where: Where, runner: Runner, err: *std.ArrayList(u8)) !u8 {
    var why: []const u8 = "";
    const a = (try parseArgs(alloc, argv, &why)) orelse {
        try err.writer().print("cov_branch run: usage error: {s}\n{s}\n", .{ why, USAGE });
        return 2;
    };
    // As the script's `[ -x "$PD" ]`.
    std.posix.access(a.profdata, std.posix.X_OK) catch {
        try err.writer().print("cov_branch run: {s} is missing\n", .{a.profdata});
        return 2;
    };
    return runAll(alloc, a, where, runner, err);
}
