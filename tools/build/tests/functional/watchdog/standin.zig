//! standin: the stand-in toolchain of the mojo_compile process cases
//! (cases.zig). Its behaviour is picked by the name it runs under:
//!
//!   .../zig   the link driver: writes its arguments, one per line, to
//!             `zig.argv` in the working directory, writes "linked" to the
//!             value after `-o`, exits 0.
//!   .../mojo  the compiler: the first argument picks a behaviour, then it
//!             writes "compiled" to the value after the last `-o` (unless
//!             the behaviour exited or wrote the output itself).
//!
//! Compiler behaviours (a deadlock is a process tree using no CPU, which a
//! sleep is):
//!   hang        sleep 600 s
//!   hangpid     write compiler.pid, start a child sleeping 600 s (child.pid), wait
//!   treehang    start a child sleeping 600 s (child.pid), wait
//!   orphan      a child starts a grandchild sleeping 600 s (child.pid) and
//!               exits, so the grandchild leaves the tree by parent; sleep 600 s
//!   orphanspin  the same with a grandchild that spins 7 s; sleep 8 s
//!   spin        spin 7 s;   childspin  a child spins 7 s, wait
//!   nap2, nap5  sleep 2 s, 5 s;   fail  exit 7
//!   selfkill    die of SIGUSR1 (10), its default action restored first
//!   envdump     write the environment, one NAME=value per line, to env.txt
//!   sigstate    write sigstate.txt: whether stdin is /dev/null, SIGINT's and
//!               SIGQUIT's dispositions, whether the pid is the session id
//!   link        exec `cc` from PATH with every row of the cc shim's rewrite table
//!   empty       write an empty output, exit 0
//!   cwd         write the working directory into the output
//!
//! Built for macOS (tests//functional/watchdog:cases_darwin) it is the same
//! program through libc; `link` is Linux only.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

/// Built for macOS (tests//functional/watchdog:cases_darwin), else Linux.
const macos = builtin.os.tag == .macos;

extern "c" fn getpid() c_int;
extern "c" fn getsid(pid: c_int) c_int;

fn myPid() i32 {
    return if (macos) getpid() else linux.getpid();
}

fn mySid() i32 {
    return if (macos) getsid(0) else @bitCast(@as(u32, @truncate(linux.syscall1(.getsid, 0))));
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("standin: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn write(name: []const u8, data: []const u8) void {
    std.fs.cwd().writeFile(name, data) catch |e| die("cannot write {s}: {s}", .{ name, @errorName(e) });
}

fn writePid(name: []const u8, pid: i32) void {
    var buf: [32]u8 = undefined;
    write(name, std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch unreachable);
}

fn sleepSecs(s: u64) void {
    std.time.sleep(s * std.time.ns_per_s);
}

fn spin(s: i64) void {
    const end = std.time.milliTimestamp() + s * 1000;
    var x: u64 = 0;
    while (std.time.milliTimestamp() < end) {
        x +%= 1;
        std.mem.doNotOptimizeAway(x);
    }
}

fn fork() i32 {
    return posix.fork() catch |e| die("cannot fork: {s}", .{@errorName(e)});
}

fn waitAll() void {
    if (macos) {
        while (true) {
            var st: c_int = 0;
            if (std.c.waitpid(-1, &st, 0) >= 0) continue;
            if (std.c._errno().* == @intFromEnum(posix.E.INTR)) continue;
            return;
        }
    }
    while (true) {
        var st: u32 = 0;
        const r = linux.waitpid(-1, &st, 0);
        switch (posix.errno(r)) {
            .SUCCESS => {},
            .INTR => {},
            else => return,
        }
    }
}

/// The value after the last `-o`, or null.
fn output(args: []const []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) out = args[i + 1];
    }
    return out;
}

