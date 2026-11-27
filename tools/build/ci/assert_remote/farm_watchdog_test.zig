//! The cases of farm_watchdog.zig, //tools/build/ci:farm_watchdog_unit: how
//! the watchdog tells a dead connection to the farm from a slow build.
//!
//! The judgement (`dead`) runs over times given in the case: a connection is
//! dead only when it has heard nothing for longer than the bound, never at the
//! bound, and the longest silent one is named. The kernel's answer
//! (`parseDump`) is read from netlink messages built in the case byte by byte,
//! as the kernel lays them out: only an established connection to the farm's
//! own address and port counts (an IPv4 farm reached from an IPv6 socket too),
//! its silence is the shorter of the two times the kernel reports, a socket
//! the kernel gives no times for is passed over, and an answer that is cut
//! short or refused is an error, never an empty list. The bound comes from the
//! farm config, 300 s when it sets none. The real read asks the kernel about a
//! loopback connection of the case's own and finds it, and only it.
const std = @import("std");
const fw = @import("farm_wait.zig");
const wd = @import("farm_watchdog.zig");
const t = std.testing;
const native_endian = @import("builtin").cpu.arch.endian();

// ---- the judgement ------------------------------------------------------------

test "no connection, or every one heard from within the bound, is alive" {
    try t.expectEqual(@as(?wd.Conn, null), wd.dead(&.{}, 300_000, std.math.maxInt(u64)));
    const live = [_]wd.Conn{ .{ .local_port = 1, .silent_ms = 0 }, .{ .local_port = 2, .silent_ms = 30_000 }, .{ .local_port = 3, .silent_ms = 299_999 } };
    try t.expectEqual(@as(?wd.Conn, null), wd.dead(&live, 300_000, std.math.maxInt(u64)));
}

test "a connection silent exactly the bound is still alive; one millisecond more is dead" {
    try t.expectEqual(@as(?wd.Conn, null), wd.dead(&.{.{ .local_port = 7, .silent_ms = 300_000 }}, 300_000, std.math.maxInt(u64)));
    try t.expectEqual(@as(?wd.Conn, .{ .local_port = 7, .silent_ms = 300_001 }), wd.dead(&.{.{ .local_port = 7, .silent_ms = 300_001 }}, 300_000, std.math.maxInt(u64)));
}

test "one dead connection among live ones makes the run dead, and the longest silent is named" {
    const conns = [_]wd.Conn{
        .{ .local_port = 1, .silent_ms = 1_000 },
        .{ .local_port = 2, .silent_ms = 400_000 },
        .{ .local_port = 3, .silent_ms = 13_200_000 }, // 3 h 40 min
        .{ .local_port = 4, .silent_ms = 20 },
    };
    try t.expectEqual(@as(?wd.Conn, .{ .local_port = 3, .silent_ms = 13_200_000 }), wd.dead(&conns, 300_000, std.math.maxInt(u64)));
}

test "a silence counts from the run's start: a connection idle from before the run is not dead early" {
    const idle = [_]wd.Conn{.{ .local_port = 9, .silent_ms = 600_000 }};
    // 1 s into the run: the ten minutes before it do not count
    try t.expectEqual(@as(?wd.Conn, null), wd.dead(&idle, 300_000, 1_000));
    try t.expectEqual(@as(?wd.Conn, null), wd.dead(&idle, 300_000, 300_000));
    // silent for more than the bound within the run: dead, named with the run's share of it
    try t.expectEqual(@as(?wd.Conn, .{ .local_port = 9, .silent_ms = 300_001 }), wd.dead(&idle, 300_000, 300_001));
}

test "buck2 is given the bound to end after SIGINT, at most 10 s" {
    const w2: wd.Watchdog = .{ .a = t.allocator, .farm = &.{}, .bound_ms = 2_000 };
    try t.expectEqual(@as(u64, 2_000), w2.grace_ms());
    const w300: wd.Watchdog = .{ .a = t.allocator, .farm = &.{}, .bound_ms = 300_000 };
    try t.expectEqual(@as(u64, 10_000), w300.grace_ms());
}

test "a silence is written in minutes and seconds, rounded down" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try wd.writeMs(&w, 300_999);
    try w.writeAll("|");
    try wd.writeMs(&w, 13_200_000);
    try w.writeAll("|");
    try wd.writeMs(&w, 999);
    try t.expectEqualStrings("5 min 0 s|220 min 0 s|0 min 0 s", w.buffered());
}

// ---- the kernel's answer ----------------------------------------------------------

const farm_v4 = [_]u8{ 192, 0, 2, 7 };
const farm_port: u16 = 8980;

