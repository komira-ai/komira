//! cases: runs the real compile wrapper (tools/build/mojo/tools/mojo_compile.zig)
//! against the stand-in toolchain (standin.zig) and requires each verdict.
//! Writes one line per case to <report> ("ok <case>" or "BAD <case>: <why>")
//! and exits 1 if any case is BAD or fewer cases than its floor say ok.
//!
//! usage: cases <mojo_compile> <standin> <report>
//!
//! Each case runs the wrapper in a directory of its own, with an
//! environment of exactly PWD, BUCK_SCRATCH_PATH=<case>/bsp, PATH=/nonexistent
//! and a variable the compiler must not see, under a deadline of its own, so
//! a watchdog that never fires is a BAD case, not a hung action. After every
//! case but the SIGKILL one the scratch directory (<case>/bsp/komira) must be
//! gone, and a child the stand-in recorded (child.pid) must not be alive.
//!
//! Built for macOS (tests//functional/watchdog:cases_darwin) it runs the
//! macOS wrapper (mojo_compile_macos.zig) on a macOS worker: every case but
//! `link` (the macOS shim runs the host's /usr/bin/cc, which no stand-in
//! replaces), with `--deployment-target` and this host's `--macos-host` in
//! place of the Linux flags and the macOS environment in `envdump`, plus
//! the macOS refusals: an unlisted host, no host, a bundle-shaped
//! shared-lib build (a self-named one is accepted), a modular.cfg
//! shared_libs line other than the compiler's lib/, and a Linux flag.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const SIG = posix.SIG;
const W = posix.W;

/// Built for macOS (the cases of tests//functional/watchdog:cases_darwin,
/// against the darwin wrapper on a macOS worker), else Linux.
const macos = builtin.os.tag == .macos;

/// macOS: the `--macos-host=<id>` every case passes (this host's identity,
/// from the wrapper's `host-identity` mode), or empty for none.
var host_flag: [:0]const u8 = "";

fn kill(pid: i32, sig: u6) void {
    if (macos) {
        _ = std.c.kill(pid, sig);
    } else {
        _ = linux.kill(pid, sig);
    }
}

var arena: std.mem.Allocator = undefined;
var root: []const u8 = undefined; // <cwd>/.komira_watchdog_cases
var wrapper: [:0]const u8 = undefined;
var report: std.ArrayList(u8) = undefined;
var bad = false;

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("watchdog cases: " ++ f ++ "\n", args);
    std.process.exit(2);
}

fn str(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, f, args) catch die("out of memory", .{});
}

fn strZ(comptime f: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, f, args, 0) catch die("out of memory", .{});
}

fn writeFile(path: []const u8, data: []const u8) void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |e| die("cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn readFile(path: []const u8) ?[]const u8 {
    return std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch null;
}

