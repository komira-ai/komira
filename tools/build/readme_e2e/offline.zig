//! The registry the README e2e points mopm at, so that the install is offline by
//! enforcement and not by assumption.
//!
//! `mopm add <package>@=<version> --overlay <staged set>` needs no request when the set
//! holds the whole closure and the registry is the production one, whose channel mopm knows.
//! Left to that default, a closure member the set lacks would be fetched from the network,
//! silently, on a machine that has one. So `verify` runs mopm with `--registry <this one>`:
//! a loopback server of its own that
//!
//!   * answers `GET /index/config.json`, the one thing mopm asks of a registry that is not the
//!     production one (it names the channel the lock records), with a configuration whose
//!     URLs are this server's, and
//!   * refuses every other request with HTTP 403 and the contract's error body, and
//!     remembers it.
//!
//! A package outside the staged set makes mopm ask for its index, which fails mopm with the
//! refusal; and `verify` fails on any remembered refusal even when mopm exited 0, so a mopm
//! that swallowed the refusal cannot pass the e2e on a closure it did not install from the set.
//!
//! `get` is the client the stand-in mopm (fake.zig) and the unit tests use.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The log is kept with the page allocator: the server thread runs while `verify` (which
/// allocates from an arena) waits for mopm.
const log_alloc = std.heap.page_allocator;

pub const Registry = struct {
    server: std.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    /// `METHOD target` of each request refused, in the order received.
    refused_list: std.ArrayList([]const u8) = .empty,
    port: u16,

    /// Starts serving on an unused port of 127.0.0.1. `stop` ends it.
    pub fn start() !*Registry {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        const server = try addr.listen(.{ .reuse_address = true });
        const self = try log_alloc.create(Registry);
        self.* = .{ .server = server, .port = server.listen_address.getPort() };
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch |e| {
            self.server.deinit();
            log_alloc.destroy(self);
            return e;
        };
        return self;
    }

    /// The URL to give `--registry`: no trailing slash.
    pub fn url(self: *const Registry, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.port});
    }

    /// Stops serving and waits for the server's thread. Call it once; `refused` is read after it.
    pub fn stop(self: *Registry) void {
        self.stopping.store(true, .release);
        // accept() is blocked: a connection of our own wakes it.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        if (self.thread) |t| t.join();
        self.thread = null;
        self.server.deinit();
    }

    /// The requests refused so far, as `METHOD target`; the slice is the caller's, the texts
    /// are the registry's (page allocator, never freed: the process is short).
    pub fn refused(self: *Registry, a: Allocator) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return a.dupe([]const u8, self.refused_list.items);
    }

    fn remember(self: *Registry, method: []const u8, target: []const u8) void {
        const line = std.fmt.allocPrint(log_alloc, "{s} {s}", .{ method, target }) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refused_list.append(log_alloc, line) catch {};
    }
};

const config_target = "/index/config.json";

fn serve(self: *Registry) void {
    while (true) {
        const conn = self.server.accept() catch return;
        defer conn.stream.close();
        if (self.stopping.load(.acquire)) return;
        answer(self, conn.stream);
    }
}

fn answer(self: *Registry, stream: std.net.Stream) void {
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const got = stream.read(buf[n..]) catch return;
        if (got == 0) break;
        n += got;
        if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") != null) break;
    }
    const head_end = std.mem.indexOf(u8, buf[0..n], "\r\n") orelse return;
    var words = std.mem.tokenizeScalar(u8, buf[0..head_end], ' ');
    const method = words.next() orelse return;
    const target = words.next() orelse return;
    var out: [2048]u8 = undefined;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, config_target)) {
        const body = std.fmt.bufPrint(&out, "{{\"index_version\":1,\"stage\":\"readme_e2e\",\"api_url\":\"http://127.0.0.1:{d}/api/v1\",\"channel_url\":\"http://127.0.0.1:{d}/channel/\",\"min_cli_version\":\"0.0.1\",\"read_only\":true}}", .{ self.port, self.port }) catch return;
        reply(stream, "200 OK", body);
        return;
    }
    self.remember(method, target);
    reply(stream, "403 Forbidden", "{\"error\":{\"code\":\"offline\",\"message\":\"the README e2e is offline: this registry serves its configuration and nothing else, so a package the staged set lacks cannot be fetched\",\"hint\":\"stage the package\"}}");
}

fn reply(stream: std.net.Stream, status: []const u8, body: []const u8) void {
    var head: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len }) catch return;
    stream.writeAll(text) catch return;
    stream.writeAll(body) catch return;
}

pub const Answer = struct { status: u16, body: []const u8 };

/// `GET <base><target>` over plain HTTP to a loopback registry (`base` as `Registry.url` gives it).
pub fn get(a: Allocator, base: []const u8, target: []const u8) !Answer {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, base, prefix)) return error.NotLoopback;
    const port = try std.fmt.parseInt(u16, base[prefix.len..], 10);
    const stream = try std.net.tcpConnectToAddress(try std.net.Address.parseIp4("127.0.0.1", port));
    defer stream.close();
    const request = try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ target, port });
    try stream.writeAll(request);
    var all: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const got = try stream.read(&buf);
        if (got == 0) break;
        try all.appendSlice(a, buf[0..got]);
    }
    const text = all.items;
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadAnswer;
    if (text.len < space + 4) return error.BadAnswer;
    const status = try std.fmt.parseInt(u16, text[space + 1 .. space + 4], 10);
    const body_at = std.mem.indexOf(u8, text, "\r\n\r\n") orelse return error.BadAnswer;
    return .{ .status = status, .body = text[body_at + 4 ..] };
}

/// `/index/<aa>/<bb>/<name>`: where mopm asks a registry for a package's records (the first
/// four letters of the name, `_`-padded, as two directories).
pub fn indexTarget(a: Allocator, name: []const u8) ![]u8 {
    var pad: [4]u8 = .{ '_', '_', '_', '_' };
    const n = @min(name.len, 4);
    @memcpy(pad[0..n], name[0..n]);
    return std.fmt.allocPrint(a, "/index/{s}/{s}/{s}", .{ pad[0..2], pad[2..4], name });
}
