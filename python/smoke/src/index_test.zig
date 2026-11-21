//! The cases of the state and verify steps (index.zig) against an index and a file host in memory: what the
//! index says about our file before an upload (absent, the same bytes, other bytes, or no answer), and after one,
//! whether it lists and serves the bytes and the metadata that were built, every difference reported, an index
//! that lags tried again and one that never has the file refused.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const h = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const idx = lib.common.testpypi;
const JSON_URL = "https://test.pypi.org/pypi/komira/0.1.7/json";
const FILE = "komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl";
const FILE_URL = "https://test-files.pythonhosted.org/packages/ab/cd/" ++ FILE;

fn listing(a: Alloc, w: lib.meta.Wheel, sha: ?[]const u8, size: ?usize, url: ?[]const u8) ![]u8 {
    return h.releaseJson(a, &.{.{
        .file = FILE,
        .sha256 = sha orelse try h.hex(a, w.bytes),
        .size = size orelse w.bytes.len,
        .url = url orelse FILE_URL,
    }});
}

fn routes(a: Alloc, json: []const u8, file: ?h.rbf.Got) ![]h.Route {
    const list = try a.alloc(h.Route, if (file == null) 1 else 2);
    list[0] = .{ .url = JSON_URL, .got = .{ .body = @constCast(json) } };
    if (file) |g| list[1] = .{ .url = FILE_URL, .got = g };
    return list;
}

fn body(bytes: []const u8) h.rbf.Got {
    return .{ .body = @constCast(bytes) };
}

fn lookupOf(a: Alloc, why: *[]const u8, fake: *h.Fake, w: lib.meta.Wheel) !lib.index.Found {
    return lib.index.lookup(a, why, fake.fetcher(), idx, w);
}

// ---- state ------------------------------------------------------------------------------

test "state is absent when the index answers 404 for the release" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .status = 404 } }} };
    var why: []const u8 = "";
    const found = try lookupOf(a, &why, &fake, w);
    try t.expectEqual(lib.index.State.absent, found.state);
    try t.expectEqual(@as(usize, 1), fake.urls.items.len);
    try t.expectEqualStrings(JSON_URL, fake.urls.items[0]);
}

test "state is absent when the release exists with another file only" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const json = try h.releaseJson(a, &.{.{ .file = "komira-0.1.7-py3-none-manylinux_2_34_aarch64.whl", .sha256 = "ab", .size = 3, .url = FILE_URL }});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, json, null) };
    var why: []const u8 = "";
    try t.expectEqual(lib.index.State.absent, (try lookupOf(a, &why, &fake, w)).state);
}

test "state is same when the index lists our file with our sha256" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), null) };
    var why: []const u8 = "";
    const found = try lookupOf(a, &why, &fake, w);
    try t.expectEqual(lib.index.State.same, found.state);
    try t.expectEqualStrings(&w.sha256, found.theirs);
}

test "state is differs when the index lists our file with another sha256, and says both" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const theirs = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, theirs, null, null), null) };
    var why: []const u8 = "";
    const found = try lookupOf(a, &why, &fake, w);
    try t.expectEqual(lib.index.State.differs, found.state);
    try t.expectEqualStrings(theirs, found.theirs);
    try t.expectEqualStrings(
        try std.fmt.allocPrint(a, FILE ++ " is on testpypi with sha256 {s}, not {s}: bytes differ at the same version: a commit that changed only documentation, which the stamp ignores; a code commit raises the version. No upload and no smoke.", .{ theirs, &w.sha256 }),
        try lib.index.stateNotice(a, found, idx, w),
    );
}

test "the notices of the other two states say what the run does" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    try t.expectEqualStrings(FILE ++ " is already on pypi with the same sha256: no upload; the smoke runs", try lib.index.stateNotice(a, .{ .state = .same }, lib.common.pypi, w));
    try t.expectEqualStrings(FILE ++ " is not on pypi: it is uploaded", try lib.index.stateNotice(a, .{ .state = .absent }, lib.common.pypi, w));
}

