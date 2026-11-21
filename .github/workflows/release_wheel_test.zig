//! The cases of the user test of the Python wheel in release.yml (the jobs `wheel` and `wheel-user-test`), part
//! of //:release_workflow_cases (release_workflow_test.zig imports this file). The workflow's own bytes are the
//! subject, with pypi.yml's beside them (the zig_test's data, under KOMIRA_TEST_WORK/workflows/). What they hold:
//!  - `wheel` builds on the farm the wheel pypi.yml publishes, as pypi.yml's `build` builds it: the target
//!    //python:komira_wheel[release] and the three stamp flags of `release_json stamp` of the run's commit are
//!    the same text in both files, then the install test and the driver with the same flags; it writes the
//!    test job's matrix for linux-x86_64 from the list of the supported Pythons it builds
//!    (//python:supported_pythons[linux-x86_64], python/pythons.bzl), and keeps the dist directory and the
//!    driver with the quickstart files as `wheel-<sha>-dist` and `wheel-<sha>-smoke`; it runs on
//!    ubuntu-24.04 in the environment `build` with `contents: read` and the `id-token: write` of farm-connect,
//!    at the batch class, with no `needs:` and no `if:` (every run of the workflow builds it);
//!  - `wheel-user-test` is the job wheel_user_test_job.zig holds, needing `wheel`, with no gate;
//!  - nothing of release.yml uploads to a Python index: no publish action, no twine, no index upload address,
//!    no environment `testpypi` or `pypi`; and no job continues on an error;
//!  - the order, played from the file's text (`play`): a job is played once the jobs it needs were, it runs
//!    when every job it needs succeeded, a job whose `if:` holds `failure()` runs only when a job it needs failed, `always()` runs
//!    whatever its needs did, every other gate is taken as true (a push to main), and a run is red when a job
//!    that does not continue on an error failed. A failed user test, or a failed wheel build, ends the run red
//!    and every job that is not a wheel job still runs and succeeds (the release set and the whole prod
//!    publish); a run in which every job succeeds is green. A merge that breaks the install is red here.

const std = @import("std");
const t = std.testing;
const reader = @import("pypi_workflow_text.zig");
const user_test = @import("wheel_user_test_job.zig");

const BUILD_JOB = "wheel";
const WHEEL_JOBS = [_][]const u8{ BUILD_JOB, user_test.JOB };
const USER_TEST = user_test.Spec{ .build_job = BUILD_JOB, .artifact = "wheel-${{ github.sha }}", .gate = null };

