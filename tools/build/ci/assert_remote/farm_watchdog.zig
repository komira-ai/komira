//! The watchdog of `assert_remote run` (farm_retry.zig): it ends a buck2 run
//! whose connection to the farm has died without buck2 noticing, so the step is
//! run again instead of hanging until the job's own timeout.
//!
//! When the network path between the runner and the farm drops for a while,
//! the farm closes the connection, and its closing never reaches the runner.
//! buck2 then waits on an action in `[re_execute]` over a TCP connection that
//! the farm no longer has: nothing arrives on it, buck2 sends nothing on it,
//! and its own HTTP/2 keepalive does not end it (two runs of the pull request's
//! check waited so for two hours and for 3 h 40 min). The log is no help:
//! buck2's simple console prints the same `Waiting on ... [re_execute]` line
//! every few seconds whether the action runs for an hour or is lost, and a long
//! remote action that prints nothing is normal.
//!
//! So the watchdog reads the connection, not the log. Once a second it asks
//! the kernel (netlink sock_diag, the source `ss -ti` reads) for the runner's
//! established TCP connections to the farm's address and port, as the machine
//! buckconfig names them (`engine_address`), and for each the time since it
//! last received anything from the farm: the shorter of `tcp_info`'s
//! `last_data_recv` and `last_ack_recv`, the measure the kernel's own TCP
//! keepalive uses. A live farm is never silent for long on a connection, slow
//! or not: it sends each open Execute stream its operation again every 30 s
//! (its progress interval), PINGs a connection that is quiet for 30 s, and
//! acknowledges any byte buck2 sends; it closes a connection that has moved
//! nothing for 150 s (the PING interval and its 120 s keepalive timeout). Those
//! are the farm server's defaults (komira-ai/kbf, `--progress-interval-secs`,
//! `--http2-keepalive-interval-secs`, `--http2-keepalive-timeout-secs`). So a
//! connection that has heard nothing for longer than 150 s is one the farm has
//! already closed, whatever buck2 is doing on it. The watchdog's bound is
//! twice that, 300 s, counted from the run's start at the earliest (a
//! connection the daemon kept idle from an earlier step is judged by what it
//! hears in this run), unless the machine buckconfig sets
//! `dead_connection_seconds` under `[komira_ci]` (farm_wait.zig).
//!
//! When a connection has been silent past the bound, the run is ended: buck2
//! is sent SIGINT, as a Ctrl-C (it cancels its command and exits), and SIGKILL
//! if it has not ended `Watchdog.grace_ms` later (the bound, at most 10 s); then `<buck2> kill` stops its daemon,
//! which holds the dead connection and the lost action, so the next run starts
//! clean. What farm_retry.zig does next (the one line in the job log and the
//! summary, the wait for the farm, the run again within the bound of three) it
//! does for a cut connection too. The watchdog never runs anything itself.
//!
//! When the kernel cannot be asked (no netlink in a sandbox), the watchdog says
//! so once and stops; the run goes on as it would without it.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const native_endian = @import("builtin").cpu.arch.endian();

/// How often the watchdog reads the runner's connections, in milliseconds.
pub const check_ms: u64 = 1000;

/// The longest buck2 is given to end after SIGINT before SIGKILL, in
/// milliseconds; a shorter bound gives it the bound (`Watchdog.grace_ms`).
pub const max_grace_ms: u64 = 10_000;

/// How long the tool still reads buck2's output after SIGKILL, in
/// milliseconds, should something buck2 started hold the pipe open.
pub const after_kill_ms: u64 = 5_000;

/// One TCP connection of the runner's to the farm, as the kernel reported it.
pub const Conn = struct {
    /// The runner's end of it, to name it in the log.
    local_port: u16,
    /// Milliseconds since it last received anything from the farm (the
    /// shorter of `tcp_info`'s `last_data_recv` and `last_ack_recv`).
    silent_ms: u64,
};

/// The connection that makes a run dead: the one silent longest, when that
/// is longer than `bound_ms`; null when every connection has heard from the
/// farm within the bound, or there is none. A silence counts from the run's
/// start at the earliest (`run_ms` ago): a connection buck2's daemon kept idle
/// from before the run is judged only by what it hears during the run.
pub fn dead(conns: []const Conn, bound_ms: u64, run_ms: u64) ?Conn {
    var worst: ?Conn = null;
    for (conns) |c| {
        const silent = @min(c.silent_ms, run_ms);
        if (silent <= bound_ms) continue;
        if (worst == null or silent > worst.?.silent_ms) worst = .{ .local_port = c.local_port, .silent_ms = silent };
    }
    return worst;
}

