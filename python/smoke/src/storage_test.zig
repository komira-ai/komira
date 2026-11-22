//! The cases of `storage` (storage.zig, cli.zig): the sum of the sizes of every file of every release of a
//! project on an index, the bullet and the outputs, the boundary of `over`, an unknown project, every answer
//! that is refused and leaves both files untouched, and every flag error that is refused before any request.
const std = @import("std");
const h = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const TEST_URL = "https://test.pypi.org/pypi/komira/json";
const PYPI_URL = "https://pypi.org/pypi/komira/json";
const GIB: usize = 1 << 30;
const ZERO = "0000000000000000000000000000000000000000000000000000000000000000";

fn f(name: []const u8, size: usize) h.Listed {
    return .{ .file = name, .sha256 = ZERO, .size = size, .url = "https://test-files.pythonhosted.org/x" };
}

fn storage(a: Alloc, tmp: *t.TmpDir, index: []const u8, limit: []const u8, over: []const u8, routes: []const h.Route, fake: *h.Fake) !h.Result {
    fake.* = .{ .alloc = a, .routes = routes };
    return h.exec(a, &.{ "storage", "--index", index, "--project", "komira", "--limit-gib", limit, "--over-percent", over, "--summary", try h.path(a, tmp, "summary.md"), "--github-output", try h.path(a, tmp, "gh.txt") }, fake);
}

fn route(url: []const u8, body: []const u8) h.Route {
    return .{ .url = url, .got = .{ .body = @constCast(body) } };
}

test "storage on a project the index does not know holds zero and is not over" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var fake: h.Fake = undefined;
    const r = try storage(a, &tmp, "testpypi", "10", "90", &.{}, &fake);
    try t.expectEqual(@as(u8, 0), r.code);
    const text = "komira on TestPyPI: 0.00 GiB (0 bytes) in 0 files of 0 versions, 0.0% of the 10 GiB limit";
    try t.expectEqualStrings("pypi_smoke: " ++ text ++ "\n", r.out);
    try t.expectEqualStrings("- " ++ text ++ "\n", try h.readAll(a, &tmp, "summary.md"));
    try t.expectEqualStrings("over=false\nbytes=0\n", try h.readAll(a, &tmp, "gh.txt"));
    try t.expectEqual(@as(usize, 1), fake.urls.items.len);
    try t.expectEqualStrings(TEST_URL, fake.urls.items[0]);
}

test "storage sums every file of every release and counts only the releases that list a file as versions" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "summary.md", .data = "# Summary\n" });
    try tmp.dir.writeFile(.{ .sub_path = "gh.txt", .data = "earlier=1\n" });
    const json = try h.projectJson(a, &.{
        .{ .version = "0.1.0", .files = &.{f("a.whl", GIB)} },
        .{ .version = "0.1.1", .files = &.{ f("b.whl", GIB / 2), f("c.whl", 107374182) } },
        .{ .version = "0.1.2" },
    });
    var fake: h.Fake = undefined;
    const r = try storage(a, &tmp, "testpypi", "10", "90", &.{route(TEST_URL, json)}, &fake);
    try t.expectEqual(@as(u8, 0), r.code);
    const text = "komira on TestPyPI: 1.60 GiB (1717986918 bytes) in 3 files of 2 versions, 16.0% of the 10 GiB limit";
    try t.expectEqualStrings("pypi_smoke: " ++ text ++ "\n", r.out);
    try t.expectEqualStrings("# Summary\n- " ++ text ++ "\n", try h.readAll(a, &tmp, "summary.md"));
    try t.expectEqualStrings("earlier=1\nover=false\nbytes=1717986918\n", try h.readAll(a, &tmp, "gh.txt"));
}

test "storage on PyPI reads PyPI's project JSON and names the index PyPI" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const json = try h.projectJson(a, &.{.{ .version = "1.0.0", .files = &.{f("a.whl", 5 * GIB)} }});
    var fake: h.Fake = undefined;
    const r = try storage(a, &tmp, "pypi", "10", "90", &.{route(PYPI_URL, json)}, &fake);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("pypi_smoke: komira on PyPI: 5.00 GiB (5368709120 bytes) in 1 files of 1 versions, 50.0% of the 10 GiB limit\n", r.out);
    try t.expectEqualStrings(PYPI_URL, fake.urls.items[0]);
}

test "storage exactly at the threshold is not over and one byte more is over, with the bullet and the error line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const json = try h.projectJson(a, &.{.{ .version = "0.1.0", .files = &.{f("a.whl", GIB / 2)} }});
        var fake: h.Fake = undefined;
        const r = try storage(a, &tmp, "testpypi", "1", "50", &.{route(TEST_URL, json)}, &fake);
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expectEqualStrings("pypi_smoke: komira on TestPyPI: 0.50 GiB (536870912 bytes) in 1 files of 1 versions, 50.0% of the 1 GiB limit\n", r.out);
        try t.expectEqualStrings("over=false\nbytes=536870912\n", try h.readAll(a, &tmp, "gh.txt"));
    }
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const json = try h.projectJson(a, &.{.{ .version = "0.1.0", .files = &.{f("a.whl", GIB / 2 + 1)} }});
        var fake: h.Fake = undefined;
        const r = try storage(a, &tmp, "testpypi", "1", "50", &.{route(TEST_URL, json)}, &fake);
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expectEqualStrings("::error title=pypi::komira on TestPyPI holds 0.50 GiB, 50.0% of its 1 GiB limit, over 50%: prune old versions on TestPyPI or ask for a higher limit (docs/ci.md, Storage on the indexes)\n", r.out);
        try t.expectEqualStrings("- komira on TestPyPI: 0.50 GiB (536870913 bytes) in 1 files of 1 versions, 50.0% of the 1 GiB limit: **over 50%**\n", try h.readAll(a, &tmp, "summary.md"));
        try t.expectEqualStrings("over=true\nbytes=536870913\n", try h.readAll(a, &tmp, "gh.txt"));
    }
}