test "state fails on an HTTP 500, a transport error, and an answer that is not a release's JSON" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var why: []const u8 = "";

    var s500 = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .status = 500 } }} };
    try t.expectError(error.Refused, lookupOf(a, &why, &s500, w));
    try t.expectEqualStrings("GET " ++ JSON_URL ++ ": HTTP 500", why);
    try t.expectEqual(@as(usize, 1), s500.urls.items.len);

    var down = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .transport = error.ConnectionRefused } }} };
    try t.expectError(error.Refused, lookupOf(a, &why, &down, w));
    try t.expectEqualStrings("GET " ++ JSON_URL ++ ": ConnectionRefused", why);

    var html = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = body("<html>maintenance</html>") }} };
    try t.expectError(error.Refused, lookupOf(a, &why, &html, w));
    try t.expect(std.mem.startsWith(u8, why, "GET " ++ JSON_URL ++ ": the answer is not the JSON of a release ("));

    var shapeless = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = body("{\"urls\":[{\"filename\":\"x\"}]}") }} };
    try t.expectError(error.Refused, lookupOf(a, &why, &shapeless, w));
    try t.expect(std.mem.startsWith(u8, why, "GET " ++ JSON_URL ++ ": the answer is not the JSON of a release ("));

    var big = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .too_large }} };
    try t.expectError(error.Refused, lookupOf(a, &why, &big, w));
    try t.expectEqualStrings("GET " ++ JSON_URL ++ ": the answer is longer than 16777216 bytes", why);
}

// ---- verify -----------------------------------------------------------------------------

fn verifyWith(a: Alloc, why: *[]const u8, fake: *h.Fake, w: lib.meta.Wheel, attempts: u32, log: *std.Io.Writer) !lib.index.Report {
    return lib.index.verify(a, why, fake.fetcher(), idx, w, attempts, 0, log);
}

fn refusal(a: Alloc, count: usize, lines: []const []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(a);
    try w.writer.print("{d} difference(s) between what testpypi serves and the wheel that was built:", .{count});
    for (lines) |l| try w.writer.print("\n  {s}", .{l});
    return w.written();
}

fn servedLine(a: Alloc, served: []const u8, w: lib.meta.Wheel) ![]u8 {
    return std.fmt.allocPrint(a, FILE ++ ": the served bytes have sha256 {s} and size {d}; the built wheel has sha256 {s} and size {d}", .{ try h.hex(a, served), served.len, &w.sha256, w.bytes.len });
}

test "verify passes when the index lists and serves the built bytes, and asks for no more than one byte over their size" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(w.bytes)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    const rep = try verifyWith(a, &why, &fake, w, 3, &log.writer);
    try t.expectEqualStrings(&w.sha256, &rep.sha256);
    try t.expectEqual(w.bytes.len, rep.size);
    try t.expectEqualStrings("", log.written());
    try t.expectEqual(@as(usize, 2), fake.urls.items.len);
    try t.expectEqualStrings(FILE_URL, fake.urls.items[1]);
    try t.expectEqual(w.bytes.len + 1, fake.maxes.items[1]);
}

test "verify refuses served bytes that are not the built ones, with their sha256 and size" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const tampered = try h.makeWheel(a, .{ .payload = "print('HELLO')\n" });
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(tampered)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 1, &.{try servedLine(a, tampered, w)}), why);
}

test "verify refuses a JSON that lists another sha256 than the built wheel's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const theirs = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, theirs, null, null), body(w.bytes)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    const line = try std.fmt.allocPrint(a, FILE ++ ": the index lists sha256 {s}, the built wheel has {s}", .{ theirs, &w.sha256 });
    try t.expectEqualStrings(try refusal(a, 1, &.{line}), why);
}

test "verify refuses a JSON that lists another size than the built wheel's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, w.bytes.len + 1, null), body(w.bytes)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    const line = try std.fmt.allocPrint(a, FILE ++ ": the index lists size {d}, the built wheel has {d}", .{ w.bytes.len + 1, w.bytes.len });
    try t.expectEqualStrings(try refusal(a, 1, &.{line}), why);
}

