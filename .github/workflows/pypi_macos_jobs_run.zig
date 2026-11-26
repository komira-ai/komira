//! Runs of the macOS arm64 wheel's nine jobs of pypi.yml, played from the workflow's own text by
//! pypi_workflow_play.zig (its header says which of GitHub's rules the play holds): for each event and
//! each answer of the indexes and the farm, which jobs run, which upload and which save a record, what
//! the verdict jobs print and whether the macOS chain ends green. Every play plays the whole file,
//! nineteen jobs, and holds the macOS assertions on `chain(.., .macos)`, the run as the macOS wheel's
//! chain sees it. The last cases play pypi.yml once for each pair of a Linux outcome and a macOS one and
//! hold the two chains independent: each chain's verdict, uploads and records are its own whatever the
//! other chain does, and the run is green exactly when both are. Part of //:pypi_workflow_cases
//! (pypi_macos_jobs_test.zig imports this file). A macOS push is one run with the Linux push now (one
//! workflow, one concurrency group): the queue of runs of that group is played in
//! pypi_workflow_run.zig ("two pushes while a run is going ..."); it plays the triggers and the groups,
//! which the two chains share, not the jobs of either.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const p_ = @import("pypi_workflow_play.zig");
const End = p_.End;
const Played = p_.Played;
const Message = p_.Message;

/// The run of the file as the macOS wheel's chain sees it.
fn play(ar: std.mem.Allocator, text: []const u8, case: p_.Case) !Played {
    return p_.chain(ar, try p_.play(ar, text, case), .macos);
}
const expanded = p_.expanded;
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
/// the Linux build and promote, for the plays of both chains
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
    const text = try reader.readWorkflow(ar);
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
    const text = try reader.readWorkflow(ar);
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
    const text = try reader.readWorkflow(ar);
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
    const text = try reader.readWorkflow(ar);
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
    const text = try reader.readWorkflow(ar);
    const stamp = "-c komira.package_stamp=<steps.stamp.outputs.build_number> -c komira.package_commit=<steps.stamp.outputs.source_commit> -c komira.package_timestamp_ms=<steps.stamp.outputs.timestamp_ms>";
    const lines = try expanded(ar, text, .{ .event = "push" }, "build-macos-arm64");
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:komira_wheel_macos_arm64[release] --out <runner.temp>/pypi-macos-arm64/built/komira.whl"));
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:wheel_install_test_macos_arm64"));
    try t.expect(reader.has(lines, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 " ++ stamp ++ " //python:wheel_libs_macos_arm64 //python:wheel_same_macos_arm64"));
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "build-macos-arm64", "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: github.ref == 'refs/heads/main' && (inputs.flavour || 'bundled') == 'bundled'\n"), .{ .event = "push", .ends = &.{MAC_NOTHING} }));
}

// ---- the two chains in one run -----------------------------------------------------------------------

/// One way a chain's run can end: how its jobs end, and whether the chain is then green.
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

fn joined(ar: std.mem.Allocator, a: []const End, b: []const End) ![]const End {
    return std.mem.concat(ar, End, &.{ a, b });
}

fn sameMessages(a: []const Message, b: []const Message) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.kind, y.kind) or !std.mem.eql(u8, x.title, y.title) or !std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn sameChain(a: Played, b: Played) bool {
    return a.green() == b.green() and sameNames(a.uploads, b.uploads) and sameNames(a.records, b.records) and sameMessages(a.messages, b.messages);
}