test "storage over the threshold on PyPI asks for a higher limit, since PyPI's releases are never deleted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const json = try h.projectJson(a, &.{.{ .version = "0.1.0", .files = &.{f("a.whl", GIB / 2 + 1)} }});
    var fake: h.Fake = undefined;
    const r = try storage(a, &tmp, "pypi", "1", "50", &.{route(PYPI_URL, json)}, &fake);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("::error title=pypi::komira on PyPI holds 0.50 GiB, 50.0% of its 1 GiB limit, over 50%: ask for a higher limit on PyPI (its releases are never deleted) (docs/ci.md, Storage on the indexes)\n", r.out);
    try t.expectEqualStrings("over=true\nbytes=536870913\n", try h.readAll(a, &tmp, "gh.txt"));
}

test "storage refuses an answer that is not a project's JSON with sizes, naming the URL, and appends nothing" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { got: h.rbf.Got, why: []const u8 };
    const cases = [_]Case{
        .{ .got = .{ .status = 500 }, .why = "GET " ++ TEST_URL ++ ": HTTP 500" },
        .{ .got = .{ .transport = error.ConnectionRefused }, .why = "GET " ++ TEST_URL ++ ": ConnectionRefused" },
        .{ .got = .too_large, .why = "GET " ++ TEST_URL ++ ": the answer is longer than 67108864 bytes" },
        .{ .got = .{ .body = @constCast("not json at all") }, .why = "GET " ++ TEST_URL ++ ": the answer is not the JSON of a project (" },
        .{ .got = .{ .body = @constCast("[]") }, .why = "GET " ++ TEST_URL ++ ": the answer is not the JSON of a project (" },
        .{ .got = .{ .body = @constCast("{\"info\":{}}") }, .why = "GET " ++ TEST_URL ++ ": the answer is not the JSON of a project (" },
        .{ .got = .{ .body = @constCast("{\"releases\":{\"0.1.0\":[{\"filename\":\"a.whl\"}]}}") }, .why = "GET " ++ TEST_URL ++ ": the answer is not the JSON of a project (" },
        .{ .got = .{ .body = @constCast("{\"releases\":{\"0.1.0\":[{\"size\":\"big\"}]}}") }, .why = "GET " ++ TEST_URL ++ ": the answer is not the JSON of a project (" },
    };
    for (cases) |c| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        var fake: h.Fake = undefined;
        const r = try storage(a, &tmp, "testpypi", "10", "90", &.{.{ .url = TEST_URL, .got = c.got }}, &fake);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(std.mem.startsWith(u8, r.err, try std.fmt.allocPrint(a, "pypi_smoke: FAILED: {s}", .{c.why})));
        try t.expect(std.mem.startsWith(u8, r.out, try std.fmt.allocPrint(a, "::error title=pypi::{s}", .{c.why})));
        try t.expect(!h.exists(&tmp, "summary.md"));
        try t.expect(!h.exists(&tmp, "gh.txt"));
    }
}

test "storage refuses a flag error with exit 2 before any request" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ok = [_][]const u8{ "--index", "testpypi", "--project", "komira", "--limit-gib", "10", "--over-percent", "90", "--summary", "/s", "--github-output", "/g" };
    const Case = struct { flag: []const u8, value: ?[]const u8 };
    const cases = [_]Case{
        .{ .flag = "--index", .value = "pipy" },
        .{ .flag = "--project", .value = "ko/mira" },
        .{ .flag = "--project", .value = "" },
        .{ .flag = "--limit-gib", .value = "0" },
        .{ .flag = "--limit-gib", .value = "1001" },
        .{ .flag = "--limit-gib", .value = "ten" },
        .{ .flag = "--over-percent", .value = "0" },
        .{ .flag = "--over-percent", .value = "101" },
        .{ .flag = "--over-percent", .value = "1.5" },
        .{ .flag = "--summary", .value = null },
        .{ .flag = "--github-output", .value = null },
        .{ .flag = "--index", .value = null },
    };
    for (cases) |c| {
        var args = std.ArrayList([]const u8).empty;
        var i: usize = 0;
        while (i < ok.len) : (i += 2) {
            if (std.mem.eql(u8, ok[i], c.flag)) {
                if (c.value) |v| {
                    try args.append(a, ok[i]);
                    try args.append(a, v);
                }
            } else {
                try args.append(a, ok[i]);
                try args.append(a, ok[i + 1]);
            }
        }
        var fake = h.Fake{ .alloc = a, .routes = &.{} };
        const r = try h.exec(a, args.items, &fake);
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expectEqualStrings("", r.out);
        try t.expect(r.err.len != 0);
        try t.expectEqual(@as(usize, 0), fake.urls.items.len);
    }
}
