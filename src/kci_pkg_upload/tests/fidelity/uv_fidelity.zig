//! The pure half of `uv_fidelity` (main.zig is the half that binds a socket
//! and runs uv): the probe wheels, the parser of what arrives at the
//! recorder, the `.request` fixture format and the comparison of a fresh
//! capture with the committed fixtures. Nothing here touches the network, a
//! file or a process, so all of it is unit-tested (uv_fidelity_test.zig).
//!
//! THE FIXTURES (per case, beside this file):
//!   <case>.whl       the probe wheel uv uploaded (deterministic: every member
//!                    dated at the MS-DOS epoch, members sorted by name,
//!                    stored, not deflated, mode 0644)
//!   <case>.METADATA  that wheel's `.dist-info/METADATA`, the text the Mojo
//!                    client takes as `upload_meta` (it has no archive reader)
//!   <case>.request   what uv sent: `KEY value` lines (METHOD, PATH,
//!                    CONTENT-TYPE, ACCEPT, BOUNDARY, FILENAME, BODY-LENGTH),
//!                    a blank line, then the RAW request body
//!
//! The Authorization header is not stored: `renderRequest` refuses a capture
//! whose Authorization is not exactly
//! `Basic base64("__token__:" ++ PLACEHOLDER_PASSWORD)`, and the Mojo test
//! asserts its own header is the same function of the same placeholder.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The credential uv is given. It is not a token of any index.
pub const PLACEHOLDER_PASSWORD = "fidelity-probe-placeholder-not-a-credential";
pub const USERNAME = "__token__";
pub const DIST = "komira_fidelity_probe";
pub const VERSION = "1.1.7";
pub const WHEEL_NAME = DIST ++ "-" ++ VERSION ++ "-py3-none-linux_x86_64.whl";
const INFO = DIST ++ "-" ++ VERSION ++ ".dist-info";

pub const Case = struct { name: []const u8, metadata: []const u8 };

/// The three cases. `minimal` is the shape the repository's wheel rule
/// writes (name, version, summary, Requires-Dist pins). `rich` carries every
/// single-valued and multi-valued field the upload form maps, a body
/// description, raw UTF-8, and the value shapes uv transforms (Project-URL
/// whitespace) or keeps (trailing whitespace, Keywords spacing).
/// `description_header` has no body: its description is the `Description`
/// HEADER.
pub const CASES = [_]Case{
    .{
        .name = "minimal",
        .metadata = "Metadata-Version: 2.1\n" ++
            "Name: " ++ DIST ++ "\n" ++
            "Version: " ++ VERSION ++ "\n" ++
            "Summary: Komira Mojo package `" ++ DIST ++ "`.\n" ++
            "Requires-Dist: mojo ==1.0.0\n" ++
            "Requires-Dist: komira_protobuf ==" ++ VERSION ++ "\n" ++
            "\n",
    },
    .{
        .name = "rich",
        .metadata = "Metadata-Version: 2.1\n" ++
            "Name: " ++ DIST ++ "\n" ++
            "Version: " ++ VERSION ++ "\n" ++
            "Summary: Komira probe \u{2014} caf\u{e9}\n" ++
            "Home-page: https://example.invalid/komira\n" ++
            "Download-URL: https://example.invalid/dl\n" ++
            "Author: Komira Maintainers\n" ++
            "Author-email: Komira <maintainers@example.invalid>\n" ++
            "Maintainer: Komira Maintainers\n" ++
            "Maintainer-email: maintainers@example.invalid\n" ++
            "License: Apache-2.0  \n" ++
            "Keywords: mojo, komira ,probe\n" ++
            "Platform: linux\n" ++
            "Classifier: Programming Language :: Python :: 3\n" ++
            "Classifier: License :: OSI Approved :: Apache Software License\n" ++
            "Dynamic: License\n" ++
            "License-File: LICENSE\n" ++
            "Project-URL: Source,https://example.invalid/src\n" ++
            "Project-URL: Docs ,  https://example.invalid/docs\n" ++
            "Requires-Python: >=3.10\n" ++
            "Description-Content-Type: text/markdown\n" ++
            "Provides-Extra: docs\n" ++
            "Requires-Dist: mojo ==1.0.0\n" ++
            "Requires-Dist: komira_protobuf ==" ++ VERSION ++ "\n" ++
            "Requires-Dist: sphinx ; extra == 'docs'\n" ++
            "Requires-External: libc\n" ++
            "Obsoletes-Dist: komira_old_probe\n" ++
            "Provides-Dist: komira_fidelity_alias\n" ++
            "\n" ++
            "# " ++ DIST ++ "\n\nA probe wheel. It is never uploaded anywhere but a loopback recorder.\n",
    },
    .{
        .name = "description_header",
        .metadata = "Metadata-Version: 2.1\n" ++
            "Name: " ++ DIST ++ "\n" ++
            "Version: " ++ VERSION ++ "\n" ++
            "Summary: a probe whose description is a header\n" ++
            "Description: One line of description, carried as a header.\n" ++
            "\n",
    },
};

