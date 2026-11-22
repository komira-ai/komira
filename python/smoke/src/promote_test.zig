//! The cases of `promote` (promote.zig, cli.zig): the record's file is downloaded from TestPyPI when TestPyPI
//! still lists it with the recorded bytes and PyPI holds no newer version of the same tag; newer TestPyPI
//! versions of the same tag are named as skipped; versions are compared as numbers; and every refusal leaves
//! the output file and the output directory untouched.
const std = @import("std");
const h = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const TAG = "py3-none-manylinux_2_34_x86_64";
const MAC_TAG = "py3-none-macosx_11_0_arm64";
const TEST_URL = "https://test.pypi.org/pypi/komira/json";
const PYPI_URL = "https://pypi.org/pypi/komira/json";
const ZERO = "0000000000000000000000000000000000000000000000000000000000000000";

fn fileOf(a: Alloc, version: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "komira-{s}-{s}.whl", .{ version, tag });
}

fn urlOf(a: Alloc, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://test-files.pythonhosted.org/packages/ab/cd/{s}", .{file});
}

/// A release of another version that lists one file of `tag`.
fn rel(a: Alloc, version: []const u8, tag: []const u8) !h.Rel {
    const file = try fileOf(a, version, tag);
    const files = try a.alloc(h.Listed, 1);
    files[0] = .{ .file = file, .sha256 = ZERO, .size = 10, .url = try urlOf(a, file) };
    return .{ .version = version, .files = files };
}

const Setup = struct {
    version: []const u8 = "0.1.9",
    /// The record's text; null is the wheel's own line.
    record: ?[]const u8 = null,
    /// Releases of TestPyPI after the record's own, in this order.
    others: []const h.Rel = &.{},
    /// What TestPyPI lists for the record's version; null is the recorded file.
    own_files: ?[]const h.Listed = null,
    /// TestPyPI's answer for the project JSON; null is the JSON of `others` and the record's release.
    testpypi: ?h.rbf.Got = null,
    pypi: ?h.rbf.Got = null,
    file: ?h.rbf.Got = null,
    listed_url: ?[]const u8 = null,
    listed_sha: ?[]const u8 = null,
    listed_size: ?usize = null,
    /// The bytes of the wheel and of the record's size and sha256; null makes the wheel of `version`.
    wheel: ?[]const u8 = null,
    old_out: bool = false,
    empty_out: bool = false,
};

const Out = struct {
    r: h.Result,
    fake: h.Fake,
    tmp: t.TmpDir,
    file_name: []const u8,
    sha: []const u8,
    size: usize,
    bytes: []const u8,

    fn done(self: *Out) void {
        self.tmp.cleanup();
    }

    fn outHolds(self: *Out, a: Alloc) !?usize {
        var d = self.tmp.dir.openDir("out", .{ .iterate = true }) catch return null;
        defer d.close();
        var n: usize = 0;
        var it = d.iterate();
        while (try it.next()) |_| n += 1;
        _ = a;
        return n;
    }
};

