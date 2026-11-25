//! Runs of pypi.yml's Linux wheel chain, played from the workflow's own text by pypi_workflow_play.zig
//! (its header says which of GitHub's rules the play holds): for each event (a push to main, the daily
//! schedule, a manual run), each answer an index gives (`absent`, `same`, `differs`) and the failure of
//! a job, which jobs run, which upload and which save a record, what the two verdict jobs print and
//! whether the run ends green; whether a push of a set of paths starts a run; and which runs of a
//! sequence of events start, wait or are replaced. Every play here plays the whole file, nineteen jobs, the
//! macOS jobs with no end of their own (the build finds nothing built and its chain is green), and holds
//! the Linux assertions on `chain(.., .linux)`, the run as the Linux wheel's chain sees it; the last case
//! holds that the whole run is green exactly when the Linux chain is, with the macOS chain's default
//! outcome. Part of //:pypi_workflow_cases (pypi_workflow_test.zig imports this file). The macOS wheel's
//! chain and the two chains together are played in pypi_macos_jobs_run.zig.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const p_ = @import("pypi_workflow_play.zig");
const End = p_.End;
const Case = p_.Case;
const Message = p_.Message;

/// The run of the file as the Linux wheel's chain sees it.
fn play(ar: std.mem.Allocator, text: []const u8, case: Case) !p_.Played {
    return p_.chain(ar, try p_.play(ar, text, case), .linux);
}
const expanded = p_.expanded;
const pushStarts = p_.pushStarts;
const queue = p_.queue;
const arrive = p_.arrive;
const leave = p_.leave;
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
const BUILT = End{ .job = "build", .outputs = &.{.{ "version", V }} };
const PROMOTED = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", "" } } };
const PROMOTED_SKIPPING = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", NEWER } } };

fn linuxError(comptime text: []const u8) Message {
    return failure("pypi", text);
}

const ON_TESTPYPI = notice("pypi", "already on TestPyPI: komira " ++ V ++ " is on TestPyPI with the bytes built; nothing was uploaded, and the smoke passed");
const DIFFERS = notice("pypi", "bytes differ at the same version: a commit that changed only what the stamp ignores changed the wheel; a code commit raises the version");
const NOT_PROMOTED = notice("pypi", "not promoted: komira " ++ NEWER ++ " on TestPyPI has no record that its TestPyPI smoke passed (the smoke failed, or its run had not ended); komira " ++ V ++ " is the newest version that passed");
const PUBLISHED = notice("pypi", "already published: komira " ++ V ++ " is on PyPI with the bytes TestPyPI served; nothing was uploaded, and the PyPI smoke passed");
const STORAGE_PUSH = linuxError("an index holds over 80 percent of the size limit of komira (the summary of the job testpypi says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes");
const STORAGE_PROMOTE = linuxError("an index holds over 80 percent of the size limit of komira (the summary of the job promote says which): prune old versions on TestPyPI or ask for a higher limit, docs/ci.md, Storage on the indexes");

pub const PUSH_JOBS = [_][]const u8{ "build", "wheel-user-test", "testpypi", "testpypi-smoke", "testpypi-passed", "result-testpypi" };
pub const PROMOTE_JOBS = [_][]const u8{ "promote", "pypi", "pypi-smoke", "result-pypi" };

test "a push with a code change uploads to TestPyPI, smokes it and saves the record, and touches no PyPI job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const ends = [_]End{ BUILT, state("testpypi", "absent") };
    const p = try play(ar, text, .{ .event = "push", .ends = &ends });
    try expectPlayed(p, true, try all(ar, &PUSH_JOBS, "success"), &.{});
    try expectPlayed(p, true, try all(ar, &PROMOTE_JOBS, "skipped"), &.{});
    try expectUploads(p, &.{"testpypi"});
    try expectRecords(p, &.{"testpypi-passed"});
    // the half gates are what keep PyPI out of a push: without them the push would promote too
    const main_only = "    if: github.ref == 'refs/heads/main'\n";
    const promote_gate = "    if: github.ref == 'refs/heads/main' && github.event_name != 'push'\n";
    const open = try reader.inJob(ar, try reader.inJob(ar, text, "promote", promote_gate, main_only), "pypi", promote_gate, main_only);
    const both = ends ++ [_]End{ PROMOTED, state("pypi", "absent") };
    try expectUploads(try play(ar, open, .{ .event = "push", .ends = &both }), &.{ "testpypi", "pypi" });
}

