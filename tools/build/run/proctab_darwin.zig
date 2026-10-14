//! The process table on macOS, from libproc (libSystem): there is no /proc.
//! One reading is every process's pid, parent pid and state from
//! proc_pidinfo(PROC_PIDTBSDINFO), and its resident memory from
//! proc_pidinfo(PROC_PIDTASKINFO), `pti_resident_size`. What differs from
//! the Linux reading (proctab.zig):
//!
//!   * resident memory is the task's resident size, which on macOS leaves
//!     out pages the memory compressor holds; Linux's VmRSS has no
//!     compressor to leave out (zram aside).
//!   * the resident memory of a process of another user cannot be read
//!     without privileges; it counts 0. The test the gate runs and every
//!     process below it are the gate's own user's.
//!   * a zombie, where libproc still reports it, is listed with state 'Z'
//!     and no resident memory (its task is gone), as on Linux.

const std = @import("std");
const proctab = @import("proctab.zig");

// <libproc.h>, <sys/proc_info.h>.
extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_listpgrppids(pgrpid: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

const PROC_PIDTBSDINFO: c_int = 3;
const PROC_PIDTASKINFO: c_int = 4;
/// pbi_status of a zombie (<sys/proc.h>).
const SZOMB: u32 = 5;
const SSTOP: u32 = 4;
const SRUN: u32 = 2;

const BsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [16]u8,
    pbi_name: [32]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

const TaskInfo = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

comptime {
    // The sizes libproc checks the buffer against (sys/proc_info.h).
    std.debug.assert(@sizeOf(BsdInfo) == 136);
    std.debug.assert(@sizeOf(TaskInfo) == 96);
}

fn bsdInfo(pid: i32) ?BsdInfo {
    var info: BsdInfo = undefined;
    const n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, @sizeOf(BsdInfo));
    if (n != @sizeOf(BsdInfo)) return null;
    return info;
}

fn residentKib(pid: i32) u64 {
    var info: TaskInfo = undefined;
    const n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, @sizeOf(TaskInfo));
    if (n != @sizeOf(TaskInfo)) return 0;
    return info.pti_resident_size / 1024;
}

fn state(status: u32) u8 {
    return switch (status) {
        SZOMB => 'Z',
        SSTOP => 'T',
        SRUN => 'R',
        else => 'S',
    };
}

/// Every pid of the system (listpgrp: of process group `pgid`), or null when
/// the list cannot be read. The list is read into a buffer with room for
/// more than the count asked first, so a process started in between fits.
fn pids(alloc: std.mem.Allocator, pgid: ?i32) ?[]i32 {
    var room: usize = 1024;
    while (true) {
        const buf = alloc.alloc(i32, room) catch return null;
        const bytes: c_int = @intCast(room * @sizeOf(i32));
        const n = if (pgid) |g| proc_listpgrppids(g, buf.ptr, bytes) else proc_listallpids(buf.ptr, bytes);
        if (n < 0) return null;
        const count: usize = @intCast(n);
        // proc_listallpids returns a count of pids; proc_listpgrppids too.
        if (count < room) return buf[0..count];
        room *= 4;
        if (room > 1 << 22) return null;
    }
}

/// One reading of the table; null when the pid list cannot be read.
pub fn read(alloc: std.mem.Allocator) ?proctab.Table {
    const all = pids(alloc, null) orelse return null;
    var procs = std.ArrayList(proctab.Proc).init(alloc);
    for (all) |pid| {
        if (pid <= 0) continue;
        const b = bsdInfo(pid) orelse continue;
        const st = state(b.pbi_status);
        procs.append(.{
            .pid = @intCast(b.pbi_pid),
            .ppid = @intCast(b.pbi_ppid),
            .state = st,
            .rss_kib = if (st == 'Z') 0 else residentKib(pid),
        }) catch return null;
    }
    return proctab.Table{ .procs = procs.items };
}

/// The members of process group `pgid` that are not zombies; null when the
/// list cannot be read.
pub fn groupMembers(alloc: std.mem.Allocator, pgid: i32) ?[]proctab.Member {
    const all = pids(alloc, pgid) orelse return null;
    var out = std.ArrayList(proctab.Member).init(alloc);
    for (all) |pid| {
        if (pid <= 0) continue;
        const b = bsdInfo(pid) orelse continue;
        if (b.pbi_pgid != @as(u32, @bitCast(pgid))) continue;
        const st = state(b.pbi_status);
        if (st == 'Z') continue;
        const comm = std.mem.sliceTo(&b.pbi_comm, 0);
        out.append(.{ .pid = pid, .state = st, .comm = alloc.dupe(u8, comm) catch return null }) catch return null;
    }
    return out.items;
}

/// The pid libproc reports for this process, twice (0 where it cannot be
/// read): macOS has no PID namespaces, so the one reading stands for both of
/// Linux's (/proc/<pid>/stat and /proc/self/stat).
pub fn selfSeen(self: i32) [2]i64 {
    const b = bsdInfo(self) orelse return .{ 0, 0 };
    return .{ b.pbi_pid, b.pbi_pid };
}

/// Whether `pid` is alive and not a zombie.
pub fn alive(pid: i32) bool {
    const b = bsdInfo(pid) orelse return false;
    return b.pbi_status != SZOMB;
}
