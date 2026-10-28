//! Unit tests of uv_fidelity.zig: everything the capture does except bind a
//! socket and run uv. Run by `zig test` as a build action
//! (`:uv_fidelity_unit`), and `:uv_fidelity` is built only when they pass.
//! The committed fixtures are embedded, so the tests also prove that they are
//! what this generator and this format produce.

const std = @import("std");
const fid = @import("uv_fidelity.zig");
const testing = std.testing;

const Committed = struct { whl: []const u8, metadata: []const u8, request: []const u8 };

/// The committed fixtures, in fid.CASES order.
const COMMITTED = [_]Committed{
    .{ .whl = @embedFile("minimal.whl"), .metadata = @embedFile("minimal.METADATA"), .request = @embedFile("minimal.request") },
    .{ .whl = @embedFile("rich.whl"), .metadata = @embedFile("rich.METADATA"), .request = @embedFile("rich.request") },
    .{ .whl = @embedFile("description_header.whl"), .metadata = @embedFile("description_header.METADATA"), .request = @embedFile("description_header.request") },
};

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

/// The value of the `KEY ` line of a committed `.request`'s head.
fn headValue(request: []const u8, key: []const u8) []const u8 {
    const head = request[0 .. std.mem.indexOf(u8, request, "\n\n").?];
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ' ') return line[key.len + 1 ..];
    }
    return "";
}

fn bodyOf(request: []const u8) []const u8 {
    return request[std.mem.indexOf(u8, request, "\n\n").? + 2 ..];
}

/// The HTTP request uv would have sent for a committed `.request`, with the
/// given Authorization (none when null), as the recorder receives it.
fn wire(a: std.mem.Allocator, request: []const u8, auth: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(a);
    try w.print("{s} {s} HTTP/1.1\r\n", .{ headValue(request, "METHOD"), headValue(request, "PATH") });
    try w.print("content-type: {s}\r\naccept: {s}\r\n", .{ headValue(request, "CONTENT-TYPE"), headValue(request, "ACCEPT") });
    if (auth) |v| try w.print("authorization: {s}\r\n", .{v});
    try w.print("content-length: {d}\r\nhost: 127.0.0.1:1\r\n\r\n", .{bodyOf(request).len});
    try w.writeAll(bodyOf(request));
    return out.toOwnedSlice(a);
}

// ---- The wheel --------------------------------------------------------------

test "each probe wheel is deterministic" {
    var ar = arena();
    defer ar.deinit();
    for (fid.CASES) |case| {
        try testing.expectEqualSlices(u8, try fid.makeWheel(ar.allocator(), case.metadata), try fid.makeWheel(ar.allocator(), case.metadata));
    }
}

test "the committed .whl of each case is the generator's, byte for byte" {
    var ar = arena();
    defer ar.deinit();
    for (fid.CASES, COMMITTED) |case, c| {
        try testing.expectEqualSlices(u8, c.whl, try fid.makeWheel(ar.allocator(), case.metadata));
    }
}

test "the committed .METADATA of each case is the generator's" {
    for (fid.CASES, COMMITTED) |case, c| try testing.expectEqualSlices(u8, c.metadata, case.metadata);
}

test "every member of a wheel is dated at the MS-DOS epoch (date 0x0021, time 0)" {
    var ar = arena();
    defer ar.deinit();
    const whl = try fid.makeWheel(ar.allocator(), fid.CASES[0].metadata);
    var seen: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, whl, i, "PK\x03\x04")) |at| {
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, whl[at + 10 ..][0..2], .little));
        try testing.expectEqual(@as(u16, 0x21), std.mem.readInt(u16, whl[at + 12 ..][0..2], .little));
        seen += 1;
        i = at + 4;
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

test "a different METADATA makes a different wheel" {
    var ar = arena();
    defer ar.deinit();
    const x = try fid.makeWheel(ar.allocator(), fid.CASES[0].metadata);
    const y = try fid.makeWheel(ar.allocator(), fid.CASES[2].metadata);
    try testing.expect(!std.mem.eql(u8, x, y));
}

// ---- The committed fixtures are consistent -----------------------------------