/// The fixture files of one case, in the order a capture writes them.
pub const EXTENSIONS = [_][]const u8{ ".whl", ".METADATA", ".request" };

// ---- The probe wheel --------------------------------------------------------

const WHEEL_FILE = "Wheel-Version: 1.0\nGenerator: komira-fidelity-probe\n" ++
    "Root-Is-Purelib: false\nTag: py3-none-linux_x86_64\n\n";

/// Every member's MS-DOS time and date: midnight on the first day the
/// format can state (date = years since its epoch << 9 | month << 5 | day).
/// Fixed, so a wheel's bytes are a function of its METADATA alone.
pub const DOS_TIME: u16 = 0;
pub const DOS_DATE: u16 = (0 << 9) | (1 << 5) | 1;
/// Unix mode 0644 in the high half of the external attributes.
const EXTERNAL_ATTR: u32 = 0o644 << 16;
/// "Version made by": Unix (3) and zip 2.0; "version needed": 2.0.
const MADE_BY: u16 = (3 << 8) | 20;
const NEEDED: u16 = 20;

const Member = struct { name: []const u8, data: []const u8 };

fn memberLess(_: void, l: Member, r: Member) bool {
    return std.mem.lessThan(u8, l.name, r.name);
}

/// A minimal, DETERMINISTIC wheel carrying `metadata` as its METADATA: an
/// empty `__init__.py`, METADATA, WHEEL and RECORD (sha256 of each, base64url
/// without padding, and the size; RECORD's own line is `RECORD,,`), stored
/// in name order.
pub fn makeWheel(a: Allocator, metadata: []const u8) ![]u8 {
    const listed = [_]Member{
        .{ .name = DIST ++ "/__init__.py", .data = "" },
        .{ .name = INFO ++ "/METADATA", .data = metadata },
        .{ .name = INFO ++ "/WHEEL", .data = WHEEL_FILE },
    };
    var record = std.ArrayList(u8).init(a);
    defer record.deinit();
    for (listed) |m| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(m.data, &digest, .{});
        var b64: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&b64, &digest);
        try record.writer().print("{s},sha256={s},{d}\n", .{ m.name, &b64, m.data.len });
    }
    try record.appendSlice(INFO ++ "/RECORD,,\n");

    var members = [_]Member{
        listed[0],
        listed[1],
        listed[2],
        .{ .name = INFO ++ "/RECORD", .data = record.items },
    };
    std.mem.sort(Member, &members, {}, memberLess);

    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();
    var offsets: [members.len]u32 = undefined;
    var crcs: [members.len]u32 = undefined;
    for (members, 0..) |m, i| {
        offsets[i] = @intCast(out.items.len);
        crcs[i] = std.hash.Crc32.hash(m.data);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, NEEDED, .little);
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, DOS_TIME, .little);
        try w.writeInt(u16, DOS_DATE, .little);
        try w.writeInt(u32, crcs[i], .little);
        try w.writeInt(u32, @intCast(m.data.len), .little);
        try w.writeInt(u32, @intCast(m.data.len), .little);
        try w.writeInt(u16, @intCast(m.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeAll(m.name);
        try w.writeAll(m.data);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (members, 0..) |m, i| {
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, MADE_BY, .little);
        try w.writeInt(u16, NEEDED, .little);
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, DOS_TIME, .little);
        try w.writeInt(u16, DOS_DATE, .little);
        try w.writeInt(u32, crcs[i], .little);
        try w.writeInt(u32, @intCast(m.data.len), .little);
        try w.writeInt(u32, @intCast(m.data.len), .little);
        try w.writeInt(u16, @intCast(m.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, EXTERNAL_ATTR, .little);
        try w.writeInt(u32, offsets[i], .little);
        try w.writeAll(m.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.items.len)) - cd_start;
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, members.len, .little);
    try w.writeInt(u16, members.len, .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little); // comment
    return out.toOwnedSlice();
}

