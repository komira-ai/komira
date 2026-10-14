//! mojo_compile (macOS): runs the hermetic Mojo compiler inside one build
//! action on a macOS arm64 execution host. The Linux build is
//! mojo_compile.zig; this is the same contract (docs/design/zig_compile_wrapper.md,
//! whose numbered behaviours both keep) with what differs on macOS:
//!
//!   mojo_compile --compiler=<dir> --deployment-target=<v> --macos-host=<id>...
//!                [--runpath=<$ORIGIN*>] [--source-root=<dir>] [--link-tail=<arg>]...
//!                [--watchdog-idle-secs=<n>] [--watchdog-sample-secs=<n>] -- <mojo arguments...>
//!   mojo_compile host-identity [--fields] [--output=<file>]
//!
//! Started as `cc`, `c++`, `gcc`, `g++`, `clang` or `clang++` (the links in
//! <scratch>/cc/), it is the link shim: the host's /usr/bin/cc, which links
//! with the host's ld, with every run path the compiler asks for dropped
//! and `-Wl,-S -Wl,-rpath,<runpath>` and the link tail added (cc_shim.zig).
//!
//! What it does, in order:
//!   * parses the options (compile_args.parseMacos; any refusal is exit 2,
//!     among them `--emit shared-lib` without `-install_name`: bundles are
//!     Linux only);
//!   * makes the private scratch directory, as on Linux;
//!   * checks the toolchain closure (CLOSURE_MANIFEST), as on Linux;
//!   * renders modular.cfg, and requires its one `shared_libs` line to be the
//!     run path to the compiler's lib/, rewritten to `@loader_path/lib` and
//!     `-S` (modular_cfg.macosSharedLibs);
//!   * refuses (exit 2, printing this host's fields) a host whose identity
//!     (host_identity.zig) is not one of the `--macos-host` values, so a
//!     result is never filed under a host toolchain the action key does not
//!     name;
//!   * runs <compiler>/bin/mojo with exactly this environment, nothing
//!     inherited: PATH=<scratch>/cc:<compiler>/bin, MODULAR_HOME, CC,
//!     MACOSX_DEPLOYMENT_TARGET, MODULAR_CACHE_DIR, XDG_CACHE_HOME, TMPDIR,
//!     HOME, KGEN_CompilerRT_AsyncRT_ParallelismLevel=1,
//!     MODULAR_CRASH_REPORTING_ENABLED=false, KOMIRA_CC_SHIM, PWD, and
//!     BUCK_SCRATCH_PATH when it is set. The compiler finds its lib/ through
//!     its own run path; nothing is set for the loader;
//!   * for `precompile` with --source-root, runs the compiler from the
//!     root's parent (PWD is that directory), given the package by its
//!     basename and `-o`, `-I` made absolute, as on Linux
//!     (compile_args.runDir, compilerArgs), so the `.mojoc` records
//!     `<name>/<file>.mojo` and not the staged buck-out path; the wrapper
//!     itself stays in the action directory, where the output check runs;
//!   * checks the output and removes the scratch directory.
//!
//! The compile watchdog is Linux's: the compiler leads a session of its own
//! (setsid(2)) with a tether in it, and the tree is the session plus every
//! descendant, read through libproc (proc_tree_macos.zig). Exit statuses are
//! Linux's (mojo_compile.zig's header).
//!
//! `host-identity` prints this host's identity, the value to list in
//! `[komira_re] darwin_macos_hosts`; with `--fields`, the six lines it is a
//! digest of; with `--output=<file>`, into that file (the census actions,
//! tests//functional/darwin:host_census). Exit 2 when a field cannot be read.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const common = @import("mojo_compile.zig");
const compile_args = @import("compile_args.zig");
const cc_shim = @import("cc_shim.zig");
const modular_cfg = @import("modular_cfg.zig");
const proc_tree = @import("proc_tree.zig");
const proc_tree_macos = @import("proc_tree_macos.zig");
const host_identity = @import("host_identity.zig");

