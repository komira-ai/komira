//! mojo_compile: runs the hermetic Mojo compiler inside one build action
//! (Linux). It replaces tools/build/mojo/mojo_wrapper.sh; the design is
//! docs/design/zig_compile_wrapper.md, whose numbered behaviours this keeps.
//! The macOS build is mojo_compile_macos.zig, which reuses the helpers this
//! file marks `pub` (scratch, refusals, paths, the output checks).
//!
//!   mojo_compile --compiler=<dir> --cc-target=<triple> --zig=<dir>
//!                [--runpath=<$ORIGIN*>] [--source-root=<dir>] [--link-tail=<arg>]...
//!                [--watchdog-idle-secs=<n>] [--watchdog-sample-secs=<n>]
//!                [--ld-debug-output=<file>] -- <mojo arguments...>
//!
//! Started as `cc`, `c++`, `gcc`, `g++`, `clang` or `clang++` (the links in
//! <scratch>/cc/), it is the link shim instead (cc_shim.zig).
//!
//! What it does, in order:
//!   * parses the options (compile_args.zig; any refusal is exit 2);
//!   * makes a private scratch directory, `$BUCK_SCRATCH_PATH/komira`
//!     (relative to the working directory when relative), else
//!     `<cwd>/.komira_action`, holding cc/, home/, tmp/, cache/, modular/;
//!   * checks the toolchain closure: <compiler>/CLOSURE_MANIFEST is
//!     non-empty and names only non-empty files, every missing one reported,
//!     and <zig>/zig is executable;
//!   * renders modular.cfg for this action (modular_cfg.zig);
//!   * writes the shim's settings, <scratch>/cc/shim.cfg, and links the six
//!     compiler-driver names in <scratch>/cc/ to its own executable;
//!   * runs <compiler>/bin/mojo with exactly this environment, nothing
//!     inherited: PATH=<scratch>/cc:<compiler>/bin, MODULAR_HOME,
//!     LD_LIBRARY_PATH=<compiler>/lib, CC, CXX, MODULAR_CACHE_DIR,
//!     XDG_CACHE_HOME, TMPDIR, HOME, ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR,
//!     KGEN_CompilerRT_AsyncRT_ParallelismLevel=1,
//!     MODULAR_CRASH_REPORTING_ENABLED=false, KOMIRA_CC_SHIM, PWD, and
//!     BUCK_SCRATCH_PATH when it is set (coverage's cov_zig reads the last
//!     two); with --ld-debug-output also LD_DEBUG=libs and LD_DEBUG_OUTPUT;
//!   * for `precompile` with --source-root, runs the compiler from the
//!     root's parent (PWD is that directory), given the package by its
//!     basename and `-o`, `-I` made absolute (compile_args.runDir,
//!     compilerArgs), so the `.mojoc` records `<name>/<file>.mojo` and not
//!     the staged buck-out path; the wrapper itself stays in the action
//!     directory, where the output check below runs;
//!   * checks the output and removes the scratch directory.
//!
//! The compile watchdog (idle > 0). The compiler leads a session of its own:
//! the wrapper forks it, it calls setsid(), starts a tether in that session
//! (not as its own child: see rootChild), puts /dev/null on
//! its stdin, ignores SIGINT and SIGQUIT (as a background job of a shell
//! would have) and execs the compiler. Each second the wrapper checks whether
//! the compiler is gone; every `sample` seconds it reads the CPU of its
//! process tree (proc_tree.zig). After ceil(idle/sample) consecutive samples
//! in which the tree gained under 1% of one CPU, it kills the tree and exits
//! 124. A slow compile uses CPU throughout and is never killed; there is no
//! wall-clock limit. HUP, INT or TERM to the wrapper kills the tree and exits
//! 129, 130 or 143. A SIGKILLed wrapper takes the compiler with it: the
//! tether blocks reading a pipe whose only writer is the wrapper, and when
//! the kernel closes it the tether kills the session. On a normal exit the
//! wrapper kills the tether only; processes the compiler orphaned are left
//! alone. With idle 0 the compiler is a plain child: no session, no tether,
//! no signal handling, the wrapper's stdin and dispositions.
//!
//! Exit status: the compiler's (128+N when signal N killed it); 124 the
//! watchdog killed it; 129, 130, 143 the wrapper was signalled; 2 a refusal;
//! 3 the compiler exited 0 but the -o output is missing or empty; 4 the output
//! holds the working directory ($PWD, or getcwd() when it differs); 126 or
//! 127 the compiler could not be started (127: not found). mutation.bzl's
//! _INFRA_EXITS reads these numbers. The scratch directory is removed on
//! every exit the wrapper makes; a SIGKILLed wrapper, or a signal with idle 0,
//! leaves it (buck2 owns BUCK_SCRATCH_PATH).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const compile_args = @import("compile_args.zig");
const cc_shim = @import("cc_shim.zig");
const modular_cfg = @import("modular_cfg.zig");
const proc_tree = @import("proc_tree.zig");