fn run(a: Alloc, s: Setup, out: *Out) !void {
    out.tmp = t.tmpDir(.{});
    const bytes = s.wheel orelse try h.makeWheel(a, .{ .version = s.version });
    const file_name = try fileOf(a, s.version, TAG);
    const sha = try h.hex(a, bytes);
    const file_url = try urlOf(a, file_name);
    const line = s.record orelse try std.fmt.allocPrint(a, "{s} {s} {d}\n", .{ file_name, sha, bytes.len });
    try out.tmp.dir.writeFile(.{ .sub_path = "record.txt", .data = line });
    if (s.empty_out) try out.tmp.dir.makePath("out");
    if (s.old_out) {
        try out.tmp.dir.makePath("out");
        try out.tmp.dir.writeFile(.{ .sub_path = "out/old", .data = "x" });
    }
    const own = [_]h.Listed{.{
        .file = file_name,
        .sha256 = s.listed_sha orelse sha,
        .size = s.listed_size orelse bytes.len,
        .url = s.listed_url orelse file_url,
    }};
    var rels = std.ArrayList(h.Rel).empty;
    try rels.append(a, .{ .version = s.version, .files = s.own_files orelse &own });
    try rels.appendSlice(a, s.others);
    var routes = std.ArrayList(h.Route).empty;
    try routes.append(a, .{ .url = TEST_URL, .got = s.testpypi orelse .{ .body = try h.projectJson(a, rels.items) } });
    if (s.pypi) |p| try routes.append(a, .{ .url = PYPI_URL, .got = p });
    try routes.append(a, .{ .url = file_url, .got = s.file orelse .{ .body = @constCast(bytes) } });
    out.fake = .{ .alloc = a, .routes = routes.items };
    out.file_name = file_name;
    out.sha = sha;
    out.size = bytes.len;
    out.bytes = bytes;
    out.r = try h.exec(a, &.{ "promote", "--record", try h.path(a, &out.tmp, "record.txt"), "--out", try h.path(a, &out.tmp, "out"), "--github-output", try h.path(a, &out.tmp, "gh.txt") }, &out.fake);
}

/// The command refused with `why`: exit 1, the failure line and the annotation say it, the output file does not
/// exist and `out` holds `held` files (null: it does not exist).
fn expectRefused(a: Alloc, o: *Out, why: []const u8, held: ?usize) !void {
    try t.expectEqual(@as(u8, 1), o.r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: {s}\n", .{why}), o.r.err);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "::error title=pypi::{s}\n", .{why}), o.r.out);
    try t.expect(!h.exists(&o.tmp, "gh.txt"));
    try t.expectEqual(held, try o.outHolds(a));
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "promote downloads the recorded file into --out and appends version, file name and an empty skipped" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .pypi = .{ .body = @constCast(try h.projectJson(a, &.{try rel(a, "0.1.8", TAG)})) } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqualStrings("", o.r.err);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: promoting komira 0.1.9: {s} (sha256 {s}, {d} bytes) downloaded from TestPyPI, as recorded\n", .{ o.file_name, o.sha, o.size }), o.r.out);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "version=0.1.9\nfilename={s}\nskipped=\n", .{o.file_name}), try h.readAll(a, &o.tmp, "gh.txt"));
    try t.expectEqualSlices(u8, o.bytes, try h.readAll(a, &o.tmp, try std.fmt.allocPrint(a, "out/{s}", .{o.file_name})));
    try t.expectEqual(@as(?usize, 1), try o.outHolds(a));
    try t.expectEqual(@as(usize, 3), o.fake.urls.items.len);
    try t.expectEqualStrings(TEST_URL, o.fake.urls.items[0]);
    try t.expectEqualStrings(PYPI_URL, o.fake.urls.items[1]);
    try t.expectEqualStrings(try urlOf(a, o.file_name), o.fake.urls.items[2]);
    try t.expectEqual(o.size + 1, o.fake.maxes.items[2]);
}

test "promote names the newer TestPyPI versions of the same tag as skipped, oldest first, and not another tag's" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .others = &.{
        try rel(a, "0.1.11", TAG),
        try rel(a, "0.1.12", MAC_TAG),
        try rel(a, "0.1.8", TAG),
        try rel(a, "0.1.10", TAG),
    } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "version=0.1.9\nfilename={s}\nskipped=0.1.10, 0.1.11\n", .{o.file_name}), try h.readAll(a, &o.tmp, "gh.txt"));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "::notice title=pypi::komira 0.1.10 is on TestPyPI with no record that its TestPyPI smoke passed (the smoke failed, or its run has not ended): not promoted\n" ++
        "::notice title=pypi::komira 0.1.11 is on TestPyPI with no record that its TestPyPI smoke passed (the smoke failed, or its run has not ended): not promoted\n" ++
        "pypi_smoke: promoting komira 0.1.9: {s} (sha256 {s}, {d} bytes) downloaded from TestPyPI, as recorded\n", .{ o.file_name, o.sha, o.size }), o.r.out);
}