test {
    _ = @import("compile_args.zig");
    _ = @import("cc_shim.zig");
    _ = @import("modular_cfg.zig");
    _ = @import("proc_tree.zig");
    _ = @import("proc_tree_macos.zig");
    _ = @import("host_identity.zig");
}

const Argv = common.Argv;
const Envp = common.Envp;
const finish = common.finish;
const join = common.join;
const oom = common.oom;
const refuse = common.refuse;
const say = common.say;

/// The host's C driver: the shim's exec (cc_shim.execLineMacos).
const host_cc = "/usr/bin/cc";

extern "c" fn setsid() c_int;

/// The signal a handler caught (HUP, INT or TERM), or 0.
var caught = std.atomic.Value(u32).init(0);

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = std.process.argsAlloc(arena) catch oom();
    const args = arena.alloc([]const u8, argv.len) catch oom();
    for (argv, 0..) |a, i| args[i] = a;
    if (args.len > 0 and cc_shim.isShimName(std.fs.path.basename(args[0]))) shimMain(arena, args[1..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "host-identity")) hostIdentityMain(arena, args[2..]);
    wrapperMain(arena, if (args.len > 0) args[1..] else args);
}

fn inheritedEnv(arena: std.mem.Allocator) Envp {
    const envp = arena.allocSentinel(?[*:0]const u8, std.os.environ.len, null) catch oom();
    for (std.os.environ, 0..) |e, i| envp[i] = e;
    return envp;
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
    const line = cc_shim.execLineMacos(arena, cfg, args) catch oom();
    const argv = common.toArgv(arena, line) catch oom();
    // The driver inherits the compiler's environment.
    _ = c.execve(argv[0].?, argv, inheritedEnv(arena));
    const e: u32 = @intCast(c._errno().*);
    std.debug.print("cc shim: cannot run {s}: errno {d}\n", .{ cfg.zig, e });
    std.process.exit(if (e == @intFromEnum(posix.E.NOENT)) 127 else 126);
}

// ---- host identity -----------------------------------------------------------

/// The output of `argv` (with its stderr when `with_stderr`), stdin
/// /dev/null; empty when it cannot be run. Its exit status is not read: an
/// unreadable field is an empty one.
fn capture(arena: std.mem.Allocator, argv_items: []const []const u8, with_stderr: bool) []const u8 {
    const p = posix.pipe2(.{ .CLOEXEC = true }) catch return "";
    const argv = common.toArgv(arena, argv_items) catch oom();
    const envp = inheritedEnv(arena);
    const pid = posix.fork() catch {
        posix.close(p[0]);
        posix.close(p[1]);
        return "";
    };
    if (pid == 0) {
        const nul = c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (nul >= 0) {
            _ = c.dup2(nul, 0);
            if (!with_stderr) _ = c.dup2(nul, 2);
        }
        _ = c.dup2(p[1], 1);
        if (with_stderr) _ = c.dup2(p[1], 2);
        _ = c.execve(argv[0].?, argv, envp);
        c._exit(127);
    }
    posix.close(p[1]);
    var out = std.ArrayList(u8).init(arena);
    var buf: [4096]u8 = undefined;
    while (out.items.len < 1 << 20) {
        const n = posix.read(p[0], &buf) catch break;
        if (n == 0) break;
        out.appendSlice(buf[0..n]) catch oom();
    }
    posix.close(p[0]);
    _ = posix.waitpid(pid, 0);
    return out.items;
}

fn hostFields(arena: std.mem.Allocator) [host_identity.fields.len][]const u8 {
    var v: [host_identity.fields.len][]const u8 = undefined;
    for (host_identity.fields, 0..) |f, i| v[i] = host_identity.fieldValue(f, capture(arena, f.argv, f.with_stderr));
    return v;
}