test {
    _ = @import("compile_args.zig");
    _ = @import("cc_shim.zig");
    _ = @import("modular_cfg.zig");
    _ = @import("proc_tree.zig");
}

/// The scratch directory, once it may exist: removed by `finish`.
pub var scratch: ?[]const u8 = null;
/// The signal a handler caught (HUP, INT or TERM), or 0.
var caught = std.atomic.Value(u32).init(0);

pub const Envp = [*:null]const ?[*:0]const u8;
pub const Argv = [*:null]const ?[*:0]const u8;

pub fn finish(code: u8) noreturn {
    if (scratch) |t| std.fs.deleteTreeAbsolute(t) catch {};
    std.process.exit(code);
}

pub fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("mojo_compile: " ++ fmt ++ "\n", args);
}

pub fn refuse(comptime fmt: []const u8, args: anytype) noreturn {
    say(fmt, args);
    finish(2);
}

pub fn oom() noreturn {
    refuse("out of memory", .{});
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = std.process.argsAlloc(arena) catch oom();
    const args = arena.alloc([]const u8, argv.len) catch oom();
    for (argv, 0..) |a, i| args[i] = a;
    if (args.len > 0 and cc_shim.isShimName(std.fs.path.basename(args[0]))) shimMain(arena, args[1..]);
    wrapperMain(arena, if (args.len > 0) args[1..] else args);
}

// ---- the cc shim ---------------------------------------------------------------

fn shimMain(arena: std.mem.Allocator, args: []const []const u8) noreturn {
    const path = posix.getenv("KOMIRA_CC_SHIM") orelse {
        std.debug.print("cc shim: KOMIRA_CC_SHIM is not set\n", .{});
        std.process.exit(2);
    };
    const text = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |e| {
        std.debug.print("cc shim: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
    const cfg = cc_shim.parseConfig(arena, text) catch {
        std.debug.print("cc shim: {s} is not a shim configuration\n", .{path});
        std.process.exit(2);
    };
    const line = cc_shim.execLineLinux(arena, cfg, args) catch oom();
    const argv = toArgv(arena, line) catch oom();
    // zig inherits the compiler's environment.
    const envp = arena.allocSentinel(?[*:0]const u8, std.os.environ.len, null) catch oom();
    for (std.os.environ, 0..) |e, i| envp[i] = e;
    const rc = linux.execve(argv[0].?, argv, envp);
    const err = posix.errno(rc);
    std.debug.print("cc shim: cannot run {s}: {s}\n", .{ cfg.zig, @tagName(err) });
    std.process.exit(if (err == .NOENT) 127 else 126);
}

pub fn toArgv(arena: std.mem.Allocator, items: []const []const u8) !Argv {
    const out = try arena.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| out[i] = try arena.dupeZ(u8, s);
    return out;
}

// ---- the wrapper -----------------------------------------------------------------

/// The working directory as a shell spells it: $PWD when it is absolute and
/// names the working directory, else getcwd().
pub fn shellPwd(arena: std.mem.Allocator) []const u8 {
    const cwd = std.process.getCwdAlloc(arena) catch |e| refuse("cannot read the working directory: {s}", .{@errorName(e)});
    const p = posix.getenv("PWD") orelse return cwd;
    if (p.len == 0 or p[0] != '/') return cwd;
    const a = posix.fstatat(posix.AT.FDCWD, p, 0) catch return cwd;
    const b = posix.fstatat(posix.AT.FDCWD, ".", 0) catch return cwd;
    if (a.dev != b.dev or a.ino != b.ino) return cwd;
    return p;
}

pub fn join(arena: std.mem.Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b }) catch oom();
}

