//! What the gate's tests share (not part of the tool).
//!
//! `runGate` forks a child H that calls `gate.entry` with the given argv in
//! a working directory of the test's own, its stdout and stderr in files, and
//! the platform's exec replaced by `fixture`: the "test" the gate supervises
//! is then a child of the test binary that runs a behaviour picked by its
//! program name (the path's last component) and its arguments, with the
//! argv and environment the gate built for it. No shell stand-in is used.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const gate = @import("gate.zig");
const supervise = @import("supervise.zig");
const proctab_darwin = if (sys.is_darwin) @import("proctab_darwin.zig") else struct {};

pub const Result = struct {
    status: u8,
    out: []const u8,
    err: []const u8,
    ms: u64,
};

pub const Opts = struct {
    /// Called in H before the gate runs: replace `supervise.plat` fields.
    setup: ?*const fn () void = null,
    /// H's environment; null keeps the test binary's.
    env: ?[]const []const u8 = null,
    /// Sent to H this many ms after it starts.
    signal: ?struct { sig: u8, after_ms: u64 } = null,
    timeout_ms: u64 = 60_000,
};

/// A fresh directory under $TMPDIR.
pub fn tempDir(alloc: std.mem.Allocator) ![]const u8 {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    var suffix: [6]u8 = undefined;
    sys.randomSuffix(&suffix);
    const p = try std.fmt.allocPrint(alloc, "{s}/gate_test.{s}", .{ base, suffix });
    try std.fs.cwd().makePath(p);
    return p;
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 28);
}

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// The busybox the zig_test action's PATH holds applets of.
pub fn busybox(alloc: std.mem.Allocator) ![]const u8 {
    const path = std.posix.getenv("PATH") orelse return error.NoPath;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        const sh = try std.fmt.allocPrint(alloc, "{s}/sh", .{d});
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const target = std.fs.cwd().readLink(sh, &buf) catch continue;
        return alloc.dupe(u8, target);
    }
    return error.NoBusybox;
}

pub fn runGate(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, opts: Opts) !Result {
    const io = try tempDir(alloc);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out", .{io});
    const err_path = try std.fmt.allocPrint(alloc, "{s}/err", .{io});
    const start = sys.monotonicMs().?;
    const h = try posix.fork();
    if (h == 0) {
        posix.chdir(cwd) catch posix.exit(250);
        const o = posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        const e = posix.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        posix.dup2(o, 1) catch posix.exit(250);
        posix.dup2(e, 2) catch posix.exit(250);
        sys.devNullOnto(0, false);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = arena.allocator();
        if (opts.env) |env| {
            const z = a.alloc([*:0]u8, env.len + 1) catch posix.exit(250);
            for (env, 0..) |kv, i| z[i] = (a.dupeZ(u8, kv) catch posix.exit(250)).ptr;
            std.os.environ = z[0..env.len];
        }
        // PWD names the test's directory, as a shell's would.
        supervise.plat = .{ .exec = fixture };
        if (opts.setup) |f| f();
        posix.exit(gate.entry(a, argv));
    }
    var signalled = false;
    var status: u8 = 0;
    while (true) {
        if (sys.waitpid(h, true)) |s| {
            status = s;
            break;
        }
        const now = sys.monotonicMs().?;
        if (opts.signal) |sg| {
            if (!signalled and now - start >= sg.after_ms) {
                sys.kill(h, sg.sig);
                signalled = true;
            }
        }
        if (now - start > opts.timeout_ms) {
            sys.kill(h, posix.SIG.KILL);
            _ = sys.waitpid(h, false);
            std.debug.print("runGate: the gate did not finish within {d} ms: {s}\n", .{ opts.timeout_ms, argv });
            return error.Timeout;
        }
        sys.sleepMs(5);
    }
    return .{
        .status = status,
        .out = try readFile(alloc, out_path),
        .err = try readFile(alloc, err_path),
        .ms = sys.monotonicMs().? - start,
    };
}

/// Whether `pid` is alive and not a zombie (a zombie has exited).
pub fn alive(pid: i32) bool {
    if (sys.is_darwin) return proctab_darwin.alive(pid);
    var buf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    const f = std.fs.cwd().openFile(p, .{}) catch return false;
    defer f.close();
    var b: [512]u8 = undefined;
    const n = f.readAll(&b) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, b[0..n], ')') orelse return false;
    if (close + 2 >= n) return false;
    return b[close + 2] != 'Z' and b[close + 2] != 'X';
}