test "promote compares versions as numbers: 0.1.10 is newer than 0.1.9 and 0.1.9 is newer than 0.1.2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .others = &.{ try rel(a, "0.1.10", TAG), try rel(a, "0.1.2", TAG), try rel(a, "0.1", TAG), try rel(a, "0.1.9.1", TAG) } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "version=0.1.9\nfilename={s}\nskipped=0.1.9.1, 0.1.10\n", .{o.file_name}), try h.readAll(a, &o.tmp, "gh.txt"));
}

test "promote leaves out a TestPyPI version that is not dot-separated numbers and says so" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .others = &.{ try rel(a, "0.1.10rc1", TAG), try rel(a, "0.2.0", TAG) } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expect(std.mem.startsWith(u8, o.r.out, "pypi_smoke: TestPyPI version 0.1.10rc1 is not dot-separated numbers; not compared\n::notice title=pypi::komira 0.2.0 is on TestPyPI"));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "version=0.1.9\nfilename={s}\nskipped=0.2.0\n", .{o.file_name}), try h.readAll(a, &o.tmp, "gh.txt"));
}

test "promote refuses when PyPI's newest of the same tag is newer than the record" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .pypi = .{ .body = @constCast(try h.projectJson(a, &.{ try rel(a, "0.1.10", TAG), try rel(a, "0.1.3", TAG) })) } }, &o);
    defer o.done();
    try expectRefused(a, &o, "PyPI's newest komira with tag " ++ TAG ++ " is 0.1.10, newer than 0.1.9, the newest version whose TestPyPI smoke passed: nothing is promoted (a run of an older commit passed after a newer one)", null);
}

test "promote accepts PyPI holding the record's own version, older ones, and a newer one of another tag only" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .pypi = .{ .body = @constCast(try h.projectJson(a, &.{ try rel(a, "0.1.9", TAG), try rel(a, "0.1.8", TAG), try rel(a, "0.3.0", MAC_TAG) })) } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqual(@as(?usize, 1), try o.outHolds(a));
}

test "promote accepts a PyPI that has no project yet" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .pypi = .{ .status = 404 } }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqual(@as(?usize, 1), try o.outHolds(a));
}

test "promote refuses a TestPyPI that does not list the recorded version" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .testpypi = .{ .body = @constCast(try h.projectJson(a, &.{try rel(a, "0.1.8", TAG)})) } }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "TestPyPI lists no version 0.1.9 of komira; {s} is not on it", .{o.file_name}), null);
}

test "promote refuses a TestPyPI release that lists another file than the recorded one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    const mac = try rel(a, "0.1.9", MAC_TAG);
    try run(a, .{ .own_files = mac.files }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "TestPyPI does not list {s} under version 0.1.9", .{o.file_name}), null);
}

test "promote refuses a listed file with another sha256 and size and names both differences" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .listed_sha = ZERO, .listed_size = 7 }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "{s} on TestPyPI is not the recorded file: TestPyPI lists sha256 {s}, the record has {s}; TestPyPI lists size 7, the record has {d}", .{ o.file_name, ZERO, o.sha, o.size }), null);
}

test "promote refuses a listed file with only another size, and one with only another sha256" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .listed_size = 7 }, &o);
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "{s} on TestPyPI is not the recorded file: TestPyPI lists size 7, the record has {d}", .{ o.file_name, o.size }), null);
    o.done();
    try run(a, .{ .listed_sha = ZERO }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "{s} on TestPyPI is not the recorded file: TestPyPI lists sha256 {s}, the record has {s}", .{ o.file_name, ZERO, o.sha }), null);
}

test "promote refuses a file that TestPyPI lists at a URL off its file host" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .listed_url = "https://files.example.org/x.whl" }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "TestPyPI serves {s} from https://files.example.org/x.whl, not from https://test-files.pythonhosted.org/", .{o.file_name}), null);
    for (o.fake.urls.items) |u| try t.expect(!std.mem.endsWith(u8, u, ".whl"));
}