fn exists(path: []const u8) bool {
    _ = posix.fstatat(posix.AT.FDCWD, path, posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

/// macOS: modular.cfg with the one `shared_libs` line the wrapper accepts.
const macos_cfg = "[max]\nroot = @@MOJO_TOOLCHAIN_ROOT@@\nshared_libs = -Xlinker,-rpath,-Xlinker,@@MOJO_TOOLCHAIN_ROOT@@/lib;\n";

fn makeToolchain(name: []const u8, manifest: []const u8, with_mojo: bool, standin_path: []const u8) void {
    const tc = str("{s}/{s}", .{ root, name });
    std.fs.cwd().makePath(str("{s}/bin", .{tc})) catch die("cannot make {s}", .{tc});
    std.fs.cwd().makePath(str("{s}/share/max", .{tc})) catch die("cannot make {s}", .{tc});
    writeFile(str("{s}/CLOSURE_MANIFEST", .{tc}), manifest);
    writeFile(str("{s}/share/max/modular.cfg", .{tc}), if (macos) macos_cfg else "[max]\nroot = @@MOJO_TOOLCHAIN_ROOT@@\n");
    if (with_mojo) posix.symlink(standin_path, str("{s}/bin/mojo", .{tc})) catch die("cannot link {s}/bin/mojo", .{tc});
}

/// macOS: this host's identity, from the wrapper's `host-identity` mode, run
/// with the environment every case gives the wrapper.
fn hostIdentity() []const u8 {
    const out = str("{s}/host.txt", .{root});
    const argv = [_:null]?[*:0]const u8{ wrapper, "host-identity", strZ("--output={s}", .{out}) };
    const envp = [_:null]?[*:0]const u8{"PATH=/nonexistent"};
    const pid = posix.fork() catch die("cannot fork", .{});
    if (pid == 0) {
        _ = std.c.execve(wrapper, &argv, &envp);
        std.c._exit(127);
    }
    const st = posix.waitpid(pid, 0).status;
    if (statusOf(st) != 0) die("{s} host-identity exited {d}", .{ wrapper, statusOf(st) });
    const text = readFile(out) orelse die("{s} host-identity wrote no {s}", .{ wrapper, out });
    return std.mem.trim(u8, text, " \n");
}

const Run = struct {
    /// The wrapper's status (128+N when signal N killed it), or null when it
    /// outlived its deadline (then it was killed).
    rc: ?u8,
    dir: []const u8,
    log: []const u8,
};

const Spec = struct {
    name: []const u8,
    tc: []const u8 = "tc",
    flags: []const []const u8 = &.{},
    mojo: []const []const u8,
    /// A file in the case directory to give the wrapper as stdin (else
    /// /dev/null). Every wrapper starts with default dispositions.
    stdin_file: ?[]const u8 = null,
};

fn caseDir(name: []const u8) []const u8 {
    return str("{s}/{s}", .{ root, name });
}

fn scratchOf(dir: []const u8) []const u8 {
    return str("{s}/bsp/komira", .{dir});
}

fn spawn(s: Spec) struct { pid: i32, dir: []const u8 } {
    const dir = caseDir(s.name);
    std.fs.cwd().makePath(str("{s}/bsp", .{dir})) catch die("cannot make {s}", .{dir});
    var argv = std.ArrayList(?[*:0]const u8).empty;
    argv.append(arena, wrapper) catch unreachable;
    argv.append(arena, strZ("--compiler={s}/{s}", .{ root, s.tc })) catch unreachable;
    if (macos) {
        argv.append(arena, "--deployment-target=11.0") catch unreachable;
        if (host_flag.len > 0) argv.append(arena, host_flag) catch unreachable;
    } else {
        argv.append(arena, strZ("--zig={s}/zig", .{root})) catch unreachable;
        argv.append(arena, "--cc-target=x86_64-linux-gnu") catch unreachable;
    }
    for (s.flags) |f| argv.append(arena, strZ("{s}", .{f})) catch unreachable;
    argv.append(arena, "--") catch unreachable;
    for (s.mojo) |a| argv.append(arena, strZ("{s}", .{a})) catch unreachable;
    argv.append(arena, null) catch unreachable;
    const envp = [_:null]?[*:0]const u8{
        strZ("PWD={s}", .{dir}),
        strZ("BUCK_SCRATCH_PATH={s}/bsp", .{dir}),
        "PATH=/nonexistent",
        "KOMIRA_CASES_LEAK=must-not-reach-the-compiler",
    };
    const dir_z = strZ("{s}", .{dir});
    const log_z = strZ("{s}/log", .{dir});
    const in_z = if (s.stdin_file) |f| strZ("{s}/{s}", .{ dir, f }) else strZ("/dev/null", .{});
    const pid = posix.fork() catch die("cannot fork", .{});
    if (pid == 0) {
        const av: Argv = @ptrCast(argv.items.ptr);
        if (macos) childMacos(dir_z, log_z, in_z, av, &envp) else childLinux(dir_z, log_z, in_z, av, &envp);
    }
    return .{ .pid = pid, .dir = dir };
}

const Argv = [*:null]const ?[*:0]const u8;

/// In the forked child: the case directory, the log on stdout and stderr,
/// the case's stdin, default dispositions, then the wrapper.
fn childLinux(dir_z: [*:0]const u8, log_z: [*:0]const u8, in_z: [*:0]const u8, argv: Argv, envp: Argv) noreturn {
    if (posix.errno(linux.chdir(dir_z)) != .SUCCESS) linux.exit_group(120);
    const log = linux.open(log_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (posix.errno(log) != .SUCCESS) linux.exit_group(121);
    _ = linux.dup2(@intCast(log), 1);
    _ = linux.dup2(@intCast(log), 2);
    const in = linux.open(in_z, .{ .ACCMODE = .RDONLY }, 0);
    if (posix.errno(in) != .SUCCESS) linux.exit_group(122);
    _ = linux.dup2(@intCast(in), 0);
    for ([_]u6{ SIG.HUP, SIG.INT, SIG.QUIT, SIG.TERM }) |sig| {
        const sa = linux.Sigaction{ .handler = .{ .handler = SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        _ = linux.sigaction(sig, &sa, null);
    }
    _ = linux.execve(wrapper, argv, envp);
    linux.exit_group(123);
}

fn childMacos(dir_z: [*:0]const u8, log_z: [*:0]const u8, in_z: [*:0]const u8, argv: Argv, envp: Argv) noreturn {
    const c = std.c;
    if (c.chdir(dir_z) != 0) c._exit(120);
    const log = c.open(log_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (log < 0) c._exit(121);
    _ = c.dup2(log, 1);
    _ = c.dup2(log, 2);
    const in = c.open(in_z, .{ .ACCMODE = .RDONLY });
    if (in < 0) c._exit(122);
    _ = c.dup2(in, 0);
    for ([_]u6{ SIG.HUP, SIG.INT, SIG.QUIT, SIG.TERM }) |sig| {
        const sa = posix.Sigaction{ .handler = .{ .handler = SIG.DFL }, .mask = 0, .flags = 0 };
        posix.sigaction(sig, &sa, null);
    }
    _ = c.execve(wrapper, argv, envp);
    c._exit(123);
}

fn statusOf(st: u32) u8 {
    if (W.IFEXITED(st)) return W.EXITSTATUS(st);
    return @intCast(128 + (W.TERMSIG(st) & 0x7f));
}

/// Waits for `pid` up to `secs`; kills it and returns null past that.
fn waitFor(pid: i32, secs: u64) ?u8 {
    const end = std.time.milliTimestamp() + @as(i64, @intCast(secs * 1000));
    while (std.time.milliTimestamp() < end) {
        const r = posix.waitpid(pid, W.NOHANG);
        if (r.pid == pid) return statusOf(r.status);
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    kill(pid, SIG.KILL);
    _ = posix.waitpid(pid, 0);
    return null;
}

fn run(s: Spec) Run {
    const sp = spawn(s);
    const rc = waitFor(sp.pid, 60);
    return .{ .rc = rc, .dir = sp.dir, .log = readFile(str("{s}/log", .{sp.dir})) orelse "" };
}

/// Running, stopped or sleeping: not a zombie, and not gone.
fn alive(pid: i32) bool {
    if (macos) return aliveMacos(pid);
    var buf: [512]u8 = undefined;
    const f = std.fs.cwd().openFile(str("/proc/{d}/stat", .{pid}), .{}) catch return false;
    defer f.close();
    const n = f.readAll(&buf) catch return false;
    const rp = std.mem.lastIndexOfScalar(u8, buf[0..n], ')') orelse return false;
    if (rp + 2 >= n) return false;
    const st = buf[rp + 2];
    return st != 'Z' and st != 'X';
}

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// macOS: proc_pidinfo(PROC_PIDTBSDINFO = 3) fills a `struct proc_bsdinfo`
/// (136 bytes) whose `pbi_status` (a u32 at offset 4) is SZOMB (5) for a
/// zombie; a pid it cannot read is gone.
fn aliveMacos(pid: i32) bool {
    var buf: [136]u8 align(8) = undefined;
    if (proc_pidinfo(pid, 3, 0, &buf, buf.len) != buf.len) return false;
    return std.mem.readInt(u32, buf[4..8], .little) != 5;
}

fn pidIn(dir: []const u8, name: []const u8) ?i32 {
    const text = readFile(str("{s}/{s}", .{ dir, name })) orelse return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn lastLines(log: []const u8) []const u8 {
    var t = std.mem.trimRight(u8, log, "\n");
    var k: usize = 0;
    var i = t.len;
    while (i > 0) : (i -= 1) {
        if (t[i - 1] == '\n') {
            k += 1;
            if (k == 3) break;
        }
    }
    t = t[i..];
    return std.mem.replaceOwned(u8, arena, t, "\n", " | ") catch t;
}

fn verdict(name: []const u8, why: ?[]const u8, log: []const u8) void {
    if (why) |w| {
        const line = str("BAD {s}: {s}: {s}\n", .{ name, w, lastLines(log) });
        std.debug.print("{s}", .{line});
        report.appendSlice(arena, line) catch unreachable;
        bad = true;
    } else {
        report.appendSlice(arena, str("ok {s}\n", .{name})) catch unreachable;
    }
}

fn killLeftovers(dir: []const u8) void {
    for ([_][]const u8{ "child.pid", "compiler.pid" }) |n| {
        if (pidIn(dir, n)) |p| {
            if (p > 1) kill(p, SIG.KILL);
        }
    }
}

/// The checks every finished case shares: status, text in the log, the
/// recorded child dead, the scratch directory gone.
fn check(s: Spec, want: u8, text: ?[]const u8) ?[]const u8 {
    std.debug.print("watchdog case: {s}\n", .{s.name});
    const r = run(s);
    defer killLeftovers(r.dir);
    const why: ?[]const u8 = blk: {
        const rc = r.rc orelse break :blk "outlived its 60 s deadline";
        if (rc != want) break :blk str("exit {d}, want {d}", .{ rc, want });
        if (text) |t| {
            if (std.mem.indexOf(u8, r.log, t) == null) break :blk str("no '{s}' in its output", .{t});
        }
        if (pidIn(r.dir, "child.pid")) |c| {
            // A killed child whose parent died too may linger as a zombie
            // until a reaper collects it; only a live state outlived the kill.
            if (alive(c)) break :blk str("the compiler's child {d} outlived the kill", .{c});
        }
        if (exists(scratchOf(r.dir))) break :blk str("the scratch directory {s} was left", .{scratchOf(r.dir)});
        break :blk null;
    };
    if (why != null) return str("{s}: {s}", .{ why.?, lastLines(r.log) });
    return null;
}

fn expect(s: Spec, want: u8, text: ?[]const u8) void {
    const why = check(s, want, text);
    if (why) |w| {
        const line = str("BAD {s}: {s}\n", .{ s.name, w });
        std.debug.print("{s}", .{line});
        report.appendSlice(arena, line) catch unreachable;
        bad = true;
    } else {
        report.appendSlice(arena, str("ok {s}\n", .{s.name})) catch unreachable;
    }
}

/// The wrapper is signalled while its compiler (and the compiler's child)
/// hang with the watchdog far from firing. Within 5 s of the signal both
/// must be gone: a caught signal kills the tree before the wrapper exits
/// (128 + signal, scratch removed); SIGKILL cannot be caught, and the tether
/// in the compiler's session must kill it (137).
fn killed(name: []const u8, sig: u6, want: u8) void {
    std.debug.print("watchdog case: {s}\n", .{name});
    const sp = spawn(.{ .name = name, .flags = &.{ "--watchdog-idle-secs=600", "--watchdog-sample-secs=1" }, .mojo = &.{ "hangpid", "-o", "out.mojoc" } });
    defer killLeftovers(sp.dir);
    var n: usize = 0;
    while (n < 200 and (pidIn(sp.dir, "child.pid") == null or pidIn(sp.dir, "compiler.pid") == null)) : (n += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    const why: ?[]const u8 = blk: {
        const child = pidIn(sp.dir, "child.pid") orelse {
            kill(sp.pid, SIG.KILL);
            _ = posix.waitpid(sp.pid, 0);
            break :blk "the stand-in compiler did not start";
        };
        const compiler = pidIn(sp.dir, "compiler.pid").?;
        kill(sp.pid, sig);
        const rc = waitFor(sp.pid, 30) orelse break :blk "the wrapper outlived the signal by 30 s";
        if (rc != want) break :blk str("the wrapper exited {d}, want {d}", .{ rc, want });
        var left: []const u8 = "";
        var k: usize = 0;
        while (k < 50) : (k += 1) {
            left = "";
            if (alive(compiler)) left = str("{s} {d}", .{ left, compiler });
            if (alive(child)) left = str("{s} {d}", .{ left, child });
            if (left.len == 0) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (left.len > 0) break :blk str("still alive 5 s after signal {d} to the wrapper:{s}", .{ sig, left });
        if (sig != SIG.KILL and exists(scratchOf(sp.dir))) break :blk "the scratch directory was left";
        break :blk null;
    };
    verdict(name, why, readFile(str("{s}/log", .{sp.dir})) orelse "");
}

fn lines(text: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, text, "\n"), '\n');
    while (it.next()) |l| out.append(arena, l) catch unreachable;
    return out.toOwnedSlice(arena) catch unreachable;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sameLines(name: []const u8, got_text: ?[]const u8, want: []const []const u8, sort: bool) ?[]const u8 {
    const got = lines(got_text orelse return str("{s} was not written", .{name}));
    const w = arena.dupe([]const u8, want) catch unreachable;
    if (sort) {
        std.mem.sort([]const u8, got, {}, lessThan);
        std.mem.sort([]const u8, w, {}, lessThan);
    }
    var i: usize = 0;
    while (i < @max(got.len, w.len)) : (i += 1) {
        const g = if (i < got.len) got[i] else "<none>";
        const x = if (i < w.len) w[i] else "<none>";
        if (!std.mem.eql(u8, g, x)) return str("{s} line {d} is '{s}', want '{s}'", .{ name, i + 1, g, x });
    }
    return null;
}

/// A case whose wrapper must exit 0, then whose file `file` (in the case
/// directory) must hold exactly `want`.
fn expectFile(s: Spec, file: []const u8, want: []const []const u8, sort: bool) void {
    var why = check(s, 0, null);
    if (why == null) why = sameLines(file, readFile(str("{s}/{s}", .{ caseDir(s.name), file })), want, sort);
    verdict(s.name, why, "");
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    arena = arena_state.allocator();
    report = std.ArrayList(u8).empty;
    const argv = std.process.argsAlloc(arena) catch die("out of memory", .{});
    if (argv.len != 4) die("usage: cases <mojo_compile> <standin> <report>", .{});
    const cwd = std.process.getCwdAlloc(arena) catch die("cannot read the working directory", .{});
    const abs = struct {
        fn f(c: []const u8, p: []const u8) []const u8 {
            return if (p.len > 0 and p[0] == '/') p else str("{s}/{s}", .{ c, p });
        }
    }.f;
    wrapper = strZ("{s}", .{abs(cwd, argv[1])});
    const standin_path = abs(cwd, argv[2]);
    root = str("{s}/.komira_watchdog_cases", .{cwd});
    std.fs.deleteTreeAbsolute(root) catch {};
    std.fs.cwd().makePath(str("{s}/zig", .{root})) catch die("cannot make {s}", .{root});
    posix.symlink(standin_path, str("{s}/zig/zig", .{root})) catch die("cannot link zig", .{});
    makeToolchain("tc", "bin/mojo\n", true, standin_path);
    makeToolchain("tc_missing", "bin/mojo\nlib/libmissing.so\n", true, standin_path);
    makeToolchain("tc_noexec", "share/max/modular.cfg\n", false, standin_path);
    if (macos) {
        // A shared_libs line naming another directory than the compiler's lib/.
        makeToolchain("tc_badcfg", "bin/mojo\n", true, standin_path);
        writeFile(str("{s}/tc_badcfg/share/max/modular.cfg", .{root}), "[max]\nshared_libs = -Xlinker,-rpath,-Xlinker,/opt/lib;\n");
        host_flag = strZ("--macos-host={s}", .{hostIdentity()});
    }

    const knobs: []const []const u8 = &.{ "--watchdog-idle-secs=3", "--watchdog-sample-secs=1" };
    const killed_text = "mojo-watchdog: killed deadlocked compiler";
    const o = [_][]const u8{ "-o", "out.mojoc" };

    // The verdicts of the compile watchdog.
    expect(.{ .name = "hang", .flags = knobs, .mojo = &([_][]const u8{"hang"} ++ o) }, 124, killed_text);
    expect(.{ .name = "treehang", .flags = knobs, .mojo = &([_][]const u8{"treehang"} ++ o) }, 124, killed_text);
    expect(.{ .name = "orphan", .flags = knobs, .mojo = &([_][]const u8{"orphan"} ++ o) }, 124, killed_text);
    // The root sleeps while an orphaned member of its session does the work:
    // CPU anywhere in the session counts, so it is not killed.
    expect(.{ .name = "orphanspin", .flags = knobs, .mojo = &([_][]const u8{"orphanspin"} ++ o) }, 0, null);
    expect(.{ .name = "spin", .flags = knobs, .mojo = &([_][]const u8{"spin"} ++ o) }, 0, null);
    expect(.{ .name = "childspin", .flags = knobs, .mojo = &([_][]const u8{"childspin"} ++ o) }, 0, null);
    expect(.{ .name = "short_nap", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 0, null);
    expect(.{ .name = "compiler_error", .flags = knobs, .mojo = &([_][]const u8{"fail"} ++ o) }, 7, null);
    // A compiler killed by signal N gives 128+N (design item 30), through
    // the watchdog's wait and through the plain wait of idle 0.
    expect(.{ .name = "compiler_signalled", .flags = knobs, .mojo = &([_][]const u8{"selfkill"} ++ o) }, 128 + @as(u8, SIG.USR1), null);
    expect(.{ .name = "compiler_signalled_plain", .flags = &.{"--watchdog-idle-secs=0"}, .mojo = &([_][]const u8{"selfkill"} ++ o) }, 128 + @as(u8, SIG.USR1), null);
    expect(.{ .name = "disabled", .flags = &.{ "--watchdog-idle-secs=0", "--watchdog-sample-secs=1" }, .mojo = &([_][]const u8{"nap5"} ++ o) }, 0, null);
    expect(.{ .name = "enabled", .flags = &.{ "--watchdog-idle-secs=2", "--watchdog-sample-secs=1" }, .mojo = &([_][]const u8{"nap5"} ++ o) }, 124, killed_text);
    expect(.{ .name = "default_knobs", .mojo = &([_][]const u8{"nap2"} ++ o) }, 0, null);
    expect(.{ .name = "bad_sample", .flags = &.{"--watchdog-sample-secs=0"}, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "watchdog-sample-secs must be at least 1");
    expect(.{ .name = "bad_idle", .flags = &.{"--watchdog-idle-secs=5m"}, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "whole numbers");

    // The wrapper signalled.
    killed("wrapper_term", SIG.TERM, 143);
    killed("wrapper_hup", SIG.HUP, 129);
    killed("wrapper_int", SIG.INT, 130);
    killed("wrapper_kill", SIG.KILL, 137);

    // The environment the compiler sees: exactly these variables.
    if (macos) {
        const dir = caseDir("envdump");
        const t = scratchOf(dir);
        const tc = str("{s}/tc", .{root});
        expectFile(.{ .name = "envdump", .flags = knobs, .mojo = &([_][]const u8{"envdump"} ++ o) }, "env.txt", &.{
            str("PATH={s}/cc:{s}/bin", .{ t, tc }),
            str("MODULAR_HOME={s}/modular", .{t}),
            str("CC={s}/cc/cc", .{t}),
            "MACOSX_DEPLOYMENT_TARGET=11.0",
            str("MODULAR_CACHE_DIR={s}/cache", .{t}),
            str("TMPDIR={s}/tmp", .{t}),
            str("HOME={s}/home", .{t}),
            str("XDG_CACHE_HOME={s}/cache", .{t}),
            "KGEN_CompilerRT_AsyncRT_ParallelismLevel=1",
            "MODULAR_CRASH_REPORTING_ENABLED=false",
            str("KOMIRA_CC_SHIM={s}/cc/shim.cfg", .{t}),
            str("PWD={s}", .{dir}),
            str("BUCK_SCRATCH_PATH={s}/bsp", .{dir}),
        }, true);
    } else {
        const dir = caseDir("envdump");
        const t = scratchOf(dir);
        const tc = str("{s}/tc", .{root});
        expectFile(.{ .name = "envdump", .flags = knobs, .mojo = &([_][]const u8{"envdump"} ++ o) }, "env.txt", &.{
            str("PATH={s}/cc:{s}/bin", .{ t, tc }),
            str("MODULAR_HOME={s}/modular", .{t}),
            str("LD_LIBRARY_PATH={s}/lib", .{tc}),
            str("CC={s}/cc/cc", .{t}),
            str("CXX={s}/cc/c++", .{t}),
            str("MODULAR_CACHE_DIR={s}/cache", .{t}),
            str("TMPDIR={s}/tmp", .{t}),
            str("HOME={s}/home", .{t}),
            str("XDG_CACHE_HOME={s}/cache", .{t}),
            str("ZIG_GLOBAL_CACHE_DIR={s}/cache/zig-global", .{t}),
            str("ZIG_LOCAL_CACHE_DIR={s}/cache/zig-local", .{t}),
            "KGEN_CompilerRT_AsyncRT_ParallelismLevel=1",
            "MODULAR_CRASH_REPORTING_ENABLED=false",
            str("KOMIRA_CC_SHIM={s}/cc/shim.cfg", .{t}),
            str("PWD={s}", .{dir}),
            str("BUCK_SCRATCH_PATH={s}/bsp", .{dir}),
        }, true);
    }

    // The link: `cc` from PATH is the shim, and zig receives exactly the
    // rewritten line (design items 15, 16, 19) of standin.zig's link_inputs.
    // Linux only: the macOS shim runs the host's /usr/bin/cc, which no
    // stand-in replaces; its line is cc_shim.zig's unit tests, and a real
    // link on the macOS workers is the build of any darwin Mojo binary.
    if (!macos) {
        var want = std.ArrayList([]const u8).empty;
        want.appendSlice(arena, &.{
            str("{s}/zig/zig", .{root}), "cc",                     "-target",              "x86_64-linux-gnu",
            "-Wl,--strip-debug",         "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/x",
        }) catch unreachable;
        want.appendSlice(arena, &.{
            "-L/d",   "-lfoo",    "-Wl,--gc-sections", "-Xlinker", "-soname",   "-Xlinker", "libx.so",
            "-Xlinker", "-z",     "keep.o",            "-Xlinker", "now",       "bare.o",   "-L/f",
            "-lg",    "-o",       "out.mojoc",         "-Xlinker", "libtail.a", "-lc++",
        }) catch unreachable;
        expectFile(.{
            .name = "link",
            .flags = &.{ "--watchdog-idle-secs=3", "--watchdog-sample-secs=1", "--runpath=$ORIGIN/x", "--link-tail=libtail.a", "--link-tail=-lc++" },
            .mojo = &([_][]const u8{"link"} ++ o),
        }, "zig.argv", want.items, false);
    }

    // What the compiler starts with: with the watchdog, stdin /dev/null,
    // SIGINT and SIGQUIT ignored, and its pid the session id; without it,
    // the wrapper's stdin and dispositions, in the wrapper's session.
    // Both runs give the wrapper a regular file as stdin, so a compiler
    // that inherited it is seen.
    for ([_][]const u8{ "sigstate", "sigstate_off" }) |name| {
        const dir = caseDir(name);
        std.fs.cwd().makePath(dir) catch die("cannot make {s}", .{dir});
        writeFile(str("{s}/stdin.txt", .{dir}), "the runner's stdin\n");
    }
    expectFile(.{ .name = "sigstate", .flags = knobs, .mojo = &([_][]const u8{"sigstate"} ++ o), .stdin_file = "stdin.txt" }, "sigstate.txt", &.{"stdin=devnull int=ign quit=ign leader=yes"}, false);
    {
        expectFile(.{ .name = "sigstate_off", .flags = &.{"--watchdog-idle-secs=0"}, .mojo = &([_][]const u8{"sigstate"} ++ o), .stdin_file = "stdin.txt" }, "sigstate.txt", &.{"stdin=other int=dfl quit=dfl leader=no"}, false);
    }

    // Output checks and refusals, each with the scratch directory gone.
    expect(.{ .name = "empty", .flags = knobs, .mojo = &([_][]const u8{"empty"} ++ o) }, 3, "is missing or empty");
    expect(.{ .name = "cwd", .flags = knobs, .mojo = &([_][]const u8{"cwd"} ++ o) }, 4, "contains this action's working directory");
    expect(.{ .name = "noout", .flags = knobs, .mojo = &.{"nap2"} }, 2, "no -o <output>");
    expect(.{ .name = "manifest", .tc = "tc_missing", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "toolchain member 'lib/libmissing.so' is missing or empty");
    expect(.{ .name = "noexec", .tc = "tc_noexec", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 127, "cannot run");
    expect(.{ .name = "noexec_plain", .tc = "tc_noexec", .flags = &.{"--watchdog-idle-secs=0"}, .mojo = &([_][]const u8{"nap2"} ++ o) }, 127, "cannot run");

    // macOS: the host must be one the action names; the bundle shape is
    // refused; modular.cfg must ask for the one run path the wrapper
    // rewrites; a Linux flag is refused.
    if (macos) {
        const listed = host_flag;
        host_flag = "--macos-host=0.0-nohost";
        expect(.{ .name = "unlisted_host", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "REFUSING: this host's identity is");
        host_flag = "";
        expect(.{ .name = "no_host", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "no --macos-host");
        host_flag = listed;
        expect(.{ .name = "shared_lib_bundle", .flags = knobs, .mojo = &([_][]const u8{ "nap2", "--emit", "shared-lib" } ++ o) }, 2, "bundles are linux only");
        expect(.{ .name = "shared_lib_dylib", .flags = knobs, .mojo = &([_][]const u8{ "nap2", "--emit", "shared-lib", "-Xlinker", "-install_name", "-Xlinker", "@rpath/x.dylib" } ++ o) }, 0, null);
        expect(.{ .name = "shared_libs_cfg", .tc = "tc_badcfg", .flags = knobs, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "shared_libs is not the one run path");
        expect(.{ .name = "linux_flag", .flags = &.{"--zig=/z"}, .mojo = &([_][]const u8{"nap2"} ++ o) }, 2, "is a Linux option");
    }

    // The floor: a run that wrote fewer ok cases than this (a case deleted,
    // a case that never says ok) is refused here in the action, so the
    // report cannot pass with less in it. Raise it when a case is added.
    const floor = if (macos) 34 else 29;
    var ok_lines: usize = 0;
    var report_lines = std.mem.splitScalar(u8, report.items, '\n');
    while (report_lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "ok ")) ok_lines += 1;
    }
    if (ok_lines < floor) {
        const line = str("BAD floor: {d} ok case(s), fewer than the {d} cases of this runner\n", .{ ok_lines, floor });
        std.debug.print("{s}", .{line});
        report.appendSlice(arena, line) catch unreachable;
        bad = true;
    }

    writeFile(argv[3], report.items);
    std.fs.deleteTreeAbsolute(root) catch {};
    std.process.exit(if (bad) 1 else 0);
}