fn addrV4(ip: [4]u8, port: u16) std.net.Address {
    return std.net.Address.initIp4(ip, port);
}

fn addrV6(ip: [16]u8, port: u16) std.net.Address {
    return std.net.Address.initIp6(ip, port, 0, 0);
}

/// The 16 bytes of an `inet_diag_sockid` address holding an IPv4 address.
fn raw4(ip: [4]u8) [16]u8 {
    var r = [_]u8{0} ** 16;
    @memcpy(r[0..4], &ip);
    return r;
}

/// The 16 bytes of `::ffff:a.b.c.d`.
fn mapped(ip: [4]u8) [16]u8 {
    var r = [_]u8{0} ** 16;
    r[10] = 0xff;
    r[11] = 0xff;
    @memcpy(r[12..16], &ip);
    return r;
}

/// A `struct tcp_info` the size of `buf`, with its two receive times set where it holds them.
fn tcpInfo(buf: []u8, data_ms: u32, ack_ms: u32) []u8 {
    @memset(buf, 0);
    if (buf.len >= 56) std.mem.writeInt(u32, buf[52..56], data_ms, native_endian);
    if (buf.len >= 60) std.mem.writeInt(u32, buf[56..60], ack_ms, native_endian);
    return buf;
}

const Sock = struct {
    family: u8 = std.posix.AF.INET,
    state: u8 = 1, // TCP_ESTABLISHED
    local_port: u16 = 41000,
    remote: [16]u8 = raw4(farm_v4),
    remote_port: u16 = farm_port,
    /// The attributes before the `INET_DIAG_INFO` one: (type, payload length).
    before: []const struct { kind: u16, len: u16 } = &.{},
    info: ?[]const u8 = null,
};

fn putAttr(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: u16, payload: []const u8) !void {
    var head: [4]u8 = undefined;
    std.mem.writeInt(u16, head[0..2], @intCast(4 + payload.len), native_endian);
    std.mem.writeInt(u16, head[2..4], kind, native_endian);
    try out.appendSlice(a, &head);
    try out.appendSlice(a, payload);
    while (out.items.len % 4 != 0) try out.append(a, 0);
}

/// One netlink message: `struct nlmsghdr` of `kind`, then `body`.
fn putMessage(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: u16, body: []const u8) !void {
    var head = [_]u8{0} ** 16;
    std.mem.writeInt(u32, head[0..4], @intCast(16 + body.len), native_endian);
    std.mem.writeInt(u16, head[4..6], kind, native_endian);
    try out.appendSlice(a, &head);
    try out.appendSlice(a, body);
    while (out.items.len % 4 != 0) try out.append(a, 0);
}

/// The `SOCK_DIAG_BY_FAMILY` message the kernel sends for `s`.
fn putSock(out: *std.ArrayList(u8), a: std.mem.Allocator, s: Sock) !void {
    var body = std.ArrayList(u8).empty;
    var msg = [_]u8{0} ** 72;
    msg[0] = s.family;
    msg[1] = s.state;
    std.mem.writeInt(u16, msg[4..6], s.local_port, .big);
    std.mem.writeInt(u16, msg[6..8], s.remote_port, .big);
    const runner = raw4(.{ 127, 0, 0, 1 }); // the runner's own address: never read
    @memcpy(msg[8..24], &runner);
    @memcpy(msg[24..40], &s.remote);
    try body.appendSlice(a, &msg);
    for (s.before) |b| {
        const payload = try a.alloc(u8, b.len);
        @memset(payload, 0xee);
        try putAttr(&body, a, b.kind, payload);
    }
    if (s.info) |info| try putAttr(&body, a, 2, info);
    try putMessage(out, a, 20, body.items);
}

fn putDone(out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try putMessage(out, a, 3, &([_]u8{0} ** 4));
}

/// The connections `bytes` reports for `farm`, and whether the dump ended.
fn parse(a: std.mem.Allocator, bytes: []const u8, farm: []const std.net.Address) !struct { conns: []wd.Conn, part: wd.Part } {
    var out = std.ArrayList(wd.Conn).empty;
    const part = try wd.parseDump(a, bytes, farm, &out);
    return .{ .conns = out.items, .part = part };
}

test "an established connection to the farm is read with the shorter of its two receive times" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: [232]u8 = undefined;
    var bytes = std.ArrayList(u8).empty;
    try putSock(&bytes, a, .{ .local_port = 41000, .info = tcpInfo(&info, 400_000, 350_000) });
    var info2: [232]u8 = undefined;
    try putSock(&bytes, a, .{ .local_port = 41001, .info = tcpInfo(&info2, 1_200, 9_000) });
    try putDone(&bytes, a);
    const r = try parse(a, bytes.items, &.{addrV4(farm_v4, farm_port)});
    try t.expectEqual(wd.Part.done, r.part);
    try t.expectEqualSlices(wd.Conn, &.{ .{ .local_port = 41000, .silent_ms = 350_000 }, .{ .local_port = 41001, .silent_ms = 1_200 } }, r.conns);
}

