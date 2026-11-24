//! Runs of pypi-macos-arm64.yml, the macOS arm64 wheel's publish workflow, played from its own text by
//! pypi_workflow_play.zig (its header says which of GitHub's rules the play holds), and runs of it side by
//! side with pypi.yml, the Linux wheel's: for each event and each answer of the indexes and the farm,
//! which jobs run, which upload and which save a record, what the verdict jobs print and whether each
//! workflow's run ends green; whether a push starts both or neither; and that the two workflows' runs
//! never wait on, replace or cancel each other. Part of //:pypi_macos_workflow_cases
//! (pypi_macos_workflow_test.zig imports this file).

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const p_ = @import("pypi_workflow_play.zig");
const End = p_.End;
const Played = p_.Played;
const Message = p_.Message;
const play = p_.play;
const expanded = p_.expanded;
const pushStarts = p_.pushStarts;
const queueOf = p_.queueOf;
const Arrival = p_.Arrival;
const state = p_.state;
const notice = p_.notice;
const failure = p_.failure;
const expectPlayed = p_.expectPlayed;
const expectList = p_.expectList;
const expectUploads = p_.expectUploads;
const expectRecords = p_.expectRecords;
const all = p_.all;

const V = "0.1.1513";
const NEWER = "0.1.1514";
/// the macOS build found its file on TestPyPI and built nothing
const MAC_NOTHING = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", "" }} };
const MAC_BUILT = End{ .job = "build-macos-arm64", .outputs = &.{.{ "version", V }} };
/// the macOS build failed: today, the farm has no Mac that runs build actions
const MAC_BUILD_FAILED = End{ .job = "build-macos-arm64", .result = "failure" };
const MAC_PROMOTED = End{ .job = "promote-macos-arm64", .outputs = &.{ .{ "version", V }, .{ "skipped", "" } } };
/// the Linux build and its TestPyPI answer, for the side-by-side plays
const BUILT = End{ .job = "build", .outputs = &.{.{ "version", V }} };
const PROMOTED = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", "" } } };

fn macError(comptime text: []const u8) Message {
    return failure("pypi-macos-arm64", text);
}

const MAC_ON_TESTPYPI = notice("pypi-macos-arm64", "the macOS wheel of this version is on TestPyPI already: nothing was built on the Macs");
const MAC_DIFFERS = notice("pypi-macos-arm64", "bytes differ at the same version: a commit that changed only what the stamp ignores changed the wheel; a code commit raises the version");
const MAC_PUBLISHED = notice("pypi-macos-arm64", "already published: the macOS wheel of komira " ++ V ++ " is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed");
const MAC_BUILD_ERROR = macError("the macOS build job did not succeed (build-macos-arm64 failure)");

const PUSH_JOBS = [_][]const u8{ "build-macos-arm64", "testpypi-macos-arm64", "testpypi-smoke-macos-arm64", "testpypi-passed-macos-arm64", "result-testpypi-macos-arm64" };
const PROMOTE_JOBS = [_][]const u8{ "promote-macos-arm64", "pypi-macos-arm64", "pypi-smoke-macos-arm64", "result-pypi-macos-arm64" };

test "a macOS push that builds the wheel uploads it to TestPyPI, smokes it and saves the record, and touches no PyPI job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readMacosWorkflow(ar);
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "absent") } });
    try expectPlayed(p, true, try all(ar, &PUSH_JOBS, "success"), &.{});
    try expectPlayed(p, true, try all(ar, &PROMOTE_JOBS, "skipped"), &.{});
    try expectUploads(p, &.{"testpypi-macos-arm64"});
    try expectRecords(p, &.{"testpypi-passed-macos-arm64"});
    // the upload gate that lets `same` through would send the bytes again
    const weak = try reader.inJob(ar, text, "testpypi-macos-arm64", "        if: steps.state.outputs.state == 'absent'\n", "        if: steps.state.outputs.state != 'differs'\n");
    try expectUploads(try play(ar, weak, .{ .event = "push", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "same") } }), &.{"testpypi-macos-arm64"});
}

