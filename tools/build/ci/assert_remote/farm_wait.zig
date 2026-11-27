//! The wait before `assert_remote run` runs a cut buck2 command again
//! (farm_retry.zig): wait until the farm's port answers, for a bounded time.
//!
//! Where the farm is and how long to wait come from the machine buckconfig the
//! farm-connect action wrote (.github/actions/farm-connect/action.yml):
//! `engine_address` under `[buck2_re_client]`, the address buck2 itself uses,
//! and `farm_wait_seconds` under `[komira_ci]`, farm-connect's
//! `farm-wait-minutes` input in seconds. So the wait here and farm-connect's
//! own wait before the first build have one bound, set in one place. The
//! same section may hold `dead_connection_seconds`, the watchdog's bound on a
//! connection to the farm that hears nothing (farm_watchdog.zig); farm-connect
//! does not write it, so the watchdog's default holds.
//!
//! The probe is the one farm-connect makes: a TCP connection to the farm's
//! port, given 5 s, every 5 s until it answers or the bound has passed, with a
//! line in the job log each minute it has not answered. It says nothing of the
//! farm beyond that its port accepts a connection, which is what a cut
//! connection takes away: the buck2 run after it is the real test.

const std = @import("std");
const posix = std.posix;

/// Where the farm is and how long to wait for it.
pub const Farm = struct {
    host: []const u8,
    port: u16,
    /// The longest wait for the farm to answer, in seconds.
    wait_seconds: u32,
    /// How long a connection to the farm may hear nothing before the watchdog
    /// calls it dead, in seconds (farm_watchdog.zig).
    dead_seconds: u32 = default_dead_seconds,
};

/// The watchdog's bound when the farm config sets none: twice the 150 s after
/// which the farm closes a connection that moved nothing (farm_watchdog.zig
/// says why).
pub const default_dead_seconds: u32 = 300;

pub const ConfigError = error{
    /// No `engine_address` under `[buck2_re_client]`.
    NoEngineAddress,
    /// An `engine_address` that is not `[<scheme>://]<host>:<port>[/...]`.
    BadEngineAddress,
    /// No `farm_wait_seconds` under `[komira_ci]`.
    NoWaitSeconds,
    /// A `farm_wait_seconds` that is not a whole number of seconds.
    BadWaitSeconds,
    /// A `dead_connection_seconds` that is not a whole number of seconds from 1.
    BadDeadSeconds,
};

/// The farm of a buckconfig's text: the sections and keys the header names,
/// in lines `[<section>]` and `<key> = <value>` (spaces around each ignored).
/// The slices point into `text`.
pub fn parseConfig(text: []const u8) ConfigError!Farm {
    var section: []const u8 = "";
    var address: ?[]const u8 = null;
    var wait: ?[]const u8 = null;
    var dead: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len >= 2 and l[0] == '[' and l[l.len - 1] == ']') {
            section = std.mem.trim(u8, l[1 .. l.len - 1], " \t");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        const key = std.mem.trim(u8, l[0..eq], " \t");
        const value = std.mem.trim(u8, l[eq + 1 ..], " \t");
        if (std.mem.eql(u8, section, "buck2_re_client") and std.mem.eql(u8, key, "engine_address")) address = value;
        if (std.mem.eql(u8, section, "komira_ci") and std.mem.eql(u8, key, "farm_wait_seconds")) wait = value;
        if (std.mem.eql(u8, section, "komira_ci") and std.mem.eql(u8, key, "dead_connection_seconds")) dead = value;
    }
    const hp = try hostPort(address orelse return error.NoEngineAddress);
    const w = wait orelse return error.NoWaitSeconds;
    const seconds = std.fmt.parseInt(u32, w, 10) catch return error.BadWaitSeconds;
    var dead_seconds = default_dead_seconds;
    if (dead) |d| {
        dead_seconds = std.fmt.parseInt(u32, d, 10) catch return error.BadDeadSeconds;
        if (dead_seconds == 0) return error.BadDeadSeconds;
    }
    return .{ .host = hp.host, .port = hp.port, .wait_seconds = seconds, .dead_seconds = dead_seconds };
}

const HostPort = struct { host: []const u8, port: u16 };