// ---- the kernel's answer -----------------------------------------------------

/// `SOCK_DIAG_BY_FAMILY`, the request and answer type of a sock_diag dump.
const sock_diag_by_family: u16 = 20;
const nlmsg_error: u16 = 2;
const nlmsg_done: u16 = 3;
/// `INET_DIAG_INFO`: the attribute that holds a socket's `struct tcp_info`.
const inet_diag_info: u16 = 2;
/// `TCP_ESTABLISHED`.
const tcp_established: u8 = 1;
/// The size of `struct nlmsghdr`.
const nlmsghdr_len = 16;
/// The size of `struct inet_diag_msg`.
const inet_diag_msg_len = 72;
/// Where `tcpi_last_data_recv` and `tcpi_last_ack_recv` sit in `struct tcp_info`.
const last_data_recv_at = 52;
const last_ack_recv_at = 56;

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

pub const DumpError = error{
    /// The kernel answered the dump with an error (`NLMSG_ERROR`).
    DumpRefused,
    /// A message shorter than its header says, or than its kind needs.
    TruncatedMessage,
};

/// Whether the kernel has more of a dump to send.
pub const Part = enum { more, done };

/// True when the 16 bytes of an `inet_diag_sockid` address of `family` hold `addr`.
fn sameAddress(family: u8, raw: []const u8, addr: std.net.Address) bool {
    switch (addr.any.family) {
        posix.AF.INET => {
            const want = std.mem.asBytes(&addr.in.sa.addr);
            if (family == posix.AF.INET) return std.mem.eql(u8, raw[0..4], want);
            // an IPv6 socket connected to an IPv4 address: `::ffff:a.b.c.d`
            const mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            return family == posix.AF.INET6 and std.mem.eql(u8, raw[0..12], &mapped) and std.mem.eql(u8, raw[12..16], want);
        },
        posix.AF.INET6 => return family == posix.AF.INET6 and std.mem.eql(u8, raw[0..16], &addr.in6.sa.addr),
        else => return false,
    }
}

fn readU32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], native_endian);
}

fn readU16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], native_endian);
}

/// The connection one `SOCK_DIAG_BY_FAMILY` message reports, when it is an
/// established one to one of `farm` (each with its port) and carries the
/// times of its `tcp_info`; null for any other socket.
fn connOf(body: []const u8, farm: []const std.net.Address) DumpError!?Conn {
    if (body.len < inet_diag_msg_len) return error.TruncatedMessage;
    const family = body[0];
    if (body[1] != tcp_established) return null;
    const local_port = std.mem.readInt(u16, body[4..6], .big);
    const remote_port = std.mem.readInt(u16, body[6..8], .big);
    const remote = body[24..40];
    var ours = false;
    for (farm) |addr| {
        if (addr.getPort() == remote_port and sameAddress(family, remote, addr)) ours = true;
    }
    if (!ours) return null;
    var at: usize = inet_diag_msg_len;
    while (at + 4 <= body.len) {
        const len = readU16(body[at..]);
        const kind = readU16(body[at + 2 ..]);
        if (len < 4 or at + len > body.len) return error.TruncatedMessage;
        if (kind == inet_diag_info) {
            const info = body[at + 4 .. at + len];
            // a kernel too old to report the times: nothing to judge by
            if (info.len < last_ack_recv_at + 4) return null;
            const data = readU32(info[last_data_recv_at..]);
            const ack = readU32(info[last_ack_recv_at..]);
            return .{ .local_port = local_port, .silent_ms = @min(data, ack) };
        }
        at += align4(len);
    }
    return null;
}

/// Reads one buffer of a sock_diag dump of TCP sockets (netlink messages as
/// the kernel sends them), appending each established connection to one of
/// `farm` to `out`. `.done` once the dump's end is in it.
pub fn parseDump(a: std.mem.Allocator, bytes: []const u8, farm: []const std.net.Address, out: *std.ArrayList(Conn)) (DumpError || std.mem.Allocator.Error)!Part {
    var at: usize = 0;
    while (at + nlmsghdr_len <= bytes.len) {
        const len = readU32(bytes[at..]);
        const kind = readU16(bytes[at + 4 ..]);
        if (len < nlmsghdr_len or at + len > bytes.len) return error.TruncatedMessage;
        const body = bytes[at + nlmsghdr_len .. at + len];
        switch (kind) {
            nlmsg_done => return .done,
            nlmsg_error => return error.DumpRefused,
            sock_diag_by_family => if (try connOf(body, farm)) |c| try out.append(a, c),
            else => {},
        }
        at += align4(len);
    }
    return .more;
}