/// Exists (following links) and is not empty: the shell's `test -s`.
pub fn nonEmpty(path: []const u8) bool {
    const st = posix.fstatat(posix.AT.FDCWD, path, 0) catch return false;
    return st.size > 0;
}

fn wrapperMain(arena: std.mem.Allocator, args: []const []const u8) noreturn {
    const pwd = shellPwd(arena);
    var diag = compile_args.Diag{};
    const o = compile_args.parse(arena, .linux, pwd, args, &diag) catch |e| switch (e) {
        error.Refused => refuse("{s}", .{diag.msg}),
        error.OutOfMemory => oom(),
    };

    // Private scratch. A remote action has its working directory to itself;
    // a local one runs in the checkout root next to every other local action,
    // so it takes the per-action scratch directory buck2 names.
    const bsp = posix.getenv("BUCK_SCRATCH_PATH") orelse "";
    const t = if (bsp.len == 0)
        join(arena, pwd, ".komira_action")
    else if (bsp[0] == '/')
        join(arena, bsp, "komira")
    else
        join(arena, join(arena, pwd, bsp), "komira");
    scratch = t;
    for ([_][]const u8{ "cc", "home", "tmp", "cache", "modular" }) |sub| {
        std.fs.cwd().makePath(join(arena, t, sub)) catch |e| refuse("cannot make {s}/{s}: {s}", .{ t, sub, @errorName(e) });
    }

    // ---- closure check
    const tc = o.compiler;
    const manifest = join(arena, tc, "CLOSURE_MANIFEST");
    if (!nonEmpty(manifest)) refuse("REFUSING: {s} is missing; the compiler input is not an unpacked toolchain", .{manifest});
    const members = std.fs.cwd().readFileAlloc(arena, manifest, 64 << 20) catch |e| refuse("cannot read {s}: {s}", .{ manifest, @errorName(e) });
    var missing = false;
    var lines = std.mem.splitScalar(u8, members, '\n');
    while (lines.next()) |m| {
        if (m.len == 0) continue;
        if (!nonEmpty(join(arena, tc, m))) {
            say("REFUSING: toolchain member '{s}' is missing or empty", .{m});
            missing = true;
        }
    }
    if (missing) finish(2);
    const zig = join(arena, o.zig, "zig");
    posix.access(zig, posix.X_OK) catch refuse("REFUSING: C link driver {s} is missing", .{zig});

    // ---- modular.cfg, rendered for this action
    const cfg_in = join(arena, tc, "share/max/modular.cfg");
    const cfg_text = std.fs.cwd().readFileAlloc(arena, cfg_in, 16 << 20) catch |e| refuse("REFUSING: cannot read {s}: {s}", .{ cfg_in, @errorName(e) });
    const rendered = (modular_cfg.renderChecked(arena, cfg_text, tc) catch oom()) orelse
        refuse("REFUSING: modular.cfg still holds the toolchain token after rendering", .{});
    const modular_home = join(arena, t, "modular");
    std.fs.cwd().writeFile(.{ .sub_path = join(arena, modular_home, "modular.cfg"), .data = rendered }) catch |e| refuse("cannot write modular.cfg: {s}", .{@errorName(e)});

    // ---- the cc shim: `mojo build` links through `cc` on PATH
    const cc_dir = join(arena, t, "cc");
    const shim_cfg = join(arena, cc_dir, "shim.cfg");
    const shim_text = cc_shim.renderConfig(arena, .{ .zig = zig, .target = o.cc_target, .runpath = o.runpath, .tail = o.link_tail }) catch |e| switch (e) {
        error.BadConfig => refuse("REFUSING: a shim setting holds a newline", .{}),
        error.OutOfMemory => oom(),
    };
    std.fs.cwd().writeFile(.{ .sub_path = shim_cfg, .data = shim_text }) catch |e| refuse("cannot write {s}: {s}", .{ shim_cfg, @errorName(e) });
    const self = std.fs.selfExePathAlloc(arena) catch |e| refuse("cannot read this program's path: {s}", .{@errorName(e)});
    for (cc_shim.shim_names) |n| {
        const link = join(arena, cc_dir, n);
        std.fs.cwd().deleteFile(link) catch {};
        posix.symlink(self, link) catch |e| refuse("cannot link {s}: {s}", .{ link, @errorName(e) });
    }

    // ---- the compiler's environment, built from nothing
    var env = std.ArrayList([]const u8).empty;
    const cache = join(arena, t, "cache");
    const pairs = [_][2][]const u8{
        .{ "PATH", std.fmt.allocPrint(arena, "{s}:{s}/bin", .{ cc_dir, tc }) catch oom() },
        .{ "MODULAR_HOME", modular_home },
        .{ "LD_LIBRARY_PATH", join(arena, tc, "lib") },
        .{ "CC", join(arena, cc_dir, "cc") },
        .{ "CXX", join(arena, cc_dir, "c++") },
        .{ "MODULAR_CACHE_DIR", cache },
        .{ "TMPDIR", join(arena, t, "tmp") },
        .{ "HOME", join(arena, t, "home") },
        .{ "XDG_CACHE_HOME", cache },
        .{ "ZIG_GLOBAL_CACHE_DIR", join(arena, cache, "zig-global") },
        .{ "ZIG_LOCAL_CACHE_DIR", join(arena, cache, "zig-local") },
        .{ "KGEN_CompilerRT_AsyncRT_ParallelismLevel", "1" },
        .{ "MODULAR_CRASH_REPORTING_ENABLED", "false" },
        .{ "KOMIRA_CC_SHIM", shim_cfg },
        .{ "PWD", compile_args.runDir(o) orelse pwd },
    };
    for (pairs) |kv| env.append(arena, std.fmt.allocPrint(arena, "{s}={s}", .{ kv[0], kv[1] }) catch oom()) catch oom();
    if (bsp.len > 0) env.append(arena, std.fmt.allocPrint(arena, "BUCK_SCRATCH_PATH={s}", .{bsp}) catch oom()) catch oom();
    if (o.ld_debug_output) |d| {
        env.append(arena, "LD_DEBUG=libs") catch oom();
        env.append(arena, std.fmt.allocPrint(arena, "LD_DEBUG_OUTPUT={s}", .{d}) catch oom()) catch oom();
    }
    const envp = toArgv(arena, env.items) catch oom();

    const mojo = join(arena, tc, "bin/mojo");
    var cmd = std.ArrayList([]const u8).empty;
    cmd.append(arena, mojo) catch oom();
    cmd.appendSlice(arena, compile_args.compilerArgs(arena, o) catch oom()) catch oom();
    const argv = toArgv(arena, cmd.items) catch oom();
    if (compile_args.runDir(o)) |d| child_dir = (arena.dupeZ(u8, d) catch oom()).ptr;
    const subcmd = if (o.mojo_args.len > 0) o.mojo_args[0] else "";

    const rc = if (o.idle_secs == 0)
        runPlain(mojo, argv, envp)
    else
        runWatched(o, mojo, argv, envp, subcmd);
    finish(postCheck(arena, rc, o.output, pwd));
}