test "a push that changes no code starts no run, and one that changes only what the stamp ignores uploads nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // documentation alone, at any depth: no run; one path of code with it: a run
    try t.expect(!try pushStarts(ar, text, &.{ "docs/ci.md", "docs/design/python_package.md", "python/README.md", "AGENTS.md" }));
    try t.expect(try pushStarts(ar, text, &.{ "docs/ci.md", "src/engine/plan.mojo" }));
    try t.expect(try pushStarts(ar, text, &.{"python/examples/quickstart.expected"}));
    try t.expect(try pushStarts(ar, text, &.{".github/workflows/pypi.yml"}));
    // without the `**.md` entry a README edit would start a run
    try t.expect(try pushStarts(ar, try reader.replaced(ar, text, "      - '**.md'\n", ""), &.{"python/README.md"}));
    // a push the stamp ignores but the filter lets through (a workflow file): the same version, `same`
    // on TestPyPI, nothing uploaded, the smoke and the record again, green with the notice
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same") } });
    try expectPlayed(p, true, &.{ .{ "testpypi-smoke", "success" }, .{ "testpypi-passed", "success" } }, &.{ON_TESTPYPI});
    try expectUploads(p, &.{});
    try expectRecords(p, &.{"testpypi-passed"});
    // an upload gate that lets `same` through would send the bytes again
    const weak = try reader.inJob(ar, text, "testpypi", "        if: steps.state.outputs.state == 'absent'\n", "        if: steps.state.outputs.state != 'differs'\n");
    try expectUploads(try play(ar, weak, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same") } }), &.{"testpypi"});
}

test "a push whose wheel differs at the same version uploads nothing, smokes nothing, saves no record, and is green with the notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "differs") } });
    try expectPlayed(p, true, &.{ .{ "testpypi-smoke", "skipped" }, .{ "testpypi-passed", "skipped" }, .{ "result-testpypi", "success" } }, &.{DIFFERS});
    try expectUploads(p, &.{});
    try expectRecords(p, &.{});
}

test "the daily run promotes the newest version that passed, naming the newer one that did not, and uploads it to PyPI alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED_SKIPPING, state("pypi", "absent") } });
    try expectPlayed(p, true, try all(ar, &PROMOTE_JOBS, "success"), &.{NOT_PROMOTED});
    try expectPlayed(p, true, try all(ar, &PUSH_JOBS, "skipped"), &.{NOT_PROMOTED});
    try expectUploads(p, &.{"pypi"});
    try expectRecords(p, &.{});
    // with nothing skipped there is no notice at all
    const q = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent") } });
    try expectPlayed(q, true, &.{}, &.{});
}

