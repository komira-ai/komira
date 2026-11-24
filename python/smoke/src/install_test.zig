//! The cases of the install step (install.zig) with a command runner in memory: the commands it runs, in order
//! and exactly, for each index and for a dist directory, how each failing step is reported, that only the install of komira is tried
//! again, and that the example's output is held to the expected file with the version and the ABI version put in.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const h = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const PIP = "W/venv/bin/python -m pip --isolated --disable-pip-version-check";
const FLAGS = " install --no-cache-dir --only-binary=:all:";
const PROBE = "import importlib.util as u; s = u.find_spec('modular'); print(list(s.submodule_search_locations or [s.origin]) if s else 'none')";
const EXPECTED = "0.1.7\n1001\nregistered readings\nTrue\n";

/// The scratch directory a case runs in: the example, its data, the expected file and the ABI table.
const Scene = struct {
    tmp: t.TmpDir,
    work: []const u8,
    opts: lib.install.Options,

    fn init(a: Alloc, index: lib.common.Index) !*Scene {
        return initSource(a, .{ .index = index });
    }

    fn initSource(a: Alloc, source: lib.install.Source) !*Scene {
        const s = try a.create(Scene);
        s.tmp = t.tmpDir(.{});
        try s.tmp.dir.makePath("in");
        try s.tmp.dir.writeFile(.{ .sub_path = "in/quickstart.py", .data = "print('x')\n" });
        try s.tmp.dir.writeFile(.{ .sub_path = "in/readings.parquet", .data = "PAR1" });
        try s.tmp.dir.writeFile(.{ .sub_path = "in/quickstart.expected", .data = "<version>\n<abi_version>\nregistered readings\nTrue\n" });
        try s.tmp.dir.writeFile(.{ .sub_path = "in/komira.tsv", .data = "version\t1.1\n# the rest of the table\n" });
        s.work = try h.path(a, &s.tmp, "work");
        const data = try a.alloc([]const u8, 1);
        data[0] = try h.path(a, &s.tmp, "in/readings.parquet");
        s.opts = .{
            .source = source,
            .python = "/py/python3.13",
            .example = try h.path(a, &s.tmp, "in/quickstart.py"),
            .expect = try h.path(a, &s.tmp, "in/quickstart.expected"),
            .data = data,
            .abi_table = try h.path(a, &s.tmp, "in/komira.tsv"),
            .work = s.work,
            .attempts = 3,
            .delay_ms = 0,
        };
        return s;
    }

    fn runner(self: *Scene, a: Alloc, rules: []const h.Rule) h.FakeRunner {
        return .{ .alloc = a, .work = self.work, .rules = rules };
    }
};

fn runWith(a: Alloc, why: *[]const u8, fake: *h.FakeRunner, s: *Scene, spec: h.WheelSpec, log: *std.Io.Writer) !void {
    const w = try h.built(a, spec);
    return lib.install.run(a, why, fake.runner(), s.opts, w, log);
}

fn expectCalls(want: []const []const u8, fake: *const h.FakeRunner) !void {
    try t.expectEqual(want.len, fake.calls.items.len);
    for (want, fake.calls.items) |w, got| try t.expectEqualStrings(w, got);
}

test "testpypi: the requirements come from PyPI first, then komira alone from TestPyPI with no dependencies" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{}, &log.writer);
    try expectCalls(&.{
        "/py/python3.13 -m venv W/venv",
        PIP ++ FLAGS ++ " --index-url https://pypi.org/simple/ mojo-compiler==1.0.0",
        PIP ++ FLAGS ++ " --no-deps --index-url https://test.pypi.org/simple/ komira==0.1.7",
        PIP ++ " check",
        PIP ++ " show komira",
        PIP ++ " freeze",
        "W/venv/bin/python -I -c " ++ PROBE,
        "W/venv/bin/python -I quickstart.py",
    }, &fake);
    try t.expectEqualStrings(s.work, fake.cwds.items[0]);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/run", .{s.work}), fake.cwds.items[7]);
}