const STAMP_FLAGS = "-c komira.package_stamp=${{ steps.stamp.outputs.build_number }} -c komira.package_commit=${{ steps.stamp.outputs.source_commit }} -c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }}";
const WHEEL_TARGET = "//python:komira_wheel[release]";
const STAMP_RUN = "        run: '\"$RUNNER_TEMP/wheel/release_json\" stamp --revision \"$GITHUB_SHA\" --github-output \"$GITHUB_OUTPUT\"'";
const BUILD_LINES = [_][]const u8{
    "    runs-on: ubuntu-24.04",
    "    environment: build",
    "      contents: read",
    "      id-token: write",
    "      matrix: ${{ steps.matrix.outputs.matrix }}",
    "          fetch-depth: 0",
    "      - uses: ./.github/actions/farm-connect",
    "          farm-qos: batch",
    "          args: build //release/ci:release_json --out ${{ runner.temp }}/wheel/release_json",
    "        id: stamp",
    STAMP_RUN,
    "          args: build " ++ STAMP_FLAGS ++ " " ++ WHEEL_TARGET ++ " --out ${{ runner.temp }}/wheel/built/komira.whl",
    "          args: build " ++ STAMP_FLAGS ++ " //python:wheel_install_test",
    "          args: build " ++ STAMP_FLAGS ++ " //python/smoke:pypi_smoke --out ${{ runner.temp }}/wheel/smoke/pypi_smoke",
    "        run: '\"$RUNNER_TEMP/wheel/smoke/pypi_smoke\" dist --wheel \"$RUNNER_TEMP/wheel/built/komira.whl\" --out \"$RUNNER_TEMP/wheel/dist\" --github-output \"$GITHUB_OUTPUT\"'",
    "        run: cp python/examples/quickstart.py python/examples/quickstart.expected python/examples/readings.parquet src/so/abi/komira.tsv \"$RUNNER_TEMP/wheel/smoke/\"",
    "        id: matrix",
    "          args: build //python:supported_pythons[linux-x86_64] --out ${{ runner.temp }}/wheel/pythons.json",
    "        run: '\"$RUNNER_TEMP/wheel/smoke/pypi_smoke\" matrix --pythons \"$RUNNER_TEMP/wheel/pythons.json\" --platform linux-x86_64 --github-output \"$GITHUB_OUTPUT\"'",
    "          name: wheel-${{ github.sha }}-dist",
    "          path: ${{ runner.temp }}/wheel/dist",
    "          name: wheel-${{ github.sha }}-smoke",
    "          path: ${{ runner.temp }}/wheel/smoke",
};
/// What no line of release.yml outside a comment may hold: an upload to a Python index, an error that does
/// not fail its job.
const NO_INDEX_UPLOAD = [_][]const u8{ "gh-action-pypi-publish", "twine", "test.pypi.org", "upload.pypi.org", "environment: testpypi", "environment: pypi", "continue-on-error" };

fn readData(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "workflows", name });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

fn isComment(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    return trimmed.len == 0 or trimmed[0] == '#';
}

/// The `args:` line of the build of WHEEL_TARGET in `job`, up to its ` --out `: the target and the flags.
fn wheelBuild(job: []const []const u8) ?[]const u8 {
    for (job) |l| {
        if (!std.mem.startsWith(u8, l, "          args: build ") or std.mem.indexOf(u8, l, WHEEL_TARGET) == null) continue;
        const out = std.mem.indexOf(u8, l, " --out ") orelse return l;
        return l[0..out];
    }
    return null;
}