/// `host-identity [--fields] [--output=<file>]`: the identity (or the field
/// lines) on stdout, or in <file> (the census actions, census.bzl).
fn hostIdentityMain(arena: std.mem.Allocator, args: []const []const u8) noreturn {
    var fields_only = false;
    var output: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--fields")) {
            fields_only = true;
        } else if (std.mem.startsWith(u8, a, "--output=") and a.len > "--output=".len) {
            output = a["--output=".len..];
        } else {
            std.debug.print("host_identity: usage: mojo_compile host-identity [--fields] [--output=<file>]\n", .{});
            std.process.exit(2);
        }
    }
    const v = hostFields(arena);
    if (host_identity.firstEmpty(&v)) |i| {
        std.debug.print("host_identity: REFUSING: cannot read '{s}' on this host\n", .{host_identity.fields[i].name});
        std.process.exit(2);
    }
    const out = if (fields_only)
        host_identity.text(arena, v) catch oom()
    else
        std.fmt.allocPrint(arena, "{s}\n", .{host_identity.identity(arena, v) catch oom()}) catch oom();
    if (output) |path| {
        std.fs.cwd().writeFile(path, out) catch |e| {
            std.debug.print("host_identity: cannot write {s}: {s}\n", .{ path, @errorName(e) });
            std.process.exit(2);
        };
    } else {
        std.io.getStdOut().writeAll(out) catch std.process.exit(2);
    }
    std.process.exit(0);
}

/// Refuses (exit 2) unless this host's identity is one of `hosts`.
fn checkHost(arena: std.mem.Allocator, hosts: []const []const u8) void {
    const v = hostFields(arena);
    const have: ?[]const u8 = if (host_identity.firstEmpty(&v) == null) host_identity.identity(arena, v) catch oom() else null;
    if (have) |h| {
        for (hosts) |listed| if (std.mem.eql(u8, listed, h)) return;
    }
    var listed = std.ArrayList(u8).init(arena);
    for (hosts) |h| {
        listed.appendSlice(h) catch oom();
        listed.append(' ') catch oom();
    }
    say("REFUSING: this host's identity is '{s}', not one of [{s}] ([komira_re] darwin_macos_hosts). This host:", .{ have orelse "unreadable", listed.items });
    for (host_identity.fields, v) |f, value| std.debug.print("{s}={s}\n", .{ f.name, value });
    finish(2);
}

// ---- the wrapper -----------------------------------------------------------------