test "a macOS push whose wheel is on TestPyPI already builds, uploads and records nothing and is green with the notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readMacosWorkflow(ar);
    const p = try play(ar, text, .{ .event = "push", .ends = &.{MAC_NOTHING} });
    try expectPlayed(p, true, &.{ .{ "testpypi-macos-arm64", "skipped" }, .{ "testpypi-smoke-macos-arm64", "skipped" }, .{ "testpypi-passed-macos-arm64", "skipped" }, .{ "result-testpypi-macos-arm64", "success" } }, &.{MAC_ON_TESTPYPI});
    try expectUploads(p, &.{});
    try expectRecords(p, &.{});
    // the same, with bytes that differ at the same version: no smoke, no record, the notice
    const d = try play(ar, text, .{ .event = "push", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "differs") } });
    try expectPlayed(d, true, &.{ .{ "testpypi-smoke-macos-arm64", "skipped" }, .{ "testpypi-passed-macos-arm64", "skipped" } }, &.{MAC_DIFFERS});
    try expectUploads(d, &.{});
    try expectRecords(d, &.{});
}

test "a failed macOS build or smoke ends the macOS run red, names the job and saves no record" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readMacosWorkflow(ar);
    const b = try play(ar, text, .{ .event = "push", .ends = &.{MAC_BUILD_FAILED} });
    try expectPlayed(b, false, &.{ .{ "testpypi-macos-arm64", "skipped" }, .{ "result-testpypi-macos-arm64", "failure" } }, &.{MAC_BUILD_ERROR});
    try expectUploads(b, &.{});
    try expectRecords(b, &.{});
    const s = try play(ar, text, .{ .event = "push", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "absent"), .{ .job = "testpypi-smoke-macos-arm64", .result = "failure" } } });
    try expectPlayed(s, false, &.{.{ "testpypi-passed-macos-arm64", "skipped" }}, &.{macError("the macOS TestPyPI smoke or the record job did not succeed (testpypi-smoke-macos-arm64 failure, testpypi-passed-macos-arm64 skipped): this macOS wheel is never promoted to PyPI")});
    try expectUploads(s, &.{"testpypi-macos-arm64"});
    try expectRecords(s, &.{});
    const u = try play(ar, text, .{ .event = "push", .ends = &.{ MAC_BUILT, .{ .job = "testpypi-macos-arm64", .result = "failure" } } });
    try expectPlayed(u, false, &.{.{ "testpypi-smoke-macos-arm64", "skipped" }}, &.{macError("the macOS TestPyPI upload job did not succeed (testpypi-macos-arm64 failure)")});
}

test "the macOS promotion uploads the newest macOS version that passed, names its skipped versions, refuses other bytes on PyPI, and prints already published only when nothing failed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readMacosWorkflow(ar);
    inline for (.{ "schedule", "workflow_dispatch" }) |event| {
        const q = try play(ar, text, .{ .event = event, .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "absent") } });
        try expectPlayed(q, true, try all(ar, &PROMOTE_JOBS, "success"), &.{});
        try expectPlayed(q, true, try all(ar, &PUSH_JOBS, "skipped"), &.{});
        try expectUploads(q, &.{"pypi-macos-arm64"});
        try expectRecords(q, &.{});
    }
    const mac_skipping = End{ .job = "promote-macos-arm64", .outputs = &.{ .{ "version", V }, .{ "skipped", NEWER } } };
    const skipped = notice("pypi-macos-arm64", "not promoted: the macOS wheel of komira " ++ NEWER ++ " on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira " ++ V ++ " is the newest version whose macOS wheel passed");
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{ mac_skipping, state("pypi-macos-arm64", "absent") } });
    try expectPlayed(p, true, &.{.{ "result-pypi-macos-arm64", "success" }}, &.{skipped});
    try expectUploads(p, &.{"pypi-macos-arm64"});
    const d = try play(ar, text, .{ .event = "schedule", .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "differs") } });
    try expectPlayed(d, false, &.{.{ "pypi-smoke-macos-arm64", "skipped" }}, &.{macError("PyPI holds the macOS wheel of komira " ++ V ++ " with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked")});
    try expectUploads(d, &.{});
    const s = try play(ar, text, .{ .event = "schedule", .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "same"), .{ .job = "pypi-smoke-macos-arm64", .result = "failure" } } });
    try expectPlayed(s, false, &.{}, &.{macError("the macOS PyPI smoke job did not succeed (pypi-smoke-macos-arm64 failure)")});
    // the version is on PyPI already: no upload, the smoke, the notice last
    const same = try play(ar, text, .{ .event = "schedule", .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "same") } });
    try expectPlayed(same, true, &.{.{ "pypi-smoke-macos-arm64", "success" }}, &.{MAC_PUBLISHED});
    try expectUploads(same, &.{});
    // no macOS record at all (no macOS wheel ever passed): nothing published, red, the job named
    const none = try play(ar, text, .{ .event = "schedule", .ends = &.{.{ .job = "promote-macos-arm64", .result = "failure" }} });
    try expectPlayed(none, false, &.{ .{ "pypi-macos-arm64", "skipped" }, .{ "result-pypi-macos-arm64", "failure" } }, &.{macError("the macOS promote job did not succeed (promote-macos-arm64 failure): no macOS wheel was published to PyPI; its log says why")});
    try expectUploads(none, &.{});
}

