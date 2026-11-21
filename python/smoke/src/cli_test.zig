//! The cases of the command line (cli.zig): each command's exit status (0 when it held, 1 when it refused or
//! failed, 2 for a usage error), what it prints and what it appends to the GitHub output file, the flags it
//! refuses by name (unknown, valueless, repeated, out of range), and that a usage error reaches neither the
//! index nor a command.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const h = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const JSON_URL = "https://test.pypi.org/pypi/komira/0.1.7/json";
const FILE = "komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl";
const FILE_URL = "https://test-files.pythonhosted.org/packages/ab/cd/" ++ FILE;
const USAGE = lib.cli.usage;

const Result = struct { code: u8, out: []const u8, err: []const u8 };

fn exec(a: Alloc, args: []const []const u8, fake: *h.Fake, runner: *h.FakeRunner) !Result {
    var out = h.sink(a);
    var err = h.sink(a);
    const code = try lib.cli.run(a, args, .{ .fetcher = fake.fetcher(), .runner = runner.runner() }, &out.writer, &err.writer);
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

/// A scratch directory with a dist directory holding the built wheel.
fn withDist(a: Alloc, tmp: *t.TmpDir, bytes: []const u8) ![]u8 {
    try tmp.dir.makePath("dist");
    try tmp.dir.writeFile(.{ .sub_path = "dist/" ++ FILE, .data = bytes });
    return h.path(a, tmp, "dist");
}

fn jsonRoutes(a: Alloc, listed: []const h.Listed, file: ?[]const u8) ![]h.Route {
    const list = try a.alloc(h.Route, if (file == null) 1 else 2);
    list[0] = .{ .url = JSON_URL, .got = .{ .body = try h.releaseJson(a, listed) } };
    if (file) |f| list[1] = .{ .url = FILE_URL, .got = .{ .body = @constCast(f) } };
    return list;
}

fn listedOf(a: Alloc, w: lib.meta.Wheel) !h.Listed {
    return .{ .file = FILE, .sha256 = try h.hex(a, w.bytes), .size = w.bytes.len, .url = FILE_URL };
}

// ---- dist -------------------------------------------------------------------------------

test "dist writes the named wheel alone into the output directory and appends version, file name and sha256" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try h.makeWheel(a, .{});
    try tmp.dir.writeFile(.{ .sub_path = "komira.whl", .data = bytes });
    try tmp.dir.writeFile(.{ .sub_path = "gh.txt", .data = "earlier=1\n" });
    const out_dir = try h.path(a, &tmp, "dist");
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "dist", "--wheel", try h.path(a, &tmp, "komira.whl"), "--out", out_dir, "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake, &runner);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    const hex = try h.hex(a, bytes);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: " ++ FILE ++ " ({d} bytes, sha256 {s}) is version 0.1.7 of komira; written to {s}\n", .{ bytes.len, hex, out_dir }), r.out);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "earlier=1\nversion=0.1.7\nfilename=" ++ FILE ++ "\nsha256={s}\n", .{hex}), try h.readAll(a, &tmp, "gh.txt"));
    try t.expectEqualSlices(u8, bytes, try h.readAll(a, &tmp, "dist/" ++ FILE));
    try t.expectEqual(@as(usize, 0), fake.urls.items.len);
}

test "dist refuses an output directory that is not empty, with exit 1, the failure line and the error annotation" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "komira.whl", .data = try h.makeWheel(a, .{}) });
    try tmp.dir.makePath("dist");
    try tmp.dir.writeFile(.{ .sub_path = "dist/old", .data = "x" });
    const out_dir = try h.path(a, &tmp, "dist");
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "dist", "--wheel", try h.path(a, &tmp, "komira.whl"), "--out", out_dir, "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: --out {s} is not empty\n", .{out_dir}), r.err);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "::error title=pypi::--out {s} is not empty\n", .{out_dir}), r.out);
    try t.expectError(error.FileNotFound, tmp.dir.access("gh.txt", .{}));
}

test "the error annotation is one line with percent signs escaped" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "dist", "--wheel", "/no/such%20dir/komira.whl", "--out", "/o", "--github-output", "/g" }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("pypi_smoke: FAILED: cannot read /no/such%20dir/komira.whl: FileNotFound\n", r.err);
    try t.expectEqualStrings("::error title=pypi::cannot read /no/such%2520dir/komira.whl: FileNotFound\n", r.out);
}