test "a day whose newest version did not pass publishes nothing and says why; a version already on PyPI is not uploaded again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the newest that passed is on PyPI already (`same`): no upload, the PyPI smoke runs, both notices
    inline for (.{ "schedule", "workflow_dispatch" }) |event| {
        const p = try play(ar, text, .{ .event = event, .ends = &.{ PROMOTED_SKIPPING, state("pypi", "same") } });
        try expectPlayed(p, true, &.{.{ "pypi-smoke", "success" }}, &.{ NOT_PROMOTED, PUBLISHED });
        try expectUploads(p, &.{});
    }
    // an upload gate that lets `same` through would upload a version PyPI holds
    const weak = try reader.inJob(ar, text, "pypi", "        if: steps.state.outputs.state == 'absent'\n", "        if: steps.state.outputs.state != 'differs'\n");
    try expectUploads(try play(ar, weak, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "same") } }), &.{"pypi"});
    // the notice gated on the promote job alone would claim a version PyPI was not asked about
    const loose = try reader.replaced(ar, text, "        if: needs.pypi.outputs.state == 'same'\n", "        if: needs.promote.result == 'success'\n");
    try expectPlayed(try play(ar, loose, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent") } }), true, &.{}, &.{PUBLISHED});
}

test "a promotion with no record, or one the promote job refused, publishes nothing and is red, naming the job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const p = try play(ar, text, .{ .event = "schedule", .ends = &.{.{ .job = "promote", .result = "failure" }} });
    try expectPlayed(p, false, &.{ .{ "pypi", "skipped" }, .{ "pypi-smoke", "skipped" }, .{ "result-pypi", "failure" } }, &.{linuxError("the promote job did not succeed (promote failure): nothing was published to PyPI; its log says why")});
    try expectUploads(p, &.{});
}

test "each failure of the promotion after the promote job ends the run red, names it, and prints no notice already published" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the upload job failed (an index error, or the upload refused)
    try expectPlayed(try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, .{ .job = "pypi", .result = "failure" } } }), false, &.{.{ "pypi-smoke", "skipped" }}, &.{linuxError("the PyPI upload job did not succeed (pypi failure)")});
    // PyPI holds the version with other bytes: nothing uploaded, no smoke, red
    const d = try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "differs") } });
    try expectPlayed(d, false, &.{.{ "pypi-smoke", "skipped" }}, &.{linuxError("PyPI holds komira " ++ V ++ " with other bytes than TestPyPI serves: nothing was uploaded and PyPI was not smoked")});
    try expectUploads(d, &.{});
    // the PyPI smoke failed after an upload
    try expectPlayed(try play(ar, text, .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), .{ .job = "pypi-smoke", .result = "failure" } } }), false, &.{}, &.{linuxError("the PyPI smoke job did not succeed (pypi-smoke failure)")});
}

test "two pushes while a run is going leave one waiting run, the newer; a push never replaces a waiting promotion" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // three merges: the first runs, the second waits and is replaced by the third, which runs next
    const merges = [_]Arrival{ arrive("push-1", "push"), arrive("push-2", "push"), arrive("push-3", "push"), leave("push-1") };
    const q = try queue(ar, text, &merges);
    try expectList("started", q.started, &.{ "push-1", "push-3" });
    try expectList("cancelled", q.cancelled, &.{"push-2"});
    // a promotion starts while a push runs, and a push that lands while a manual run waits replaces nothing
    const mixed = [_]Arrival{ arrive("push-1", "push"), arrive("daily", "schedule"), arrive("manual", "workflow_dispatch"), arrive("push-2", "push"), leave("daily"), leave("push-1") };
    const m = try queue(ar, text, &mixed);
    try expectList("started", m.started, &.{ "push-1", "daily", "manual", "push-2" });
    try expectList("cancelled", m.cancelled, &.{});
    // one group for both halves: a push that lands while a manual run waits would replace it
    const waiting = [_]Arrival{ arrive("daily", "schedule"), arrive("manual", "workflow_dispatch"), arrive("push-1", "push") };
    try expectList("cancelled", (try queue(ar, text, &waiting)).cancelled, &.{});
    const one = try reader.replaced(ar, text, "  group: pypi-${{ github.event_name == 'push' && 'testpypi' || 'promote' }}\n", "  group: pypi\n");
    try expectList("cancelled", (try queue(ar, one, &waiting)).cancelled, &.{"manual"});
    // cancelling in progress: the second merge would cut the first one's upload short
    const cut = try reader.replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: true\n");
    try expectList("cancelled", (try queue(ar, cut, merges[0..3])).cancelled, &.{ "push-1", "push-2" });
}