fn wrapperMain(arena: std.mem.Allocator, args: []const []const u8) noreturn {
    const pwd = common.shellPwd(arena);
    var diag = compile_args.Diag{};
    const o = compile_args.parseMacos(arena, pwd, args, &diag) catch |e| switch (e) {
        error.Refused => refuse("{s}", .{diag.msg}),
        error.OutOfMemory => oom(),
    };

    // Private scratch, as on Linux (mojo_compile.zig).
    const bsp = posix.getenv("BUCK_SCRATCH_PATH") orelse "";
    const t = if (bsp.len == 0)
        join(arena, pwd, ".komira_action")
    else if (bsp[0] == '/')
        join(arena, bsp, "komira")
    else
        join(arena, join(arena, pwd, bsp), "komira");
    common.scratch = t;
    for ([_][]const u8{ "cc", "home", "tmp", "cache", "modular" }) |sub| {
        std.fs.cwd().makePath(join(arena, t, sub)) catch |e| refuse("cannot make {s}/{s}: {s}", .{ t, sub, @errorName(e) });
    }

    // ---- closure check
    const tc = o.compiler;
    const manifest = join(arena, tc, "CLOSURE_MANIFEST");
    if (!common.nonEmpty(manifest)) refuse("REFUSING: {s} is missing; the compiler input is not an unpacked toolchain", .{manifest});
    const members = std.fs.cwd().readFileAlloc(arena, manifest, 64 << 20) catch |e| refuse("cannot read {s}: {s}", .{ manifest, @errorName(e) });
    var missing = false;
    var lines = std.mem.splitScalar(u8, members, '\n');
    while (lines.next()) |m| {
        if (m.len == 0) continue;
        if (!common.nonEmpty(join(arena, tc, m))) {
            say("REFUSING: toolchain member '{s}' is missing or empty", .{m});
            missing = true;
        }
    }
    if (missing) finish(2);

    // ---- modular.cfg, rendered for this action, with the macOS run path
    const cfg_in = join(arena, tc, "share/max/modular.cfg");
    const cfg_text = std.fs.cwd().readFileAlloc(arena, cfg_in, 16 << 20) catch |e| refuse("REFUSING: cannot read {s}: {s}", .{ cfg_in, @errorName(e) });
    const rendered = (modular_cfg.renderChecked(arena, cfg_text, tc) catch oom()) orelse
        refuse("REFUSING: modular.cfg still holds the toolchain token after rendering", .{});
    const final = (modular_cfg.macosSharedLibs(arena, rendered, tc) catch oom()) orelse
        refuse("REFUSING: modular.cfg's shared_libs is not the one run path to the compiler's lib/", .{});
    const modular_home = join(arena, t, "modular");
    std.fs.cwd().writeFile(join(arena, modular_home, "modular.cfg"), final) catch |e| refuse("cannot write modular.cfg: {s}", .{@errorName(e)});

    // ---- the host is one the action key names
    checkHost(arena, o.macos_hosts);

    // ---- the cc shim: `mojo build` links through `cc` on PATH
    const cc_dir = join(arena, t, "cc");
    const shim_cfg = join(arena, cc_dir, "shim.cfg");
    const shim_text = cc_shim.renderConfig(arena, .{ .zig = host_cc, .target = o.deployment_target, .runpath = o.runpath, .tail = o.link_tail }) catch |e| switch (e) {
        error.BadConfig => refuse("REFUSING: a shim setting holds a newline", .{}),
        error.OutOfMemory => oom(),
    };
    std.fs.cwd().writeFile(shim_cfg, shim_text) catch |e| refuse("cannot write {s}: {s}", .{ shim_cfg, @errorName(e) });
    const self = std.fs.selfExePathAlloc(arena) catch |e| refuse("cannot read this program's path: {s}", .{@errorName(e)});
    for (cc_shim.shim_names) |n| {
        const link = join(arena, cc_dir, n);
        std.fs.cwd().deleteFile(link) catch {};
        posix.symlink(self, link) catch |e| refuse("cannot link {s}: {s}", .{ link, @errorName(e) });
    }

    // ---- the compiler's environment, built from nothing
    var env = std.ArrayList([]const u8).init(arena);
    const cache = join(arena, t, "cache");
    const pairs = [_][2][]const u8{
        .{ "PATH", std.fmt.allocPrint(arena, "{s}:{s}/bin", .{ cc_dir, tc }) catch oom() },
        .{ "MODULAR_HOME", modular_home },
        .{ "CC", join(arena, cc_dir, "cc") },
        .{ "MACOSX_DEPLOYMENT_TARGET", o.deployment_target },
        .{ "MODULAR_CACHE_DIR", cache },
        .{ "TMPDIR", join(arena, t, "tmp") },
        .{ "HOME", join(arena, t, "home") },
        .{ "XDG_CACHE_HOME", cache },
        .{ "KGEN_CompilerRT_AsyncRT_ParallelismLevel", "1" },
        .{ "MODULAR_CRASH_REPORTING_ENABLED", "false" },
        .{ "KOMIRA_CC_SHIM", shim_cfg },
        .{ "PWD", compile_args.runDir(o.common()) orelse pwd },
    };
    for (pairs) |kv| env.append(std.fmt.allocPrint(arena, "{s}={s}", .{ kv[0], kv[1] }) catch oom()) catch oom();
    if (bsp.len > 0) env.append(std.fmt.allocPrint(arena, "BUCK_SCRATCH_PATH={s}", .{bsp}) catch oom()) catch oom();
    const envp = common.toArgv(arena, env.items) catch oom();

    const mojo = join(arena, tc, "bin/mojo");
    var cmd = std.ArrayList([]const u8).init(arena);
    cmd.append(mojo) catch oom();
    cmd.appendSlice(compile_args.compilerArgs(arena, o.common()) catch oom()) catch oom();
    const argv = common.toArgv(arena, cmd.items) catch oom();
    if (compile_args.runDir(o.common())) |d| child_dir = (arena.dupeZ(u8, d) catch oom()).ptr;
    const subcmd = if (o.mojo_args.len > 0) o.mojo_args[0] else "";

    const rc = if (o.idle_secs == 0)
        runPlain(mojo, argv, envp)
    else
        runWatched(o, mojo, argv, envp, subcmd);
    finish(common.postCheck(arena, rc, o.output, pwd));
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
        if (c.chdir(d) != 0) {
            const e: u32 = @as(u32, @intCast(c._errno().*)) | chdir_failed;
            _ = c.write(report, std.mem.asBytes(&e), 4);
            c._exit(127);
        }
    }
    _ = c.execve(path, argv, envp);
    const e: u32 = @intCast(c._errno().*);
    _ = c.write(report, std.mem.asBytes(&e), 4);
    c._exit(127);
}

