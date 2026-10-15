//! The operating system calls the gate makes, as plain functions that do not
//! return error unions where a failure only means "nothing to do" (a kill of a
//! process that is gone). Linux calls go to the kernel directly (the tool is
//! a static musl executable); on macOS they go through libSystem.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const is_linux = builtin.os.tag == .linux;
pub const is_darwin = builtin.os.tag.isDarwin();
pub const linux = std.os.linux;
pub const pid_t = posix.pid_t;
pub const fd_t = posix.fd_t;

const darwin_c = struct {
    extern "c" fn setsid() c_int;
    extern "c" fn getpid() c_int;
};

pub fn getpid() pid_t {
    if (is_linux) return linux.getpid();
    return darwin_c.getpid();
}

pub fn setsid() void {
    if (is_linux) {
        _ = linux.setsid();
    } else {
        _ = darwin_c.setsid();
    }
}

/// kill(2); every failure (ESRCH, EPERM) is ignored.
pub fn kill(pid: pid_t, sig: u8) void {
    posix.kill(pid, sig) catch {};
}

/// The shell's form of a wait status: the exit code, or 128+N for a death
/// by signal N.
pub fn shellStatus(raw: u32) u8 {
    const sig = raw & 0x7f;
    if (sig == 0) return @intCast((raw >> 8) & 0xff);
    return @intCast((128 + sig) & 0xff);
}

/// waitpid(2) of `pid`, retried on EINTR. With `nohang`, null while the
/// process runs. Null as well when there is nothing to wait for (ECHILD).
pub fn waitpid(pid: pid_t, nohang: bool) ?u8 {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const flags: u32 = if (nohang) 1 else 0; // WNOHANG is 1 on Linux and macOS
    while (true) {
        const rc = posix.system.waitpid(pid, &status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null;
                return shellStatus(@bitCast(status));
            },
            .INTR => continue,
            else => return null,
        }
    }
}

/// Linux only: the status of `pid` once it has exited, WITHOUT reaping it
/// (waitid WEXITED | WNOWAIT | WNOHANG): it stays a zombie, so neither its
/// pid nor its process group id can be reused until waitpid reaps it. Null
/// while it runs.
pub fn exitedNoReap(pid: pid_t) ?u8 {
    if (!is_linux) @compileError("exitedNoReap is Linux only");
    // siginfo_t: signo, errno, code (i32 each), padding to 8, then for
    // SIGCHLD si_pid (i32), si_uid (u32), si_status (i32).
    var info: [128]u8 align(8) = [_]u8{0} ** 128;
    while (true) {
        const rc = linux.waitid(.PID, pid, @ptrCast(&info), linux.W.EXITED | linux.W.NOWAIT | linux.W.NOHANG);
        switch (linux.E.init(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        break;
    }
    const got = std.mem.readInt(i32, info[16..20], builtin.cpu.arch.endian());
    if (got == 0) return null;
    const code = std.mem.readInt(i32, info[8..12], builtin.cpu.arch.endian());
    const st = std.mem.readInt(i32, info[24..28], builtin.cpu.arch.endian());
    const CLD_EXITED = 1;
    if (code == CLD_EXITED) return @intCast(st & 0xff);
    return @intCast((128 + st) & 0xff);
}

/// A pidfd of `pid` (Linux 5.3), readable once it exits; null where the
/// kernel has none.
pub fn pidfdOpen(pid: pid_t) ?fd_t {
    if (!is_linux) return null;
    const rc = linux.pidfd_open(pid, 0);
    if (linux.E.init(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// CLOCK_MONOTONIC in milliseconds, or null when the clock cannot be read.
pub fn monotonicMs() ?u64 {
    const ts = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch return null;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn sleepMs(ms: u64) void {
    posix.nanosleep(ms / 1000, (ms % 1000) * 1_000_000);
}

/// write(2) of all of `bytes`, retried on EINTR and short writes; errors
/// are dropped (a closed stderr is nothing to report to).
pub fn writeAll(fd: fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = posix.write(fd, rest) catch return;
        if (n == 0) return;
        rest = rest[n..];
    }
}

/// Reads until `buf` is full or end of file; returns the count.
pub fn readFull(fd: fd_t, buf: []u8) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = posix.read(fd, buf[got..]) catch |e| switch (e) {
            else => return got,
        };
        if (n == 0) return got;
        got += n;
    }
    return got;
}

/// Six characters of [A-Za-z0-9] from the kernel's random source.
pub fn randomSuffix(out: *[6]u8) void {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var raw: [6]u8 = undefined;
    posix.getrandom(&raw) catch {
        const t = monotonicMs() orelse 0;
        const p: u64 = @intCast(getpid());
        std.mem.writeInt(u48, &raw, @truncate(t *% 2654435761 +% p), .little);
    };
    for (raw, 0..) |b, i| out[i] = alphabet[b % alphabet.len];
}

/// Opens /dev/null and moves it onto `target`.
pub fn devNullOnto(target: fd_t, write: bool) void {
    const fd = posix.openZ("/dev/null", .{ .ACCMODE = if (write) .WRONLY else .RDONLY }, 0) catch return;
    if (fd != target) {
        posix.dup2(fd, target) catch {};
        posix.close(fd);
    }
}

/// Signal dispositions back to the default (a forked child that does not
/// exec keeps the parent's handlers).
pub fn defaultSignals() void {
    const act = posix.Sigaction{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    for ([_]u6{ posix.SIG.HUP, posix.SIG.INT, posix.SIG.TERM, posix.SIG.CHLD, posix.SIG.ALRM, posix.SIG.PIPE }) |s| {
        posix.sigaction(s, &act, null);
    }
}