/// Waits up to `ms` for every pid to be gone; true when they are.
pub fn goneWithin(pids: []const i32, ms: u64) bool {
    const end = sys.monotonicMs().? + ms;
    while (true) {
        var any = false;
        for (pids) |p| {
            if (alive(p)) any = true;
        }
        if (!any) return true;
        if (sys.monotonicMs().? >= end) return false;
        sys.sleepMs(20);
    }
}

/// Reads the pids a fixture wrote (one per line) to `path`, waiting up to
/// 5 s for the file to hold `n` of them.
pub fn pidsFrom(alloc: std.mem.Allocator, path: []const u8, n: usize) ![]i32 {
    const end = sys.monotonicMs().? + 5000;
    while (true) {
        if (std.fs.cwd().readFileAlloc(alloc, path, 4096)) |text| {
            var out = std.ArrayList(i32).init(alloc);
            var it = std.mem.tokenizeScalar(u8, text, '\n');
            while (it.next()) |t| try out.append(try std.fmt.parseInt(i32, t, 10));
            if (out.items.len >= n) return out.items;
        } else |_| {}
        if (sys.monotonicMs().? >= end) return error.NoPids;
        sys.sleepMs(10);
    }
}

// ---- the fixture ------------------------------------------------------------

fn say(comptime fmt: []const u8, a: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, a) catch return;
    sys.writeAll(1, s);
}

fn num(s: ?[]const u8, default: u64) u64 {
    const v = s orelse return default;
    return std.fmt.parseInt(u64, v, 10) catch default;
}

fn appendPid(path: []const u8, pid: i32) void {
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    f.writeAll(s) catch return;
}

fn hold(mib: u64, secs: u64) noreturn {
    const mem = std.heap.page_allocator.alloc(u8, mib << 20) catch posix.exit(99);
    var i: usize = 0;
    while (i < mem.len) : (i += 4096) mem[i] = 1;
    say("hog holds {d} MiB\n", .{mib});
    sys.sleepMs(secs * 1000);
    posix.exit(0);
}

/// The supervised "test". Program names (the path's last component):
///   exit N             exits N
///   signal N           kills itself with signal N
///   sleep S [N]        sleeps S s, exits N
///   hog MiB [S]        holds MiB of touched memory for S s (60), exits 0
///   daemon FILE KIND   forks a child (KIND: sleep or hog) that stays in the
///                      group, writes its pid to FILE, and exits 0 at once
///   spawnwait FILE     forks a 100 s sleeper, writes its pid, waits for it
///   treehog P C [S]    forks a child that holds C MiB for S s (5), then holds
///                      P MiB itself and waits for the child, exits 0 (the
///                      fork comes first, so neither counts the other's pages)
///   env [N]            prints its environment, exits N (default 3)
///   args               prints `[arg]` per argument (argv[0] too), exits 3
///   where              prints its cwd and the bytes on stdin, exits 3
///   lines N NL RC      prints `line 1`..`line N` (NL 0: no final newline), exits RC
///   pid FILE ...       writes its pid to FILE, then runs the next behaviour
///   rust_* ...         fake libtest harnesses (rust_test.zig)
pub fn fixture(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    sys.defaultSignals();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    var args = std.ArrayList([]const u8).init(a);
    var i: usize = 0;
    while (argv[i]) |p| : (i += 1) args.append(std.mem.span(p)) catch posix.exit(99);
    var env = std.ArrayList([]const u8).init(a);
    i = 0;
    while (envp[i]) |p| : (i += 1) env.append(std.mem.span(p)) catch posix.exit(99);
    behave(a, std.fs.path.basename(std.mem.span(path)), args.items, env.items);
}