fn execFailed(mojo: []const u8, raw: u32) u8 {
    const e = raw & ~chdir_failed;
    const where: []const u8 = if (raw & chdir_failed != 0) "cannot enter " else "";
    const dir: []const u8 = if (raw & chdir_failed != 0) std.mem.span(child_dir.?) else "";
    const sep: []const u8 = if (raw & chdir_failed != 0) ": " else "";
    if (std.meta.intToEnum(posix.E, e)) |err| {
        say("cannot run {s}: {s}{s}{s}{s}", .{ mojo, where, dir, sep, @tagName(err) });
    } else |_| {
        say("cannot run {s}: {s}{s}{s}errno {d}", .{ mojo, where, dir, sep, e });
    }
    return if (e == @intFromEnum(posix.E.NOENT)) 127 else 126;
}

fn statusOf(st: u32) u8 {
    if (posix.W.IFEXITED(st)) return posix.W.EXITSTATUS(st);
    if (posix.W.IFSIGNALED(st)) return @intCast(128 + (posix.W.TERMSIG(st) & 0x7f));
    return 2;
}

/// Idle 0: a plain child, with the wrapper's stdin and signal dispositions.
fn runPlain(mojo: []const u8, argv: Argv, envp: Envp) u8 {
    const report = pipeCloexec();
    const pid = posix.fork() catch |e| refuse("cannot fork: {s}", .{@errorName(e)});
    if (pid == 0) {
        _ = c.close(report[0]);
        execChild(argv[0].?, argv, envp, report[1]);
    }
    posix.close(report[1]);
    var buf: [8]u8 = undefined;
    const n = common.readReport(report[0], &buf);
    const st = posix.waitpid(pid, 0).status;
    if (n >= 4) return execFailed(mojo, std.mem.readInt(u32, buf[0..4], .little));
    return statusOf(st);
}

fn onSignal(sig: i32) callconv(.C) void {
    caught.store(@intCast(sig), .seq_cst);
}

fn setHandler(sig: u6, handler: ?posix.Sigaction.handler_fn) void {
    const sa = posix.Sigaction{ .handler = .{ .handler = handler }, .mask = 0, .flags = 0 };
    posix.sigaction(sig, &sa, null) catch {};
}

const caught_signals = [_]u6{ posix.SIG.HUP, posix.SIG.INT, posix.SIG.TERM };

/// In the root, after fork: lead a session, start the tether (through an
/// intermediate process, so it is in the session but not the compiler's
/// child), then become the compiler. As mojo_compile.zig's rootChild.
fn rootChild(tether_pipe: [2]i32, report: [2]i32, argv: Argv, envp: Envp) noreturn {
    _ = c.close(tether_pipe[1]);
    _ = c.close(report[0]);
    _ = setsid();
    const mid = c.fork();
    if (mid < 0) c._exit(2);
    if (mid == 0) {
        const t = c.fork();
        if (t < 0) c._exit(2);
        if (t == 0) tether(tether_pipe[0], report[1]);
        const tpid: u32 = @intCast(t);
        _ = c.write(report[1], std.mem.asBytes(&tpid), 4);
        c._exit(0);
    }
    var st: c_int = 0;
    while (true) {
        const r = c.waitpid(mid, &st, 0);
        if (r >= 0 or c._errno().* != @intFromEnum(posix.E.INTR)) break;
    }
    // No tether, no compile: the wrapper reads no pid and refuses.
    const ust: u32 = @bitCast(st);
    if (!posix.W.IFEXITED(ust) or posix.W.EXITSTATUS(ust) != 0) c._exit(2);
    _ = c.close(tether_pipe[0]);
    // As a background job of a non-interactive shell: stdin is /dev/null,
    // SIGINT and SIGQUIT are ignored, and both survive the exec.
    const nul = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (nul >= 0 and nul != 0) {
        _ = c.dup2(nul, 0);
        _ = c.close(nul);
    }
    setHandler(posix.SIG.INT, posix.SIG.IGN);
    setHandler(posix.SIG.QUIT, posix.SIG.IGN);
    execChild(argv[0].?, argv, envp, report[1]);
}