/// Every row of the cc shim's rewrite table (design item 15), in one link.
/// cases.zig holds the line zig must receive for it.
pub const link_inputs = [_][]const u8{
    "-Xlinker",         "-L/d",         "-Xlinker",       "-lfoo",           "-Xlinker",      "--gc-sections",
    "-Xlinker",         "-rpath",       "-Xlinker",       "/sandbox/a",      "-Xlinker",      "--rpath",
    "/sandbox/b",       "-Xlinker",     "-rpath=/sandbox/c", "-Xlinker",     "--rpath=/sandbox/d",
    "-Xlinker",         "-soname",      "-Xlinker",       "libx.so",         "-Xlinker",      "-z",
    "keep.o",           "-Xlinker",     "now",            "-Xlinker",        "bare.o",        "-rpath",
    "/sandbox/e",       "--rpath",      "/sandbox/f",     "-Wl,-rpath",      "/sandbox/g",    "-Wl,--rpath",
    "/sandbox/h",       "-Wl,-rpath,/sandbox/i", "-Wl,-rpath=/sandbox/j", "-Wl,--rpath,/sandbox/k",
    "-Wl,--rpath=/sandbox/l", "-Wl,-R,/sandbox/m", "-Wl,-L/f", "-Wl,-lg",
};

fn execCc(arena: std.mem.Allocator, out: []const u8) noreturn {
    if (macos) die("link: the macOS shim runs the host's cc, no stand-in", .{});
    const path = posix.getenv("PATH") orelse die("no PATH", .{});
    var dirs = std.mem.splitScalar(u8, path, ':');
    const cc = while (dirs.next()) |d| {
        const p = std.fmt.allocPrintZ(arena, "{s}/cc", .{d}) catch die("out of memory", .{});
        if (posix.accessZ(p, posix.X_OK)) |_| break p else |_| {}
    } else die("no cc on PATH {s}", .{path});
    var argv = std.ArrayList(?[*:0]const u8).init(arena);
    argv.append("cc") catch unreachable;
    for (link_inputs) |a| argv.append(arena.dupeZ(u8, a) catch unreachable) catch unreachable;
    argv.append("-o") catch unreachable;
    argv.append(arena.dupeZ(u8, out) catch unreachable) catch unreachable;
    // Last: a trailing -Xlinker passes through.
    argv.append("-Xlinker") catch unreachable;
    argv.append(null) catch unreachable;
    const envp = arena.allocSentinel(?[*:0]const u8, std.os.environ.len, null) catch unreachable;
    for (std.os.environ, 0..) |e, i| envp[i] = e;
    const rc = linux.execve(cc, @ptrCast(argv.items.ptr), envp);
    die("cannot run {s}: {s}", .{ cc, @tagName(posix.errno(rc)) });
}

fn disposition(sig: u6) []const u8 {
    var old: posix.Sigaction = undefined;
    if (macos) {
        posix.sigaction(sig, null, &old) catch {};
    } else {
        _ = linux.sigaction(sig, null, &old);
    }
    const h: usize = if (old.handler.handler) |p| @intFromPtr(p) else 0;
    return switch (h) {
        0 => "dfl", // SIG_DFL
        1 => "ign", // SIG_IGN
        else => "other",
    };
}

fn sigstate() void {
    const in = posix.fstat(0) catch die("cannot stat stdin", .{});
    const nul = posix.fstatat(posix.AT.FDCWD, "/dev/null", 0) catch die("cannot stat /dev/null", .{});
    const devnull = in.rdev == nul.rdev and in.ino == nul.ino and in.dev == nul.dev;
    const pid = myPid();
    const sid = mySid();
    var buf: [128]u8 = undefined;
    write("sigstate.txt", std.fmt.bufPrint(&buf, "stdin={s} int={s} quit={s} leader={s}\n", .{
        if (devnull) "devnull" else "other",
        disposition(posix.SIG.INT),
        disposition(posix.SIG.QUIT),
        if (pid == sid) "yes" else "no",
    }) catch unreachable);
}