fn behave(a: std.mem.Allocator, name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const arg = struct {
        fn at(xs: []const []const u8, k: usize) ?[]const u8 {
            return if (k < xs.len) xs[k] else null;
        }
    }.at;
    if (std.mem.eql(u8, name, "exit")) posix.exit(@intCast(num(arg(args, 1), 0)));
    if (std.mem.eql(u8, name, "signal")) {
        posix.raise(@intCast(num(arg(args, 1), 9))) catch {};
        posix.exit(99);
    }
    if (std.mem.eql(u8, name, "sleep")) {
        sys.sleepMs(num(arg(args, 1), 1) * 1000);
        posix.exit(@intCast(num(arg(args, 2), 0)));
    }
    if (std.mem.eql(u8, name, "hog")) hold(num(arg(args, 1), 64), num(arg(args, 2), 60));
    if (std.mem.eql(u8, name, "daemon")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const kind = arg(args, 2) orelse "sleep";
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            if (std.mem.eql(u8, kind, "hog")) hold(64, 60);
            sys.sleepMs(100_000);
            posix.exit(0);
        }
        appendPid(file, pid);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "spawnwait")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            sys.sleepMs(100_000);
            posix.exit(0);
        }
        appendPid(file, sys.getpid());
        appendPid(file, pid);
        _ = sys.waitpid(-1, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "treehog")) {
        const secs = num(arg(args, 3), 5);
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) hold(num(arg(args, 2), 24), secs);
        const mem = std.heap.page_allocator.alloc(u8, num(arg(args, 1), 16) << 20) catch posix.exit(99);
        var k: usize = 0;
        while (k < mem.len) : (k += 4096) mem[k] = 1;
        say("parent holds {d} MiB\n", .{mem.len >> 20});
        _ = sys.waitpid(pid, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "env")) {
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(@intCast(num(arg(args, 1), 3)));
    }
    if (std.mem.eql(u8, name, "args")) {
        for (args) |x| say("[{s}]\n", .{x});
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "where")) {
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch "?";
        var b: [64]u8 = undefined;
        const n = posix.read(0, &b) catch 999;
        say("cwd {s}\nstdin {d}\n", .{ cwd, n });
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "rundir")) {
        // The run directory as the test sees it: TMPDIR, TEST_TMPDIR, what
        // TMPDIR holds, and whether the applets are installed beside it.
        var tmp: []const u8 = "";
        for (env) |kv| {
            if (std.mem.startsWith(u8, kv, "TMPDIR=")) tmp = kv["TMPDIR=".len..];
            if (std.mem.startsWith(u8, kv, "TMPDIR=") or std.mem.startsWith(u8, kv, "TEST_TMPDIR=")) say("{s}\n", .{kv});
        }
        var n: usize = 0;
        if (std.fs.openDirAbsolute(tmp, .{ .iterate = true })) |dir| {
            var d = dir;
            var it = d.iterate();
            while (it.next() catch null) |_| n += 1;
            d.close();
        } else |_| n = 999;
        say("entries {d}\n", .{n});
        const sh = std.fmt.allocPrint(a, "{s}/../bin/sh", .{tmp}) catch posix.exit(99);
        say("applets {}\n", .{exists(sh)});
        const mine = std.fmt.allocPrint(a, "{s}/left_by_test", .{tmp}) catch posix.exit(99);
        writeFile(mine, "x") catch {};
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "lines")) {
        const n = num(arg(args, 1), 0);
        const nl = num(arg(args, 2), 1);
        var k: u64 = 1;
        while (k <= n) : (k += 1) {
            if (k == n and nl == 0) say("line {d}", .{k}) else say("line {d}\n", .{k});
        }
        posix.exit(@intCast(num(arg(args, 3), 1)));
    }
    if (std.mem.eql(u8, name, "pid")) {
        appendPid(arg(args, 1) orelse posix.exit(99), sys.getpid());
        if (args.len < 3) posix.exit(99);
        behave(a, args[2], args[2..], env);
    }
    if (std.mem.startsWith(u8, name, "rust_")) rustFake(name, args, env);
    say("fixture: unknown behaviour {s}\n", .{name});
    posix.exit(98);
}

/// Fake libtest harnesses: `--list --format terse` lists, no argument runs.
fn rustFake(name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const listing = args.len > 1 and std.mem.eql(u8, args[1], "--list");
    const eq = std.mem.eql;
    if (eq(u8, name, "rust_ok")) {
        if (listing) {
            say("a::one: test\na::two: test\nb::three: test\n", .{});
        } else say("running 3 tests\ntest a::one ... ok\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_empty")) {
        if (listing) say("\n", .{}) else say("test result: ok. 0 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_listfails")) {
        if (listing) {
            sys.writeAll(2, "cannot list\n");
            posix.exit(5);
        }
        posix.exit(0);
    }
    if (eq(u8, name, "rust_ignored")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test a ... ok\ntest b ... ignored\ntest result: ok. 1 passed; 0 failed; 1 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_mismatch")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test result: ok. 1 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_nosummary")) {
        if (listing) say("a: test\n", .{}) else say("test a ... ok\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_fails")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        say("test a ... FAILED\ntest result: FAILED. 0 passed; 1 failed; 0 ignored;\n", .{});
        posix.exit(101);
    }
    if (eq(u8, name, "rust_killed")) {
        if (!listing) posix.raise(posix.SIG.KILL) catch {};
        say("a: test\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_killedlist")) {
        posix.raise(posix.SIG.KILL) catch {};
        posix.exit(0);
    }
    if (eq(u8, name, "rust_hangs")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        sys.sleepMs(100_000);
        posix.exit(0);
    }
    if (eq(u8, name, "rust_env")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(7);
    }
    posix.exit(98);
}