test "promote refuses a URL on a host whose name only starts with TestPyPI's file host" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .listed_url = "https://test-files.pythonhosted.org.example.org/x.whl" }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "TestPyPI serves {s} from https://test-files.pythonhosted.org.example.org/x.whl, not from https://test-files.pythonhosted.org/", .{o.file_name}), null);
    for (o.fake.urls.items) |u| try t.expect(!std.mem.endsWith(u8, u, ".whl"));
}

test "promote refuses served bytes that differ from the record, with both values" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const other = try h.makeWheel(a, .{ .payload = "print('other')\n" });
    var o: Out = undefined;
    try run(a, .{ .file = .{ .body = @constCast(other) } }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "GET {s}: the served bytes have sha256 {s} and size {d}; the record has sha256 {s} and size {d}", .{ try urlOf(a, o.file_name), try h.hex(a, other), other.len, o.sha, o.size }), null);
}

test "promote refuses served bytes that are the recorded ones but no wheel" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .wheel = "these bytes are not a zip" }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 1), o.r.code);
    try t.expect(std.mem.startsWith(u8, o.r.err, try std.fmt.allocPrint(a, "pypi_smoke: FAILED: GET {s}: the served bytes: not a wheel this tool reads", .{try urlOf(a, o.file_name)})));
    try t.expect(!h.exists(&o.tmp, "gh.txt"));
    try t.expectEqual(@as(?usize, null), try o.outHolds(a));
}

test "promote refuses a served wheel that its own metadata names otherwise than the record" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    // the record and TestPyPI say 0.1.9; the bytes, whose sha256 and size they hold, are the wheel of 0.1.8
    try run(a, .{ .wheel = try h.makeWheel(a, .{ .version = "0.1.8" }) }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "GET {s}: the served wheel is named komira-0.1.8-{s}.whl by its METADATA and WHEEL, not {s}", .{ try urlOf(a, o.file_name), TAG, o.file_name }), null);
}

test "promote refuses a malformed record, naming the file, before any request" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const f = "komira-0.1.9-" ++ TAG ++ ".whl";
    const sha = ZERO;
    const Case = struct { text: []const u8, why: []const u8 };
    const cases = [_]Case{
        .{ .text = f ++ " " ++ sha ++ " 10\n" ++ f ++ " " ++ sha ++ " 10\n", .why = "holds more than one line; exactly one line is wanted" },
        .{ .text = f ++ " " ++ sha ++ " 10\n\n", .why = "holds more than one line; exactly one line is wanted" },
        .{ .text = "", .why = " has 1 parts;" },
        .{ .text = f ++ " " ++ sha ++ "\n", .why = " has 2 parts;" },
        .{ .text = f ++ "  " ++ sha ++ " 10\n", .why = " has 4 parts;" },
        .{ .text = f ++ " " ++ "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789" ++ " 10\n", .why = "the sha256 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789' is not 64 lowercase hex digits" },
        .{ .text = f ++ " abc 10\n", .why = "the sha256 'abc' is not 64 lowercase hex digits" },
        .{ .text = f ++ " " ++ sha ++ " 0\n", .why = "the size '0' is not a decimal number of bytes above 0" },
        .{ .text = f ++ " " ++ sha ++ " +5\n", .why = "the size '+5' is not a decimal number of bytes above 0" },
        .{ .text = f ++ " " ++ sha ++ " 1x\n", .why = "the size '1x' is not a decimal number of bytes above 0" },
        .{ .text = "komira-0.1.9.whl " ++ sha ++ " 10\n", .why = "the name file's line 'komira-0.1.9.whl' has 2 '-' separated parts" },
        .{ .text = "komira-0.1.9rc1-" ++ TAG ++ ".whl " ++ sha ++ " 10\n", .why = "the version '0.1.9rc1' is not dot-separated numbers" },
    };
    for (cases) |c| {
        var o: Out = undefined;
        try run(a, .{ .record = c.text }, &o);
        defer o.done();
        const path = try h.path(a, &o.tmp, "record.txt");
        try t.expectEqual(@as(u8, 1), o.r.code);
        const prefix = try std.fmt.allocPrint(a, "pypi_smoke: FAILED: --record {s}", .{path});
        try t.expect(std.mem.startsWith(u8, o.r.err, prefix));
        try t.expect(std.mem.indexOf(u8, o.r.err, c.why) != null);
        try t.expect(std.mem.startsWith(u8, o.r.out, "::error title=pypi::--record "));
        try t.expectEqual(@as(usize, 0), o.fake.urls.items.len);
        try t.expect(!h.exists(&o.tmp, "gh.txt"));
        try t.expectEqual(@as(?usize, null), try o.outHolds(a));
    }
}