// ---- state ------------------------------------------------------------------------------

test "state appends absent, same or differs, and prints a notice for the last two" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try h.makeWheel(a, .{});
    const w = try h.built(a, .{});
    const theirs = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var other = try listedOf(a, w);
    other.sha256 = theirs;
    const Case = struct { listed: ?h.Listed, state: []const u8, out: []const u8 };
    const cases = [_]Case{
        .{ .listed = null, .state = "state=absent\n", .out = "pypi_smoke: " ++ FILE ++ " is not on testpypi: it is uploaded\n" },
        .{ .listed = try listedOf(a, w), .state = "state=same\n", .out = "::notice title=pypi::" ++ FILE ++ " is already on testpypi with the same sha256: no upload; the smoke runs\n" },
        .{ .listed = other, .state = "state=differs\n", .out = try std.fmt.allocPrint(a, "::notice title=pypi::" ++ FILE ++ " is on testpypi with sha256 {s}, not {s}: bytes differ at the same version: a commit that changed only documentation, which the stamp ignores; a code commit raises the version. No upload and no smoke.\n", .{ theirs, &w.sha256 }) },
    };
    for (cases) |c| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const dist = try withDist(a, &tmp, bytes);
        const routes: []const h.Route = if (c.listed) |l| try jsonRoutes(a, &.{l}, null) else &.{};
        var fake = h.Fake{ .alloc = a, .routes = routes };
        var runner = h.FakeRunner{ .alloc = a, .work = "" };
        const r = try exec(a, &.{ "state", "--index", "testpypi", "--dist", dist, "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake, &runner);
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expectEqualStrings(c.out, r.out);
        try t.expectEqualStrings("", r.err);
        try t.expectEqualStrings(c.state, try h.readAll(a, &tmp, "gh.txt"));
        try t.expectEqual(@as(usize, 1), fake.urls.items.len);
    }
}

test "state fails on an index error and appends no state" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try withDist(a, &tmp, try h.makeWheel(a, .{}));
    var fake = h.Fake{ .alloc = a, .routes = &.{.{ .url = JSON_URL, .got = .{ .status = 500 } }} };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "state", "--index", "testpypi", "--dist", dist, "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("pypi_smoke: FAILED: GET " ++ JSON_URL ++ ": HTTP 500\n", r.err);
    try t.expectEqualStrings("::error title=pypi::GET " ++ JSON_URL ++ ": HTTP 500\n", r.out);
    try t.expectError(error.FileNotFound, tmp.dir.access("gh.txt", .{}));
}

test "state refuses a dist directory with two files" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try h.makeWheel(a, .{});
    const dist = try withDist(a, &tmp, bytes);
    try tmp.dir.writeFile(.{ .sub_path = "dist/other-1.0-py3-none-any.whl", .data = bytes });
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "state", "--index", "pypi", "--dist", dist, "--github-output", try h.path(a, &tmp, "gh.txt") }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: --dist {s} holds 2 files; exactly one .whl is wanted\n", .{dist}), r.err);
    try t.expectEqual(@as(usize, 0), fake.urls.items.len);
}

// ---- verify -----------------------------------------------------------------------------

test "verify prints that the index serves the wheel as built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try h.makeWheel(a, .{});
    const w = try h.built(a, .{});
    const dist = try withDist(a, &tmp, bytes);
    var fake = h.Fake{ .alloc = a, .routes = try jsonRoutes(a, &.{try listedOf(a, w)}, bytes) };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "verify", "--index", "testpypi", "--dist", dist, "--attempts", "1", "--delay", "0" }, &fake, &runner);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: testpypi serves " ++ FILE ++ " as built (sha256 {s}, {d} bytes, METADATA Name, Version, Requires-Python and Requires-Dist equal)\n", .{ &w.sha256, bytes.len }), r.out);
    try t.expectEqualStrings("", r.err);
}

test "verify of tampered served bytes exits 1 and puts the whole refusal on one annotation line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try h.makeWheel(a, .{});
    const w = try h.built(a, .{});
    const tampered = try h.makeWheel(a, .{ .payload = "print('HELLO')\n" });
    const dist = try withDist(a, &tmp, bytes);
    var fake = h.Fake{ .alloc = a, .routes = try jsonRoutes(a, &.{try listedOf(a, w)}, tampered) };
    var runner = h.FakeRunner{ .alloc = a, .work = "" };
    const r = try exec(a, &.{ "verify", "--index", "testpypi", "--dist", dist, "--attempts", "1", "--delay", "0" }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    const head = "1 difference(s) between what testpypi serves and the wheel that was built:";
    const line = try std.fmt.allocPrint(a, FILE ++ ": the served bytes have sha256 {s} and size {d}; the built wheel has sha256 {s} and size {d}", .{ try h.hex(a, tampered), tampered.len, &w.sha256, bytes.len });
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: {s}\n  {s}\n", .{ head, line }), r.err);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "::error title=pypi::{s} | {s}\n", .{ head, line }), r.out);
}

