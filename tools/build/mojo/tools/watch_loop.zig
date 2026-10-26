//! watch_loop: the compile watchdog's loop (mojo_compile.zig on Linux,
//! mojo_compile_macos.zig on macOS), apart from the process it watches, so
//! that its decisions are made on values a test supplies.
//!
//! One iteration is one tick: wait for it, check for a signal, see whether
//! the compiler has exited, read the CPU of its tree, and count it (the
//! idle arithmetic is proc_tree.Watch's). `run` is generic over the `env`
//! that does those things:
//!
//!   env.beginTick()        a fresh arena for this tick
//!   env.waitTick()         returns when a tick has passed
//!   env.checkSignal()      handles a caught signal (it does not return then)
//!   env.reaped() ?u32      the compiler's wait status once it has exited
//!   env.treeTicks() ?i64   the tree's CPU ticks, null when it is not listed
//!   env.ack()              the iteration is over
//!
//! The shipped wrappers' tick is a one-second sleep. A test executable gets
//! its ticks from the process that runs it instead: it declares
//! `pub const tick_source: enum { inherited_fd } = .inherited_fd;` at its root (see
//! mojo_compile_ticked.zig), and then a tick is one byte read from
//! descriptor 3, and every finished iteration writes one byte to descriptor
//! 4. The test sends a tick, waits for its acknowledgement (or for the
//! descriptor to close, which is the wrapper's exit), and so decides exactly
//! how many ticks the wrapper has seen when it acts. The declaration is the
//! only difference between the two executables: no option, no environment.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const proc_tree = @import("proc_tree.zig");

/// The descriptors of a ticked executable: ticks in, acknowledgements out.
pub const tick_fd: posix.fd_t = 3;
pub const ack_fd: posix.fd_t = 4;

/// Whether this executable takes its ticks from `tick_fd`.
pub fn ticked() bool {
    const root = @import("root");
    return comptime (@hasDecl(root, "tick_source") and std.mem.eql(u8, @tagName(root.tick_source), "inherited_fd"));
}

/// read(2) once, not retried when a signal interrupts it (a caught signal
/// must wake the loop): the count, 0 at end of file, -1 on any error.
fn rawRead(fd: posix.fd_t, buf: []u8) isize {
    if (builtin.os.tag == .linux) {
        const r = linux.read(fd, buf.ptr, buf.len);
        return if (linux.E.init(r) == .SUCCESS) @intCast(r) else -1;
    }
    return std.c.read(fd, buf.ptr, buf.len);
}

/// A tick: `sleep_one_second` normally; in a ticked executable one byte from
/// `tick_fd` (and the sleep once that descriptor is at end of file, so a
/// closed source does not spin). A signal that interrupts the wait returns.
pub fn waitTick(sleep_one_second: *const fn () void) void {
    if (comptime !ticked()) return sleep_one_second();
    var b: [1]u8 = undefined;
    if (rawRead(tick_fd, &b) == 0) sleep_one_second();
}

/// The iteration is over (ticked executables only).
pub fn ack() void {
    if (comptime !ticked()) return;
    _ = posix.write(ack_fd, "a") catch {};
}

/// A ticked executable's two descriptors must not reach the compiler or
/// anything it starts: they close when the wrapper exits, and that closing is
/// what the test waits for.
pub fn closeOnExec() void {
    if (comptime !ticked()) return;
    for ([_]posix.fd_t{ tick_fd, ack_fd }) |fd| _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch {};
}

/// In a process forked from the wrapper that does not exec (the tether).
pub fn closeInForked() void {
    if (comptime !ticked()) return;
    posix.close(tick_fd);
    posix.close(ack_fd);
}

pub const Result = union(enum) {
    /// The compiler's wait status.
    exited: u32,
    /// The watchdog says kill; the idle seconds behind it.
    killed: u64,
};

