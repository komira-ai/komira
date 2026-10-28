//! `gate mojo` (G1-G12 of docs/design/zig_gate_runner.md): usage, the
//! environment, arguments, the run directory, the working directory, the
//! marker and the banner. Each test names the row it holds and the defect it
//! catches; the supervised test is testkit's fixture.

const std = @import("std");
const kit = @import("testkit.zig");
const supervise = @import("supervise.zig");
const sys = @import("sys.zig");
const util = @import("util.zig");
const gate_mojo = @import("mojo.zig");

const label = "//x:y";

const Env = struct {
    a: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    real: []const u8,
    bb: []const u8,

    fn init() !*Env {
        const e = try std.heap.page_allocator.create(Env);
        e.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        e.a = e.arena.allocator();
        e.dir = try kit.tempDir(e.a);
        e.real = try std.fs.realpathAlloc(e.a, e.dir);
        e.bb = try kit.busybox(e.a);
        return e;
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        std.heap.page_allocator.destroy(e);
    }

    /// `gate mojo` of the fixture behaviour `what`, then `extra`.
    fn args(e: *Env, what: []const u8, extra: []const []const u8) ![]const []const u8 {
        var l = std.ArrayList([]const u8).empty;
        try l.appendSlice(e.a, &.{ "mojo", "--busybox", e.bb, "--runtime-lib", "rt/lib", "--label", label, "--test" });
        try l.append(e.a, try std.fmt.allocPrint(e.a, "root/bin/{s}", .{what}));
        try l.appendSlice(e.a, &.{ "--marker", "passed" });
        try l.appendSlice(e.a, extra);
        return l.items;
    }

    fn run(e: *Env, argv: []const []const u8, opts: kit.Opts) !kit.Result {
        return kit.runGate(e.a, e.dir, argv, opts);
    }

    fn path(e: *Env, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(e.a, "{s}/{s}", .{ e.dir, rel });
    }
};

/// The test's output inside the banner (between the `--- output` rule and
/// the closing rule).
fn output(err: []const u8) []const u8 {
    const head = "------------------------------------------------------------------ output\n";
    const i = std.mem.indexOf(u8, err, head) orelse return "";
    const rest = err[i + head.len ..];
    const j = std.mem.lastIndexOf(u8, rest, util.rule) orelse return rest;
    return rest[0..j];
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

fn lineWith(text: []const u8, prefix: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) return l[prefix.len..];
    return null;
}