test "testpypi: a wheel without requirements installs no requirements" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{ .requires_dist = &.{} }, &log.writer);
    try expectCalls(&.{
        "/py/python3.13 -m venv W/venv",
        PIP ++ FLAGS ++ " --no-deps --index-url https://test.pypi.org/simple/ komira==0.1.7",
        PIP ++ " check",
        PIP ++ " show komira",
        PIP ++ " freeze",
        "W/venv/bin/python -I -c " ++ PROBE,
        "W/venv/bin/python -I quickstart.py",
    }, &fake);
}

test "testpypi: every requirement is its own argument of the one requirements install" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{ .requires_dist = &.{ "alpha==1", "zeta>=2" } }, &log.writer);
    try t.expectEqualStrings(PIP ++ FLAGS ++ " --index-url https://pypi.org/simple/ alpha==1 zeta>=2", fake.calls.items[1]);
}

test "pypi: komira comes from PyPI plainly, with its dependencies" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{}, &log.writer);
    try expectCalls(&.{
        "/py/python3.13 -m venv W/venv",
        PIP ++ FLAGS ++ " --index-url https://pypi.org/simple/ komira==0.1.7",
        PIP ++ " check",
        PIP ++ " show komira",
        PIP ++ " freeze",
        "W/venv/bin/python -I -c " ++ PROBE,
        "W/venv/bin/python -I quickstart.py",
    }, &fake);
}

test "dist: the requirements come from PyPI first, then komira alone from the dist directory with no index and no dependencies" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.initSource(a, .{ .dist = "/runner/wheel/dist" });
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{}, &log.writer);
    try expectCalls(&.{
        "/py/python3.13 -m venv W/venv",
        PIP ++ FLAGS ++ " --index-url https://pypi.org/simple/ mojo-compiler==1.0.0",
        PIP ++ FLAGS ++ " --no-deps --no-index --find-links /runner/wheel/dist komira==0.1.7",
        PIP ++ " check",
        PIP ++ " show komira",
        PIP ++ " freeze",
        "W/venv/bin/python -I -c " ++ PROBE,
        "W/venv/bin/python -I quickstart.py",
    }, &fake);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/run", .{s.work}), fake.cwds.items[7]);
}

test "dist: a wheel without requirements reads no index at all" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.initSource(a, .{ .dist = "/runner/wheel/dist" });
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{ .requires_dist = &.{} }, &log.writer);
    try expectCalls(&.{
        "/py/python3.13 -m venv W/venv",
        PIP ++ FLAGS ++ " --no-deps --no-index --find-links /runner/wheel/dist komira==0.1.7",
        PIP ++ " check",
        PIP ++ " show komira",
        PIP ++ " freeze",
        "W/venv/bin/python -I -c " ++ PROBE,
        "W/venv/bin/python -I quickstart.py",
    }, &fake);
    for (fake.calls.items) |c| try t.expect(std.mem.indexOf(u8, c, "--index-url") == null);
}

test "dist: a wheel that does not install is refused with pip's stderr, and the example never runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.initSource(a, .{ .dist = "/runner/wheel/dist" });
    defer s.tmp.cleanup();
    s.opts.attempts = 1;
    const rules = [_]h.Rule{.{ .contains = "--find-links", .code = 1, .stderr = "ERROR: komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl is not a supported wheel on this platform.\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{ .requires_dist = &.{} }, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "install komira: `{s}/venv/bin/python -m pip --isolated --disable-pip-version-check install --no-cache-dir --only-binary=:all: --no-deps --no-index --find-links /runner/wheel/dist komira==0.1.7` exited with 1; last lines of stderr:\nERROR: komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl is not a supported wheel on this platform.", .{s.work}), why);
    // the venv and the one install; nothing after the install runs
    try t.expectEqual(@as(usize, 2), fake.calls.items.len);
}

test "the example and its data are copied into the run directory under their base names" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{}, &log.writer);
    try t.expectEqualStrings("print('x')\n", try h.readAll(a, &s.tmp, "work/run/quickstart.py"));
    try t.expectEqualStrings("PAR1", try h.readAll(a, &s.tmp, "work/run/readings.parquet"));
}