// ---- running the compiler ----------------------------------------------------------

fn pipeCloexec() [2]i32 {
    return posix.pipe2(.{ .CLOEXEC = true }) catch |e| refuse("cannot make a pipe: {s}", .{@errorName(e)});
}

/// The directory the compiler runs in, when not the wrapper's own
/// (compile_args.runDir); the forked child enters it before exec.
var child_dir: ?[*:0]const u8 = null;

/// A report-pipe errno with this bit set came from the chdir, not the exec.
const chdir_failed: u32 = 1 << 31;

/// In a forked child: enter child_dir and exec, or report the errno on
/// `report` and exit 127.
fn execChild(path: [*:0]const u8, argv: Argv, envp: Envp, report: i32) noreturn {
    if (child_dir) |d| {
        const crc = linux.chdir(d);
        if (posix.errno(crc) != .SUCCESS) {
            const e: u32 = @as(u32, @intFromEnum(posix.errno(crc))) | chdir_failed;
            _ = linux.write(report, std.mem.asBytes(&e), 4);
            linux.exit_group(127);
        }
    }
    const rc = linux.execve(path, argv, envp);
    const e: u32 = @intFromEnum(posix.errno(rc));
    _ = linux.write(report, std.mem.asBytes(&e), 4);
    linux.exit_group(127);
}

