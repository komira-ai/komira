//! proc_tree: the compile watchdog's view of the compiler's process tree
//! (mojo_compile.zig), on Linux through /proc.
//!
//! The tree of a root: every process whose session id is the root's pid
//! (the compiler leads a session of its own, so a helper reparented away
//! from it, to init or a subreaper, is still in it), plus every descendant
//! by parent pid of anything in the tree, to a fixed point. Its CPU is the
//! sum of utime+stime+cutime+cstime (clock ticks, 1/100 s) of its members,
//! so children already reaped count too. What is sampled is exactly what
//! `killTree` kills, so a helper doing the work while the root waits is never
//! read as idle.

const std = @import("std");
const linux = std.os.linux;

pub const Proc = struct {
    pid: i32,
    state: u8,
    ppid: i32,
    sid: i32,
    ticks: i64,
};

/// One /proc/<pid>/stat line. `comm` (field 2) may hold spaces and
/// parentheses: the fields after it start past the LAST `)`.
pub fn parseStat(text: []const u8) ?Proc {
    const sp = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    const pid = std.fmt.parseInt(i32, text[0..sp], 10) catch return null;
    const rp = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[rp + 1 ..], " \t\n");
    var f: [15][]const u8 = undefined;
    for (&f) |*slot| slot.* = it.next() orelse return null;
    if (f[0].len != 1) return null;
    var ticks: i64 = 0;
    // Fields 14-17 of stat(5): utime, stime, cutime, cstime.
    for (f[11..15]) |t| ticks += std.fmt.parseInt(i64, t, 10) catch return null;
    return .{
        .pid = pid,
        .state = f[0][0],
        .ppid = std.fmt.parseInt(i32, f[1], 10) catch return null,
        .sid = std.fmt.parseInt(i32, f[3], 10) catch return null,
        .ticks = ticks,
    };
}

/// The pids of `root`'s tree, ascending, or null when `root` is not among
/// `procs`.
pub fn select(alloc: std.mem.Allocator, procs: []const Proc, root: i32) !?[]i32 {
    var found = false;
    for (procs) |p| {
        if (p.pid == root) found = true;
    }
    if (!found) return null;
    var in = std.AutoHashMap(i32, void).init(alloc);
    defer in.deinit();
    try in.put(root, {});
    for (procs) |p| {
        if (p.sid == root) try in.put(p.pid, {});
    }
    var grew = true;
    while (grew) {
        grew = false;
        for (procs) |p| {
            if (!in.contains(p.pid) and in.contains(p.ppid)) {
                try in.put(p.pid, {});
                grew = true;
            }
        }
    }
    const out = try alloc.alloc(i32, in.count());
    var k: usize = 0;
    var keys = in.keyIterator();
    while (keys.next()) |key| : (k += 1) out[k] = key.*;
    std.mem.sort(i32, out, {}, std.sort.asc(i32));
    return out;
}

/// The CPU ticks of `members`.
pub fn cpu(procs: []const Proc, members: []const i32) i64 {
    var tot: i64 = 0;
    for (procs) |p| {
        for (members) |m| {
            if (m == p.pid) tot += p.ticks;
        }
    }
    return tot;
}

/// The members a kill may name: never pid 0 (the caller's own process
/// group) or 1, nor a negative pid.
pub fn killable(alloc: std.mem.Allocator, members: []const i32) ![]i32 {
    var out = std.ArrayList(i32).init(alloc);
    for (members) |m| {
        if (m > 1) try out.append(m);
    }
    return out.toOwnedSlice();
}