/// Null if the wheel jobs of release.yml hold their contract (pypi.yml's text beside it), else the refusal.
fn check(ar: std.mem.Allocator, text: []const u8, pypi: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        for (NO_INDEX_UPLOAD) |w| {
            if (std.mem.indexOf(u8, line, w) != null) return try std.fmt.allocPrint(ar, "release.yml names \"{s}\" outside a comment: it uploads to no Python index and no job continues on an error", .{w});
        }
    }
    for (WHEEL_JOBS) |name| {
        var n: usize = 0;
        _ = try reader.jobLines(ar, text, name, &n);
        if (n != 1) return try std.fmt.allocPrint(ar, "release.yml does not define the job {s} exactly once", .{name});
    }

    var n: usize = 0;
    const build = (try reader.jobLines(ar, text, BUILD_JOB, &n)).?;
    for (BUILD_LINES) |l| {
        if (!reader.has(build, l)) return try std.fmt.allocPrint(ar, "wheel: the farm build of the stamped wheel, its install test, the driver, the matrix and the two artifacts: the line `{s}` is missing", .{std.mem.trim(u8, l, " ")});
    }
    if (reader.countPrefix(build, "    needs:") != 0 or reader.countPrefix(build, "    if:") != 0) return "wheel: it has a needs: or an if: (every run of the workflow builds the wheel, apart from the other jobs)";
    if (permCount(build) != 2) return "wheel: its permissions are not exactly contents: read and id-token: write";
    if (reader.countMentions(build, "komira.package_stamp=") != 3) return "wheel: the wheel, the install test and the driver are not each built with the stamp flags";
    if (reader.countMentions(build, "actions/upload-artifact@") != 2 or reader.countPrefix(build, "          if-no-files-found: error") != 2) return "wheel: it does not keep exactly the dist and the smoke artifacts, each failing when empty";

    // the same wheel as pypi.yml's: the target and the stamp flags of its build, and the stamp itself
    var pn: usize = 0;
    const pypi_build = (try reader.jobLines(ar, pypi, "build", &pn)) orelse return "pypi.yml has no job build";
    const ours = wheelBuild(build).?;
    const theirs = wheelBuild(pypi_build) orelse return "pypi.yml's build does not build " ++ WHEEL_TARGET;
    if (!std.mem.eql(u8, ours, theirs)) return try std.fmt.allocPrint(ar, "wheel: the wheel is not built as pypi.yml's build builds it: `{s}` here, `{s}` there", .{ std.mem.trim(u8, ours, " "), std.mem.trim(u8, theirs, " ") });
    if (!reader.mentions(pypi_build, "_json\" stamp --revision \"$GITHUB_SHA\" --github-output \"$GITHUB_OUTPUT\"'")) return "pypi.yml's build stamps another revision than the run's commit";

    var un: usize = 0;
    const test_job = (try reader.jobLines(ar, text, user_test.JOB, &un)).?;
    if (try user_test.check(ar, test_job, USER_TEST)) |why| return why;

    // nothing waits on the wheel jobs or reads their result
    for (try reader.jobNames(ar, text)) |name| {
        var jn: usize = 0;
        const job = (try reader.jobLines(ar, text, name, &jn)).?;
        for (WHEEL_JOBS) |w| {
            if (std.mem.eql(u8, name, user_test.JOB) and std.mem.eql(u8, w, BUILD_JOB)) continue;
            const reads = try std.fmt.allocPrint(ar, "needs.{s}.", .{w});
            for (job) |l| {
                if (std.mem.startsWith(u8, l, "    needs:")) {
                    var tok = std.mem.tokenizeAny(u8, l["    needs:".len..], " ,[]");
                    while (tok.next()) |item| if (std.mem.eql(u8, item, w)) return try std.fmt.allocPrint(ar, "{s} needs {s}: no job waits on the user test of the wheel", .{ name, w });
                }
                if (std.mem.indexOf(u8, l, reads) != null) return try std.fmt.allocPrint(ar, "{s} reads the result of {s}: no job waits on the user test of the wheel", .{ name, w });
            }
        }
    }
    return try checkPlayed(ar, text);
}

/// The number of lines under the job's `    permissions:` key.
fn permCount(job: []const []const u8) usize {
    var inside = false;
    var n: usize = 0;
    for (job) |l| {
        if (std.mem.eql(u8, l, "    permissions:")) {
            inside = true;
            continue;
        }
        if (!inside) continue;
        if (std.mem.startsWith(u8, l, "      ") and !std.mem.startsWith(u8, l, "      - ")) n += 1 else break;
    }
    return n;
}

// ---- the play ------------------------------------------------------------------------------------

const Done = struct { name: []const u8, result: []const u8 };

const Played = struct {
    jobs: []const Done,
    green: bool,

    fn resultOf(self: Played, name: []const u8) []const u8 {
        for (self.jobs) |d| if (std.mem.eql(u8, d.name, name)) return d.result;
        return "(no such job)";
    }
};

fn needsOf(ar: std.mem.Allocator, job: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (job) |l| {
        if (!std.mem.startsWith(u8, l, "    needs:")) continue;
        var tok = std.mem.tokenizeAny(u8, l["    needs:".len..], " ,[]");
        while (tok.next()) |item| try out.append(ar, item);
    }
    return out.toOwnedSlice(ar);
}

fn gateHas(job: []const []const u8, word: []const u8) bool {
    for (job) |l| {
        if (std.mem.startsWith(u8, l, "    if: ") and std.mem.indexOf(u8, l, word) != null) return true;
    }
    return false;
}