// ---- install ----------------------------------------------------------------------------

test "install prints that pip installed komira and the example printed what the expected file says" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try withDist(a, &tmp, try h.makeWheel(a, .{}));
    try tmp.dir.makePath("in");
    try tmp.dir.writeFile(.{ .sub_path = "in/quickstart.py", .data = "print('x')\n" });
    try tmp.dir.writeFile(.{ .sub_path = "in/readings.parquet", .data = "PAR1" });
    try tmp.dir.writeFile(.{ .sub_path = "in/quickstart.expected", .data = "<version>\n<abi_version>\nregistered readings\nTrue\n" });
    try tmp.dir.writeFile(.{ .sub_path = "in/komira.tsv", .data = "version\t1.1\n" });
    const work = try h.path(a, &tmp, "work");
    const example = try h.path(a, &tmp, "in/quickstart.py");
    const expect = try h.path(a, &tmp, "in/quickstart.expected");
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = work };
    const data = try h.path(a, &tmp, "in/readings.parquet");
    const table = try h.path(a, &tmp, "in/komira.tsv");
    const r = try exec(a, &.{
        "install",     "--index",  "testpypi",       "--dist",  dist,
        "--python",    "/py/python3.13", "--example", example, "--expect",
        expect,        "--data",   data,             "--abi-table", table,
        "--work",      work,       "--attempts",     "2",       "--delay",
        "0",
    }, &fake, &runner);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    try t.expect(std.mem.endsWith(u8, r.out, try std.fmt.allocPrint(a, "pypi_smoke: pip installed komira==0.1.7 from testpypi into an empty environment and {s} printed what {s} says\n", .{ example, expect })));
    try t.expectEqual(@as(usize, 6), runner.calls.items.len);
}

test "install fails with exit 1 and the step's failure when a command fails" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try withDist(a, &tmp, try h.makeWheel(a, .{}));
    try tmp.dir.makePath("in");
    try tmp.dir.writeFile(.{ .sub_path = "in/quickstart.py", .data = "print('x')\n" });
    try tmp.dir.writeFile(.{ .sub_path = "in/readings.parquet", .data = "PAR1" });
    try tmp.dir.writeFile(.{ .sub_path = "in/quickstart.expected", .data = "x\n" });
    try tmp.dir.writeFile(.{ .sub_path = "in/komira.tsv", .data = "version\t1.1\n" });
    const work = try h.path(a, &tmp, "work");
    const rules = [_]h.Rule{.{ .contains = " -m venv ", .code = 3, .stderr = "no venv module\n" }};
    var fake = h.Fake{ .alloc = a, .routes = &.{} };
    var runner = h.FakeRunner{ .alloc = a, .work = work, .rules = &rules };
    const example = try h.path(a, &tmp, "in/quickstart.py");
    const expect = try h.path(a, &tmp, "in/quickstart.expected");
    const data = try h.path(a, &tmp, "in/readings.parquet");
    const table = try h.path(a, &tmp, "in/komira.tsv");
    const r = try exec(a, &.{
        "install", "--index",  "pypi",  "--dist",      dist,
        "--python", "/py/python3.13", "--example", example, "--expect",
        expect,    "--data",   data,    "--abi-table", table,
        "--work",  work,
    }, &fake, &runner);
    try t.expectEqual(@as(u8, 1), r.code);
    const why = try std.fmt.allocPrint(a, "create the virtual environment: `/py/python3.13 -m venv {s}/venv` exited with 3; last lines of stderr:\nno venv module", .{work});
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "pypi_smoke: FAILED: {s}\n", .{why}), r.err);
    try t.expect(std.mem.endsWith(u8, r.out, try std.fmt.allocPrint(a, "::error title=pypi::create the virtual environment: `/py/python3.13 -m venv {s}/venv` exited with 3; last lines of stderr: | no venv module\n", .{work})));
}