test "the macOS push builds the macOS wheel for darwin-arm64 from the stamp; a read of an input is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readMacosWorkflow(ar);
    const stamp = "-c komira.package_stamp=<steps.stamp.outputs.build_number> -c komira.package_commit=<steps.stamp.outputs.source_commit> -c komira.package_timestamp_ms=<steps.stamp.outputs.timestamp_ms>";
    const lines = try expanded(ar, text, .{ .event = "push" }, "build-macos-arm64");
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:komira_wheel_macos_arm64[release] --out <runner.temp>/pypi-macos-arm64/built/komira.whl"));
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:wheel_install_test_macos_arm64"));
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:wheel_libs_macos_arm64 //python:wheel_same_macos_arm64"));
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "build-macos-arm64", "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: github.ref == 'refs/heads/main' && (inputs.flavour || 'bundled') == 'bundled'\n"), .{ .event = "push", .ends = &.{MAC_NOTHING} }));
    // a case for a job of pypi.yml is a job this workflow does not have
    try t.expectError(error.Unreadable, play(ar, text, .{ .event = "push", .ends = &.{ MAC_NOTHING, BUILT } }));
}

// ---- the two workflows side by side ----------------------------------------------------------------

/// The run of each workflow for one event: pypi.yml's with `linux` ends, pypi-macos-arm64.yml's with `macos`.
const Two = struct { linux: Played, macos: Played };

fn playBoth(ar: std.mem.Allocator, linux_text: []const u8, macos_text: []const u8, event: []const u8, linux: []const End, macos: []const End) !Two {
    return .{
        .linux = try play(ar, linux_text, .{ .event = event, .ends = linux }),
        .macos = try play(ar, macos_text, .{ .event = event, .ends = macos }),
    };
}

/// One way a chain's run can end: how its jobs end, and whether the run is then green.
const Outcome = struct { what: []const u8, ends: []const End, green: bool };