test "each committed request body carries the committed wheel" {
    for (COMMITTED) |c| try testing.expect(std.mem.indexOf(u8, bodyOf(c.request), c.whl) != null);
}

test "the normaliser finds each committed boundary at least three times" {
    var ar = arena();
    defer ar.deinit();
    for (COMMITTED) |c| {
        const n = try fid.normalized(ar.allocator(), c.request);
        try testing.expect(std.mem.count(u8, n, "<BOUNDARY>") >= 3);
        try testing.expect(std.mem.indexOf(u8, n, headValue(c.request, "BOUNDARY")) == null);
    }
}

test "the normaliser replaces every boundary occurrence and refuses a head without one" {
    var ar = arena();
    defer ar.deinit();
    const fake = "METHOD POST\nBOUNDARY abc\n\n--abc\r\nx\r\n--abc--\r\n";
    try testing.expectEqualStrings(
        "METHOD POST\nBOUNDARY <BOUNDARY>\n\n--<BOUNDARY>\r\nx\r\n--<BOUNDARY>--\r\n",
        try fid.normalized(ar.allocator(), fake),
    );
    try testing.expectError(error.NoBoundary, fid.normalized(ar.allocator(), "METHOD POST\n\nbody"));
}

// ---- Where the recorder listens -------------------------------------------------

fn addr(s: []const u8) !std.net.Address {
    return std.net.Address.parseIp(s, 0);
}

test "isLoopback: 127.0.0.1, 127.0.0.2 and ::1 are loopback" {
    try testing.expect(fid.isLoopback(try addr("127.0.0.1")));
    try testing.expect(fid.isLoopback(try addr("127.0.0.2")));
    try testing.expect(fid.isLoopback(try addr("::1")));
}

test "isLoopback: the wildcards 0.0.0.0 and ::, documentation-range addresses (IPv4 and IPv6), 128.0.0.1, ::2 and ::ffff:127.0.0.1 are not" {
    for ([_][]const u8{ "0.0.0.0", "::", "192.0.2.10", "203.0.113.1", "128.0.0.1", "::2", "2001:db8::1", "::ffff:127.0.0.1" }) |s| {
        try testing.expect(!fid.isLoopback(try addr(s)));
    }
}

test "the recorder's bind address RECORDER_HOST is loopback" {
    try testing.expect(fid.isLoopback(try addr(fid.RECORDER_HOST)));
}

// ---- The recorder's parser ---------------------------------------------------

test "a Content-Length request parses whole, and not before it is all there" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const raw = "POST /legacy/ HTTP/1.1\r\nContent-Type:  x/y \r\nContent-Length: 5\r\n\r\nhelloNEXT";
    const p = (try fid.parseRequest(a, raw)).?;
    try testing.expectEqualStrings("POST", p.request.method);
    try testing.expectEqualStrings("/legacy/", p.request.path);
    try testing.expectEqualStrings("x/y", p.request.header("content-type"));
    try testing.expectEqualStrings("hello", p.request.body);
    try testing.expect(!p.request.chunked);
    try testing.expectEqual(raw.len - "NEXT".len, p.consumed);
    try testing.expect((try fid.parseRequest(a, raw[0 .. raw.len - 5])) == null);
    try testing.expect((try fid.parseRequest(a, "POST / HTTP/1.1\r\nHost: x\r\n")) == null);
}

test "a chunked body is decoded and its trailers skipped" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const raw = "POST /legacy/ HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n3;ext=1\r\nabc\r\n2\r\nde\r\n0\r\nX-Trailer: 1\r\n\r\n";
    const p = (try fid.parseRequest(a, raw)).?;
    try testing.expect(p.request.chunked);
    try testing.expectEqualStrings("abcde", p.request.body);
    try testing.expectEqual(raw.len, p.consumed);
    try testing.expect((try fid.parseRequest(a, raw[0 .. raw.len - 2])) == null);
    try testing.expectError(error.BadChunk, fid.parseRequest(a, "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"));
}

test "malformed request lines and headers are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.BadRequestLine, fid.parseRequest(a, "POST /\r\n\r\n"));
    try testing.expectError(error.BadHeader, fid.parseRequest(a, "POST / HTTP/1.1\r\nno colon\r\n\r\n"));
    try testing.expectError(error.BadContentLength, fid.parseRequest(a, "POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n"));
}