test "a virtual environment that cannot be made is refused naming the step, the command, the status and the stderr" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " -m venv ", .code = 1, .stderr = "Error: ensurepip is not available\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "create the virtual environment: `/py/python3.13 -m venv {s}/venv` exited with 1; last lines of stderr:\nError: ensurepip is not available", .{s.work}), why);
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "a command that is killed, or cannot be started, is refused as such" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    var why: []const u8 = "";
    var log = h.sink(a);

    const killed = [_]h.Rule{.{ .contains = " -m venv ", .code = null }};
    var f1 = s.runner(a, &killed);
    try t.expectError(error.Refused, runWith(a, &why, &f1, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "create the virtual environment: `/py/python3.13 -m venv {s}/venv` did not exit (killed by a signal); last lines of stderr:\n(nothing on stderr)", .{s.work}), why);

    // a second scene: the first run left its run directory in the first one's work directory
    const s2 = try Scene.init(a, lib.common.testpypi);
    defer s2.tmp.cleanup();
    const missing = [_]h.Rule{.{ .contains = " -m venv ", .spawn = error.FileNotFound }};
    var f2 = s2.runner(a, &missing);
    try t.expectError(error.Refused, runWith(a, &why, &f2, s2, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "create the virtual environment: `/py/python3.13 -m venv {s}/venv` could not run: FileNotFound", .{s2.work}), why);
}

test "an install of komira that fails every attempt is refused after the last, with the step's stderr" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "--no-deps", .code = 1, .stderr = "ERROR: No matching distribution found for komira==0.1.7\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    const cmd = try std.fmt.allocPrint(a, "{s}/venv/bin/python -m pip --isolated --disable-pip-version-check install --no-cache-dir --only-binary=:all: --no-deps --index-url https://test.pypi.org/simple/ komira==0.1.7", .{s.work});
    const failure = try std.fmt.allocPrint(a, "install komira: `{s}` exited with 1; last lines of stderr:\nERROR: No matching distribution found for komira==0.1.7", .{cmd});
    try t.expectEqualStrings(failure, why);
    // the venv, the requirements once, and komira three times
    try t.expectEqual(@as(usize, 5), fake.calls.items.len);
    try t.expect(std.mem.indexOf(u8, log.written(), try std.fmt.allocPrint(a, "attempt 1 of 3 failed, trying again: {s}\n", .{failure})) != null);
    try t.expect(std.mem.indexOf(u8, log.written(), try std.fmt.allocPrint(a, "attempt 2 of 3 failed, trying again: {s}\n", .{failure})) != null);
    try t.expect(std.mem.indexOf(u8, log.written(), "attempt 3 of 3") == null);
}

test "an install of komira that fails once and then succeeds goes on to the check" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "--no-deps", .code = 1, .stderr = "ERROR: not there yet\n", .times = 1 }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{}, &log.writer);
    try t.expectEqual(@as(usize, 9), fake.calls.items.len);
    try t.expectEqualStrings(PIP ++ " check", fake.calls.items[4]);
    try t.expect(std.mem.indexOf(u8, log.written(), "attempt 1 of 3 failed, trying again: install komira: ") != null);
    try t.expect(std.mem.indexOf(u8, log.written(), "attempt 2 of 3") == null);
}