test "promote refuses a record file that does not exist, naming it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    const path = try h.path(a, &tmp, "missing.txt");
    const r = try h.exec(a, &.{ "promote", "--record", path, "--out", try h.path(a, &tmp, "out"), "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: cannot read {s}: FileNotFound\n", .{path}), r.err);
    try t.expectEqual(@as(usize, 0), fake.urls.items.len);
}

test "promote refuses an --out that is not empty and leaves it as it was" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .old_out = true }, &o);
    defer o.done();
    try expectRefused(a, &o, try std.fmt.allocPrint(a, "--out {s} is not empty", .{try h.path(a, &o.tmp, "out")}), 1);
    try t.expectEqualStrings("x", try h.readAll(a, &o.tmp, "out/old"));
}

test "promote accepts an --out that exists and is empty" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .empty_out = true }, &o);
    defer o.done();
    try t.expectEqual(@as(u8, 0), o.r.code);
    try t.expectEqual(@as(?usize, 1), try o.outHolds(a));
}

test "promote refuses a TestPyPI that has no such project" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var o: Out = undefined;
    try run(a, .{ .testpypi = .{ .status = 404 } }, &o);
    defer o.done();
    try expectRefused(a, &o, "TestPyPI has no project komira", null);
}

test "promote refuses an HTTP 500, a transport error or a body that is no project JSON on each request" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const pypi_ok: h.rbf.Got = .{ .status = 404 };
    {
        var o: Out = undefined;
        try run(a, .{ .testpypi = .{ .status = 500 } }, &o);
        defer o.done();
        try expectRefused(a, &o, "GET " ++ TEST_URL ++ ": HTTP 500", null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .pypi = .{ .status = 500 } }, &o);
        defer o.done();
        try expectRefused(a, &o, "GET " ++ PYPI_URL ++ ": HTTP 500", null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .pypi = pypi_ok, .file = .{ .status = 500 } }, &o);
        defer o.done();
        try expectRefused(a, &o, try std.fmt.allocPrint(a, "GET {s}: HTTP 500", .{try urlOf(a, o.file_name)}), null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .testpypi = .{ .transport = error.ConnectionRefused } }, &o);
        defer o.done();
        try expectRefused(a, &o, "GET " ++ TEST_URL ++ ": ConnectionRefused", null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .file = .{ .transport = error.ConnectionResetByPeer } }, &o);
        defer o.done();
        try expectRefused(a, &o, try std.fmt.allocPrint(a, "GET {s}: ConnectionResetByPeer", .{try urlOf(a, o.file_name)}), null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .file = .too_large }, &o);
        defer o.done();
        try expectRefused(a, &o, try std.fmt.allocPrint(a, "GET {s}: the file is larger than the recorded {d} bytes", .{ try urlOf(a, o.file_name), o.size }), null);
    }
    {
        var o: Out = undefined;
        try run(a, .{ .testpypi = .{ .body = @constCast("{\"releases\":[]}") } }, &o);
        defer o.done();
        try t.expect(std.mem.startsWith(u8, o.r.err, "pypi_smoke: FAILED: GET " ++ TEST_URL ++ ": the answer is not the JSON of a project ("));
        try t.expect(!h.exists(&o.tmp, "gh.txt"));
    }
}