const LINUX_PUSH = [_]Outcome{
    .{ .what = "the Linux wheel uploaded and passed", .ends = &.{ BUILT, state("testpypi", "absent") }, .green = true },
    .{ .what = "the Linux wheel on TestPyPI already", .ends = &.{ BUILT, state("testpypi", "same") }, .green = true },
    .{ .what = "the Linux build failed", .ends = &.{.{ .job = "build", .result = "failure" }}, .green = false },
    .{ .what = "the Linux user test failed", .ends = &.{ BUILT, .{ .job = "wheel-user-test", .result = "failure" } }, .green = false },
    .{ .what = "the Linux TestPyPI upload failed", .ends = &.{ BUILT, .{ .job = "testpypi", .result = "failure" } }, .green = false },
    .{ .what = "the Linux TestPyPI smoke failed", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" } }, .green = false },
};
const MACOS_PUSH = [_]Outcome{
    .{ .what = "the macOS wheel uploaded and passed", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "absent") }, .green = true },
    .{ .what = "the macOS wheel on TestPyPI already", .ends = &.{MAC_NOTHING}, .green = true },
    .{ .what = "the macOS build failed", .ends = &.{MAC_BUILD_FAILED}, .green = false },
    .{ .what = "the macOS TestPyPI smoke failed", .ends = &.{ MAC_BUILT, state("testpypi-macos-arm64", "absent"), .{ .job = "testpypi-smoke-macos-arm64", .result = "failure" } }, .green = false },
};
const LINUX_PROMOTE = [_]Outcome{
    .{ .what = "the Linux promotion published", .ends = &.{ PROMOTED, state("pypi", "absent") }, .green = true },
    .{ .what = "the Linux promotion found no record", .ends = &.{.{ .job = "promote", .result = "failure" }}, .green = false },
    .{ .what = "the Linux PyPI smoke failed", .ends = &.{ PROMOTED, state("pypi", "absent"), .{ .job = "pypi-smoke", .result = "failure" } }, .green = false },
};
const MACOS_PROMOTE = [_]Outcome{
    .{ .what = "the macOS promotion published", .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "absent") }, .green = true },
    .{ .what = "the macOS promotion found no record", .ends = &.{.{ .job = "promote-macos-arm64", .result = "failure" }}, .green = false },
    .{ .what = "the macOS PyPI smoke failed", .ends = &.{ MAC_PROMOTED, state("pypi-macos-arm64", "absent"), .{ .job = "pypi-smoke-macos-arm64", .result = "failure" } }, .green = false },
};

/// Plays every pair of a Linux and a macOS outcome of `event`: each workflow's run is green exactly
/// when its own chain's outcome is, whatever the other's is.
fn expectEachOwnVerdict(ar: std.mem.Allocator, linux_text: []const u8, macos_text: []const u8, event: []const u8, linux: []const Outcome, macos: []const Outcome) !void {
    for (linux) |l| {
        for (macos) |m| {
            const two = try playBoth(ar, linux_text, macos_text, event, l.ends, m.ends);
            if (two.linux.green() == l.green and two.macos.green() == m.green) continue;
            const got_linux: []const u8 = if (two.linux.green()) "green" else "red";
            const got_macos: []const u8 = if (two.macos.green()) "green" else "red";
            std.debug.print("{s}, {s}: pypi.yml's run ended {s}, pypi-macos-arm64.yml's {s}\n", .{ l.what, m.what, got_linux, got_macos });
            return error.WrongVerdict;
        }
    }
}

test "a push gives each wheel its own run: Linux green with the macOS build failing is one green run and one red; a Linux failure is red whatever macOS does" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const linux = try reader.readWorkflow(ar);
    const macos = try reader.readMacosWorkflow(ar);
    // the case of today: the Linux chain passed, the macOS build failed for want of a Mac
    const today = try playBoth(ar, linux, macos, "push", &.{ BUILT, state("testpypi", "absent") }, &.{MAC_BUILD_FAILED});
    try expectPlayed(today.linux, true, try all(ar, &.{ "build", "wheel-user-test", "testpypi", "testpypi-smoke", "testpypi-passed", "result-testpypi" }, "success"), &.{});
    try expectUploads(today.linux, &.{"testpypi"});
    try expectRecords(today.linux, &.{"testpypi-passed"});
    try expectPlayed(today.macos, false, &.{.{ "result-testpypi-macos-arm64", "failure" }}, &.{MAC_BUILD_ERROR});
    // both green: two green runs
    const both = try playBoth(ar, linux, macos, "push", &.{ BUILT, state("testpypi", "absent") }, &.{ MAC_BUILT, state("testpypi-macos-arm64", "absent") });
    try t.expect(both.linux.green() and both.macos.green());
    // every pair of outcomes, the push and the promotion
    try expectEachOwnVerdict(ar, linux, macos, "push", &LINUX_PUSH, &MACOS_PUSH);
    inline for (.{ "schedule", "workflow_dispatch" }) |event| {
        try expectEachOwnVerdict(ar, linux, macos, event, &LINUX_PROMOTE, &MACOS_PROMOTE);
    }
}