// G1. Mutant: accept `--env` after `--arg` (the case "env after arg" turns
// red), or accept a leading zero in a number (the cap and deadline cases).
test "G1 usage: every bad command line exits 2 with its runner's message, and no marker" {
    const e = try Env.init();
    defer e.deinit();
    const Case = struct { argv: []const []const u8, msg: []const u8 };
    const cases = [_]Case{
        .{ .argv = &.{"mojo"}, .msg = "gate_runner: usage error" },
        .{ .argv = &.{ "mojo", "--busybox", "b", "--runtime-lib", "l", "--label", "x", "--test", "r/bin/t" }, .msg = "gate_runner: usage error" },
        .{ .argv = try e.args("exit", &.{ "--bogus", "1" }), .msg = "gate_runner: unknown argument --bogus" },
        .{ .argv = try e.args("exit", &.{"--env"}), .msg = "gate_runner: --env needs NAME=VALUE" },
        .{ .argv = try e.args("exit", &.{"--arg"}), .msg = "gate_runner: --arg needs a value" },
        .{ .argv = try e.args("exit", &.{ "--arg", "x", "--env", "A=b" }), .msg = "gate_runner: --env A=b after an --arg" },
        .{ .argv = try e.args("exit", &.{"--lib-dir"}), .msg = "gate_runner: --lib-dir needs a directory" },
        .{ .argv = try e.args("exit", &.{ "--arg", "x", "--lib-dir", "/d" }), .msg = "gate_runner: --lib-dir /d after an --arg" },
        .{ .argv = try e.args("exit", &.{ "--lib-dir", "" }), .msg = "gate_runner: --lib-dir '' is not one directory" },
        .{ .argv = try e.args("exit", &.{ "--lib-dir", "/a:/b" }), .msg = "gate_runner: --lib-dir '/a:/b' is not one directory" },
        .{ .argv = try e.args("exit", &.{ "--lib-dir", "/d", "--label", "again" }), .msg = "gate_runner: --label after an --env, --lib-dir or --arg" },
        .{ .argv = try e.args("exit", &.{ "--env", "1A=b" }), .msg = "gate_runner: --env 1A=b is not NAME=VALUE" },
        .{ .argv = try e.args("exit", &.{ "--env", "A" }), .msg = "gate_runner: --env A is not NAME=VALUE" },
        .{ .argv = try e.args("exit", &.{ "--env", "=b" }), .msg = "gate_runner: --env =b is not NAME=VALUE" },
        .{ .argv = try e.args("exit", &.{ "--env", "A-B=c" }), .msg = "gate_runner: --env A-B=c is not NAME=VALUE" },
        .{ .argv = try e.args("exit", &.{ "--label", "again" }), .msg = "gate_runner: --label given twice" },
        .{ .argv = try e.args("exit", &.{ "--mem-cap-mib", "0" }), .msg = "mem_cap: REFUSING: cap '0' is not a positive whole number of MiB" },
        .{ .argv = try e.args("exit", &.{ "--mem-cap-mib", "032" }), .msg = "mem_cap: REFUSING: cap '032' is not a positive whole number of MiB" },
        .{ .argv = try e.args("exit", &.{ "--mem-cap-mib", "" }), .msg = "mem_cap: REFUSING: cap '' is not a positive whole number of MiB" },
        .{ .argv = try e.args("exit", &.{ "--deadline-s", "30" }), .msg = "test_deadline: usage error" },
        .{ .argv = try e.args("exit", &.{ "--deadline-s", "030", "--runner-timeout-s", "90" }), .msg = "test_deadline: REFUSING: '030' is not a positive whole number of seconds" },
        .{ .argv = try e.args("exit", &.{ "--deadline-s", "30", "--runner-timeout-s", "9x" }), .msg = "test_deadline: REFUSING: '9x' is not a positive whole number of seconds" },
        .{ .argv = try e.args("exit", &.{ "--limit-s", "2" }), .msg = "gate_runner: usage error" },
        .{ .argv = try e.args("exit", &.{ "--limit-s", "02", "--limit-report", "coverage" }), .msg = "cov_run: the limit '02' is not a positive whole number of seconds" },
        .{ .argv = try e.args("exit", &.{ "--limit-s", "2", "--limit-report", "other" }), .msg = "gate_runner: --limit-report other: the only report is coverage" },
        .{ .argv = try e.args("exit", &.{ "--hang-limit-s", "0" }), .msg = "hang_limit: REFUSING: the limit '0' is not a positive whole number of seconds" },
        .{ .argv = try e.args("exit", &.{ "--hang-limit-s", "1800s" }), .msg = "hang_limit: REFUSING: the limit '1800s' is not a positive whole number of seconds" },
        .{ .argv = try e.args("exit", &.{ "--hang-limit-s", "5", "--deadline-s", "30", "--runner-timeout-s", "90" }), .msg = "gate_runner: usage error: --hang-limit-s is a limit of its own" },
        .{ .argv = try e.args("exit", &.{ "--hang-limit-s", "5", "--limit-s", "30", "--limit-report", "coverage" }), .msg = "gate_runner: usage error: --hang-limit-s is a limit of its own" },
        .{ .argv = &.{ "mojo", "--busybox", e.bb, "--runtime-lib", "l", "--label", label, "--test", "root/x", "--marker", "passed" }, .msg = "gate_runner: " },
    };
    for (cases) |c| {
        const r = try e.run(c.argv, .{});
        if (r.status != 2 or !std.mem.startsWith(u8, r.err, c.msg)) {
            std.debug.print("argv {s}: exit {d}, stderr {s}\n", .{ std.mem.join(std.heap.page_allocator, " ", c.argv) catch "", r.status, r.err });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(!kit.exists(try e.path("passed")));
    }
    // G2: the test must be <root>/bin/<name>.
    const r = try e.run(&.{ "mojo", "--busybox", e.bb, "--runtime-lib", "l", "--label", label, "--test", "root/x", "--marker", "passed" }, .{});
    try std.testing.expect(std.mem.endsWith(u8, r.err, "/root/x is not <root>/bin/<name>\n"));
    try std.testing.expectEqualStrings("gate: usage: gate mojo|rust|step <options> (README.md)\n", (try e.run(&.{}, .{})).err);
}

// G3. Mutant: drop LD_PRELOAD from the list (its case passes the run).
test "G3 reserved names: each of the ten is refused with exit 2" {
    const e = try Env.init();
    defer e.deinit();
    for ([_][]const u8{ "PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "TMPDIR", "TEST_TMPDIR", "HOME", "PWD" }) |n| {
        const kv = try std.fmt.allocPrint(e.a, "{s}=x", .{n});
        const r = try e.run(try e.args("exit", &.{ "--env", kv }), .{});
        const want = try std.fmt.allocPrint(e.a, "gate_runner: --env may not set {s}; the runner sets it\n", .{n});
        if (r.status != 2 or !std.mem.eql(u8, r.err, want)) {
            std.debug.print("--env {s}: exit {d}, stderr {s}\n", .{ kv, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
}

// G4. Mutant: read the label or the marker from the environment the test
// gets (the decoy cases turn red).
test "G4 isolation: no --env reaches the runner's own state" {
    const e = try Env.init();
    defer e.deinit();
    for ([_][]const u8{ "BIN=true", "BIN=root/bin/exit", "rc=0", "MARKER=decoy", "LABEL=decoy", "T=", "CWD=", "IFS=", "ENV=", "BB=", "RUNNER=" }) |kv| {
        // A failing test stays red, under its own label.
        const r = try e.run(try e.args("exit", &.{ "--env", kv, "--arg", "1" }), .{});
        if (r.status != 1 or std.mem.indexOf(u8, r.err, "GATED TEST FAILED: //x:y (exit 1)\n") == null) {
            std.debug.print("--env {s}: exit {d}, stderr {s}\n", .{ kv, r.status, r.err });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(!kit.exists(try e.path("passed")));
        try std.testing.expect(!kit.exists(try e.path("decoy")));
    }
    // A passing test writes its own label to its own marker.
    const r = try e.run(try e.args("exit", &.{ "--env", "MARKER=decoy", "--env", "LABEL=decoy", "--arg", "0" }), .{});
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("PASS //x:y\n", try kit.readFile(e.a, try e.path("passed")));
    try std.testing.expect(!kit.exists(try e.path("decoy")));
}

// G5. Mutant: replace only the first @KOMIRA_ACTION_DIR@ of a value.
test "G5 arguments: in order, exactly, every action-directory token replaced, none exported" {
    const e = try Env.init();
    defer e.deinit();
    const vals = [_][]const u8{ "--arg", "--pair=@KOMIRA_ACTION_DIR@/a,@KOMIRA_ACTION_DIR@/b", "--arg", "two words", "--arg", "SEEN_ARG=1" };
    const r = try e.run(try e.args("args", &vals), .{});
    try std.testing.expectEqual(@as(u8, 3), r.status);
    const want = try std.fmt.allocPrint(e.a, "[{s}/root/bin/args]\n[--pair={s}/a,{s}/b]\n[two words]\n[SEEN_ARG=1]\n", .{ e.real, e.real, e.real });
    try std.testing.expectEqualStrings(want, output(r.err));
    const r2 = try e.run(try e.args("env", &vals), .{});
    try std.testing.expect(!hasLine(output(r2.err), "SEEN_ARG=1"));
    try std.testing.expect(std.mem.indexOf(u8, output(r2.err), "two words") == null);
}

// G6. Mutants: a fixed directory name (the two runs share it), or no
// cleanup (the directories are left).
test "G6 run directory: each run its own empty TMPDIR under the action's directory, applets installed, gone after" {
    const e = try Env.init();
    defer e.deinit();
    var seen: [2][]const u8 = undefined;
    for (0..2) |i| {
        const r = try e.run(try e.args("rundir", &.{}), .{});
        try std.testing.expectEqual(@as(u8, 3), r.status);
        const out = output(r.err);
        const tmp = lineWith(out, "TMPDIR=").?;
        try std.testing.expectEqualStrings(tmp, lineWith(out, "TEST_TMPDIR=").?);
        const prefix = try std.fmt.allocPrint(e.a, "{s}/.komira_test.", .{e.real});
        try std.testing.expect(std.mem.startsWith(u8, tmp, prefix));
        try std.testing.expect(std.mem.endsWith(u8, tmp, "/tmp"));
        try std.testing.expect(hasLine(out, "entries 0"));
        try std.testing.expect(hasLine(out, "applets true"));
        seen[i] = try e.a.dupe(u8, tmp);
        try std.testing.expect(!kit.exists(std.fs.path.dirname(tmp).?));
    }
    try std.testing.expect(!std.mem.eql(u8, seen[0], seen[1]));
}

// G7. Mutant: drop the inherited environment (GATE_INHERITED is lost), or
// let an inherited PATH or HOME through.
test "G7 environment: the runner's five variables, the action's others, and each --env" {
    const e = try Env.init();
    defer e.deinit();
    const env = [_][]const u8{ "GATE_INHERITED=yes", "PATH=/nowhere", "HOME=/nohome", "TMPDIR=/notmp" };
    const r = try e.run(try e.args("rundir", &.{}), .{ .env = &env });
    const tmp_line = lineWith(output(r.err), "TMPDIR=") orelse {
        std.debug.print("exit {d}, stderr {s}\n", .{ r.status, r.err });
        return error.TestUnexpectedResult;
    };
    const run_dir = std.fs.path.dirname(tmp_line).?;
    const r2 = try e.run(try e.args("env", &.{ "--env", "SPACED=a b=c", "--env", "EMPTY=", "--env", "TWICE=1", "--env", "TWICE=2" }), .{ .env = &env });
    const out = output(r2.err);
    const run2 = std.fs.path.dirname(lineWith(out, "TMPDIR=").?).?;
    try std.testing.expect(std.mem.startsWith(u8, run_dir, e.real));
    for ([_][2][]const u8{
        .{ "PATH=", "/bin" },
        .{ "TMPDIR=", "/tmp" },
        .{ "TEST_TMPDIR=", "/tmp" },
        .{ "HOME=", "/home" },
    }) |kv| {
        const want = try std.fmt.allocPrint(e.a, "{s}{s}{s}", .{ kv[0], run2, kv[1] });
        if (!hasLine(out, want)) {
            std.debug.print("no line {s} in\n{s}\n", .{ want, out });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(hasLine(out, try std.fmt.allocPrint(e.a, "LD_LIBRARY_PATH={s}/rt/lib", .{e.real})));
    // G12: on macOS dyld reads DYLD_LIBRARY_PATH, set to the same directory.
    // Mutant (macOS): drop it from the environment the gate builds.
    try std.testing.expectEqual(sys.is_darwin, hasLine(out, try std.fmt.allocPrint(e.a, "DYLD_LIBRARY_PATH={s}/rt/lib", .{e.real})));
    for ([_][]const u8{ "GATE_INHERITED=yes", "SPACED=a b=c", "EMPTY=", "TWICE=2" }) |l| try std.testing.expect(hasLine(out, l));
    for ([_][]const u8{ "PATH=/nowhere", "HOME=/nohome", "TMPDIR=/notmp", "TWICE=1" }) |l| try std.testing.expect(!hasLine(out, l));
}

// G7b. Mutant: put the directories first on LD_LIBRARY_PATH (the compiler's lib must stay first), drop one, reverse them, leave a relative one relative
// (the test runs from another directory), or set DYLD_FALLBACK_LIBRARY_PATH with none given.
test "G7b system libraries: --lib-dir directories follow the compiler's lib in order; macOS puts them first in the fallback path" {
    const e = try Env.init();
    defer e.deinit();
    const none = try e.run(try e.args("env", &.{}), .{ .env = &.{"DYLD_FALLBACK_LIBRARY_PATH=/inherited"} });
    try std.testing.expect(hasLine(output(none.err), try std.fmt.allocPrint(e.a, "LD_LIBRARY_PATH={s}/rt/lib", .{e.real})));
    try std.testing.expect(hasLine(output(none.err), "DYLD_FALLBACK_LIBRARY_PATH=/inherited"));

    const r = try e.run(try e.args("env", &.{ "--env", "A=1", "--lib-dir", "/pinned/one", "--lib-dir", "rel/two" }), .{ .env = &.{"DYLD_FALLBACK_LIBRARY_PATH=/inherited"} });
    const out = output(r.err);
    try std.testing.expect(hasLine(out, try std.fmt.allocPrint(e.a, "LD_LIBRARY_PATH={s}/rt/lib:/pinned/one:{s}/rel/two", .{ e.real, e.real })));
    try std.testing.expect(hasLine(out, "A=1"));
    if (sys.is_darwin) {
        try std.testing.expect(hasLine(out, try std.fmt.allocPrint(e.a, "DYLD_FALLBACK_LIBRARY_PATH=/pinned/one:{s}/rel/two:/inherited", .{e.real})));
        try std.testing.expect(hasLine(out, try std.fmt.allocPrint(e.a, "DYLD_LIBRARY_PATH={s}/rt/lib", .{e.real})));
    } else {
        // Linux: the inherited fallback is nobody's business, and the variable is not rewritten.
        try std.testing.expect(hasLine(out, "DYLD_FALLBACK_LIBRARY_PATH=/inherited"));
    }
    // The same with no inherited fallback: dyld's own defaults follow the directories.
    const r2 = try e.run(try e.args("env", &.{ "--lib-dir", "/pinned/one" }), .{});
    if (sys.is_darwin) try std.testing.expect(hasLine(output(r2.err), "DYLD_FALLBACK_LIBRARY_PATH=/pinned/one:/usr/local/lib:/usr/lib"));
}

// G7c. Mutant: count a set-but-empty variable as set (a path then ends in an empty entry, which means the current directory), or match a longer name.
test "G7c inheritedValue: a set, non-empty value is returned; empty, unset and a longer name are not" {
    const env = [_][]const u8{ "A=1", "DYLD_FALLBACK_LIBRARY_PATH=", "B_LONG=2", "C=x:y" };
    try std.testing.expectEqualStrings("1", gate_mojo.inheritedValue(&env, "A").?);
    try std.testing.expectEqualStrings("x:y", gate_mojo.inheritedValue(&env, "C").?);
    try std.testing.expect(gate_mojo.inheritedValue(&env, "DYLD_FALLBACK_LIBRARY_PATH") == null);
    try std.testing.expect(gate_mojo.inheritedValue(&env, "B") == null);
    try std.testing.expect(gate_mojo.inheritedValue(&env, "NOPE") == null);
}

// G8. Mutant: run the test in the action's directory.
test "G8 working directory: <root>/share when it exists, else an empty one; never the action's; stdin empty" {
    const e = try Env.init();
    defer e.deinit();
    const r = try e.run(try e.args("where", &.{}), .{});
    const cwd = lineWith(output(r.err), "cwd ").?;
    try std.testing.expect(std.mem.startsWith(u8, cwd, try std.fmt.allocPrint(e.a, "{s}/.komira_test.", .{e.real})));
    try std.testing.expect(std.mem.endsWith(u8, cwd, "/share"));
    try std.testing.expect(hasLine(output(r.err), "stdin 0"));
    try std.fs.cwd().makePath(try e.path("root/share"));
    const r2 = try e.run(try e.args("where", &.{}), .{});
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, "{s}/root/share", .{e.real}), lineWith(output(r2.err), "cwd ").?);
    // G2: the root is cut at the LAST /bin/.
    try std.fs.cwd().makePath(try e.path("deep/bin/x/share"));
    var l = std.ArrayList([]const u8).empty;
    for (try e.args("where", &.{})) |x| try l.append(e.a, if (std.mem.eql(u8, x, "root/bin/where")) "deep/bin/x/bin/where" else x);
    const r3 = try e.run(l.items, .{});
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, "{s}/deep/bin/x/share", .{e.real}), lineWith(output(r3.err), "cwd ").?);
}

// G9. Mutants: a trailing space in the marker, or the marker written before
// the verdict (it exists after a red run).
test "G9 marker: exactly `PASS <label>\\n` on exit 0, nothing printed; nothing written on red" {
    const e = try Env.init();
    defer e.deinit();
    var argv = try e.args("exit", &.{ "--arg", "0" });
    var l = std.ArrayList([]const u8).empty;
    for (argv) |x| try l.append(e.a, if (std.mem.eql(u8, x, "passed")) "out/m.passed" else x);
    try std.fs.cwd().makePath(try e.path("out"));
    const r = try e.run(l.items, .{});
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqualStrings("PASS //x:y\n", try kit.readFile(e.a, try e.path("out/m.passed")));
    argv = try e.args("exit", &.{ "--arg", "4" });
    const red = try e.run(argv, .{});
    try std.testing.expectEqual(@as(u8, 4), red.status);
    try std.testing.expect(!kit.exists(try e.path("passed")));
    // /dev/null is a marker.
    var n = std.ArrayList([]const u8).empty;
    for (try e.args("exit", &.{ "--arg", "0" })) |x| try n.append(e.a, if (std.mem.eql(u8, x, "passed")) "/dev/null" else x);
    try std.testing.expectEqual(@as(u8, 0), (try e.run(n.items, .{})).status);
}

// G10, G11. Mutants: 65 `=`, or 77 taken as a pass.
test "G10 G11 banner: byte golden for exit 1 and 77 and deaths by SIGKILL and SIGABRT" {
    const e = try Env.init();
    defer e.deinit();
    const head = "==================================================================\nGATED TEST FAILED: //x:y (exit {d})\nThe library's package is not produced until this test passes.\n------------------------------------------------------------------ output\n";
    const tail = "==================================================================\n";
    // A final line with no newline runs into the closing rule, as busybox
    // tail and echo printed it.
    for ([_]u8{ 1, 77 }) |rc| {
        const rcs = try std.fmt.allocPrint(e.a, "{d}", .{rc});
        const r = try e.run(try e.args("lines", &.{ "--arg", "3", "--arg", "0", "--arg", rcs }), .{});
        try std.testing.expectEqual(rc, r.status);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, head ++ "line 1\nline 2\nline 3" ++ tail, .{rc}), r.err);
        try std.testing.expect(!kit.exists(try e.path("passed")));
    }
    for ([_][2]u8{ .{ 9, 137 }, .{ 6, 134 } }) |sr| {
        const s = try std.fmt.allocPrint(e.a, "{d}", .{sr[0]});
        const r = try e.run(try e.args("signal", &.{ "--arg", s }), .{});
        try std.testing.expectEqual(sr[1], r.status);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, head ++ tail, .{sr[1]}), r.err);
    }
    // The last 200 lines of a longer output.
    const r = try e.run(try e.args("lines", &.{ "--arg", "250", "--arg", "1", "--arg", "1" }), .{});
    const out = output(r.err);
    try std.testing.expect(std.mem.startsWith(u8, out, "line 51\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, "line 250\n"));
}

// The production exec (execve, no fixture): busybox's printenv as the test,
// by its applet name, so the environment and the status are the kernel's.
// Linux only: the macOS busybox front end (darwin/busybox.sh) has no
// printenv applet. There the welded tests of a darwin-arm64 Mojo library are
// this case: each is executed by the gate and loads its runtime libraries
// through DYLD_LIBRARY_PATH.
test "a real program: execve of the test, its status and the environment it sees" {
    if (!sys.is_linux) return error.SkipZigTest;
    const e = try Env.init();
    defer e.deinit();
    try std.fs.cwd().makePath(try e.path("root/bin"));
    try std.fs.cwd().symLink(e.bb, try e.path("root/bin/printenv"), .{});
    const setup = struct {
        fn f() void {
            supervise.plat.exec = supervise.realExec;
        }
    }.f;
    const r = try e.run(try e.args("printenv", &.{ "--env", "GATE_SEEN=yes", "--arg", "LD_LIBRARY_PATH", "--arg", "GATE_SEEN", "--arg", "GATE_NOT_SET" }), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 1), r.status);
    const want = try std.fmt.allocPrint(e.a, "{s}/rt/lib\nyes\n", .{e.real});
    try std.testing.expectEqualStrings(want, output(r.err));
    // A test that cannot be executed is red (127), not a pass.
    const r2 = try e.run(try e.args("missing", &.{}), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 127), r2.status);
}