/// The host and port of `[<scheme>://]<host>:<port>[/<path>]`, as
/// farm-connect reads FARM_ADDRESS; a host in brackets (`[::1]`) loses them.
fn hostPort(address: []const u8) ConfigError!HostPort {
    var rest = address;
    if (std.mem.indexOf(u8, rest, "://")) |at| rest = rest[at + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |at| rest = rest[0..at];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.BadEngineAddress;
    var host = rest[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0) return error.BadEngineAddress;
    const digits = rest[colon + 1 ..];
    if (digits.len == 0) return error.BadEngineAddress;
    for (digits) |d| if (!std.ascii.isDigit(d)) return error.BadEngineAddress;
    const port = std.fmt.parseInt(u16, digits, 10) catch return error.BadEngineAddress;
    if (port == 0) return error.BadEngineAddress;
    return .{ .host = host, .port = port };
}

/// Why a buckconfig gives no farm, for the job log.
pub fn describeConfigError(e: ConfigError) []const u8 {
    return switch (e) {
        error.NoEngineAddress => "it has no engine_address under [buck2_re_client]",
        error.BadEngineAddress => "its engine_address is not <host>:<port>",
        error.NoWaitSeconds => "it has no farm_wait_seconds under [komira_ci]",
        error.BadWaitSeconds => "its farm_wait_seconds is not a whole number of seconds",
        error.BadDeadSeconds => "its dead_connection_seconds is not a whole number of seconds from 1",
    };
}

/// How a wait for the farm ended.
pub const Waited = union(enum) {
    /// The farm answered after this many seconds; 0 when the first probe answered.
    answered: u64,
    /// The bound passed with no answer, after this many seconds.
    gave_up: u64,
};

/// Seconds between the starts of two probes, and how long one probe waits for
/// its connection.
pub const probe_seconds: u64 = 5;

/// Probes until the farm answers or `bound` seconds have passed since the
/// first probe, sleeping `probe_seconds` (never past the bound) between two,
/// and writes a line to `w` each whole minute the farm has not answered.
/// `clock` has `now() u64` (seconds) and `sleep(seconds: u64) void`; `prober`
/// has `answers() bool`.
pub fn waitForFarm(clock: anytype, prober: anytype, bound: u64, w: *std.Io.Writer) std.Io.Writer.Error!Waited {
    const start = clock.now();
    var next_note: u64 = 60;
    var first = true;
    while (true) {
        const answered = prober.answers();
        const waited = clock.now() -| start;
        if (answered) return .{ .answered = if (first) 0 else waited };
        first = false;
        if (waited >= bound) return .{ .gave_up = waited };
        if (waited >= next_note) {
            try w.writeAll("buck2-farm: the farm has not answered for ");
            try writeDuration(w, waited);
            try w.writeAll("; waiting up to ");
            try writeDuration(w, bound);
            try w.writeAll("\n");
            try w.flush();
            next_note = (waited / 60 + 1) * 60;
        }
        clock.sleep(@min(probe_seconds, bound - waited));
    }
}

/// `<N> min <M> s`, the way the job log and summary give a wait.
pub fn writeDuration(w: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    try w.print("{d} min {d} s", .{ seconds / 60, seconds % 60 });
}

/// The clock of a real wait: seconds since it was made, on the monotonic clock.
pub const RealClock = struct {
    start: std.time.Instant,
    /// The seconds slept so far: a lower bound of the time passed.
    slept: u64 = 0,

    pub fn init() error{Unsupported}!RealClock {
        return .{ .start = try std.time.Instant.now() };
    }

    pub fn now(c: *RealClock) u64 {
        // Should a read of the monotonic clock fail after the first, the
        // seconds slept stand in for it, so the wait still ends at its bound.
        const n = std.time.Instant.now() catch return c.slept;
        return @max(c.slept, n.since(c.start) / std.time.ns_per_s);
    }

    pub fn sleep(c: *RealClock, seconds: u64) void {
        std.Thread.sleep(seconds * std.time.ns_per_s);
        c.slept += seconds;
    }
};

/// The probe of a real wait: a TCP connection to the farm's port.
pub const TcpProber = struct {
    a: std.mem.Allocator,
    host: []const u8,
    port: u16,

    /// True when a TCP connection to one of the host's addresses is accepted
    /// within `probe_seconds`; false on any error (a name that does not
    /// resolve, a refusal, no route, no answer in time).
    pub fn answers(p: TcpProber) bool {
        const list = std.net.getAddressList(p.a, p.host, p.port) catch return false;
        defer list.deinit();
        for (list.addrs) |addr| {
            if (connectsWithin(addr, @intCast(probe_seconds * std.time.ms_per_s))) return true;
        }
        return false;
    }
};

/// True when a non-blocking connect to `addr` completes within `ms`.
fn connectsWithin(addr: std.net.Address, ms: i32) bool {
    const fd = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return false;
    defer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const ready = posix.poll(&fds, ms) catch return false;
            if (ready == 0) return false;
            posix.getsockoptError(fd) catch return false;
            return true;
        },
        else => return false,
    };
    return true;
}