// ---- Where the recorder listens ---------------------------------------------

/// The address the recorder binds (port 0: the kernel picks one) and the
/// host of the publish URL uv is given. It must be loopback: the capture
/// refuses to measure when the address it is actually bound to is not
/// (`isLoopback`), and a unit test holds this constant to it.
pub const RECORDER_HOST = "127.0.0.1";

/// Whether `addr` is reachable from this host only: IPv4 127.0.0.0/8 or the
/// IPv6 loopback `::1`. A wildcard (`0.0.0.0`, `::`), any other address and
/// any other family (an IPv4-mapped IPv6 address included) are not.
pub fn isLoopback(addr: std.net.Address) bool {
    return switch (addr.any.family) {
        std.posix.AF.INET => @as(*const [4]u8, @ptrCast(&addr.in.sa.addr))[0] == 127,
        std.posix.AF.INET6 => std.mem.eql(u8, &addr.in6.sa.addr, &([_]u8{0} ** 15 ++ [_]u8{1})),
        else => false,
    };
}

// ---- What arrives at the recorder ------------------------------------------

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    /// The body came with `Transfer-Encoding: chunked` (decoded into `body`).
    chunked: bool,
    body: []const u8,

    /// The first header of that name, compared without case; "" if none.
    pub fn header(self: Request, name: []const u8) []const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return "";
    }
};

pub const Parsed = struct { request: Request, consumed: usize };

pub const ParseError = error{ BadRequestLine, BadHeader, BadContentLength, BadChunk };

/// One HTTP/1.1 request at the start of `buf`, copied into `a`, and how many
/// bytes of `buf` it took; null while `buf` does not yet hold all of it. A
/// header's value is trimmed of spaces and tabs. A chunked body is decoded
/// (its trailer fields are skipped); otherwise the body is Content-Length
/// bytes (none without the header).
pub fn parseRequest(a: Allocator, buf: []const u8) (ParseError || Allocator.Error)!?Parsed {
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, buf[0..head_end], "\r\n");
    const first = lines.next() orelse return error.BadRequestLine;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse return error.BadRequestLine;
    const path = parts.next() orelse return error.BadRequestLine;
    const version = parts.next() orelse return error.BadRequestLine;
    if (method.len == 0 or path.len == 0 or !std.mem.startsWith(u8, version, "HTTP/") or parts.next() != null)
        return error.BadRequestLine;

    var headers = std.ArrayList(Header).init(a);
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
        if (colon == 0) return error.BadHeader;
        try headers.append(.{
            .name = try a.dupe(u8, line[0..colon]),
            .value = try a.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t")),
        });
    }
    var req = Request{
        .method = try a.dupe(u8, method),
        .path = try a.dupe(u8, path),
        .headers = headers.items,
        .chunked = false,
        .body = "",
    };
    req.chunked = std.ascii.indexOfIgnoreCase(req.header("Transfer-Encoding"), "chunked") != null;

    var pos = head_end + 4;
    if (req.chunked) {
        var body = std.ArrayList(u8).init(a);
        while (true) {
            const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return null;
            const size_field = buf[pos..line_end];
            const size_text = std.mem.trim(u8, size_field[0 .. std.mem.indexOfScalar(u8, size_field, ';') orelse size_field.len], " \t");
            const size = std.fmt.parseInt(usize, size_text, 16) catch return error.BadChunk;
            pos = line_end + 2;
            if (size == 0) {
                while (true) {
                    const end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return null;
                    const blank = end == pos;
                    pos = end + 2;
                    if (blank) break;
                }
                break;
            }
            if (buf.len < pos + size + 2) return null;
            try body.appendSlice(buf[pos .. pos + size]);
            if (!std.mem.eql(u8, buf[pos + size .. pos + size + 2], "\r\n")) return error.BadChunk;
            pos += size + 2;
        }
        req.body = body.items;
    } else {
        const cl = req.header("Content-Length");
        const n = if (cl.len == 0) 0 else std.fmt.parseInt(usize, cl, 10) catch return error.BadContentLength;
        if (buf.len < pos + n) return null;
        req.body = try a.dupe(u8, buf[pos .. pos + n]);
        pos += n;
    }
    return .{ .request = req, .consumed = pos };
}

// ---- The `.request` fixture -------------------------------------------------

const MULTIPART = "multipart/form-data; boundary=";