/// Everything the child wrote on the report pipe before it closed (by exec
/// or exit): up to 8 bytes.
pub fn readReport(fd: i32, buf: *[8]u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = posix.read(fd, buf[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    posix.close(fd);
    return n;
}

fn execFailed(mojo: []const u8, e: u32) u8 {
    const err: linux.E = @enumFromInt(e & ~chdir_failed);
    if (e & chdir_failed != 0) {
        say("cannot run {s}: cannot enter {s}: {s}", .{ mojo, std.mem.span(child_dir.?), @tagName(err) });
    } else {
        say("cannot run {s}: {s}", .{ mojo, @tagName(err) });
    }
    return if (err == .NOENT) 127 else 126;
}

fn statusOf(st: u32) u8 {
    if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
    if (linux.W.IFSIGNALED(st)) return @intCast(128 + (linux.W.TERMSIG(st) & 0x7f));
    return 2;
}

/// Idle 0: a plain child, with the wrapper's stdin and signal dispositions.
fn runPlain(mojo: []const u8, argv: Argv, envp: Envp) u8 {
    const report = pipeCloexec();
    const pid = posix.fork() catch |e| refuse("cannot fork: {s}", .{@errorName(e)});
    if (pid == 0) {
        posix.close(report[0]);
        execChild(argv[0].?, argv, envp, report[1]);
    }
    posix.close(report[1]);
    var buf: [8]u8 = undefined;
    const n = readReport(report[0], &buf);
    const st = posix.waitpid(pid, 0).status;
    if (n >= 4) return execFailed(mojo, std.mem.readInt(u32, buf[0..4], .little));
    return statusOf(st);
}

fn onSignal(sig: i32) callconv(.c) void {
    caught.store(@intCast(sig), .seq_cst);
}

fn setHandler(sig: u6, handler: ?linux.Sigaction.handler_fn) void {
    const sa = linux.Sigaction{ .handler = .{ .handler = handler }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &sa, null);
}

const caught_signals = [_]u6{ linux.SIG.HUP, linux.SIG.INT, linux.SIG.TERM };

/// In the root, after fork: lead a session, start the tether, then become
/// the compiler.
///
/// The tether is started through an intermediate process that reports its
/// pid and exits, so the tether is in the compiler's session (the session
/// kill reaches it, and its own kill reaches the session) but is not the
/// compiler's child: a compiler that waits for every child it has (wait(),
/// waitpid(-1)) never waits for, or reaps, the tether.
fn rootChild(tether_pipe: [2]i32, report: [2]i32, argv: Argv, envp: Envp) noreturn {
    _ = linux.close(tether_pipe[1]);
    _ = linux.close(report[0]);
    _ = linux.setsid();
    const mid = linux.fork();
    if (posix.errno(mid) != .SUCCESS) linux.exit_group(2);
    if (mid == 0) {
        const t = linux.fork();
        if (posix.errno(t) != .SUCCESS) linux.exit_group(2);
        if (t == 0) tether(tether_pipe[0], report[1]);
        const tpid: u32 = @intCast(t);
        _ = linux.write(report[1], std.mem.asBytes(&tpid), 4);
        linux.exit_group(0);
    }
    var st: u32 = 0;
    while (true) {
        const r = linux.waitpid(@intCast(mid), &st, 0);
        if (posix.errno(r) != .INTR) break;
    }
    // No tether, no compile: the wrapper reads no pid and refuses.
    if (!linux.W.IFEXITED(st) or linux.W.EXITSTATUS(st) != 0) linux.exit_group(2);
    _ = linux.close(tether_pipe[0]);
    // As a background job of a non-interactive shell: stdin is /dev/null,
    // SIGINT and SIGQUIT are ignored, and both survive the exec. The
    // wrapper's own handlers (HUP, INT, TERM) are reset by the exec.
    const nul = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (posix.errno(nul) == .SUCCESS) {
        const fd: i32 = @intCast(nul);
        if (fd != 0) {
            _ = linux.dup2(fd, 0);
            _ = linux.close(fd);
        }
    }
    setHandler(linux.SIG.INT, linux.SIG.IGN);
    setHandler(linux.SIG.QUIT, linux.SIG.IGN);
    execChild(argv[0].?, argv, envp, report[1]);
}

/// The tether: blocks on a pipe whose only writer is the wrapper. When the
/// read returns (the wrapper is gone, however it died), it kills its own
/// process group, which is the compiler's session.
fn tether(fd: i32, report_w: i32) noreturn {
    _ = linux.close(report_w);
    _ = linux.close(0);
    _ = linux.close(1);
    _ = linux.close(2);
    var b: [64]u8 = undefined;
    while (true) {
        const r = linux.read(fd, &b, b.len);
        switch (posix.errno(r)) {
            .SUCCESS => if (r == 0) break,
            .INTR => {},
            else => break,
        }
    }
    _ = linux.kill(0, linux.SIG.KILL);
    linux.exit_group(0);
}

/// The compiler's wait status once it has exited (reaping it), else null.
fn reaped(pid: i32) ?u32 {
    const r = posix.waitpid(pid, linux.W.NOHANG);
    if (r.pid == pid) return r.status;
    return null;
}

fn sleepOneSecond() void {
    // Interrupted early by a caught signal (no SA_RESTART).
    const ts = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&ts, null);
}

fn checkSignal(alloc: std.mem.Allocator, pid: i32) void {
    const s = caught.load(.seq_cst);
    if (s == 0) return;
    proc_tree.killTree(alloc, pid);
    finish(@intCast(128 + s));
}

/// The CPU ticks of the compiler's tree now, or null when it is not in /proc.
fn treeTicks(alloc: std.mem.Allocator, pid: i32) ?i64 {
    const procs = proc_tree.readAll(alloc) catch return null;
    const members = (proc_tree.select(alloc, procs, pid) catch return null) orelse return null;
    return proc_tree.cpu(procs, members);
}

fn runWatched(o: compile_args.Options, mojo: []const u8, argv: Argv, envp: Envp, subcmd: []const u8) u8 {
    var loop_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const loop = loop_state.allocator();
    for (caught_signals) |s| setHandler(s, &onSignal);
    const tether_pipe = pipeCloexec();
    const report = pipeCloexec();
    const pid = posix.fork() catch |e| refuse("cannot fork: {s}", .{@errorName(e)});
    if (pid == 0) rootChild(tether_pipe, report, argv, envp);
    // The wrapper keeps the only write end of the tether's pipe, open until
    // it exits.
    posix.close(tether_pipe[0]);
    posix.close(report[1]);
    var buf: [8]u8 = undefined;
    const n = readReport(report[0], &buf);
    if (n < 4) {
        proc_tree.killTree(loop, pid);
        _ = posix.waitpid(pid, 0);
        refuse("the compiler's session did not start", .{});
    }
    const tether_pid: i32 = @intCast(std.mem.readInt(u32, buf[0..4], .little));
    if (n >= 8) {
        _ = posix.waitpid(pid, 0);
        _ = linux.kill(tether_pid, linux.SIG.KILL);
        return execFailed(mojo, std.mem.readInt(u32, buf[4..8], .little));
    }

    var status: ?u32 = reaped(pid);
    var watch = proc_tree.Watch.init(o.idle_secs, o.sample_secs, treeTicks(loop, pid) orelse 0);
    while (status == null) {
        _ = loop_state.reset(.retain_capacity);
        sleepOneSecond();
        checkSignal(loop, pid);
        status = reaped(pid);
        if (status != null) break;
        const ticks = treeTicks(loop, pid) orelse continue;
        if (watch.tick(ticks)) {
            proc_tree.killTree(loop, pid);
            _ = posix.waitpid(pid, 0);
            std.debug.print("mojo-watchdog: killed deadlocked compiler after {d}s of zero process-tree CPU (mojo {s}, output {s}); the action is safe to retry. Knobs: watchdog_idle_secs / watchdog_sample_secs of the Mojo toolchain.\n", .{ watch.idleSecs(), subcmd, o.output });
            finish(124);
        }
    }
    // The compiler is gone: stop the tether first (its pipe closes when the
    // wrapper exits), so the processes the compiler orphaned are left alone.
    _ = linux.kill(tether_pid, linux.SIG.KILL);
    for (caught_signals) |s| setHandler(s, linux.SIG.DFL);
    const s = caught.load(.seq_cst);
    if (s != 0) finish(@intCast(128 + s));
    return statusOf(status.?);
}

// ---- the output checks ---------------------------------------------------------------

fn printable(c: u8) bool {
    return c == '\t' or (c >= 0x20 and c <= 0x7e);
}

fn holdsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (n.len > 0 and std.mem.indexOf(u8, hay, n) != null) return true;
    }
    return false;
}