test "verify refuses a file served from another host, and does not fetch it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const other = "https://evil.example/packages/" ++ FILE;
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, other), body(w.bytes)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 1, &.{FILE ++ ": the index serves it from " ++ other ++ ", not from https://test-files.pythonhosted.org/"}), why);
    try t.expectEqual(@as(usize, 1), fake.urls.items.len);
}

test "verify reports every difference of an attempt: the served bytes and each METADATA field" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const served = try h.makeWheel(a, .{ .name = "Komira2", .version = "0.1.8", .requires_python = ">=3.12", .requires_dist = &.{ "b==2", "a==1" } });
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(served)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 5, &.{
        try servedLine(a, served, w),
        "METADATA Name: served 'Komira2', built 'komira'",
        "METADATA Version: served '0.1.8', built '0.1.7'",
        "METADATA Requires-Python: served '>=3.12', built '>=3.13'",
        "METADATA Requires-Dist: served [b==2, a==1], built [mojo-compiler==1.0.0]",
    }), why);
}

test "verify holds Requires-Dist to the full ordered list" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{ .requires_dist = &.{ "alpha==1", "zeta==2" } });
    const served = try h.makeWheel(a, .{ .requires_dist = &.{ "zeta==2", "alpha==1" } });
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(served)) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 2, &.{
        try servedLine(a, served, w),
        "METADATA Requires-Dist: served [zeta==2, alpha==1], built [alpha==1, zeta==2]",
    }), why);
}

test "verify refuses served bytes that are not a wheel, naming what the zip reader found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body("garbage")) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 2, &.{
        try servedLine(a, "garbage", w),
        FILE ++ ": the served bytes: not a wheel this tool reads: no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)",
    }), why);
}

test "verify refuses a file the host does not serve, serves too long, or fails on" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const json = try listing(a, w, null, null, null);
    var log = h.sink(a);
    var why: []const u8 = "";

    var missing = h.Fake{ .alloc = a, .routes = try routes(a, json, .{ .status = 404 }) };
    try t.expectError(error.Refused, verifyWith(a, &why, &missing, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 1, &.{"GET " ++ FILE_URL ++ ": HTTP 404"}), why);

    var long = h.Fake{ .alloc = a, .routes = try routes(a, json, .too_large) };
    try t.expectError(error.Refused, verifyWith(a, &why, &long, w, 1, &log.writer));
    const line = try std.fmt.allocPrint(a, "GET " ++ FILE_URL ++ ": the file is larger than the built wheel's {d} bytes", .{w.bytes.len});
    try t.expectEqualStrings(try refusal(a, 1, &.{line}), why);

    var reset = h.Fake{ .alloc = a, .routes = try routes(a, json, .{ .transport = error.ConnectionResetByPeer }) };
    try t.expectError(error.Refused, verifyWith(a, &why, &reset, w, 1, &log.writer));
    try t.expectEqualStrings(try refusal(a, 1, &.{"GET " ++ FILE_URL ++ ": ConnectionResetByPeer"}), why);
}

test "verify passes on the second attempt when the index lags, and its log says the first failed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(w.bytes)), .lag = 1 };
    var log = h.sink(a);
    var why: []const u8 = "";
    _ = try verifyWith(a, &why, &fake, w, 3, &log.writer);
    try t.expectEqualStrings("attempt 1 of 3 failed, trying again: " ++ FILE ++ " is not on testpypi yet\n", log.written());
    try t.expectEqual(@as(usize, 2), fake.json_hits);
}

test "verify refuses a file that is still absent after every attempt" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(w.bytes)), .lag = 100 };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &fake, w, 2, &log.writer));
    try t.expectEqualStrings(FILE ++ " is not on testpypi yet", why);
    try t.expectEqualStrings("attempt 1 of 2 failed, trying again: " ++ FILE ++ " is not on testpypi yet\n", log.written());
    try t.expectEqual(@as(usize, 2), fake.json_hits);
}