/// A run of release.yml (the header's rules) in which the jobs of `failing` fail when they run. A job is played
/// once every job it needs was (GitHub reads `needs:` in any order); a job that needs one the file lacks, or a
/// cycle, is refused.
fn play(ar: std.mem.Allocator, text: []const u8, failing: []const []const u8) !Played {
    var done = std.ArrayList(Done).empty;
    var green = true;
    const names = try reader.jobNames(ar, text);
    while (done.items.len < names.len) {
        var progressed = false;
        for (names) |name| {
            if (doneResult(done.items, name) != null) continue;
            var n: usize = 0;
            const job = (try reader.jobLines(ar, text, name, &n)).?;
            var all_ok = true;
            var any_failed = false;
            var ready = true;
            for (try needsOf(ar, job)) |need| {
                const r = doneResult(done.items, need) orelse {
                    ready = false;
                    break;
                };
                all_ok = all_ok and std.mem.eql(u8, r, "success");
                any_failed = any_failed or std.mem.eql(u8, r, "failure");
            }
            if (!ready) continue;
            progressed = true;
            const runs = if (gateHas(job, "failure()")) any_failed else if (gateHas(job, "always()")) true else all_ok;
            if (!runs) {
                try done.append(ar, .{ .name = name, .result = "skipped" });
                continue;
            }
            var fails = false;
            for (failing) |f| fails = fails or std.mem.eql(u8, f, name);
            try done.append(ar, .{ .name = name, .result = if (fails) "failure" else "success" });
            if (fails and !reader.has(job, "    continue-on-error: true")) green = false;
        }
        if (!progressed) {
            std.debug.print("the play cannot read release.yml: a job needs one the file lacks, or the needs make a cycle\n", .{});
            return error.Unreadable;
        }
    }
    return .{ .jobs = try done.toOwnedSlice(ar), .green = green };
}

fn doneResult(done: []const Done, name: []const u8) ?[]const u8 {
    for (done) |d| if (std.mem.eql(u8, d.name, name)) return d.result;
    return null;
}

fn isWheelJob(name: []const u8) bool {
    for (WHEEL_JOBS) |w| if (std.mem.eql(u8, w, name)) return true;
    return false;
}

/// Null if a failed user test and a failed wheel build each end the run red and hold back no other job, and a
/// run of successes is green; else the refusal.
fn checkPlayed(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    for (WHEEL_JOBS) |failed| {
        const p = try play(ar, text, &.{failed});
        if (p.green) return try std.fmt.allocPrint(ar, "a run in which {s} fails ends green: a merge that breaks the wheel would leave main green", .{failed});
        for (p.jobs) |d| {
            if (isWheelJob(d.name) or std.mem.eql(u8, d.result, "success")) continue;
            // a job that runs only after a failure (the abort) is skipped when no job it needs failed
            var n: usize = 0;
            const job = (try reader.jobLines(ar, text, d.name, &n)).?;
            if (gateHas(job, "failure()") and std.mem.eql(u8, d.result, "skipped")) continue;
            return try std.fmt.allocPrint(ar, "a run in which {s} fails leaves {s} {s}: the user test of the wheel holds back no other job", .{ failed, d.name, d.result });
        }
    }
    const ok = try play(ar, text, &.{});
    if (!ok.green) return "a run in which every job succeeds is not green";
    return null;
}

// ---- the cases -----------------------------------------------------------------------------------

fn texts(ar: std.mem.Allocator) ![2][]const u8 {
    return .{ try readData(ar, "release.yml"), try readData(ar, "pypi.yml") };
}