/// Exit 3 when the compiler exited 0 but the output is missing or empty; 4
/// when it holds the working directory, printing up to five printable runs
/// (4 bytes or longer) that hold it.
pub fn postCheck(arena: std.mem.Allocator, rc: u8, out: []const u8, pwd: []const u8) u8 {
    if (rc != 0) return rc;
    if (!nonEmpty(out)) {
        say("compiler exited 0 but {s} is missing or empty", .{out});
        return 3;
    }
    const data = std.fs.cwd().readFileAlloc(arena, out, std.math.maxInt(usize)) catch return 0;
    var needles = std.ArrayList([]const u8).empty;
    needles.append(arena, pwd) catch oom();
    const cwd = std.process.getCwdAlloc(arena) catch pwd;
    if (!std.mem.eql(u8, cwd, pwd)) needles.append(arena, cwd) catch oom();
    if (!holdsAny(data, needles.items)) return 0;
    say("{s} contains this action's working directory ({s}):", .{ out, pwd });
    var shown: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= data.len and shown < 5) : (i += 1) {
        if (i < data.len and printable(data[i])) continue;
        const run = data[start..i];
        if (run.len >= 4 and holdsAny(run, needles.items)) {
            std.debug.print("{s}\n", .{run});
            shown += 1;
        }
        start = i + 1;
    }
    return 4;
}