test "verify treats a release that lists other files only as absent, and refuses a difference that every attempt finds" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try h.built(a, .{});
    const other = try h.releaseJson(a, &.{.{ .file = "komira-0.1.7-py3-none-any.whl", .sha256 = "ab", .size = 1, .url = FILE_URL }});
    var absent = h.Fake{ .alloc = a, .routes = try routes(a, other, null) };
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, verifyWith(a, &why, &absent, w, 1, &log.writer));
    try t.expectEqualStrings(FILE ++ " is not on testpypi yet", why);

    const tampered = try h.makeWheel(a, .{ .payload = "print('HELLO')\n" });
    var differing = h.Fake{ .alloc = a, .routes = try routes(a, try listing(a, w, null, null, null), body(tampered)) };
    var log2 = h.sink(a);
    try t.expectError(error.Refused, verifyWith(a, &why, &differing, w, 3, &log2.writer));
    try t.expectEqual(@as(usize, 3), differing.json_hits);
    const again = try std.fmt.allocPrint(a, "attempt {d} of 3 failed, trying again: {s}\n", .{ 1, try refusal(a, 1, &.{try servedLine(a, tampered, w)}) });
    try t.expect(std.mem.startsWith(u8, log2.written(), again));
}

// ---- present ----------------------------------------------------------------------------

const MAC_FILE = "komira-0.1.7-py3-none-macosx_11_0_arm64.whl";
const mac_name = lib.meta.FileName{ .name = "komira", .version = "0.1.7", .tag = "py3-none-macosx_11_0_arm64" };

fn hasFileOf(a: Alloc, why: *[]const u8, fake: *h.Fake) !bool {
    return lib.index.hasFile(a, why, fake.fetcher(), idx, mac_name, MAC_FILE);
}

test "a file is not present when the index answers 404 for the release" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fake = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .status = 404 } }} };
    var why: []const u8 = "";
    try t.expect(!try hasFileOf(a, &why, &fake));
    try t.expectEqual(@as(usize, 1), fake.urls.items.len);
    try t.expectEqualStrings(JSON_URL, fake.urls.items[0]);
}

test "a file is not present when the release of that version lists the Linux wheel only" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const json = try h.releaseJson(a, &.{.{ .file = FILE, .sha256 = "ab", .size = 3, .url = FILE_URL }});
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, json, null) };
    var why: []const u8 = "";
    try t.expect(!try hasFileOf(a, &why, &fake));
}

test "a file is present when the release lists a file of exactly that name, whatever its bytes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const json = try h.releaseJson(a, &.{
        .{ .file = FILE, .sha256 = "ab", .size = 3, .url = FILE_URL },
        .{ .file = MAC_FILE, .sha256 = "cd", .size = 9, .url = FILE_URL },
    });
    var fake = h.Fake{ .alloc = a, .routes = try routes(a, json, null) };
    var why: []const u8 = "";
    try t.expect(try hasFileOf(a, &why, &fake));
    try t.expectEqual(@as(usize, 1), fake.urls.items.len);
}

test "presence is refused on an HTTP 500, a transport error, and an answer that is not a release's JSON" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";

    var s500 = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .status = 500 } }} };
    try t.expectError(error.Refused, hasFileOf(a, &why, &s500));
    try t.expectEqualStrings("GET " ++ JSON_URL ++ ": HTTP 500", why);

    var down = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .transport = error.ConnectionRefused } }} };
    try t.expectError(error.Refused, hasFileOf(a, &why, &down));
    try t.expectEqualStrings("GET " ++ JSON_URL ++ ": ConnectionRefused", why);

    var html = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = body("<html>maintenance</html>") }} };
    try t.expectError(error.Refused, hasFileOf(a, &why, &html));
    try t.expect(std.mem.startsWith(u8, why, "GET " ++ JSON_URL ++ ": the answer is not the JSON of a release ("));
}
