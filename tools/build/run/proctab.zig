//! The process table, read from /proc on Linux: one reading is every
//! process's pid, parent pid, state and resident memory, from
//! /proc/<pid>/status. A process that exits while the table is read is
//! skipped, as `cat /proc/[0-9]*/status` skips it. macOS has no /proc: there
//! the same reading comes from libproc (proctab_darwin.zig, which says what
//! differs).

const std = @import("std");
const sys = @import("sys.zig");
const darwin = if (sys.is_darwin) @import("proctab_darwin.zig") else struct {};

pub const Proc = struct {
    pid: i32,
    ppid: i32,
    state: u8,
    rss_kib: u64,
};

pub const Table = struct {
    procs: []Proc,

    pub fn find(self: Table, pid: i32) ?Proc {
        for (self.procs) |p| if (p.pid == pid) return p;
        return null;
    }

    pub fn has(self: Table, pid: i32) bool {
        return self.find(pid) != null;
    }

    /// `root` and every process below it (by parent pid), root first; null
    /// when root is not in the table or is a zombie (it has exited).
    pub fn tree(self: Table, alloc: std.mem.Allocator, root: i32) ?[]i32 {
        const r = self.find(root) orelse return null;
        if (r.state == 'Z') return null;
        var out = std.ArrayList(i32).empty;
        out.append(alloc, root) catch return null;
        var grew = true;
        while (grew) {
            grew = false;
            for (self.procs) |p| {
                if (std.mem.indexOfScalar(i32, out.items, p.pid) != null) continue;
                if (std.mem.indexOfScalar(i32, out.items, p.ppid) == null) continue;
                out.append(alloc, p.pid) catch return null;
                grew = true;
            }
        }
        return out.items;
    }

    /// The resident memory of `pids`, in KiB.
    pub fn rss(self: Table, pids: []const i32) u64 {
        var tot: u64 = 0;
        for (pids) |q| {
            if (self.find(q)) |p| tot += p.rss_kib;
        }
        return tot;
    }
};

/// Parses one /proc/<pid>/status; null when it holds no Pid line.
pub fn parseStatus(text: []const u8) ?Proc {
    var p = Proc{ .pid = 0, .ppid = 0, .state = '?', .rss_kib = 0 };
    var have_pid = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Pid")) {
            p.pid = std.fmt.parseInt(i32, val, 10) catch return null;
            have_pid = true;
        } else if (std.mem.eql(u8, key, "PPid")) {
            p.ppid = std.fmt.parseInt(i32, val, 10) catch return null;
        } else if (std.mem.eql(u8, key, "State")) {
            if (val.len > 0) p.state = val[0];
        } else if (std.mem.eql(u8, key, "VmRSS")) {
            const end = std.mem.indexOfAny(u8, val, " \t") orelse val.len;
            p.rss_kib = std.fmt.parseInt(u64, val[0..end], 10) catch 0;
        }
    }
    return if (have_pid) p else null;
}

fn isPidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// One reading of the table; null when /proc (macOS: the pid list) cannot be
/// listed.
pub fn read(alloc: std.mem.Allocator) ?Table {
    if (sys.is_darwin) return darwin.read(alloc);
    if (!sys.is_linux) return null;
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer dir.close();
    var procs = std.ArrayList(Proc).empty;
    var it = dir.iterate();
    var buf: [4096]u8 = undefined;
    while (true) {
        const entry = it.next() catch return null;
        const e = entry orelse break;
        if (!isPidName(e.name)) continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/status", .{e.name}) catch continue;
        const f = dir.openFile(path, .{}) catch continue;
        defer f.close();
        const n = f.readAll(&buf) catch continue;
        const p = parseStatus(buf[0..n]) orelse continue;
        procs.append(alloc, p) catch return null;
    }
    return Table{ .procs = procs.items };
}

/// A process of a process group, from /proc/<pid>/stat.
pub const Member = struct {
    pid: i32,
    state: u8,
    comm: []const u8,
};

/// Parses /proc/<pid>/stat: `pid (comm) state ppid pgrp ...`. comm may hold
/// spaces and parentheses, so the fields after it start after the LAST ')'.
pub fn parseStat(text: []const u8) ?struct { pid: i32, comm: []const u8, state: u8, ppid: i32, pgrp: i32 } {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close < open or close + 2 > text.len) return null;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text[0..open], " "), 10) catch return null;
    var f = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    const state = f.next() orelse return null;
    const ppid = f.next() orelse return null;
    const pgrp = f.next() orelse return null;
    return .{
        .pid = pid,
        .comm = text[open + 1 .. close],
        .state = state[0],
        .ppid = std.fmt.parseInt(i32, ppid, 10) catch return null,
        .pgrp = std.fmt.parseInt(i32, pgrp, 10) catch return null,
    };
}

/// The members of process group `pgid` that are neither zombies nor dead;
/// null when /proc (macOS: the group's pid list) cannot be listed.
pub fn groupMembers(alloc: std.mem.Allocator, pgid: i32) ?[]Member {
    if (sys.is_darwin) return darwin.groupMembers(alloc, pgid);
    if (!sys.is_linux) return null;
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer dir.close();
    var out = std.ArrayList(Member).empty;
    var it = dir.iterate();
    var buf: [1024]u8 = undefined;
    while (true) {
        const entry = it.next() catch return null;
        const e = entry orelse break;
        if (!isPidName(e.name)) continue;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/stat", .{e.name}) catch continue;
        const f = dir.openFile(path, .{}) catch continue;
        defer f.close();
        const n = f.readAll(&buf) catch continue;
        const s = parseStat(buf[0..n]) orelse continue;
        if (s.pgrp != pgid or s.state == 'Z' or s.state == 'X') continue;
        out.append(alloc, .{ .pid = s.pid, .state = s.state, .comm = alloc.dupe(u8, s.comm) catch return null }) catch return null;
    }
    return out.items;
}

/// The first field of /proc/<own pid>/stat and of /proc/self/stat (0 where
/// unreadable): both are this process's pid when /proc is this process's
/// own (not another PID namespace's, not one hiding processes). macOS: the
/// pid libproc reports for this process, twice.
pub fn selfSeen() [2]i64 {
    var out = [2]i64{ 0, 0 };
    if (sys.is_darwin) return darwin.selfSeen(sys.getpid());
    if (!sys.is_linux) return out;
    var path_buf: [64]u8 = undefined;
    const own = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{sys.getpid()}) catch return out;
    for ([_][]const u8{ own, "/proc/self/stat" }, 0..) |p, i| {
        var buf: [512]u8 = undefined;
        const f = std.fs.openFileAbsolute(p, .{}) catch continue;
        defer f.close();
        const n = f.readAll(&buf) catch continue;
        const sp = std.mem.indexOfScalar(u8, buf[0..n], ' ') orelse continue;
        out[i] = std.fmt.parseInt(i64, buf[0..sp], 10) catch 0;
    }
    return out;
}