test "a socket to another port, another address, or not established is not the farm's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: [232]u8 = undefined;
    const silent = tcpInfo(&info, 900_000, 900_000);
    var bytes = std.ArrayList(u8).empty;
    try putSock(&bytes, a, .{ .remote_port = farm_port + 1, .info = silent });
    try putSock(&bytes, a, .{ .remote = raw4(.{ 192, 0, 2, 8 }), .info = silent });
    try putSock(&bytes, a, .{ .state = 8, .info = silent }); // CLOSE_WAIT: buck2 has the farm's end of it
    // an IPv6 socket to the farm's IPv4 address, not mapped: another host
    try putSock(&bytes, a, .{ .family = std.posix.AF.INET6, .remote = raw4(farm_v4), .info = silent });
    try putDone(&bytes, a);
    const r = try parse(a, bytes.items, &.{addrV4(farm_v4, farm_port)});
    try t.expectEqual(wd.Part.done, r.part);
    try t.expectEqual(@as(usize, 0), r.conns.len);
}

test "an IPv4 farm reached from an IPv6 socket, and an IPv6 farm, are the farm's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: [232]u8 = undefined;
    const silent = tcpInfo(&info, 5_000, 6_000);
    const farm_v6 = [_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7 };
    var bytes = std.ArrayList(u8).empty;
    try putSock(&bytes, a, .{ .family = std.posix.AF.INET6, .local_port = 1, .remote = mapped(farm_v4), .info = silent });
    try putSock(&bytes, a, .{ .family = std.posix.AF.INET6, .local_port = 2, .remote = farm_v6, .info = silent });
    // the IPv6 farm's address in an IPv4 socket's four bytes is another address
    try putSock(&bytes, a, .{ .family = std.posix.AF.INET, .local_port = 3, .remote = farm_v6, .info = silent });
    const r = try parse(a, bytes.items, &.{ addrV4(farm_v4, farm_port), addrV6(farm_v6, farm_port) });
    try t.expectEqual(wd.Part.more, r.part);
    try t.expectEqualSlices(wd.Conn, &.{ .{ .local_port = 1, .silent_ms = 5_000 }, .{ .local_port = 2, .silent_ms = 5_000 } }, r.conns);
}

test "the times are found past the other attributes, and a socket without them is passed over" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var info: [232]u8 = undefined;
    var short: [56]u8 = undefined;
    var bytes = std.ArrayList(u8).empty;
    // INET_DIAG_MEMINFO (1) of 16 bytes and an odd-length attribute before the info, padded to 4
    try putSock(&bytes, a, .{ .local_port = 1, .before = &.{ .{ .kind = 1, .len = 16 }, .{ .kind = 9, .len = 5 } }, .info = tcpInfo(&info, 700_000, 650_000) });
    // no INET_DIAG_INFO at all, and one too short to hold last_ack_recv: nothing to judge by
    try putSock(&bytes, a, .{ .local_port = 2 });
    try putSock(&bytes, a, .{ .local_port = 3, .info = tcpInfo(&short, 700_000, 0) });
    try putDone(&bytes, a);
    const r = try parse(a, bytes.items, &.{addrV4(farm_v4, farm_port)});
    try t.expectEqualSlices(wd.Conn, &.{.{ .local_port = 1, .silent_ms = 650_000 }}, r.conns);
}

test "an answer the kernel refused, or cut short, is an error, never an empty list" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const farm = [_]std.net.Address{addrV4(farm_v4, farm_port)};

    var refused = std.ArrayList(u8).empty;
    try putMessage(&refused, a, 2, &([_]u8{0} ** 20)); // NLMSG_ERROR
    try t.expectError(error.DumpRefused, parse(a, refused.items, &farm));

    var info: [232]u8 = undefined;
    var whole = std.ArrayList(u8).empty;
    try putSock(&whole, a, .{ .info = tcpInfo(&info, 1, 1) });
    // a message longer than the bytes that came
    try t.expectError(error.TruncatedMessage, parse(a, whole.items[0 .. whole.items.len - 8], &farm));
    // a header whose length is shorter than a header
    const bad_len = try a.dupe(u8, whole.items);
    std.mem.writeInt(u32, bad_len[0..4], 8, native_endian);
    try t.expectError(error.TruncatedMessage, parse(a, bad_len, &farm));
    // a socket message too short for `struct inet_diag_msg`
    var tiny = std.ArrayList(u8).empty;
    try putMessage(&tiny, a, 20, &[_]u8{ std.posix.AF.INET, 1, 0, 0 });
    try t.expectError(error.TruncatedMessage, parse(a, tiny.items, &farm));
    // an attribute that runs past its message
    const long_attr = try a.dupe(u8, whole.items);
    std.mem.writeInt(u16, long_attr[16 + 72 ..][0..2], 4000, native_endian);
    try t.expectError(error.TruncatedMessage, parse(a, long_attr, &farm));
}