// ---- The .request format and the Authorization assertion --------------------

test "the expected Authorization is Basic base64(__token__:<placeholder>)" {
    var ar = arena();
    defer ar.deinit();
    try testing.expectEqualStrings(
        "Basic X190b2tlbl9fOmZpZGVsaXR5LXByb2JlLXBsYWNlaG9sZGVyLW5vdC1hLWNyZWRlbnRpYWw=",
        try fid.expectedAuthorization(ar.allocator()),
    );
}

test "uv's request, recorded and rendered, is the committed .request byte for byte" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const auth = try fid.expectedAuthorization(a);
    for (COMMITTED) |c| {
        const p = (try fid.parseRequest(a, try wire(a, c.request, auth))).?;
        try testing.expectEqualSlices(u8, c.request, try fid.renderRequest(a, p.request));
    }
}

test "a capture with another Authorization, or none, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const c = COMMITTED[0];
    const other = (try fid.parseRequest(a, try wire(a, c.request, "Basic X190b2tlbl9fOnJlYWwtdG9rZW4="))).?;
    try testing.expectError(error.AuthorizationMismatch, fid.renderRequest(a, other.request));
    const none = (try fid.parseRequest(a, try wire(a, c.request, null))).?;
    try testing.expectError(error.AuthorizationMismatch, fid.renderRequest(a, none.request));
}

test "a chunked, non-multipart or mis-sized capture is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const auth = try fid.expectedAuthorization(a);
    const multipart = "Content-Type: multipart/form-data; boundary=b\r\n";
    const chunked = try std.fmt.allocPrint(a, "POST /legacy/ HTTP/1.1\r\n{s}Authorization: {s}\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n", .{ multipart, auth });
    try testing.expectError(error.Chunked, fid.renderRequest(a, (try fid.parseRequest(a, chunked)).?.request));
    const plain = try std.fmt.allocPrint(a, "POST /legacy/ HTTP/1.1\r\nContent-Type: text/plain\r\nAuthorization: {s}\r\nContent-Length: 1\r\n\r\nx", .{auth});
    try testing.expectError(error.NotMultipart, fid.renderRequest(a, (try fid.parseRequest(a, plain)).?.request));
    var req = (try fid.parseRequest(a, try std.fmt.allocPrint(a, "POST /legacy/ HTTP/1.1\r\n{s}Authorization: {s}\r\nContent-Length: 1\r\n\r\nx", .{ multipart, auth }))).?.request;
    req.body = "xy";
    try testing.expectError(error.ContentLengthMismatch, fid.renderRequest(a, req));
}

// ---- The comparison ------------------------------------------------------------

test "firstDifference: equal, a changed byte, a prefix" {
    try testing.expectEqual(@as(?usize, null), fid.firstDifference("abc", "abc"));
    try testing.expectEqual(@as(?usize, 1), fid.firstDifference("abc", "aXc"));
    try testing.expectEqual(@as(?usize, 2), fid.firstDifference("ab", "abc"));
}

test "compareFile: a request differing only in its boundary is the same; one flipped byte is reported at its offset" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var report = std.ArrayList(u8).empty;
    const c = COMMITTED[0].request;
    const old_b = headValue(c, "BOUNDARY");
    const other = try std.mem.replaceOwned(u8, a, c, old_b, "0123456789abcdef-0123456789abcdef-0123456789abcdef-0123456789abcdef");
    try testing.expect(try fid.compareFile(a, report.writer(a), "minimal.request", c, other));
    try testing.expectEqual(@as(usize, 0), report.items.len);

    const flipped = try a.dupe(u8, COMMITTED[0].whl);
    flipped[100] ^= 1;
    try testing.expect(!try fid.compareFile(a, report.writer(a), "minimal.whl", COMMITTED[0].whl, flipped));
    try testing.expect(std.mem.indexOf(u8, report.items, "minimal.whl: committed 1283 bytes, captured 1283 bytes; first difference at byte 100") != null);
}