/// `Basic base64("__token__:" ++ PLACEHOLDER_PASSWORD)`, the one
/// Authorization a capture may carry.
pub fn expectedAuthorization(a: Allocator) ![]u8 {
    const plain = USERNAME ++ ":" ++ PLACEHOLDER_PASSWORD;
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, "Basic ".len + enc.calcSize(plain.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], plain);
    return out;
}

pub const RenderError = error{
    /// Content-Type is not `multipart/form-data; boundary=<b>`.
    NotMultipart,
    /// uv did not send exactly Basic __token__:<placeholder>.
    AuthorizationMismatch,
    /// The body came chunked; the fixture format assumes Content-Length.
    Chunked,
    /// The recorded body's length is not the Content-Length uv sent.
    ContentLengthMismatch,
};

/// The committed `.request` bytes of one capture (see the file comment).
/// Refuses a capture whose Authorization is not the placeholder's.
pub fn renderRequest(a: Allocator, req: Request) (RenderError || Allocator.Error)![]u8 {
    const ctype = req.header("Content-Type");
    if (!std.mem.startsWith(u8, ctype, MULTIPART)) return error.NotMultipart;
    const boundary = ctype[MULTIPART.len..];
    const want_auth = try expectedAuthorization(a);
    defer a.free(want_auth);
    if (!std.mem.eql(u8, req.header("Authorization"), want_auth)) return error.AuthorizationMismatch;
    if (req.chunked) return error.Chunked;
    var len_buf: [20]u8 = undefined;
    const len_text = std.fmt.bufPrint(&len_buf, "{d}", .{req.body.len}) catch unreachable;
    if (!std.mem.eql(u8, len_text, req.header("Content-Length"))) return error.ContentLengthMismatch;
    const head = try std.fmt.allocPrint(
        a,
        "METHOD {s}\nPATH {s}\nCONTENT-TYPE {s}\nACCEPT {s}\nBOUNDARY {s}\nFILENAME {s}\nBODY-LENGTH {d}\n\n",
        .{ req.method, req.path, ctype, req.header("Accept"), boundary, WHEEL_NAME, req.body.len },
    );
    defer a.free(head);
    return std.mem.concat(a, u8, &.{ head, req.body });
}

/// A `.request` with its (random) boundary replaced, everywhere, by
/// `<BOUNDARY>`: two captures of one wheel compare equal under it. The
/// boundary is the value of the last `BOUNDARY ` line of the head.
pub fn normalized(a: Allocator, request: []const u8) ![]u8 {
    const head_end = std.mem.indexOf(u8, request, "\n\n") orelse request.len;
    var boundary: []const u8 = "";
    var lines = std.mem.splitScalar(u8, request[0..head_end], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "BOUNDARY ")) boundary = line["BOUNDARY ".len..];
    }
    if (boundary.len == 0) return error.NoBoundary;
    return std.mem.replaceOwned(u8, a, request, boundary, "<BOUNDARY>");
}

// ---- Comparing a capture with the committed fixtures ------------------------

/// The first offset at which `old` and `new` differ (the shorter length when
/// one is a prefix of the other); null when they are equal.
pub fn firstDifference(old: []const u8, new: []const u8) ?usize {
    const n = @min(old.len, new.len);
    for (0..n) |i| {
        if (old[i] != new[i]) return i;
    }
    return if (old.len == new.len) null else n;
}

/// Compares one fixture file; a `.request` is compared in its normalised
/// form. Returns false and writes one diff paragraph to `w` when they
/// differ: the sizes, the first differing offset and up to 48 bytes of each
/// side from there, escaped.
pub fn compareFile(a: Allocator, w: anytype, name: []const u8, committed: []const u8, captured: []const u8) !bool {
    const is_request = std.mem.endsWith(u8, name, ".request");
    const old = if (is_request) try normalized(a, committed) else committed;
    const new = if (is_request) try normalized(a, captured) else captured;
    const at = firstDifference(old, new) orelse return true;
    const form = if (is_request) " (boundary-normalised)" else "";
    try w.print("  {s}: committed {d} bytes, captured {d} bytes{s}; first difference at byte {d}\n", .{ name, old.len, new.len, form, at });
    try w.print("    committed: \"{}\"\n", .{std.fmt.fmtSliceEscapeLower(old[at..@min(old.len, at + 48)])});
    try w.print("    captured:  \"{}\"\n", .{std.fmt.fmtSliceEscapeLower(new[at..@min(new.len, at + 48)])});
    return false;
}