/// The idle arithmetic. `tick` is called once a second with the tree's CPU
/// ticks; every `sample` calls it compares them with the last sample: a
/// sample in which the tree gained fewer ticks than `sample` (under 1% of
/// one CPU) is idle, and after ceil(idle_secs / sample) consecutive idle
/// samples `tick` says kill.
pub const Watch = struct {
    sample: u64,
    need: u64,
    last: i64,
    idle: u64 = 0,
    waited: u64 = 0,

    pub fn samplesNeeded(idle_secs: u32, sample_secs: u32) u64 {
        const i: u64 = idle_secs;
        const s: u64 = sample_secs;
        return (i + s - 1) / s;
    }

    pub fn init(idle_secs: u32, sample_secs: u32, first: i64) Watch {
        return .{ .sample = sample_secs, .need = samplesNeeded(idle_secs, sample_secs), .last = first };
    }

    pub fn tick(self: *Watch, ticks: i64) bool {
        self.waited += 1;
        if (self.waited < self.sample) return false;
        self.waited = 0;
        if (ticks - self.last < @as(i64, @intCast(self.sample))) {
            self.idle += 1;
        } else {
            self.idle = 0;
        }
        self.last = ticks;
        return self.idle >= self.need;
    }

    /// Seconds of idle samples behind a kill, for the watchdog's message.
    pub fn idleSecs(self: Watch) u64 {
        return self.idle * self.sample;
    }
};

// ---- Linux: read and kill (not pure) -----------------------------------------

/// Every process /proc shows now. A process that exits while it is read is
/// skipped.
pub fn readAll(alloc: std.mem.Allocator) ![]Proc {
    var out = std.ArrayList(Proc).init(alloc);
    var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var buf: [4096]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    while (try it.next()) |e| {
        if (e.name.len == 0 or e.name[0] < '0' or e.name[0] > '9') continue;
        const path = std.fmt.bufPrint(&path_buf, "{s}/stat", .{e.name}) catch continue;
        const f = dir.openFile(path, .{}) catch continue;
        defer f.close();
        const n = f.readAll(&buf) catch continue;
        if (parseStat(buf[0..n])) |p| try out.append(p);
    }
    return out.toOwnedSlice();
}

/// The killable pids of `root`'s tree now (empty when root is gone).
pub fn treePids(alloc: std.mem.Allocator, root: i32) ![]const i32 {
    const procs = try readAll(alloc);
    const members = (try select(alloc, procs, root)) orelse return &.{};
    return killable(alloc, members);
}

/// Stops the session and every process of the tree, so none can start
/// another; lists the (now frozen) tree; kills the session's process group
/// and that list. Never pid 0 or 1.
pub fn killTree(alloc: std.mem.Allocator, root: i32) void {
    if (root <= 1) return;
    _ = linux.kill(-root, linux.SIG.STOP);
    const first = treePids(alloc, root) catch &[_]i32{};
    for (first) |p| _ = linux.kill(p, linux.SIG.STOP);
    const frozen = treePids(alloc, root) catch first;
    _ = linux.kill(-root, linux.SIG.KILL);
    for (frozen) |p| _ = linux.kill(p, linux.SIG.KILL);
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

// Catches: fields counted from the first `)` (a comm holding `) (` shifts
// every field). Mutant planted: read the fields after the first `)`.
test "/proc parse: comm with ') (' and spaces; field offsets 14-17" {
    const line = "4242 (a) (b c) d) S 17 4242 4240 0 -1 4194560 100 0 0 0 11 22 33 44 20 0 1 0 5 0 0\n";
    const p = parseStat(line) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 4242), p.pid);
    try testing.expectEqual(@as(u8, 'S'), p.state);
    try testing.expectEqual(@as(i32, 17), p.ppid);
    try testing.expectEqual(@as(i32, 4240), p.sid);
    try testing.expectEqual(@as(i64, 11 + 22 + 33 + 44), p.ticks);
}

test "/proc parse: zombie state; plain comm; short line refused" {
    const z = parseStat("9 (mojo) Z 1 9 9 0 -1 0 0 0 0 0 5 6 0 0 20 0 1 0\n") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 'Z'), z.state);
    try testing.expectEqual(@as(i32, 1), z.ppid);
    try testing.expectEqual(@as(i64, 11), z.ticks);
    try testing.expect(parseStat("9 (mojo) S 1 9 9 0") == null);
    try testing.expect(parseStat("") == null);
    try testing.expect(parseStat("x (mojo) S 1 9 9 0 -1 0 0 0 0 0 5 6 0 0") == null);
}