test "messages of another type are passed over, and an answer without its end asks for more" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes = std.ArrayList(u8).empty;
    try putMessage(&bytes, a, 1, &([_]u8{0} ** 8)); // NLMSG_NOOP
    const r = try parse(a, bytes.items, &.{addrV4(farm_v4, farm_port)});
    try t.expectEqual(wd.Part.more, r.part);
    try t.expectEqual(@as(usize, 0), r.conns.len);
    try t.expectEqual(wd.Part.more, (try parse(a, &.{}, &.{addrV4(farm_v4, farm_port)})).part);
}

test "the dump asks for the established TCP sockets of one family, with their tcp_info" {
    const req = wd.dumpRequest(std.posix.AF.INET6, 9);
    try t.expectEqual(@as(usize, 72), req.len);
    try t.expectEqual(@as(u32, 72), std.mem.readInt(u32, req[0..4], native_endian));
    try t.expectEqual(@as(u16, 20), std.mem.readInt(u16, req[4..6], native_endian)); // SOCK_DIAG_BY_FAMILY
    try t.expectEqual(@as(u16, 0x301), std.mem.readInt(u16, req[6..8], native_endian)); // NLM_F_REQUEST | NLM_F_DUMP
    try t.expectEqual(@as(u32, 9), std.mem.readInt(u32, req[8..12], native_endian));
    try t.expectEqual(@as(u8, std.posix.AF.INET6), req[16]);
    try t.expectEqual(@as(u8, 6), req[17]); // IPPROTO_TCP
    try t.expectEqual(@as(u8, 2), req[18]); // 1 << (INET_DIAG_INFO - 1)
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, req[20..24], native_endian)); // 1 << TCP_ESTABLISHED
    for (req[24..]) |b| try t.expectEqual(@as(u8, 0), b);
}

// ---- the bound ------------------------------------------------------------------

const address_and_wait = "[buck2_re_client]\n  engine_address = grpc://re.example.com:8980\n[komira_ci]\n  farm_wait_seconds = 1200\n";

test "the bound is 300 s unless the farm config sets dead_connection_seconds" {
    try t.expectEqual(@as(u32, 300), (try fw.parseConfig(address_and_wait)).dead_seconds);
    try t.expectEqual(@as(u32, 2), (try fw.parseConfig(address_and_wait ++ "  dead_connection_seconds = 2\n")).dead_seconds);
    // in another section it is not the watchdog's
    try t.expectEqual(@as(u32, 300), (try fw.parseConfig(address_and_wait ++ "[komira_re]\n  dead_connection_seconds = 2\n")).dead_seconds);
}

test "a bound that is not a whole number of seconds from 1 is refused by name" {
    for ([_][]const u8{ "", "0", "5m", "-1", "1.5", "99999999999" }) |bad| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{s}  dead_connection_seconds = {s}\n", .{ address_and_wait, bad });
        try t.expectError(error.BadDeadSeconds, fw.parseConfig(text));
    }
    try t.expectEqualStrings("its dead_connection_seconds is not a whole number of seconds from 1", fw.describeConfigError(error.BadDeadSeconds));
}

// ---- the real read ----------------------------------------------------------------

test "the kernel reports a loopback connection to the farm's port, the runner's end of it only" {
    const listen_at = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_at.listen(.{});
    defer server.deinit();
    const port = server.listen_address.getPort();
    const client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();
    const accepted = try server.accept();
    defer accepted.stream.close();
    var mine = try std.net.Address.parseIp("127.0.0.1", 0);
    var len = mine.getOsSockLen();
    try std.posix.getsockname(client.handle, &mine.any, &len);

    var w = try wd.Watchdog.init(t.allocator, "127.0.0.1", port, 300);
    defer w.deinit();
    try t.expectEqual(@as(u64, 300_000), w.bound_ms);
    try t.expect(w.look(std.math.maxInt(u64)) == .alive);
    // the client's socket, and not the server's end, whose remote is the client
    try t.expectEqual(@as(usize, 1), w.conns.items.len);
    try t.expectEqual(mine.getPort(), w.conns.items[0].local_port);
}