/// `text` with the first `from` at or after the header of the job `job` replaced by `to`.
fn inJob(ar: std.mem.Allocator, text: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const header = try std.fmt.allocPrint(ar, "\n  {s}:\n", .{job});
    const start = std.mem.indexOf(u8, text, header) orelse {
        std.debug.print("the case's job is not in the workflow: {s}\n", .{job});
        return error.NoAnchor;
    };
    const at = std.mem.indexOfPos(u8, text, start, from) orelse {
        std.debug.print("the case's anchor is not in job {s}: {s}\n", .{ job, from });
        return error.NoAnchor;
    };
    return try std.mem.concat(ar, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, pypi: []const u8, want: []const u8) !void {
    const got = (try check(ar, text, pypi)) orelse {
        std.debug.print("accepted a release.yml that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "release.yml builds the wheel as pypi.yml does and runs its user test on every run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const f = try texts(ar);
    if (try check(ar, f[0], f[1])) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.ContractBroken;
    }
}

test "a merge that breaks the install is red in the user test, and the release set and the prod publish still run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const f = try texts(ar);
    const broken = try play(ar, f[0], &.{user_test.JOB});
    try t.expect(!broken.green);
    try t.expectEqualStrings("failure", broken.resultOf(user_test.JOB));
    try t.expectEqualStrings("success", broken.resultOf(BUILD_JOB));
    for ([_][]const u8{ "release", "mopm-stage", "prod-stage", "prod-test", "prod-commit", "prod-smoke", "prod-add" }) |job| try t.expectEqualStrings("success", broken.resultOf(job));
    try t.expectEqualStrings("skipped", broken.resultOf("prod-abort"));
    // a wheel that does not build: no user test, red, the rest runs
    const unbuilt = try play(ar, f[0], &.{BUILD_JOB});
    try t.expect(!unbuilt.green);
    try t.expectEqualStrings("skipped", unbuilt.resultOf(user_test.JOB));
    try t.expectEqualStrings("success", unbuilt.resultOf("prod-add"));
    // every job succeeds: green, the user test ran
    const ok = try play(ar, f[0], &.{});
    try t.expect(ok.green);
    try t.expectEqualStrings("success", ok.resultOf(user_test.JOB));
    // the verdict of the play on a user test that continues on an error: the run would end green
    const lenient = try inJob(ar, f[0], user_test.JOB, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: true\n");
    try t.expect((try play(ar, lenient, &.{user_test.JOB})).green);
    try t.expectEqualStrings("a run in which wheel-user-test fails ends green: a merge that breaks the wheel would leave main green", (try checkPlayed(ar, lenient)).?);
    // and on a prod publish that waits on it: held back
    const waiting = try inJob(ar, f[0], "prod-stage", "    needs: [release, mopm-stage]\n", "    needs: [release, mopm-stage, wheel-user-test]\n");
    try t.expectEqualStrings("a run in which wheel fails leaves prod-stage skipped: the user test of the wheel holds back no other job", (try checkPlayed(ar, waiting)).?);
}

test "each defect of the wheel jobs of release.yml is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const f = try texts(ar);
    const rel = f[0];
    const pypi = f[1];
    // the prod publish waits on the user test: a broken wheel would hold back the packages
    try expectRefused(ar, try inJob(ar, rel, "prod-stage", "    needs: [release, mopm-stage]\n", "    needs: [release, mopm-stage, wheel-user-test]\n"), pypi, "prod-stage needs wheel-user-test");
    try expectRefused(ar, try inJob(ar, rel, "mopm-stage", "    runs-on: ubuntu-24.04\n", "    needs: wheel\n    runs-on: ubuntu-24.04\n"), pypi, "mopm-stage needs wheel");
    // a failed user test that does not fail the run
    try expectRefused(ar, try inJob(ar, rel, user_test.JOB, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: true\n"), pypi, "names \"continue-on-error\"");
    // the user test gated, or the build gated, so some runs skip it
    try expectRefused(ar, try inJob(ar, rel, user_test.JOB, "    needs: wheel\n", "    needs: wheel\n    if: github.event_name == 'workflow_dispatch'\n"), pypi, "wheel-user-test: it has an if:");
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, "    runs-on: ubuntu-24.04\n", "    if: github.event_name == 'workflow_dispatch'\n    runs-on: ubuntu-24.04\n"), pypi, "wheel: it has a needs: or an if:");
    // another wheel than pypi.yml's: unstamped, another target, one flag missing
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, " -c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }} //python:komira_wheel[release]", " //python:komira_wheel[release]"), pypi, "the line `args: build -c komira.package_stamp");
    try expectRefused(ar, rel, try inJob(ar, pypi, "build", " //python:komira_wheel[release] --out", " -c komira.extra=1 //python:komira_wheel[release] --out"), "wheel: the wheel is not built as pypi.yml's build builds it");
    // no install test, no matrix from the list, the files of the quickstart not beside the driver
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, " //python:wheel_install_test\n", " //python:komira_wheel\n"), pypi, "the line `args: build -c komira.package_stamp=${{ steps.stamp.outputs.build_number }} -c komira.package_commit=${{ steps.stamp.outputs.source_commit }} -c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }} //python:wheel_install_test` is missing");
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, "--platform linux-x86_64", "--platform macos-arm64"), pypi, "--platform linux-x86_64");
    // the matrix from another list than the one built from python/pythons.bzl, or from the macOS one
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, "matrix --pythons \"$RUNNER_TEMP/wheel/pythons.json\"", "matrix --pythons python/pythons.json"), pypi, "matrix --pythons");
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, "//python:supported_pythons[linux-x86_64]", "//python:supported_pythons[macos-arm64]"), pypi, "the line `args: build //python:supported_pythons[linux-x86_64]");
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, " src/so/abi/komira.tsv \"$RUNNER_TEMP/wheel/smoke/\"", " \"$RUNNER_TEMP/wheel/smoke/\""), pypi, "the line `run: cp python/examples/quickstart.py");
    // an upload to an index from release.yml
    try expectRefused(ar, try inJob(ar, rel, BUILD_JOB, "      - name: Stop buck2\n", "      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # v1.14.3\n      - name: Stop buck2\n"), pypi, "names \"gh-action-pypi-publish\"");
    try expectRefused(ar, try inJob(ar, rel, user_test.JOB, "    permissions: {}\n", "    environment: pypi\n    permissions: {}\n"), pypi, "names \"environment: pypi\"");
    // the user test from a checkout
    try expectRefused(ar, try inJob(ar, rel, user_test.JOB, "    steps:\n", "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"), pypi, "names \"actions/checkout\"");
    // the jobs gone or doubled
    try expectRefused(ar, try std.mem.replaceOwned(u8, ar, rel, "\n  wheel-user-test:\n", "\n  wheel-check:\n"), pypi, "the job wheel-user-test exactly once");
    try expectRefused(ar, try std.fmt.allocPrint(ar, "{s}\n  wheel:\n    runs-on: ubuntu-24.04\n", .{rel}), pypi, "the job wheel exactly once");
    // a comment may speak of an upload
    const commented = try inJob(ar, rel, BUILD_JOB, "      - name: Stop buck2\n", "      # pypi.yml, not this job, runs gh-action-pypi-publish and twine is never used\n      - name: Stop buck2\n");
    try t.expect((try check(ar, commented, pypi)) == null);
}

test "the play reads the gates of release.yml: an abort runs only after a failure; a need the file lacks, or a cycle, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const f = try texts(ar);
    const p = try play(ar, f[0], &.{"prod-test"});
    try t.expectEqualStrings("success", p.resultOf("prod-abort"));
    try t.expectEqualStrings("skipped", p.resultOf("prod-commit"));
    try t.expect(!p.green);
    // a job that needs one the file lacks, and two jobs that need each other
    const missing = try std.mem.replaceOwned(u8, ar, f[0], "    needs: wheel\n", "    needs: wheel-later\n");
    try t.expectError(error.Unreadable, play(ar, missing, &.{}));
    const cycle = try inJob(ar, f[0], BUILD_JOB, "    runs-on: ubuntu-24.04\n", "    needs: wheel-user-test\n    runs-on: ubuntu-24.04\n");
    try t.expectError(error.Unreadable, play(ar, cycle, &.{}));
}