fn proc(pid: i32, ppid: i32, sid: i32, ticks: i64) Proc {
    return .{ .pid = pid, .state = 'S', .ppid = ppid, .sid = sid, .ticks = ticks };
}

// Catches: a helper reparented away from the compiler (to init) missed,
// so its CPU does not count and it survives the kill. Mutant planted: drop
// the session rule.
test "tree selection: a session member reparented to 1 and a grandchild are in; others out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const procs = [_]Proc{
        proc(1, 0, 1, 1000),
        proc(50, 1, 50, 1), // the wrapper's parent: another session
        proc(60, 50, 50, 2), // the wrapper
        proc(100, 60, 100, 10), // root: the compiler, its own session
        proc(101, 100, 100, 20), // child
        proc(102, 101, 100, 30), // grandchild
        proc(103, 1, 100, 40), // reparented to init, still in the session
        proc(104, 103, 777, 50), // left the session (setsid), child of a member
        proc(200, 1, 200, 1000), // unrelated
    };
    const got = (try select(a, &procs, 100)).?;
    try testing.expectEqualSlices(i32, &.{ 100, 101, 102, 103, 104 }, got);
    try testing.expectEqual(@as(i64, 10 + 20 + 30 + 40 + 50), cpu(&procs, got));
    try testing.expect((try select(a, &procs, 999)) == null);
}

// Catches: a kill list holding 1 (init) or 0 (the caller's own group).
test "tree selection: pid 1 and 0 are never in the kill list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A session id of 1 makes init a member: it must still not be killed.
    const procs = [_]Proc{ proc(1, 0, 1, 0), proc(0, 0, 1, 0), proc(5, 1, 1, 0) };
    const members = (try select(a, &procs, 1)).?;
    try testing.expectEqualSlices(i32, &.{ 0, 1, 5 }, members);
    try testing.expectEqualSlices(i32, &.{5}, try killable(a, members));
}

// Catches: a busy tree read as idle, or the reverse, at the 1% boundary.
// Mutant planted: `<=` for `<`.
test "idle arithmetic: delta = sample is busy, sample - 1 idle" {
    var w = Watch.init(60, 30, 0);
    try testing.expectEqual(@as(u64, 2), w.need);
    var t: i64 = 0;
    // 29 seconds between samples say nothing.
    for (0..29) |_| try testing.expect(!w.tick(t));
    t += 30; // exactly `sample` ticks: busy
    try testing.expect(!w.tick(t));
    try testing.expectEqual(@as(u64, 0), w.idle);
    for (0..29) |_| try testing.expect(!w.tick(t));
    t += 29; // one under: idle
    try testing.expect(!w.tick(t));
    try testing.expectEqual(@as(u64, 1), w.idle);
    for (0..29) |_| try testing.expect(!w.tick(t));
    try testing.expect(w.tick(t)); // second idle sample: kill
    try testing.expectEqual(@as(u64, 60), w.idleSecs());
}

test "idle arithmetic: need is ceil(idle / sample); a busy sample resets the count" {
    try testing.expectEqual(@as(u64, 3), Watch.samplesNeeded(3, 1));
    try testing.expectEqual(@as(u64, 10), Watch.samplesNeeded(300, 30));
    try testing.expectEqual(@as(u64, 11), Watch.samplesNeeded(301, 30));
    try testing.expectEqual(@as(u64, 1), Watch.samplesNeeded(1, 30));
    try testing.expectEqual(@as(u64, 4294967295), Watch.samplesNeeded(4294967295, 1));
    var w = Watch.init(3, 1, 100);
    try testing.expect(!w.tick(100));
    try testing.expect(!w.tick(100));
    try testing.expect(!w.tick(105)); // busy: back to 0
    try testing.expect(!w.tick(105));
    try testing.expect(!w.tick(105));
    try testing.expect(w.tick(105));
    try testing.expectEqual(@as(u64, 3), w.idleSecs());
}
