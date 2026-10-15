//! The network, behind one interface. `update` is the only caller; it takes a
//! `Fetcher`, so its tests use a registry on loopback and nothing else in
//! kpin can reach a socket.

const std = @import("std");

/// Where a fetch's bytes go.
pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn write(s: Sink, bytes: []const u8) anyerror!void {
        return s.writeFn(s.ctx, bytes);
    }
};

pub const Fetcher = struct {
    ctx: *anyopaque,
    /// GET `url`; the body, in order, to `sink`. An error for any status but
    /// 200 (redirects are followed by the implementation, under its policy).
    getFn: *const fn (ctx: *anyopaque, url: []const u8, sink: Sink) anyerror!void,

    pub fn get(f: Fetcher, url: []const u8, sink: Sink) anyerror!void {
        return f.getFn(f.ctx, url, sink);
    }
};

/// A sink that keeps the body (metadata documents), up to `max` bytes.
pub const Collect = struct {
    a: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .{},
    max: usize,

    pub fn sink(self: *Collect) Sink {
        return .{ .ctx = self, .writeFn = write };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Collect = @ptrCast(@alignCast(ctx));
        if (self.buf.items.len + bytes.len > self.max) return error.ResponseTooLarge;
        try self.buf.appendSlice(self.a, bytes);
    }
};

/// A sink that keeps no bytes, only their sha256, sha512 and count; refuses
/// more than `max`.
pub const Digest = struct {
    sha256: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    sha512: std.crypto.hash.sha2.Sha512 = std.crypto.hash.sha2.Sha512.init(.{}),
    size: u64 = 0,
    max: u64,

    pub const Result = struct {
        sha256: []const u8,
        sri512: []const u8,
        size: u64,
    };

    pub fn sink(self: *Digest) Sink {
        return .{ .ctx = self, .writeFn = write };
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Digest = @ptrCast(@alignCast(ctx));
        if (self.size + bytes.len > self.max) return error.ResponseTooLarge;
        self.sha256.update(bytes);
        self.sha512.update(bytes);
        self.size += bytes.len;
    }

    /// The sha256 as lower-case hex and the sha512 as npm writes it
    /// (`sha512-` and base64). Call once.
    pub fn finish(self: *Digest, a: std.mem.Allocator) !Result {
        var d256: [32]u8 = undefined;
        self.sha256.final(&d256);
        var d512: [64]u8 = undefined;
        self.sha512.final(&d512);
        const hex = std.fmt.bytesToHex(d256, .lower);
        var sri: [7 + 88]u8 = undefined;
        @memcpy(sri[0..7], "sha512-");
        _ = std.base64.standard.Encoder.encode(sri[7..], &d512);
        return .{ .sha256 = try a.dupe(u8, &hex), .sri512 = try a.dupe(u8, &sri), .size = self.size };
    }
};

/// https always; http only to the machine itself, and only when asked (the
/// tests' registry). A `user@` in the authority is how a URL names one host
/// and connects to another, so it is refused outright.
pub fn urlAllowed(url: []const u8, allow_http_loopback: bool) bool {
    const https = "https://";
    const http = "http://";
    var rest: []const u8 = undefined;
    var plain = false;
    if (std.mem.startsWith(u8, url, https)) {
        rest = url[https.len..];
    } else if (std.mem.startsWith(u8, url, http)) {
        rest = url[http.len..];
        plain = true;
    } else return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (!plain) return true;
    if (!allow_http_loopback) return false;
    const host_end = std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..host_end];
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
}

pub const HttpFetcher = struct {
    allocator: std.mem.Allocator,
    allow_http_loopback: bool = false,
    max_redirects: u8 = 5,

    pub fn fetcher(self: *HttpFetcher) Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, url: []const u8, sink: Sink) anyerror!void {
        const self: *HttpFetcher = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var cur: []const u8 = url;
        var hops: u8 = 0;
        while (true) {
            // Checked on every hop: a redirect is a new URL a registry chose.
            if (!urlAllowed(cur, self.allow_http_loopback)) return error.UrlNotAllowed;
            const uri = try std.Uri.parse(cur);
            var hdr: [16 * 1024]u8 = undefined;
            var req = try client.open(.GET, uri, .{
                .server_header_buffer = &hdr,
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                .headers = .{
                    .accept_encoding = .{ .override = "identity" },
                    .user_agent = .{ .override = "kpin" },
                },
            });
            defer req.deinit();
            try req.send();
            try req.finish();
            try req.wait();
            const status = req.response.status;
            if (status.class() == .redirect) {
                const loc = req.response.location orelse return error.RedirectWithoutLocation;
                hops += 1;
                if (hops > self.max_redirects) return error.TooManyRedirects;
                cur = try arena.allocator().dupe(u8, loc);
                continue;
            }
            if (status != .ok) return error.HttpStatusNotOk;
            var buf: [64 * 1024]u8 = undefined;
            var total: u64 = 0;
            while (true) {
                const n = try req.read(&buf);
                if (n == 0) break;
                total += n;
                try sink.write(buf[0..n]);
            }
            // A body that ended early must not be pinned as if it were whole.
            if (req.response.content_length) |cl| {
                if (total != cl) return error.TruncatedBody;
            }
            return;
        }
    }
};