test "each failure of the push chain ends the run red, names the job, saves no record and prints no notice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    // the build fails: nothing after it runs
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{.{ .job = "build", .result = "failure" }} }), false, &.{ .{ "wheel-user-test", "skipped" }, .{ "testpypi", "skipped" }, .{ "result-testpypi", "failure" } }, &.{linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build failure, wheel-user-test skipped, testpypi skipped)")});
    // the state of TestPyPI could not be asked: the job failed, no state
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, .{ .job = "testpypi", .result = "failure" } } }), false, &.{.{ "testpypi-smoke", "skipped" }}, &.{linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build success, wheel-user-test success, testpypi failure)")});
    // the TestPyPI smoke fails on one Python: no record, so the version is never promoted
    const s = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" } } });
    try expectPlayed(s, false, &.{.{ "testpypi-passed", "skipped" }}, &.{linuxError("the TestPyPI smoke or the record job did not succeed (testpypi-smoke failure, testpypi-passed skipped): this version is never promoted to PyPI")});
    try expectRecords(s, &.{});
    try expectUploads(s, &.{"testpypi"});
    // a record job that did not wait for the smoke would record a version that failed it
    const early = try reader.inJob(ar, text, "testpypi-passed", "    needs: [build, testpypi-smoke]\n", "    needs: [build, testpypi]\n");
    try expectRecords(try play(ar, early, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" } } }), &.{"testpypi-passed"});
}

test "a wheel that failed its user test is not uploaded: TestPyPI is never asked, red, the job named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const failed = End{ .job = "wheel-user-test", .result = "failure" };
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, failed } });
    try expectPlayed(p, false, &.{ .{ "testpypi", "skipped" }, .{ "testpypi-smoke", "skipped" }, .{ "testpypi-passed", "skipped" }, .{ "result-testpypi", "failure" } }, &.{linuxError("the build, the user test of the wheel or the TestPyPI upload job did not succeed (build success, wheel-user-test failure, testpypi skipped)")});
    try expectUploads(p, &.{});
    // an upload that did not wait for the user test would send the failed wheel to TestPyPI
    const unguarded = try reader.inJob(ar, text, "testpypi", "    needs: [build, wheel-user-test]\n", "    needs: build\n");
    try expectUploads(try play(ar, unguarded, .{ .event = "push", .ends = &.{ BUILT, failed, state("testpypi", "absent") } }), &.{"testpypi"});
}

test "an index over 80 percent of its size limit ends a push run and a promotion red, the uploads still made" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const full = End{ .job = "testpypi", .outputs = &.{ .{ "state", "absent" }, .{ "testpypi_storage", "true" }, .{ "pypi_storage", "false" } } };
    const p = try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, full } });
    try expectPlayed(p, false, &.{.{ "result-testpypi", "failure" }}, &.{STORAGE_PUSH});
    try expectUploads(p, &.{"testpypi"});
    try expectRecords(p, &.{"testpypi-passed"});
    // PyPI over its limit, in the promotion
    const pfull = End{ .job = "promote", .outputs = &.{ .{ "version", V }, .{ "skipped", "" }, .{ "testpypi_storage", "false" }, .{ "pypi_storage", "true" } } };
    const q = try play(ar, text, .{ .event = "schedule", .ends = &.{ pfull, state("pypi", "absent") } });
    try expectPlayed(q, false, &.{.{ "result-pypi", "failure" }}, &.{STORAGE_PROMOTE});
    try expectUploads(q, &.{"pypi"});
    // under the limit on both: green
    const ok = End{ .job = "testpypi", .outputs = &.{ .{ "state", "absent" }, .{ "testpypi_storage", "false" }, .{ "pypi_storage", "false" } } };
    try expectPlayed(try play(ar, text, .{ .event = "push", .ends = &.{ BUILT, ok } }), true, &.{}, &.{});
}