fn envdump(arena: std.mem.Allocator) void {
    var out = std.ArrayList(u8).init(arena);
    for (std.os.environ) |e| {
        out.appendSlice(std.mem.span(e)) catch unreachable;
        out.append('\n') catch unreachable;
    }
    write("env.txt", out.items);
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = std.process.argsAlloc(arena) catch die("out of memory", .{});
    const args = arena.alloc([]const u8, argv.len) catch die("out of memory", .{});
    for (argv, 0..) |a, i| args[i] = a;
    const name = std.fs.path.basename(args[0]);
    const out = output(args[1..]);

    if (std.mem.eql(u8, name, "zig")) {
        var rec = std.ArrayList(u8).init(arena);
        for (args) |a| {
            rec.appendSlice(a) catch unreachable;
            rec.append('\n') catch unreachable;
        }
        write("zig.argv", rec.items);
        write(out orelse die("zig: no -o", .{}), "linked\n");
        std.process.exit(0);
    }

    const mode = if (args.len > 1) args[1] else "";
    const eql = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (eql(mode, "hang")) {
        sleepSecs(600);
    } else if (eql(mode, "hangpid")) {
        writePid("compiler.pid", myPid());
        const c = fork();
        if (c == 0) {
            sleepSecs(600);
            std.process.exit(0);
        }
        writePid("child.pid", c);
        waitAll();
    } else if (eql(mode, "treehang")) {
        const c = fork();
        if (c == 0) {
            sleepSecs(600);
            std.process.exit(0);
        }
        writePid("child.pid", c);
        waitAll();
    } else if (eql(mode, "orphan") or eql(mode, "orphanspin")) {
        const spinning = eql(mode, "orphanspin");
        const a = fork();
        if (a == 0) {
            const b = fork();
            if (b == 0) {
                if (spinning) spin(7) else sleepSecs(600);
                std.process.exit(0);
            }
            writePid("child.pid", b);
            std.process.exit(0);
        }
        _ = posix.waitpid(a, 0);
        sleepSecs(if (spinning) 8 else 600);
    } else if (eql(mode, "spin")) {
        spin(7);
    } else if (eql(mode, "childspin")) {
        const c = fork();
        if (c == 0) {
            spin(7);
            std.process.exit(0);
        }
        waitAll();
    } else if (eql(mode, "nap2")) {
        sleepSecs(2);
    } else if (eql(mode, "nap5")) {
        sleepSecs(5);
    } else if (eql(mode, "fail")) {
        std.process.exit(7);
    } else if (eql(mode, "selfkill")) {
        // SIGUSR1's default action terminates without a core file; the
        // wrapper neither catches nor forwards it.
        if (macos) {
            const sa = posix.Sigaction{ .handler = .{ .handler = posix.SIG.DFL }, .mask = 0, .flags = 0 };
            posix.sigaction(posix.SIG.USR1, &sa, null) catch {};
            _ = std.c.kill(getpid(), posix.SIG.USR1);
        } else {
            const sa = linux.Sigaction{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.empty_sigset, .flags = 0 };
            _ = linux.sigaction(linux.SIG.USR1, &sa, null);
            _ = linux.kill(linux.getpid(), linux.SIG.USR1);
        }
        die("selfkill: still alive after SIGUSR1", .{});
    } else if (eql(mode, "envdump")) {
        envdump(arena);
    } else if (eql(mode, "sigstate")) {
        sigstate();
    } else if (eql(mode, "link")) {
        execCc(arena, out orelse die("link: no -o", .{}));
    } else if (eql(mode, "empty")) {
        write(out orelse die("empty: no -o", .{}), "");
        std.process.exit(0);
    } else if (eql(mode, "cwd")) {
        const cwd = std.process.getCwdAlloc(arena) catch die("cannot read the working directory", .{});
        write(out orelse die("cwd: no -o", .{}), std.fmt.allocPrint(arena, "built in {s}\n", .{cwd}) catch unreachable);
        std.process.exit(0);
    }
    if (out) |o| write(o, "compiled\n");
    std.process.exit(0);
}
