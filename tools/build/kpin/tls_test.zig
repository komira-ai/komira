//! The https client against a real TLS server on loopback: aws-lc's
//! `bssl s_server` (the zig_test's `exec_tools`, BSSL), pinned to one protocol
//! version, with the throwaway certificates of komira_http_core's tests (the
//! zig_test's `data`, under KOMIRA_TEST_WORK). `s_server -www` answers a GET
//! with the facts of the connection, `Version: TLSv1.2` among them, so what
//! the server negotiated is read from what kpin downloaded.
//!
//! What the cases catch:
//!  - a client that cannot complete TLS 1.2 (registry.npmjs.org negotiates
//!    1.2 with a 1.3-capable client in some paths; 0.12's std fails both
//!    registries kpin reads) fails the 1.2 case;
//!  - a client that only speaks 1.2 fails the 1.3 case;
//!  - certificate verification switched off: the untrusted-root case would then
//!    succeed;
//!  - the trust anchor handed in being ignored: the trusted cases would fail.
//! Loopback only; nothing leaves the machine.

const std = @import("std");
const fetch = @import("fetch.zig");

const a = std.testing.allocator;

fn env(name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| {
        std.debug.print("{s} is not in the environment (the zig_test's exec_tools / data)\n", .{name});
        return e;
    };
}

fn work(sub: []const u8) ![]u8 {
    const w = try env("KOMIRA_TEST_WORK");
    defer a.free(w);
    return std.fs.path.join(a, &.{ w, sub });
}

fn freePort() !u16 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var s = try addr.listen(.{ .reuse_address = true });
    defer s.deinit();
    return s.listen_address.getPort();
}

/// `bssl s_server -www` restricted to `version` (`tls1.2`, `tls1.3`), serving
/// every connection until it is killed.
const Server = struct {
    child: std.process.Child,
    port: u16,

    fn start(version: []const u8) !Server {
        const bssl = try env("BSSL");
        defer a.free(bssl);
        const cert = try work("fixtures/leaf_cert.pem");
        defer a.free(cert);
        const key = try work("fixtures/leaf_key.pem");
        defer a.free(key);
        const port = try freePort();
        const port_s = try std.fmt.allocPrint(a, "{d}", .{port});
        defer a.free(port_s);
        var child = std.process.Child.init(&.{
            bssl,     "s_server",  "-accept",      port_s, "-cert", cert, "-key", key,
            "-min-version", version, "-max-version", version, "-www",  "-loop",
        }, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        return .{ .child = child, .port = port };
    }

    fn stop(self: *Server) void {
        _ = self.child.kill() catch {};
    }

    fn url(self: *const Server) ![]u8 {
        return std.fmt.allocPrint(a, "https://localhost:{d}/", .{self.port});
    }
};

/// One GET of `/`, retried while the server is still starting.
fn getWhenUp(f: *fetch.HttpFetcher, url: []const u8) ![]u8 {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var c = fetch.Collect{ .a = a, .max = 1 << 20 };
        if (f.fetcher().get(url, c.sink())) |_| {
            return c.buf.toOwnedSlice(a);
        } else |e| {
            c.buf.deinit(a);
            if (e != error.ConnectionRefused or tries >= 100) return e;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

fn trusting(ca: []const u8) fetch.HttpFetcher {
    return .{ .allocator = a, .ca_file = ca };
}

test "a TLS 1.2-only server is reached: the negotiated version is 1.2" {
    var srv = try Server.start("tls1.2");
    defer srv.stop();
    const ca = try work("fixtures/root_ca.pem");
    defer a.free(ca);
    const url = try srv.url();
    defer a.free(url);
    var f = trusting(ca);
    const body = try getWhenUp(&f, url);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Version: TLSv1.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "TLSv1.3") == null);
}

test "a TLS 1.3-only server is reached: the negotiated version is 1.3" {
    var srv = try Server.start("tls1.3");
    defer srv.stop();
    const ca = try work("fixtures/root_ca.pem");
    defer a.free(ca);
    const url = try srv.url();
    defer a.free(url);
    var f = trusting(ca);
    const body = try getWhenUp(&f, url);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Version: TLSv1.3") != null);
}

test "a certificate that does not chain to the trusted roots is refused, on TLS 1.2 and 1.3" {
    for ([_][]const u8{ "tls1.2", "tls1.3" }) |version| {
        var srv = try Server.start(version);
        defer srv.stop();
        const good = try work("fixtures/root_ca.pem");
        defer a.free(good);
        const url = try srv.url();
        defer a.free(url);
        // The server is up once a client that trusts its root gets through.
        var ok = trusting(good);
        a.free(try getWhenUp(&ok, url));
        // The same server, a client whose only root is another certificate.
        const other = try work("fixtures/smoke_cert.pem");
        defer a.free(other);
        var bad = trusting(other);
        var c = fetch.Collect{ .a = a, .max = 1 << 20 };
        defer c.buf.deinit(a);
        try std.testing.expectError(error.TlsInitializationFailed, bad.fetcher().get(url, c.sink()));
        try std.testing.expectEqual(@as(usize, 0), c.buf.items.len);
    }
}