test "an install of the requirements that fails is refused at once, without a second try" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "pypi.org/simple/ mojo-compiler", .code = 1, .stderr = "ERROR: Could not find a version\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expect(std.mem.startsWith(u8, why, "install the requirements from PyPI: `"));
    try t.expect(std.mem.endsWith(u8, why, "exited with 1; last lines of stderr:\nERROR: Could not find a version"));
    try t.expectEqual(@as(usize, 2), fake.calls.items.len);
}

test "a pip check that exits non-zero is refused with what it printed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " check", .code = 1, .stderr = "komira 0.1.7 requires mojo-compiler==1.0.0, which is not installed.\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    const cmd = try std.fmt.allocPrint(a, "{s}/venv/bin/python -m pip --isolated --disable-pip-version-check check", .{s.work});
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "check the installed requirements: `{s}` exited with 1; last lines of stderr:\nkomira 0.1.7 requires mojo-compiler==1.0.0, which is not installed.", .{cmd}), why);
    try t.expectEqual(@as(usize, 4), fake.calls.items.len);
}

test "an installed version other than the published one is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    fake.shown_version = "0.1.6";
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings("pip show komira reports version 0.1.6, not 0.1.7", why);
}

test "an example that prints other text is refused with the expected text, its output and its stderr in full" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "-I quickstart.py", .code = 0, .stdout = "0.1.7\n1002\nregistered readings\nTrue\n", .stderr = "a warning\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "quickstart.py printed other text than {s} says\nexpected:\n{s}\noutput:\n0.1.7\n1002\nregistered readings\nTrue\n\nstderr:\na warning\n", .{ s.opts.expect, EXPECTED }), why);
}

test "an example that exits non-zero is refused with the last lines of its stderr" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "-I quickstart.py", .code = 1, .stderr = "Traceback (most recent call last):\nkomira.KomiraError: no such file\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "run the example: `{s}/venv/bin/python -I quickstart.py` exited with 1; last lines of stderr:\nTraceback (most recent call last):\nkomira.KomiraError: no such file", .{s.work}), why);
}

test "a refusal shows only the last twelve lines of a long stderr" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var text = std.Io.Writer.Allocating.init(a);
    for (1..16) |i| try text.writer.print("line {d}\n\n", .{i});
    const tail = try lib.common.lastLines(a, text.written(), 12);
    try t.expect(std.mem.startsWith(u8, tail, "line 4\nline 5\n"));
    try t.expect(std.mem.endsWith(u8, tail, "line 15"));
    try t.expectEqualStrings("(nothing on stderr)", try lib.common.lastLines(a, " \n\r\n", 12));
}

test "the ABI version is major times a thousand plus minor from the first line of the table" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectEqual(@as(u32, 1001), try lib.install.abiVersion(a, &why, "komira.tsv", "version\t1.1\n# comment\n"));
    try t.expectEqual(@as(u32, 2013), try lib.install.abiVersion(a, &why, "komira.tsv", "version\t2.13\r\nmore\n"));
    try t.expectEqual(@as(u32, 1000), try lib.install.abiVersion(a, &why, "komira.tsv", "version\t1.0"));
}

test "a table whose first line is not version, a tab and major.minor is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "version 1.1", "version\t1", "version\t1.x", "# comment", "", "version\t1.1\textra", "version\t1.1000", "release\t1.1", "version\t1.1.2" };
    for (bad) |text| {
        var why: []const u8 = "";
        try t.expectError(error.Refused, lib.install.abiVersion(a, &why, "komira.tsv", text));
        const first = std.mem.sliceTo(text, '\n');
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "the first line of komira.tsv is '{s}', not `version<TAB><major>.<minor>`", .{first}), why);
    }
}

test "a malformed ABI table stops the install before any command runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    try s.tmp.dir.writeFile(.{ .sub_path = "in/komira.tsv", .data = "nothing useful\n" });
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "the first line of {s} is 'nothing useful', not `version<TAB><major>.<minor>`", .{s.opts.abi_table}), why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "the expected text has the version and the ABI version put in" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("v 0.1.7 abi 1001 0.1.7\n", try lib.install.expectedText(a, "v <version> abi <abi_version> <version>\n", "0.1.7", 1001));
}

test "a work directory that is not empty is refused and nothing runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("work");
    try s.tmp.dir.writeFile(.{ .sub_path = "work/old", .data = "x" });
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--work {s} is not empty", .{s.work}), why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "two files to copy with one base name are refused before any command runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("more");
    try s.tmp.dir.writeFile(.{ .sub_path = "more/readings.parquet", .data = "other" });
    const both = try a.alloc([]const u8, 2);
    both[0] = s.opts.data[0];
    both[1] = try h.path(a, &s.tmp, "more/readings.parquet");
    s.opts.data = both;
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings("two files to copy are named readings.parquet", why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "a data file that does not exist is refused naming it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const missing = try h.path(a, &s.tmp, "in/absent.parquet");
    const only = try a.alloc([]const u8, 1);
    only[0] = missing;
    s.opts.data = only;
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot copy {s} to {s}/run/absent.parquet: FileNotFound", .{ missing, s.work }), why);
}

test "an environment that holds a distribution besides komira is refused, naming what is installed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.testpypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = "komira==0.1.7\npyarrow==26.0.1\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{ .requires_dist = &.{} }, &log.writer));
    try t.expectEqualStrings("the environment holds other distributions than komira\nexpected:\nkomira==0.1.7\ninstalled:\nkomira==0.1.7\npyarrow==26.0.1\n", why);
    try t.expectEqual(@as(usize, 5), fake.calls.items.len);
}

test "an environment without komira in pip freeze is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = "" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings("the environment holds other distributions than komira and its requirements (mojo-compiler)\nexpected:\nkomira==0.1.7\nmojo-compiler==<any version>\ninstalled:\n", why);
}

test "an environment that holds komira and a requirement of the wheel at any version passes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = "komira==0.1.7\npyarrow==26.0.1\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{ .requires_dist = &.{"pyarrow>=25.0.1"} }, &log.writer);
    try t.expectEqual(@as(usize, 7), fake.calls.items.len);
}

test "a requirement is matched to its pip freeze line by normalised name, whatever its spelling, extras or marker" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = "komira==0.1.7\nfoo-bar==1.0\ntyping-extensions==4.12.0\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    const spec: h.WheelSpec = .{ .requires_dist = &.{ "Typing_Extensions>=4", "Foo.Bar[extra] ; python_version < \"3.12\"" } };
    try runWith(a, &why, &fake, s, spec, &log.writer);
    try t.expectEqual(@as(usize, 7), fake.calls.items.len);
}

test "a requirement that pip freeze does not list does not fail the freeze check" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    var fake = s.runner(a, &.{});
    var log = h.sink(a);
    var why: []const u8 = "";
    try runWith(a, &why, &fake, s, .{ .requires_dist = &.{"pyarrow>=25.0.1"} }, &log.writer);
}

test "a distribution that is neither komira nor a requirement is refused, naming the requirements, with expected and installed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = "komira==0.1.7\nnumpy==2.5.3\npyarrow==26.0.1\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{ .requires_dist = &.{"pyarrow>=25.0.1"} }, &log.writer));
    try t.expectEqualStrings("the environment holds other distributions than komira and its requirements (pyarrow)\nexpected:\nkomira==0.1.7\npyarrow==<any version>\ninstalled:\nkomira==0.1.7\nnumpy==2.5.3\npyarrow==26.0.1\n", why);
}

test "a pip freeze with komira at another version, or komira listed twice, is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var log = h.sink(a);
    const frozen = [_][]const u8{ "komira==0.1.6\npyarrow==26.0.1\n", "komira==0.1.7\nkomira==0.1.7\npyarrow==26.0.1\n", "pyarrow==26.0.1\n" };
    for (frozen) |text| {
        const s = try Scene.init(a, lib.common.pypi);
        defer s.tmp.cleanup();
        const rules = [_]h.Rule{.{ .contains = " freeze", .code = 0, .stdout = text }};
        var fake = s.runner(a, &rules);
        var why: []const u8 = "";
        try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{ .requires_dist = &.{"pyarrow>=25.0.1"} }, &log.writer));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "the environment holds other distributions than komira and its requirements (pyarrow)\nexpected:\nkomira==0.1.7\npyarrow==<any version>\ninstalled:\n{s}", .{text}), why);
    }
}

test "a pip freeze that fails is refused with its command" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = " freeze", .code = 2, .stderr = "boom\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expect(std.mem.startsWith(u8, why, "list the installed distributions: `"));
    try t.expect(std.mem.endsWith(u8, why, "exited with 2; last lines of stderr:\nboom"));
}

test "an importable modular package is refused, naming where it is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "find_spec", .code = 0, .stdout = "['/venv/lib/python3.13/site-packages/modular']\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expectEqualStrings("a modular package is importable in the environment: ['/venv/lib/python3.13/site-packages/modular']", why);
    try t.expectEqual(@as(usize, 6), fake.calls.items.len);
}

test "a modular probe that fails to run is refused with its command" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Scene.init(a, lib.common.pypi);
    defer s.tmp.cleanup();
    const rules = [_]h.Rule{.{ .contains = "find_spec", .code = 1, .stderr = "SyntaxError\n" }};
    var fake = s.runner(a, &rules);
    var log = h.sink(a);
    var why: []const u8 = "";
    try t.expectError(error.Refused, runWith(a, &why, &fake, s, .{}, &log.writer));
    try t.expect(std.mem.startsWith(u8, why, "look for a modular package: `"));
}