test "the macOS jobs back in pypi.yml would make a merge whose Linux wheel passed a red pypi.yml run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const linux = try reader.readWorkflow(ar);
    const macos = try reader.readMacosWorkflow(ar);
    // pypi.yml with the macOS file's jobs appended: the one-file shape the macOS workflow replaces
    const jobs_at = std.mem.indexOf(u8, macos, "\njobs:\n").? + "\njobs:\n".len;
    const joined = try std.mem.concat(ar, u8, &.{ linux, "\n", macos[jobs_at..] });
    const p = try play(ar, joined, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), MAC_BUILD_FAILED } });
    try expectPlayed(p, false, &.{ .{ "result-testpypi", "success" }, .{ "result-testpypi-macos-arm64", "failure" } }, &.{MAC_BUILD_ERROR});
    // the same answers played as the two files are: one green run and one red
    try expectEachOwnVerdict(ar, linux, macos, "push", LINUX_PUSH[0..1], MACOS_PUSH[2..3]);
}

test "a push that starts one workflow starts the other, and one that changes no code starts neither" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const linux = try reader.readWorkflow(ar);
    const macos = try reader.readMacosWorkflow(ar);
    const pushes = [_][]const []const u8{
        &.{ "docs/ci.md", "python/README.md", "AGENTS.md" },
        &.{ "docs/ci.md", "src/engine/plan.mojo" },
        &.{".github/workflows/pypi-macos-arm64.yml"},
        &.{".github/workflows/pypi.yml"},
        &.{"python/examples/quickstart.expected"},
    };
    const starts = [_]bool{ false, true, true, true, true };
    for (pushes, starts) |paths, want| {
        try t.expectEqual(want, try pushStarts(ar, linux, paths));
        try t.expectEqual(want, try pushStarts(ar, macos, paths));
    }
}

fn run(comptime name: []const u8, comptime event: []const u8, comptime file: usize) Arrival {
    return .{ .run = name, .event = event, .file = file };
}

fn done(comptime name: []const u8) Arrival {
    return .{ .run = name };
}

test "the two workflows' runs never wait on, replace or cancel each other; one shared group would" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const linux = try reader.readWorkflow(ar);
    const macos = try reader.readMacosWorkflow(ar);
    // two merges and a day: each workflow runs its first push and its promotion at once, and its second
    // push when its own first one ends
    const day = [_]Arrival{
        run("linux-push-1", "push", 0),    run("macos-push-1", "push", 1),
        run("linux-push-2", "push", 0),    run("macos-push-2", "push", 1),
        run("linux-daily", "schedule", 0), run("macos-daily", "schedule", 1),
        done("macos-push-1"),              done("linux-push-1"),
    };
    const q = try queueOf(ar, &.{ linux, macos }, &day);
    try expectList("started", q.started, &.{ "linux-push-1", "macos-push-1", "linux-daily", "macos-daily", "macos-push-2", "linux-push-2" });
    try expectList("cancelled", q.cancelled, &.{});
    // the macOS workflow in pypi.yml's group: its push waits behind the Linux one, and each newer push of
    // either replaces the other's waiting run
    const shared = try reader.replaced(ar, macos, "  group: pypi-macos-arm64-${{", "  group: pypi-${{");
    const s = try queueOf(ar, &.{ linux, shared }, day[0..4]);
    try expectList("started", s.started, &.{"linux-push-1"});
    try expectList("cancelled", s.cancelled, &.{ "macos-push-1", "linux-push-2" });
    // a run of a workflow the case does not give is refused
    try t.expectError(error.Unreadable, queueOf(ar, &.{linux}, &.{run("macos-push-1", "push", 1)}));
}