/// Runs the loop until the compiler has exited or `watch` says kill.
/// `first` is the status when it had exited before the first tick.
pub fn run(env: anytype, watch: *proc_tree.Watch, first: ?u32) Result {
    var status = first;
    while (status == null) {
        env.beginTick();
        env.waitTick();
        env.checkSignal();
        status = env.reaped();
        if (status != null) break;
        const ticks = env.treeTicks() orelse {
            env.ack();
            continue;
        };
        if (watch.tick(ticks)) return .{ .killed = watch.idleSecs() };
        env.ack();
    }
    return .{ .exited = status.? };
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// An env whose CPU readings and exit are a script: the tree gains
/// `cpu[k]` ticks over tick k+1 (past the script, the last value repeats),
/// the compiler exits at tick `exit_at` (0: never), and a reading is missing
/// at the ticks in `unlisted`.
const Script = struct {
    cpu: []const i64,
    exit_at: usize = 0,
    unlisted: []const usize = &.{},
    tick: usize = 0,
    total: i64 = 0,
    acks: usize = 0,

    fn beginTick(_: *Script) void {}
    fn checkSignal(_: *Script) void {}
    fn waitTick(s: *Script) void {
        s.tick += 1;
    }
    fn reaped(s: *Script) ?u32 {
        return if (s.exit_at != 0 and s.tick >= s.exit_at) 0 else null;
    }
    fn treeTicks(s: *Script) ?i64 {
        for (s.unlisted) |u| if (u == s.tick) return null;
        const k = @min(s.tick - 1, s.cpu.len - 1);
        s.total += s.cpu[k];
        return s.total;
    }
    fn ack(s: *Script) void {
        s.acks += 1;
    }
};

// Catches: an off-by-one in the number of idle samples before the kill, in
// either direction. A tree using no CPU is killed at tick ceil(idle/sample)
// * sample exactly, and one tick earlier it is not.
test "a silent tree is killed at tick idle (sample 1), and not at the tick before" {
    var s = Script{ .cpu = &.{0} };
    var w = proc_tree.Watch.init(3, 1, 0);
    const r = run(&s, &w, null);
    try testing.expectEqual(@as(u64, 3), r.killed);
    try testing.expectEqual(@as(usize, 3), s.tick);
    // The compiler exiting at the third tick is not a kill: the exit is read first.
    var s2 = Script{ .cpu = &.{0}, .exit_at = 3 };
    var w2 = proc_tree.Watch.init(3, 1, 0);
    try testing.expectEqual(@as(u32, 0), run(&s2, &w2, null).exited);
    try testing.expectEqual(@as(usize, 2), s2.acks);
}

test "with a sample of 2 and an idle of 5, the kill is at the sixth tick" {
    var s = Script{ .cpu = &.{0} };
    var w = proc_tree.Watch.init(5, 2, 0);
    try testing.expectEqual(@as(u64, 6), run(&s, &w, null).killed);
    try testing.expectEqual(@as(usize, 6), s.tick);
}

// Catches: CPU anywhere in the tree not counted (an orphaned spinner), or a
// busy sample not resetting the idle count.
test "a tree that gains CPU is not killed, and a busy sample restarts the count" {
    // Idle, idle, busy, idle, idle, then the compiler ends: never 3 in a row.
    var s = Script{ .cpu = &.{ 0, 0, 5, 0, 0 }, .exit_at = 6 };
    var w = proc_tree.Watch.init(3, 1, 0);
    try testing.expectEqual(@as(u32, 0), run(&s, &w, null).exited);
    // A spinner (1 tick per second is the boundary: sample ticks gained is busy).
    var s2 = Script{ .cpu = &.{1}, .exit_at = 50 };
    var w2 = proc_tree.Watch.init(3, 1, 0);
    try testing.expectEqual(@as(u32, 0), run(&s2, &w2, null).exited);
}

test "a tick with no reading counts for nothing, and the compiler gone before the first tick is its status" {
    var s = Script{ .cpu = &.{0}, .unlisted = &.{ 1, 2 } };
    var w = proc_tree.Watch.init(2, 1, 0);
    // Ticks 1 and 2 are unlisted (not counted); 3 and 4 are the two idle samples.
    try testing.expectEqual(@as(u64, 2), run(&s, &w, null).killed);
    try testing.expectEqual(@as(usize, 4), s.tick);
    var s3 = Script{ .cpu = &.{0} };
    var w3 = proc_tree.Watch.init(2, 1, 0);
    try testing.expectEqual(@as(u32, 7), run(&s3, &w3, 7).exited);
    try testing.expectEqual(@as(usize, 0), s3.tick);
}

test "the shipped executables tick on the clock" {
    // This test runner declares no tick_source.
    try testing.expect(!ticked());
}