// ---- usage ------------------------------------------------------------------------------

test "a usage error is exit 2 with its message, and reaches neither the index nor a command" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { args: []const []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{}, .want = USAGE },
        .{ .args = &.{"frobnicate"}, .want = USAGE },
        .{ .args = &.{ "dist", "--wheel", "a", "--out", "b", "--github-output", "c", "--extra", "x" }, .want = "pypi_smoke: unknown argument --extra\n" ++ USAGE },
        .{ .args = &.{ "dist", "--index", "pypi" }, .want = "pypi_smoke: unknown argument --index\n" ++ USAGE },
        .{ .args = &.{ "dist", "--wheel" }, .want = "pypi_smoke: --wheel needs one value, given once\n" },
        .{ .args = &.{ "dist", "--wheel", "a", "--wheel", "b", "--out", "o", "--github-output", "g" }, .want = "pypi_smoke: --wheel needs one value, given once\n" },
        .{ .args = &.{ "dist", "--wheel", "a" }, .want = USAGE },
        .{ .args = &.{ "state", "--index", "testpypi", "--dist", "d" }, .want = USAGE },
        .{ .args = &.{ "verify", "--index", "testpypi" }, .want = USAGE },
        .{ .args = &.{ "verify", "--index", "testpypi", "--dist", "d", "--attempts", "0" }, .want = "pypi_smoke: --attempts is a number from 1 to 20\n" },
        .{ .args = &.{ "verify", "--index", "testpypi", "--dist", "d", "--attempts", "21" }, .want = "pypi_smoke: --attempts is a number from 1 to 20\n" },
        .{ .args = &.{ "verify", "--index", "testpypi", "--dist", "d", "--attempts", "many" }, .want = "pypi_smoke: --attempts is a number from 1 to 20\n" },
        .{ .args = &.{ "verify", "--index", "testpypi", "--dist", "d", "--delay", "301" }, .want = "pypi_smoke: --delay is a number of seconds from 0 to 300\n" },
        .{ .args = &.{ "verify", "--index", "testpypi", "--dist", "d", "--delay", "-1" }, .want = "pypi_smoke: --delay is a number of seconds from 0 to 300\n" },
        .{ .args = &.{ "verify", "--index", "npm", "--dist", "d" }, .want = "pypi_smoke: --index is testpypi or pypi\n" },
        .{ .args = &.{ "state", "--index", "", "--dist", "d", "--github-output", "g" }, .want = "pypi_smoke: --index is testpypi or pypi\n" },
        .{ .args = &.{ "install", "--index", "pip", "--dist", "d", "--python", "p", "--example", "e", "--expect", "x", "--data", "f", "--abi-table", "t", "--work", "w" }, .want = "pypi_smoke: --index is testpypi or pypi\n" },
        .{ .args = &.{ "install", "--index", "pypi", "--dist", "d", "--python", "p", "--example", "e", "--expect", "x", "--abi-table", "t", "--work", "w" }, .want = USAGE },
        .{ .args = &.{ "install", "--index", "pypi", "--dist", "d", "--python", "p", "--example", "e", "--expect", "x", "--abi-table", "t", "--work", "w", "--data" }, .want = "pypi_smoke: --data needs one value\n" },
    };
    for (cases) |c| {
        var fake = h.Fake{ .alloc = a, .routes = &.{} };
        var runner = h.FakeRunner{ .alloc = a, .work = "" };
        const r = try exec(a, c.args, &fake, &runner);
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expectEqualStrings(c.want, r.err);
        try t.expectEqualStrings("", r.out);
        try t.expectEqual(@as(usize, 0), fake.urls.items.len);
        try t.expectEqual(@as(usize, 0), runner.calls.items.len);
    }
}

test "the bounds of --attempts and --delay are accepted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { attempts: []const u8, delay: []const u8 };
    const cases = [_]Case{ .{ .attempts = "1", .delay = "0" }, .{ .attempts = "20", .delay = "300" } };
    for (cases) |c| {
        var fake = h.Fake{ .alloc = a, .routes = &.{} };
        var runner = h.FakeRunner{ .alloc = a, .work = "" };
        const r = try exec(a, &.{ "verify", "--index", "pypi", "--dist", "/no/such/dist", "--attempts", c.attempts, "--delay", c.delay }, &fake, &runner);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expectEqualStrings("pypi_smoke: FAILED: cannot open --dist /no/such/dist: FileNotFound\n", r.err);
    }
}