test "a push builds the one wheel from the stamp; a read of an input is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const stamp = "-c komira.package_stamp=<steps.stamp.outputs.build_number> -c komira.package_commit=<steps.stamp.outputs.source_commit> -c komira.package_timestamp_ms=<steps.stamp.outputs.timestamp_ms>";
    const lines = try expanded(ar, text, .{ .event = "push" }, "build");
    try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:komira_wheel[release] --out <runner.temp>/pypi/built/komira.whl"));
    try t.expect(reader.has(lines, "          args: build " ++ stamp ++ " //python:wheel_install_test"));
    const ends = [_]End{ BUILT, state("testpypi", "absent") };
    try t.expectError(error.Unreadable, expanded(ar, try reader.replaced(ar, text, "//python:komira_wheel[release]", "//python:komira_wheel_${{ inputs.flavour || 'bundled' }}[release]"), .{ .event = "push" }, "build"));
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "testpypi", "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: github.ref == 'refs/heads/main' && (inputs.flavour || 'bundled') == 'bundled'\n"), .{ .event = "push", .ends = &ends }));
}

test "the plays refuse a workflow or a case they cannot read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const ok = Case{ .event = "push", .ends = &.{ BUILT, state("testpypi", "same") } };
    // a context it does not know, a job it does not need, a status function in a verdict step
    try t.expectError(error.Unreadable, play(ar, try reader.inJob(ar, text, "result-testpypi", "    if: always() && github.ref == 'refs/heads/main' && github.event_name == 'push'\n", "    if: always() && vars.X == 'y'\n"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "        if: needs.testpypi.outputs.state == 'differs'\n", "        if: needs.promote.outputs.version == 'differs'\n"), ok));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "        if: needs.build.result != 'success' || needs.wheel-user-test.result != 'success' || needs.testpypi.result != 'success'\n", "        if: failure()\n"), ok));
    // a verdict step that is not one echo, and an echo of a name the step's env does not hold
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "(pypi-smoke $PYPI_SMOKE)\" && exit 1'", "(pypi-smoke $PYPI_SMOKE)\"; exit 1'"), .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent"), .{ .job = "pypi-smoke", .result = "failure" } } }));
    try t.expectError(error.Unreadable, play(ar, try reader.replaced(ar, text, "komira $VERSION is on TestPyPI with", "komira $RELEASE is on TestPyPI with"), ok));
    // a case for a job the file lacks, or for a job that was skipped (a PyPI job in a push run)
    try t.expectError(error.Unreadable, play(ar, text, .{ .event = "push", .ends = &.{.{ .job = "publish" }} }));
    try t.expectError(error.Unreadable, play(ar, text, .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), state("pypi", "absent") } }));
    // a push filter pattern the play does not know, a concurrency line it does not know, a run ended twice
    try t.expectError(error.Unreadable, pushStarts(ar, try reader.replaced(ar, text, "      - '**.md'\n", "      - '!docs/keep.md'\n"), &.{"docs/x.md"}));
    try t.expectError(error.Unreadable, queue(ar, try reader.replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: ${{ false }}\n"), &.{arrive("a", "push")}));
    try t.expectError(error.Unreadable, queue(ar, text, &.{ arrive("a", "push"), leave("a"), leave("a") }));
}

test "the whole run is green exactly when the Linux chain is, with the macOS chain at its default outcome" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try reader.readWorkflow(ar);
    const cases = [_]Case{
        .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent") } },
        .{ .event = "push", .ends = &.{.{ .job = "build", .result = "failure" }} },
        .{ .event = "push", .ends = &.{ BUILT, state("testpypi", "absent"), .{ .job = "testpypi-smoke", .result = "failure" } } },
        .{ .event = "schedule", .ends = &.{ PROMOTED, state("pypi", "absent") } },
        .{ .event = "schedule", .ends = &.{.{ .job = "promote", .result = "failure" }} },
    };
    const green = [_]bool{ true, false, false, true, false };
    for (cases, green) |case, want| {
        const whole = try p_.play(ar, text, case);
        try t.expectEqual(want, (try p_.chain(ar, whole, .linux)).green());
        try t.expectEqual(want, whole.green());
        try t.expect((try p_.chain(ar, whole, .macos)).green());
    }
}