/// Plays `text` once for every pair of a Linux and a macOS outcome of `event` and returns what is
/// wrong with the first pair that breaks the independence of the chains, or null: the Linux view green
/// exactly when the Linux outcome is, the macOS view exactly when the macOS outcome is, the whole run
/// green exactly when both are, and each chain's uploads, records and messages the same as when the
/// other chain ends in its first (successful) outcome.
fn independence(ar: std.mem.Allocator, text: []const u8, event: []const u8, linux: []const Outcome, macos: []const Outcome) !?[]const u8 {
    for (linux) |l| {
        for (macos) |m| {
            const whole = try p_.play(ar, text, .{ .event = event, .ends = try joined(ar, l.ends, m.ends) });
            const lv = try p_.chain(ar, whole, .linux);
            const mv = try p_.chain(ar, whole, .macos);
            if (lv.green() != l.green) return try std.fmt.allocPrint(ar, "{s}, {s}: the Linux chain ended {s}", .{ l.what, m.what, if (lv.green()) "green" else "red" });
            if (mv.green() != m.green) return try std.fmt.allocPrint(ar, "{s}, {s}: the macOS chain ended {s}", .{ l.what, m.what, if (mv.green()) "green" else "red" });
            if (whole.green() != (l.green and m.green)) return try std.fmt.allocPrint(ar, "{s}, {s}: the run ended {s}", .{ l.what, m.what, if (whole.green()) "green" else "red" });
            const alone_l = try p_.chain(ar, try p_.play(ar, text, .{ .event = event, .ends = try joined(ar, l.ends, macos[0].ends) }), .linux);
            const alone_m = try p_.chain(ar, try p_.play(ar, text, .{ .event = event, .ends = try joined(ar, linux[0].ends, m.ends) }), .macos);
            if (!sameChain(lv, alone_l)) return try std.fmt.allocPrint(ar, "{s}, {s}: the Linux chain's uploads, records or messages changed with the macOS outcome", .{ l.what, m.what });
            if (!sameChain(mv, alone_m)) return try std.fmt.allocPrint(ar, "{s}, {s}: the macOS chain's uploads, records or messages changed with the Linux outcome", .{ l.what, m.what });
        }
    }
    return null;
}

fn expectIndependent(ar: std.mem.Allocator, text: []const u8, event: []const u8, linux: []const Outcome, macos: []const Outcome) !void {
    if (try independence(ar, text, event, linux, macos)) |why| {
        std.debug.print("{s} run: {s}\n", .{ event, why });
        return error.Coupled;
    }
}

test "a failure of one wheel's chain never changes the other's verdict, uploads, records or messages, for every pair of outcomes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    try expectIndependent(ar, text, "push", &LINUX_PUSH, &MACOS_PUSH);
    inline for (.{ "schedule", "workflow_dispatch" }) |event| {
        try expectIndependent(ar, text, event, &LINUX_PROMOTE, &MACOS_PROMOTE);
    }
}

test "the Linux wheel passed and the macOS build failed: the Linux wheel is uploaded and recorded, the run is red, and the error is named under the macOS title" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const whole = try p_.play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), MAC_BUILD_FAILED } });
    const lv = try p_.chain(ar, whole, .linux);
    try expectPlayed(lv, true, try all(ar, &.{ "build", "wheel-user-test", "testpypi", "testpypi-smoke", "testpypi-passed", "result-testpypi" }, "success"), &.{});
    try expectUploads(lv, &.{"testpypi"});
    try expectRecords(lv, &.{"testpypi-passed"});
    const mv = try p_.chain(ar, whole, .macos);
    try expectPlayed(mv, false, &.{.{ "result-testpypi-macos-arm64", "failure" }}, &.{MAC_BUILD_ERROR});
    try expectUploads(mv, &.{});
    try expectRecords(mv, &.{});
    try t.expect(!whole.green());
    // the Linux upload and record are in the whole run too, and the one error is the macOS one
    try expectUploads(whole, &.{"testpypi"});
    try expectRecords(whole, &.{"testpypi-passed"});
    try expectPlayed(whole, false, &.{}, &.{MAC_BUILD_ERROR});
}

test "a coupling of one chain to the other is caught by the pairs: a macOS upload that waits for the Linux build is skipped by its failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the macOS upload also needs the Linux build: a Linux build failure skips the macOS upload
    const macos_waits = try reader.inJob(ar, text, "testpypi-macos-arm64", "    needs: build-macos-arm64\n", "    needs: [build-macos-arm64, build]\n");
    const linux_failed = [_]End{.{ .job = "build", .result = "failure" }};
    const skipped = try p_.play(ar, macos_waits, .{ .event = "push", .ends = &(linux_failed ++ .{MAC_BUILT}) });
    try t.expectEqualStrings("skipped", skipped.resultOf("testpypi-macos-arm64"));
    const independent = try p_.play(ar, text, .{ .event = "push", .ends = &(linux_failed ++ .{MAC_BUILT}) });
    try t.expectEqualStrings("success", independent.resultOf("testpypi-macos-arm64"));
    // and the pairs refuse the edited file: the case that says how that upload ends names a skipped job
    try t.expectError(error.Unreadable, independence(ar, macos_waits, "push", &LINUX_PUSH, &MACOS_PUSH));
    // (a Linux job that needs a macOS job is refused by the text: release_macos_test.zig, checkPypiMacos)
    // the unedited file passes the same pairs
    try t.expect((try independence(ar, text, "push", &LINUX_PUSH, &MACOS_PUSH)) == null);
}
