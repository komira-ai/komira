//! Test support: a registry on loopback. A thread accepts connections on
//! 127.0.0.1 and answers GETs from a table of routes, so `update` is tested
//! through the real HTTP client against a real socket, and nothing outside
//! the machine.

const std = @import("std");

pub const Route = struct {
    path: []const u8,
    body: []const u8 = "",
    status: u16 = 200,
    /// A `Location` header (for a 3xx).
    location: ?[]const u8 = null,
    /// Promise this many bytes and send only `body`, then close.
    claim_length: ?usize = null,
    hits: usize = 0,
};

pub const Registry = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    routes: []Route,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16,

    /// Starts serving `routes` (kept by pointer: tests change a body between
    /// requests to play a registry that republished).
    pub fn start(a: std.mem.Allocator, routes: []Route) !*Registry {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        const self = try a.create(Registry);
        self.* = .{
            .server = try addr.listen(.{ .reuse_address = true }),
            .routes = routes,
            .port = 0,
        };
        self.port = self.server.listen_address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn stop(self: *Registry) void {
        self.stopping.store(true, .release);
        // Wake the accept().
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    pub fn url(self: *Registry, a: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    pub fn hitsOf(self: *Registry, path: []const u8) usize {
        for (self.routes) |r| if (std.mem.eql(u8, r.path, path)) return r.hits;
        return 0;
    }

    fn serve(self: *Registry) void {
        while (!self.stopping.load(.acquire)) {
            const conn = self.server.accept() catch continue;
            defer conn.stream.close();
            if (self.stopping.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [1024]u8 = undefined;
            var reader = conn.stream.reader(&rbuf);
            var writer = conn.stream.writer(&wbuf);
            const w = &writer.interface;
            var srv = std.http.Server.init(reader.interface(), w);
            const req = srv.receiveHead() catch continue;
            const target = req.head.target;
            var found: ?*Route = null;
            for (self.routes) |*r| if (std.mem.eql(u8, r.path, target)) {
                found = r;
            };
            var head_buf: [512]u8 = undefined;
            if (found) |r| {
                r.hits += 1;
                const len = r.claim_length orelse r.body.len;
                const loc = if (r.location) |l| std.fmt.bufPrint(head_buf[256..], "Location: {s}\r\n", .{l}) catch "" else "";
                const head = std.fmt.bufPrint(head_buf[0..256], "HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ r.status, len }) catch continue;
                w.writeAll(head) catch continue;
                w.writeAll(loc) catch continue;
                w.writeAll("\r\n") catch continue;
                w.writeAll(r.body) catch continue;
            } else {
                w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch continue;
            }
            // The writer buffers; the client reads nothing until it is flushed.
            w.flush() catch continue;
        }
    }
};