/// The tether: blocks on a pipe whose only writer is the wrapper; when the
/// read returns, kills its own process group, the compiler's session.
fn tether(fd: i32, report_w: i32) noreturn {
    _ = c.close(report_w);
    _ = c.close(0);
    _ = c.close(1);
    _ = c.close(2);
    var b: [64]u8 = undefined;
    while (true) {
        const r = c.read(fd, &b, b.len);
        if (r > 0) continue;
        if (r < 0 and c._errno().* == @intFromEnum(posix.E.INTR)) continue;
        break;
    }
    _ = c.kill(0, posix.SIG.KILL);
    c._exit(0);
}

/// The compiler's wait status once it has exited (reaping it), else null.
fn reaped(pid: i32) ?u32 {
    const r = posix.waitpid(pid, posix.W.NOHANG);
    if (r.pid == pid) return r.status;
    return null;
}

fn sleepOneSecond() void {
    // Interrupted early by a caught signal (no SA_RESTART).
    const ts = c.timespec{ .tv_sec = 1, .tv_nsec = 0 };
    _ = c.nanosleep(&ts, null);
}

fn checkSignal(alloc: std.mem.Allocator, pid: i32) void {
    const s = caught.load(.seq_cst);
    if (s == 0) return;
    proc_tree_macos.killTree(alloc, pid);
    finish(@intCast(128 + s));
}

/// The CPU ticks of the compiler's tree now, or null when it is not listed.
fn treeTicks(alloc: std.mem.Allocator, pid: i32) ?i64 {
    const procs = proc_tree_macos.readAll(alloc) catch return null;
    const members = (proc_tree.select(alloc, procs, pid) catch return null) orelse return null;
    return proc_tree.cpu(procs, members);
}

fn runWatched(o: compile_args.MacosOptions, mojo: []const u8, argv: Argv, envp: Envp, subcmd: []const u8) u8 {
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
    const n = common.readReport(report[0], &buf);
    if (n < 4) {
        proc_tree_macos.killTree(loop, pid);
        _ = posix.waitpid(pid, 0);
        refuse("the compiler's session did not start", .{});
    }
    const tether_pid: i32 = @intCast(std.mem.readInt(u32, buf[0..4], .little));
    if (n >= 8) {
        _ = posix.waitpid(pid, 0);
        _ = c.kill(tether_pid, posix.SIG.KILL);
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
            proc_tree_macos.killTree(loop, pid);
            _ = posix.waitpid(pid, 0);
            std.debug.print("mojo-watchdog: killed deadlocked compiler after {d}s of zero process-tree CPU (mojo {s}, output {s}); the action is safe to retry. Knobs: watchdog_idle_secs / watchdog_sample_secs of the Mojo toolchain.\n", .{ watch.idleSecs(), subcmd, o.output });
            finish(124);
        }
    }
    // The compiler is gone: stop the tether first, so the processes the
    // compiler orphaned are left alone.
    _ = c.kill(tether_pid, posix.SIG.KILL);
    for (caught_signals) |s| setHandler(s, posix.SIG.DFL);
    const s = caught.load(.seq_cst);
    if (s != 0) finish(@intCast(128 + s));
    return statusOf(status.?);
}
