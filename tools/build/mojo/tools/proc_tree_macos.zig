//! proc_tree_macos: the compile watchdog's view of the compiler's process
//! tree on macOS (mojo_compile_macos.zig), read through libproc. The tree,
//! its CPU, the idle arithmetic and the kill list are proc_tree.zig's; this
//! file only reads the processes and sends the signals.
//!
//! Each process: its parent and status from `proc_pidinfo(PROC_PIDTBSDINFO)`,
//! its session from `getsid`, and its CPU from `proc_pidinfo(PROC_PIDTASKINFO)`
//! (user + system time of its threads, live and exited, in Mach time units,
//! converted with `mach_timebase_info` to 1/100 s). macOS keeps no CPU time
//! of reaped children, so a child reaped between two samples no longer
//! counts; one that ran through a sample did.
//!
//! The libproc structures are declared here, not taken from the SDK
//! headers; their sizes are pinned below against the headers' values
//! (PROC_PIDTBSDINFO_SIZE, PROC_PIDTASKINFO_SIZE).

const std = @import("std");
const proc_tree = @import("proc_tree.zig");

/// `struct proc_bsdinfo` of <sys/proc_info.h>.
pub const ProcBsdInfo = extern struct {
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

/// `struct proc_taskinfo` of <sys/proc_info.h>.
pub const ProcTaskInfo = extern struct {
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
    // PROC_PIDTBSDINFO_SIZE and PROC_PIDTASKINFO_SIZE of <sys/proc_info.h>:
    // a layout that differs is a wrong read of every field after it.
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_status") == 4);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_ppid") == 16);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_pgid") == 100);
    std.debug.assert(@sizeOf(ProcTaskInfo) == 96);
    std.debug.assert(@offsetOf(ProcTaskInfo, "pti_total_user") == 16);
    std.debug.assert(@offsetOf(ProcTaskInfo, "pti_total_system") == 24);
}

const PROC_PIDTBSDINFO: c_int = 3;
const PROC_PIDTASKINFO: c_int = 4;
/// `SZOMB` of <sys/proc.h>: exited, not yet reaped.
pub const SZOMB: u32 = 5;

pub const Timebase = extern struct {
    numer: u32,
    denom: u32,
};

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn getsid(pid: c_int) c_int;
extern "c" fn mach_timebase_info(info: *Timebase) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

const SIGKILL: c_int = 9;
const SIGSTOP: c_int = 17;

/// Mach time units of CPU as clock ticks (1/100 s), rounded down.
pub fn ticksOf(units: u64, tb: Timebase) i64 {
    if (tb.denom == 0) return 0;
    const ns = @as(u128, units) * tb.numer / tb.denom;
    return @intCast(@min(ns / 10_000_000, std.math.maxInt(i64)));
}

/// Every process libproc shows now. A process that exits while it is read
/// is skipped; one whose task cannot be read (a zombie) counts no CPU.
pub fn readAll(alloc: std.mem.Allocator) ![]proc_tree.Proc {
    var tb = Timebase{ .numer = 0, .denom = 0 };
    if (mach_timebase_info(&tb) != 0) return error.Timebase;
    var cap: usize = 4096;
    var pids: []c_int = &.{};
    while (true) {
        const buf = try alloc.alloc(c_int, cap);
        const n = proc_listallpids(buf.ptr, @intCast(cap * @sizeOf(c_int)));
        if (n < 0) return error.ProcList;
        const count: usize = @intCast(n);
        if (count < cap) {
            pids = buf[0..count];
            break;
        }
        cap *= 2;
    }
    var out = std.ArrayList(proc_tree.Proc).empty;
    for (pids) |pid| {
        var bsd: ProcBsdInfo = undefined;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) continue;
        var task: ProcTaskInfo = undefined;
        const ticks = if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, @sizeOf(ProcTaskInfo)) == @sizeOf(ProcTaskInfo))
            ticksOf(task.pti_total_user +| task.pti_total_system, tb)
        else
            0;
        try out.append(alloc, .{
            .pid = pid,
            .state = if (bsd.pbi_status == SZOMB) 'Z' else 'S',
            .ppid = @bitCast(bsd.pbi_ppid),
            .sid = getsid(pid),
            .ticks = ticks,
        });
    }
    return out.toOwnedSlice(alloc);
}

/// The killable pids of `root`'s tree now (empty when root is gone).
pub fn treePids(alloc: std.mem.Allocator, root: i32) ![]const i32 {
    const procs = try readAll(alloc);
    const members = (try proc_tree.select(alloc, procs, root)) orelse return &.{};
    return proc_tree.killable(alloc, members);
}

/// As proc_tree.killTree: stops the session and every process of the tree,
/// lists the frozen tree, kills the session's process group and that list.
/// Never pid 0 or 1.
pub fn killTree(alloc: std.mem.Allocator, root: i32) void {
    if (root <= 1) return;
    _ = kill(-root, SIGSTOP);
    const first = treePids(alloc, root) catch &[_]i32{};
    for (first) |p| _ = kill(p, SIGSTOP);
    const frozen = treePids(alloc, root) catch first;
    _ = kill(-root, SIGKILL);
    for (frozen) |p| _ = kill(p, SIGKILL);
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

// Catches: CPU read in Mach units as if they were nanoseconds (on Apple
// silicon one unit is 125/3 ns, so every tree would look 24 times idler and
// a busy compile be killed). Mutant planted: skip the timebase conversion.
test "macOS CPU: Mach units to 1/100 s through the timebase" {
    // Apple silicon: 24 MHz units, numer/denom = 125/3.
    try testing.expectEqual(@as(i64, 100), ticksOf(24_000_000, .{ .numer = 125, .denom = 3 }));
    try testing.expectEqual(@as(i64, 1), ticksOf(240_000, .{ .numer = 125, .denom = 3 }));
    try testing.expectEqual(@as(i64, 0), ticksOf(239_999, .{ .numer = 125, .denom = 3 }));
    // Intel: units are nanoseconds.
    try testing.expectEqual(@as(i64, 250), ticksOf(2_500_000_000, .{ .numer = 1, .denom = 1 }));
    try testing.expectEqual(@as(i64, 0), ticksOf(5, .{ .numer = 1, .denom = 0 }));
}