/// The request of a dump of the established TCP sockets of `family`, with
/// their `tcp_info`: `struct nlmsghdr` and `struct inet_diag_req_v2`.
pub fn dumpRequest(family: u8, seq: u32) [nlmsghdr_len + 56]u8 {
    var req = [_]u8{0} ** (nlmsghdr_len + 56);
    std.mem.writeInt(u32, req[0..4], req.len, native_endian);
    std.mem.writeInt(u16, req[4..6], sock_diag_by_family, native_endian);
    std.mem.writeInt(u16, req[6..8], linux.NLM_F_REQUEST | linux.NLM_F_DUMP, native_endian);
    std.mem.writeInt(u32, req[8..12], seq, native_endian);
    req[16] = family;
    req[17] = posix.IPPROTO.TCP;
    req[18] = 1 << (2 - 1); // idiag_ext: ask for INET_DIAG_INFO (2)
    std.mem.writeInt(u32, req[20..24], 1 << 1, native_endian); // idiag_states: TCP_ESTABLISHED (1) only
    return req;
}

/// Asks the kernel for the runner's established TCP connections to `farm`
/// (IPv4 and IPv6 sockets), into `out` (cleared first).
pub fn readConnections(a: std.mem.Allocator, farm: []const std.net.Address, out: *std.ArrayList(Conn)) !void {
    out.clearRetainingCapacity();
    const fd = try posix.socket(posix.AF.NETLINK, posix.SOCK.RAW | posix.SOCK.CLOEXEC, linux.NETLINK.SOCK_DIAG);
    defer posix.close(fd);
    // the kernel answers at once; never wait on it for long
    const two_s: posix.timeval = .{ .sec = 2, .usec = 0 };
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&two_s));
    var buf: [32 * 1024]u8 align(4) = undefined;
    for ([_]u8{ posix.AF.INET, posix.AF.INET6 }, 1..) |family, seq| {
        const req = dumpRequest(family, @intCast(seq));
        _ = try posix.send(fd, &req, 0);
        while (true) {
            const n = try posix.recv(fd, &buf, 0);
            if (n == 0) return error.TruncatedMessage;
            const part = parseDump(a, buf[0..n], farm, out) catch |e| switch (e) {
                // a kernel without IPv6 has no IPv6 sockets to report
                error.DumpRefused => if (family == posix.AF.INET6) break else return e,
                else => return e,
            };
            if (part == .done) break;
        }
    }
}

// ---- the watchdog of one step ---------------------------------------------------

/// What one look at the connections found.
pub const Look = union(enum) {
    /// No connection to the farm has been silent past the bound.
    alive,
    /// This connection has.
    dead: Conn,
    /// The kernel could not be asked; the watchdog stops.
    unreadable: anyerror,
};

/// The watchdog of one step: the farm's addresses and the bound.
pub const Watchdog = struct {
    a: std.mem.Allocator,
    /// The farm's addresses, each with its port.
    farm: []const std.net.Address,
    /// How long a connection may hear nothing, in milliseconds.
    bound_ms: u64,
    conns: std.ArrayList(Conn) = .empty,

    /// The watchdog of a farm at `host`:`port`, or the reason there is none.
    pub fn init(a: std.mem.Allocator, host: []const u8, port: u16, dead_seconds: u32) !Watchdog {
        const list = try std.net.getAddressList(a, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.UnknownHostName;
        return .{ .a = a, .farm = try a.dupe(std.net.Address, list.addrs), .bound_ms = @as(u64, dead_seconds) * std.time.ms_per_s };
    }

    pub fn deinit(w: *Watchdog) void {
        w.conns.deinit(w.a);
        w.a.free(w.farm);
    }

    /// Reads the connections once and judges them, `run_ms` into the run.
    pub fn look(w: *Watchdog, run_ms: u64) Look {
        readConnections(w.a, w.farm, &w.conns) catch |e| return .{ .unreadable = e };
        if (dead(w.conns.items, w.bound_ms, run_ms)) |c| return .{ .dead = c };
        return .alive;
    }

    /// How long buck2 is given to end after SIGINT: the bound, at most `max_grace_ms`.
    pub fn grace_ms(w: *const Watchdog) u64 {
        return @min(w.bound_ms, max_grace_ms);
    }
};

/// `<N> min <M> s` of a time in milliseconds, rounded down to the second.
pub fn writeMs(w: *std.Io.Writer, ms: u64) std.Io.Writer.Error!void {
    const s = ms / std.time.ms_per_s;
    try w.print("{d} min {d} s", .{ s / 60, s % 60 });
}
