//! The cases of the macOS build of the release, //:release_macos_cases: a `zig_test` run as a build
//! action. The subjects are the bytes of the workflows (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/<name>.yml), the shards of the pull request's check set
//! (ci_targets/shard_<n>.bzl) and the macOS set's own definition (darwin_libs.bzl).
//!
//! The decision these hold: before the merge, macOS is built only by pr.yml's macOS part (the libraries of
//! the macOS set a change reaches, on the farm's Macs, through a config file no other step names, bounded),
//! and the release workflows build it after the merge:
//! release-macos.yml once per release (a push to main, a manual run), in a concurrency group of its own
//! so that a stalled Mac build never holds the next release, and pypi.yml's build-macos-arm64 on
//! a push to main, building only when TestPyPI lacks that version's macOS wheel; the daily promotion builds
//! nothing.
//! What the cases catch:
//!  - the workflow release-macos.yml exists, runs on push to main and workflow_dispatch only (never
//!    pull_request, pull_request_target or merge_group, never a schedule), its concurrency group is not
//!    release.yml's and it cancels a running build in favour of a newer push;
//!  - release.yml holds no macOS job: no job `release-macos`, no job `needs` it or reads its result;
//!    the one place it names macOS is its job `mopm-stage`, which publishes the packages of both platforms:
//!    the lines of MOPM_STAGE_MACOS, exactly as written, each once in the file and all in that job (the macOS
//!    keys passed to farm-connect in a buckconfig of their own, and the two builds (one per Mojo) that name that
//!    file and build //release:mopm_release_artifacts, whose transition configures the macOS set for
//!    darwin-arm64); in release.yml the Linux platform of the second Mojo (MOJO_NEXT_PLATFORM) is no macOS platform, and any
//!    other `--target-platforms`, the macOS rows included, is refused;
//!    any other non-comment line naming a macOS platform, worker set or runner (a `--target-platforms`, a
//!    macOS runner, the keys in another job) is refused;
//!  - the job `release-macos` of release-macos.yml exists once and builds the macOS set on the farm: it runs on
//!    the ubuntu runner (a macOS runner is refused), joins the farm with the macOS worker set and
//!    hosts and `farm-qos: batch`, passes `--target-platforms komira//tools/build/platforms:darwin-arm64`
//!    to `//release:mopm_darwin_libs` through the buck2-farm action (which fails a step that ran
//!    anything locally), and says in its buckconfig step that the macOS worker keys must be set;
//!  - it does not hold up the Linux path: it `needs` nothing (nothing in release.yml `needs` it, so the prod
//!    publish never waits on this workflow; the publish waits on its own build of the macOS packages, in
//!    mopm-stage), and it is bounded (`timeout-minutes` at most 120, the longest of the other jobs);
//!  - a failed or skipped macOS build ends the run failed: the job is not `continue-on-error`, and a last job
//!    `release-macos-result` (`needs: release-macos`, `if: always()`) fails with "the macOS build did not run"
//!    when the build's result is skipped, so a run whose build never ran is not green;
//!  - it is not triggered on a pull request: neither macOS-naming workflow's `on:` names one, and no
//!    workflow that runs on a pull request (pr.yml, coverage.yml) has a non-comment line naming darwin,
//!    macOS, osx or `--target-platforms`, with three exceptions, all in pr.yml and exactly as written: the
//!    lines of its macOS part (PR_MACOS_PART), the lines of its Mojo 1.2.0 part on linux (PR_MOJO_NEXT; a
//!    line that names the platform of that Mojo and is none of them is refused, and so is each of them in
//!    coverage.yml) and
//!    the line that analyses the macOS set (ANALYSIS_ARGS, a
//!    `bxl` of release/darwin_analysis.bxl, which configures and analyses and runs no action); the same
//!    lines in coverage.yml are refused;
//!  - pr.yml's macOS part holds its contract: each of its lines once; the macOS keys passed to
//!    farm-connect with `darwin-config-file`, so they reach no step but the build, which names the file;
//!    the targets chosen by darwin.bxl from the linux part's list; the build of darwin-arm64 through the
//!    buck2-farm action with its remote assertion, only when there is a target, bounded at 60 minutes,
//!    never with --no-remote-cache; and the part after the step `test` and before the analysis;
//!  - pr.yml's Mojo 1.2.0 part on linux (five steps: the selection of tools/build/ci/mojo_next.bxl over the
//!    list of the linux part, the labels of its log, the build and the standalone tests of that selection,
//!    and the test, for linux-x86_64-mojo-1.2.0) holds its contract: its lines once, exactly as written (the
//!    one other place a pull request workflow names `--target-platforms`), the selection, the build and the
//!    test through the buck2-farm action with its remote assertion, the selection reading the list of the
//!    step `build`, the build reading the selected list and the test the selected list without the tests
//!    cell, the build and the test under their `if:`s and bounds, in the order select, targets, build,
//!    standalone tests, test, after the step `test` and before the selection of the macOS targets, and no
//!    macOS key or config file in them;
//!  - pr.yml does analyse the macOS set: that line is there once, in a buck2-farm step with its remote
//!    assertion, so a change that makes the set unanalysable fails its own pull request;
//!  - pypi.yml, the release workflow of both wheels, runs on no pull request or merge group; its ten Linux jobs
//!    and its nine macOS jobs (build, testpypi, testpypi-smoke, testpypi-passed, result-testpypi on a push;
//!    promote, pypi, pypi-smoke, result-pypi on the promotion) exist once each, each macOS job gated on its
//!    half's event, and the two chains are independent inside the file (no needs, no read of a result, record
//!    or artifact of the other, no macOS word in a Linux job); both builds run the same stamp step and pass
//!    the same three stamp flags to every //python build, so the two wheels of a run carry one version;
//!    build-macos-arm64 runs on ubuntu, joins the farm
//!    with the macOS worker set and hosts, `farm-qos: batch` and the tls literal, builds on a push to main,
//!    asks TestPyPI only (one `present` step) after building the file name, and every Mac build and later
//!    step but Stop buck2 carries exactly that gate; the list of the supported Pythons is built into the
//!    smoke directory and the matrix written from it before TestPyPI is asked; the macOS smoke jobs run
//!    the macOS driver, read the quickstart from the smoke artifact (no checkout) and are one job per entry
//!    of their chain's matrix (promote-macos-arm64's for the PyPI one); promote-macos-arm64 and
//!    pypi-macos-arm64 run the Linux driver on ubuntu;
//!  - the pull request's check set (ci/targets shards) names neither the macOS set, the five macOS targets
//!    of the wheel (komira_wheel_macos_arm64, wheel_install_test_macos_arm64, wheel_libs_macos_arm64,
//!    wheel_same_macos_arm64, pypi_smoke_macos_arm64) nor a macOS runner;
//!  - the macOS set is the packages of packages.bzl without the excluded ones, in one place: the
//!    set's definition builds each member's `:lib`, and each excluded package is a package.
//!  - the step `build the macOS Python harness tests` builds DARWIN_PYTHON_HARNESS of darwin_libs.bzl, the
//!    list pr.yml analyses with the set (release_macos_harness_test.zig).
//! Every defect above is written into the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

// The harness step builds the list pr.yml analyses (release_macos_harness_test.zig says what each case catches).
test {
    _ = @import("release_macos_harness_test.zig");
}

const JOB = "release-macos";
const BUILD_ARGS = "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:mopm_darwin_libs";
const FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
const BUCK2_FARM = "        uses: ./.github/actions/buck2-farm";
const ASSERT = "          assert-remote: ${{ steps.assert.outputs.path }}";
const DARWIN_PROPS = "          darwin-properties: ${{ vars.FARM_DARWIN_ARM64_PROPERTIES }}";
const DARWIN_HOSTS = "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}";
const QOS = "          farm-qos: batch";
const MACOS_LIBS = "          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}";
const MAC_CONFIG_INPUT = "          darwin-config-file: ${{ runner.temp }}/darwin.buckconfig";
const PACKAGES_BUILD = "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig -c komira_release.mac_tree=true //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts-1.1.0";
/// The same build for the second Mojo: the platform names the Linux row built with it, and the transition of the
/// release target picks the macOS row for the same compiler.
const MOJO_NEXT_PLATFORM = "--target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0";
const PACKAGES_BUILD_NEXT = "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig -c komira_release.mac_tree=true " ++ MOJO_NEXT_PLATFORM ++ " //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts-1.2.0";
/// The job of release.yml that stages and publishes the packages of both platforms, and the only lines of release.yml
/// that may name macOS: its farm connection's macOS keys, written to a buckconfig of their own, and the build of the
/// packages, the one step that names that file.
const MOPM_STAGE = "mopm-stage";
const MOPM_STAGE_MACOS = [_][]const u8{ DARWIN_PROPS, DARWIN_HOSTS, MACOS_LIBS, MAC_CONFIG_INPUT, PACKAGES_BUILD, PACKAGES_BUILD_NEXT };
const BOUND = "    timeout-minutes: 90";
const CONTINUE_ON_ERROR = "    continue-on-error: true";
const RESULT_JOB = "release-macos-result";
const RESULT_REASON = "the macOS build did not run";
const SAID_RUN = "        run: '\"$RUNNER_TEMP/buck2_failure\" --log \"$RUNNER_TEMP/buck2-farm.log\" --step \"$FAILED_STEP\" --github-output \"$GITHUB_OUTPUT\" --summary-file \"$GITHUB_STEP_SUMMARY\"'";
const SAID_IF = "        if: failure() && steps.reader.outcome == 'success' && (steps.build.outcome == 'failure' || steps.python.outcome == 'failure')";
const REPORT_OUTPUT = "      report: ${{ steps.said.outputs.message || ";
const REPORT_ENV = "          REPORT: ${{ needs.release-macos.outputs.report }}";
const REPORT_SET = "(steps.build.outcome == 'failure' && 'step `build the macOS set` failed (its log says why)')";
const REPORT_PYTHON = "(steps.python.outcome == 'failure' && 'step `build the macOS Python harness tests` failed (its log says why)')";
const REPORT_ECHO = "              echo \"::error title=release-macos::the macOS build did not pass: ${REPORT:-";
const GUESS = "farm-connect refuses when a repository variable is empty";
const MAX_MINUTES = 120;

fn isComment(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    return trimmed.len > 0 and trimmed[0] == '#';
}

/// Walks `jobs:` (a job is a key at two spaces of indent): the names of the jobs go to `names`, and the
/// lines of the job `want` (without comments and blank lines) are returned, or null; `count` counts the
/// jobs of that name.
fn scanJobs(ar: std.mem.Allocator, text: []const u8, want: []const u8, count: *usize, names: *std.ArrayList([]const u8)) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var in_jobs = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "jobs:")) {
            in_jobs = true;
            continue;
        }
        if (!in_jobs) continue;
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        if (indent == 2 and std.mem.endsWith(u8, trimmed, ":")) {
            try names.append(ar, trimmed[0 .. trimmed.len - 1]);
            inside = std.mem.eql(u8, trimmed[0 .. trimmed.len - 1], want);
            if (inside) {
                count.* += 1;
                found = true;
                out.clearRetainingCapacity();
            }
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

/// The lines of the job `name` of `jobs:`, or null. Counts the jobs of that name in `count`.
fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8, count: *usize) !?[]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    return scanJobs(ar, text, name, count, &names);
}

/// The lines of the job `name`, which the caller knows exists (the jobs are counted first).
fn jobOf(ar: std.mem.Allocator, text: []const u8, name: []const u8) ![]const []const u8 {
    var n: usize = 0;
    return (try jobLines(ar, text, name, &n)).?;
}

/// The names of the jobs of `jobs:`, in order.
fn jobNames(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    var n: usize = 0;
    _ = try scanJobs(ar, text, "", &n, &names);
    return names.items;
}

fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

fn mentionsLine(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

fn mentions(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

fn startsWithAny(lines: []const []const u8, prefix: []const u8) bool {
    for (lines) |l| if (std.mem.startsWith(u8, l, prefix)) return true;
    return false;
}

/// Whether a line names a macOS platform, worker set or runner, or any `--target-platforms`. A pull request
/// workflow is read with this: the Linux platform of the second Mojo counts too, and only checkPullRequestWorkflow
/// exempts the PR_MOJO_NEXT lines of pr.yml.
fn namesMacos(line: []const u8) bool {
    const words = [_][]const u8{ "darwin", "macos", "osx", "target-platforms" };
    for (words) |w| if (std.ascii.indexOfIgnoreCase(line, w) != null) return true;
    return false;
}

/// Like namesMacos, but the Linux platform of the second Mojo (MOJO_NEXT_PLATFORM) is the one
/// `--target-platforms` that names no macOS platform. The release workflows are read with this.
fn namesMacosBesidesMojoNext(raw: []const u8) bool {
    const line = std.mem.replaceOwned(u8, std.heap.page_allocator, raw, MOJO_NEXT_PLATFORM, "") catch return true;
    defer std.heap.page_allocator.free(line);
    return namesMacos(line);
}

/// The value of `key` (`group` or `cancel-in-progress`) under the top-level `concurrency:`, or null.
fn concurrencyValue(text: []const u8, key: []const u8) ?[]const u8 {
    var in_c = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] != ' ' and line[0] != '#') in_c = std.mem.eql(u8, line, "concurrency:");
        if (!in_c or !std.mem.startsWith(u8, line, "  ")) continue;
        const rest = line[2..];
        if (std.mem.startsWith(u8, rest, key) and rest.len > key.len and rest[key.len] == ':') return std.mem.trim(u8, rest[key.len + 1 ..], " ");
    }
    return null;
}

/// Null if the concurrency group of the macOS workflow is its own, else the refusal.
fn checkGroups(mac: []const u8, rel: []const u8) ?[]const u8 {
    const g = concurrencyValue(mac, "group") orelse return "release-macos.yml has no concurrency group (it would share none, or the default)";
    const r = concurrencyValue(rel, "group") orelse return "release.yml has no concurrency group";
    if (std.mem.eql(u8, g, r)) return "release-macos.yml is in release.yml's concurrency group: a stalled macOS build would hold the next release";
    if (std.mem.indexOf(u8, g, "release-main") != null) return "release-macos.yml names release.yml's group release-main";
    return null;
}

/// Null if release.yml holds no macOS job, else the refusal.
fn checkRelease(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    if ((try jobLines(ar, text, JOB, &n)) != null) return "release.yml has a job release-macos: the macOS build is the workflow release-macos.yml";
    const names = try jobNames(ar, text);
    for (names) |other| {
        var m: usize = 0;
        const lines = (try jobLines(ar, text, other, &m)).?;
        for (lines) |l| {
            if (std.mem.startsWith(u8, l, "    needs:") and std.mem.indexOf(u8, l, JOB) != null)
                return try std.fmt.allocPrint(ar, "{s} needs release-macos: the Linux path would wait on the macOS build", .{other});
            if (std.mem.indexOf(u8, l, "needs." ++ JOB) != null)
                return try std.fmt.allocPrint(ar, "{s} reads the result of release-macos: the Linux path would depend on the macOS build", .{other});
        }
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line) or !namesMacosBesidesMojoNext(line)) continue;
        var allowed = false;
        for (MOPM_STAGE_MACOS) |l| allowed = allowed or std.mem.eql(u8, line, l);
        if (!allowed) return try std.fmt.allocPrint(ar, "release.yml names a macOS platform, worker set or runner outside mopm-stage's macOS keys and its build of the packages: {s}", .{std.mem.trim(u8, line, " ")});
    }
    // each of those lines once in the file, in mopm-stage: the keys reach no other job, and the packages are built
    // for both platforms (without the keys the osx-arm64 half has no worker to build on)
    var m: usize = 0;
    const stage = (try jobLines(ar, text, MOPM_STAGE, &m)) orelse return "release.yml has no job mopm-stage";
    for (MOPM_STAGE_MACOS) |l| {
        if (!has(stage, l)) return try std.fmt.allocPrint(ar, "mopm-stage does not hold `{s}`: the osx-arm64 packages are not built for the release", .{std.mem.trim(u8, l, " ")});
        if (std.mem.count(u8, text, l) != 1) return try std.fmt.allocPrint(ar, "release.yml has {d} lines `{s}`: it is mopm-stage's, once", .{ std.mem.count(u8, text, l), std.mem.trim(u8, l, " ") });
    }
    return null;
}

/// Null if release-macos.yml holds its contract (the job and the workflow around it), else the refusal.
fn checkMacos(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    // the workflow: push to main and a manual run, never a pull request, a merge group or a schedule
    if (runsOnPullRequest(text)) return "release-macos.yml runs on a pull request (pull_request, pull_request_target or merge_group)";
    if (!mentionsLine(text, "\n    branches: [main]\n")) return "release-macos.yml does not run on push to main";
    if (!mentionsLine(text, "\n  push:\n") or !mentionsLine(text, "\n  workflow_dispatch:\n")) return "release-macos.yml is not triggered by push and workflow_dispatch";
    if (mentionsLine(text, "\n  schedule:") or mentionsLine(text, "\n  workflow_run:")) return "release-macos.yml has a trigger beyond push and workflow_dispatch";
    const cancel = concurrencyValue(text, "cancel-in-progress") orelse return "release-macos.yml has no cancel-in-progress";
    if (!std.mem.eql(u8, cancel, "true")) return "release-macos.yml does not cancel a running build for a newer push (cancel-in-progress: true)";
    var n: usize = 0;
    const job = (try jobLines(ar, text, JOB, &n)) orelse return "release-macos.yml has no job release-macos";
    if (n != 1) return "release-macos is defined more than once";

    // on the farm's macOS workers, never a hosted macOS runner: the job itself runs on ubuntu
    if (!has(job, "    runs-on: ubuntu-24.04")) return "release-macos does not run on ubuntu-24.04 (a hosted macOS runner is not the farm's Macs)";
    if (mentions(job, "runs-on: macos") or mentions(job, "runs-on: [")) return "release-macos names a hosted macOS runner";
    if (!has(job, "    environment: build")) return "release-macos is not in the environment build (the claim the farm's trust was set for)";

    // it does not hold up the Linux path
    if (startsWithAny(job, "    needs:")) return "release-macos has needs: it waits on another job";
    if (startsWithAny(job, "    if:")) return "release-macos has a condition: it runs on every release run";
    // not blocking comes from nothing waiting on the job; `continue-on-error` would end a failed build green
    if (mentions(job, "continue-on-error")) return "release-macos is continue-on-error: a failed or skipped macOS build would end the run green (the run must end failed)";
    const bound = (for (job) |l| {
        if (std.mem.startsWith(u8, l, "    timeout-minutes: ")) break std.fmt.parseInt(u32, std.mem.trim(u8, l["    timeout-minutes: ".len..], " "), 10) catch return "release-macos: timeout-minutes is not a number";
    } else return "release-macos has no timeout-minutes (a stalled macOS build would hold the next release)");
    if (bound == 0 or bound > MAX_MINUTES) return "release-macos: timeout-minutes is not bounded at 120 or less";
    if (!has(job, BOUND)) return "release-macos: timeout-minutes is not the 90 the comment and docs/ci.md state";
    // the farm connection: batch priority, with the macOS set, tls as every caller passes it
    const connect_at = lineAt(job, FARM_CONNECT) orelse return "release-macos does not join the farm";
    if (!has(job, QOS)) return "release-macos does not pass farm-qos: batch";
    if (!has(job, DARWIN_PROPS)) return "release-macos does not pass the macOS worker properties to farm-connect (darwin-properties)";
    if (!has(job, DARWIN_HOSTS)) return "release-macos does not pass the macOS worker hosts to farm-connect (darwin-macos-hosts)";
    if (!has(job, "          tls: ${{ vars.FARM_TLS || 'false' }}")) return "release-macos does not pass tls from FARM_TLS";

    // the buckconfig names the macOS workers, before anything is built
    const guard_at = lineAt(job, "      - name: the buckconfig names the farm and its macOS workers") orelse return "release-macos does not check that the buckconfig names the macOS workers";
    if (!mentions(job, "linux_x86_64_properties darwin_arm64_properties darwin_macos_hosts")) return "release-macos does not check the linux set, the macOS set and the macOS hosts";

    // the build: darwin-arm64, the macOS set, through the farm action, asserted remote
    var builds: usize = 0;
    for (job) |l| if (std.mem.startsWith(u8, l, "          args:") and std.mem.indexOf(u8, l, "//release:mopm_darwin_libs") != null) {
        builds += 1;
    };
    if (builds != 1) return "release-macos does not build //release:mopm_darwin_libs in exactly one buck2 step";
    const build_at = lineAt(job, BUILD_ARGS) orelse return "release-macos does not build //release:mopm_darwin_libs for --target-platforms komira//tools/build/platforms:darwin-arm64";
    if (!(connect_at < guard_at and guard_at < build_at)) return "release-macos builds before the farm is joined and the macOS workers checked";
    if (build_at < 2 or !std.mem.eql(u8, job[build_at - 1], "        with:") or !std.mem.eql(u8, job[build_at - 2], BUCK2_FARM))
        return "release-macos builds outside the buck2-farm action (a step that ran locally would pass)";
    if (build_at + 1 >= job.len or !std.mem.eql(u8, job[build_at + 1], ASSERT)) return "release-macos does not assert the build remote";
    if (mentions(job, "--no-remote-cache") or mentions(job, "--isolation-dir")) return "release-macos builds with --no-remote-cache or --isolation-dir";
    if (mentions(job, "|| true") and !has(job, "        run: ./buck2 kill || true")) return "release-macos ignores a failure";

    // the run ends failed when the build did not run: a last job reads the build's result
    var rn: usize = 0;
    const res = (try jobLines(ar, text, RESULT_JOB, &rn)) orelse return "release-macos.yml has no job release-macos-result (a skipped macOS build would end the run green)";
    if (rn != 1) return "release-macos-result is defined more than once";
    if (!has(res, "    needs: release-macos")) return "release-macos-result does not need exactly release-macos";
    if (!has(res, "    if: always()")) return "release-macos-result is not if: always() (a skipped build would skip it too, and the run would end green)";
    if (!has(res, "    runs-on: ubuntu-24.04")) return "release-macos-result does not run on ubuntu-24.04";
    if (mentions(res, "continue-on-error")) return "release-macos-result is continue-on-error: its failure would read as success";
    if (!mentions(res, "needs.release-macos.result")) return "release-macos-result does not read the result of release-macos";
    if (!mentions(res, "skipped")) return "release-macos-result does not test for a skipped build";
    if (!mentions(res, RESULT_REASON)) return "release-macos-result does not say \"the macOS build did not run\"";
    if (!mentions(res, "exit 1")) return "release-macos-result never fails";
    if (!mentions(res, "::error")) return "release-macos-result writes no ::error annotation";
    if (mentions(res, "uses:")) return "release-macos-result uses an action: it only reads a result";
    // a failed build is reported with what the failed step said, never with a guess at the cause
    if (!has(job, SAID_RUN)) return "release-macos does not read the build's log with buck2_failure (what buck2 said would be lost)";
    if (!has(job, "        id: said") or !startsWithAny(job, REPORT_OUTPUT)) return "release-macos does not pass what buck2 printed to release-macos-result (outputs: report, buck2_failure's message first)";
    if (!mentions(job, REPORT_SET) or !mentions(job, REPORT_PYTHON)) return "release-macos's report does not name a failed build step (the set, the Python harness tests)";
    if (!has(job, SAID_IF)) return "release-macos does not read the build's log exactly when a buck2 step failed and the reader was built";
    if (!has(res, REPORT_ENV) or !startsWithAny(res, REPORT_ECHO)) return "release-macos-result does not print the build job's report (needs.release-macos.outputs.report)";
    // the report is decided in the build job (an expression and buck2_failure), not by shell branches here
    if (mentions(res, "if [") or mentions(res, "elif ")) return "release-macos-result branches in shell: the report is the build job's output, printed as it is";
    if (mentions(res, GUESS)) return "release-macos-result guesses at the cause of a failed build instead of reporting what the step said";

    // not on a pull request, and nothing publishes from it
    if (mentions(job, "pull_request")) return "release-macos names pull_request";
    if (mentions(job, "mopm publish") or mentions(job, "--oidc")) return "release-macos publishes";
    return null;
}

/// Null if a workflow that runs on a pull request names macOS nowhere but where it may, else the refusal.
/// A workflow that does not run on a pull request is not read here (null). `name` is the file's name: the
/// lines of pr.yml's macOS part (PR_MACOS_PART, exactly as written) are pr.yml's alone, and the analysis
/// line (ANALYSIS_ARGS) builds nothing; any other line naming darwin, macOS, osx or `--target-platforms`
/// is refused, in coverage.yml or any other pull request workflow too.
fn checkPullRequestWorkflow(name: []const u8, text: []const u8) ?[]const u8 {
    if (!runsOnPullRequest(text)) return null;
    const is_pr = std.mem.eql(u8, name, "pr.yml");
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        // the analysis of the macOS set runs no action: the one line that may name it, as written
        if (std.mem.eql(u8, line, ANALYSIS_ARGS)) continue;
        if (is_pr and (isMacosPartLine(line) or isMojoNextLine(line))) continue;
        if (namesMacos(line)) return "a workflow that runs on a pull request names a macOS platform, worker set or runner outside pr.yml's macOS part (its lines are PR_MACOS_PART, as written)";
    }
    return null;
}

/// The non-comment lines of pr.yml that name macOS: the job's macOS part (docs/ci.md, "The macOS part of
/// the check"), each exactly as written. checkMacosPart holds where they stand and what surrounds them.
const PR_MACOS_PART = [_][]const u8{
    DARWIN_PROPS,
    DARWIN_HOSTS,
    "          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}",
    DARWIN_FILE,
    SELECT_NAME,
    SELECT_ARGS,
    TOOL_NAME,
    TOOL_ID,
    TOOL_RUN,
    TARGETS_NAME,
    TARGETS_ID,
    TARGETS_ENV,
    TARGETS_RUN,
    PR_BUILD_NAME,
    PR_BUILD_IF,
    PR_BUILD_ARGS,
};

/// The non-comment lines of pr.yml's Mojo 1.2.0 part on linux: the selection of the targets the linux part
/// built, the file of their labels, the build and the test of that selection for the platform that selects
/// Mojo 1.2.0. Each exactly as written (the `if:` and bound lines that other steps repeat are held by
/// the step checks of checkMojoNext).
const PR_MOJO_NEXT = [_][]const u8{
    NEXT_SELECT_NAME,
    NEXT_SELECT_ARGS,
    NEXT_TARGETS_NAME,
    NEXT_TARGETS_ID,
    NEXT_TARGETS_RUN,
    NEXT_BUILD_NAME,
    NEXT_BUILD_BOUND,
    NEXT_BUILD_ARGS,
    NEXT_TESTS_NAME,
    NEXT_TESTS_ID,
    NEXT_TESTS_RUN,
    NEXT_TEST_NAME,
    NEXT_TEST_ARGS,
};
const NEXT_SELECT_NAME = "      - name: select the Mojo 1.2.0 targets";
const NEXT_SELECT_ARGS = "          args: bxl komira//tools/build/ci/mojo_next.bxl:select @tools/build/ci/mojo_next_affected.args @${{ runner.temp }}/targets.txt";
const NEXT_TARGETS_NAME = "      - name: the Mojo 1.2.0 targets to build";
const NEXT_TARGETS_ID = "        id: next";
const NEXT_TARGETS_RUN = "        run: grep -E '^[a-z_]+//[^ ]+$' \"$RUNNER_TEMP/buck2-farm.log\" > \"$RUNNER_TEMP/next_targets.txt\" && echo \"any=true\" >> \"$GITHUB_OUTPUT\" || true";
const NEXT_BUILD_NAME = "      - name: build with Mojo 1.2.0";
const NEXT_BUILD_IF = "        if: steps.next.outputs.any == 'true'";
const NEXT_BUILD_BOUND = "        timeout-minutes: 120";
const NEXT_BUILD_ARGS = "          args: build --keep-going --target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/next_targets.txt";
const NEXT_TESTS_NAME = "      - name: the Mojo 1.2.0 standalone test targets";
const NEXT_TESTS_ID = "        id: next_tests";
const NEXT_TESTS_RUN = "        run: grep -v '^tests//' \"$RUNNER_TEMP/next_targets.txt\" > \"$RUNNER_TEMP/next_test_targets.txt\" && echo \"any=true\" >> \"$GITHUB_OUTPUT\" || true";
const NEXT_TEST_NAME = "      - name: test with Mojo 1.2.0";
const NEXT_TEST_IF = "        if: steps.next_tests.outputs.any == 'true'";
const NEXT_TEST_BOUND = "        timeout-minutes: 60";
const NEXT_TEST_ARGS = "          args: test --target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/next_test_targets.txt";
const DARWIN_FILE = "          darwin-config-file: ${{ runner.temp }}/darwin.buckconfig";
const SELECT_NAME = "      - name: select the macOS targets";
const SELECT_ARGS = "          args: bxl komira//tools/build/ci/darwin.bxl:select @tools/build/ci/darwin_affected.args @${{ runner.temp }}/targets.txt";
const TARGETS_NAME = "      - name: the macOS targets to build";
const TARGETS_ID = "        id: darwin";
const TARGETS_ENV = "          DARWIN_TARGETS: ${{ steps.darwin_tool.outputs.path }}";
const TARGETS_RUN = "        run: '\"$DARWIN_TARGETS\" --log \"$RUNNER_TEMP/buck2-farm.log\" --out \"$RUNNER_TEMP/darwin_targets.txt\" --github-output \"$GITHUB_OUTPUT\"'";
const TOOL_NAME = "      - name: build the macOS targets tool";
const TOOL_ID = "        id: darwin_tool";
const TOOL_RUN = "        run: echo \"path=$(./buck2 build komira//tools/build/ci:darwin_targets --show-full-simple-output)\" >> \"$GITHUB_OUTPUT\"";
const PR_BUILD_NAME = "      - name: build for macOS";
const PR_BUILD_IF = "        if: steps.darwin.outputs.any == 'true'";
const PR_BUILD_BOUND = "        timeout-minutes: 60";
const PR_BUILD_ARGS = "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going @${{ runner.temp }}/darwin_targets.txt";
const PR_TEST_NAME = "      - name: test";

fn isMojoNextLine(line: []const u8) bool {
    for (PR_MOJO_NEXT) |l| if (std.mem.eql(u8, line, l)) return true;
    return false;
}

fn isMacosPartLine(line: []const u8) bool {
    for (PR_MACOS_PART) |l| if (std.mem.eql(u8, line, l)) return true;
    return false;
}

/// Null if pr.yml's macOS part holds its contract, else the refusal: every line of it is there once; the
/// macOS keys go to farm-connect as a file of their own (so no other step configures a macOS platform);
/// the targets are chosen by darwin.bxl from the linux part's list; the build names that file, the
/// darwin-arm64 platform and that list, runs through the buck2-farm action with its remote assertion,
/// only when there is a target, and is bounded at 60 minutes; and it comes after the linux part's test
/// step and before the analysis of the set (whose own config file replaces the macOS keys).
fn checkMacosPart(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (!isComment(l)) try lines.append(ar, l);
    const ls = lines.items;
    for (PR_MACOS_PART) |want| {
        var n: usize = 0;
        for (ls) |l| if (std.mem.eql(u8, l, want)) {
            n += 1;
        };
        if (n != 1) return try std.fmt.allocPrint(ar, "pr.yml holds {d} times, not once, the line of its macOS part: {s}", .{ n, std.mem.trim(u8, want, " ") });
    }
    if (mentions(ls, "--no-remote-cache")) return "pr.yml builds with --no-remote-cache";
    // the macOS keys are farm-connect's inputs, the file among them
    const connect = lineAt(ls, FARM_CONNECT) orelse return "pr.yml does not join the farm";
    for ([_][]const u8{ DARWIN_PROPS, DARWIN_HOSTS, DARWIN_FILE }) |want| {
        const at = lineAt(ls, want).?;
        if (at < connect or stepStartBetween(ls, connect, at)) return try std.fmt.allocPrint(ar, "pr.yml passes `{s}` outside its farm-connect step", .{std.mem.trim(u8, want, " ")});
    }
    // the selection: a buck2-farm step over the linux part's list
    const sel = lineAt(ls, SELECT_ARGS).?;
    if (!stepIs(ls, sel, SELECT_NAME, &.{})) return "pr.yml selects the macOS targets outside its buck2-farm step `select the macOS targets` (a step that ran an action locally would pass)";
    // the tool that reads the selection, built on the farm and its path the step's output
    const tool = lineAt(ls, TOOL_ID).?;
    if (!consecutive(ls, tool, &.{ TOOL_NAME, TOOL_ID, TOOL_RUN }))
        return "pr.yml's step `build the macOS targets tool` is not its name, `id: darwin_tool` and the build of //tools/build/ci:darwin_targets";
    // the targets: that tool over the selection's log, writing the labels and whether there is any
    const ids = lineAt(ls, TARGETS_ID).?;
    if (!consecutive(ls, ids, &.{ TARGETS_NAME, TARGETS_ID, "        env:", TARGETS_ENV, TARGETS_RUN }))
        return "pr.yml's step `the macOS targets to build` is not its name, `id: darwin`, the tool's path and the one command that writes darwin_targets.txt";
    // the build
    const build = lineAt(ls, PR_BUILD_ARGS).?;
    if (!stepIs(ls, build, PR_BUILD_NAME, &.{ PR_BUILD_IF, PR_BUILD_BOUND }))
        return "pr.yml's step `build for macOS` is not: its name, `if: steps.darwin.outputs.any == 'true'`, `timeout-minutes: 60`, the buck2-farm action with the build and its remote assertion";
    // the order: after the linux part's test step, before the analysis of the set
    const tst = lineAt(ls, PR_TEST_NAME) orelse return "pr.yml has no step `test`";
    const analysis = lineAt(ls, ANALYSIS_ARGS) orelse return "pr.yml does not analyse the release's macOS set";
    if (!(tst < sel and sel < ids and ids < build and build < analysis))
        return "pr.yml's macOS part is not after the step `test` and before the analysis of the macOS set, in the order select, targets, build";
    if (!(tool < ids)) return "pr.yml builds the macOS targets tool after the step that runs it";
    return null;
}

/// Null if pr.yml's Mojo 1.2.0 part on linux holds its contract, else the refusal: every line of it is
/// there once; the selection reads the list the step `build` builds; the selection, the build and the
/// test run through the buck2-farm action with its remote assertion, the build under the `if:` on the
/// selection's labels and the test under the `if:` on the standalone test targets, both bounded; the build
/// reads the selected list and the test the selected list without the tests cell; and the part stands after
/// the step `test`, in the order select, targets, build, standalone tests, test, before the selection of
/// the macOS targets (which reads the log of the step before it).
fn checkMojoNext(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (!isComment(l)) try lines.append(ar, l);
    const ls = lines.items;
    for (PR_MOJO_NEXT) |want| {
        var n: usize = 0;
        for (ls) |l| if (std.mem.eql(u8, l, want)) {
            n += 1;
        };
        if (n != 1) return try std.fmt.allocPrint(ar, "pr.yml holds {d} times, not once, the line of its Mojo 1.2.0 part: {s}", .{ n, std.mem.trim(u8, want, " ") });
    }
    if (mentions(ls, "--no-remote-cache")) return "pr.yml builds with --no-remote-cache";
    const sel = lineAt(ls, NEXT_SELECT_ARGS).?;
    if (!stepIs(ls, sel, NEXT_SELECT_NAME, &.{}))
        return "pr.yml selects the Mojo 1.2.0 targets outside its buck2-farm step `select the Mojo 1.2.0 targets` with its remote assertion";
    // the selection reads the list the linux part's step `build` builds
    if (lineAt(ls, "          args: build --keep-going @${{ runner.temp }}/targets.txt") == null)
        return "pr.yml's step `build` does not build the list that the Mojo 1.2.0 selection reads";
    const ids = lineAt(ls, NEXT_TARGETS_ID).?;
    if (!consecutive(ls, ids, &.{ NEXT_TARGETS_NAME, NEXT_TARGETS_ID, NEXT_TARGETS_RUN }))
        return "pr.yml's step `the Mojo 1.2.0 targets to build` is not its name, `id: next` and the one command that writes next_targets.txt";
    const build = lineAt(ls, NEXT_BUILD_ARGS).?;
    if (!stepIs(ls, build, NEXT_BUILD_NAME, &.{ NEXT_BUILD_IF, NEXT_BUILD_BOUND }))
        return "pr.yml's step `build with Mojo 1.2.0` is not: its name, `if: steps.next.outputs.any == 'true'`, `timeout-minutes: 120`, the buck2-farm action with the build and its remote assertion";
    const standalone = lineAt(ls, NEXT_TESTS_ID).?;
    if (!consecutive(ls, standalone, &.{ NEXT_TESTS_NAME, NEXT_TESTS_ID, NEXT_BUILD_IF, NEXT_TESTS_RUN }))
        return "pr.yml's step `the Mojo 1.2.0 standalone test targets` is not its name, `id: next_tests`, `if: steps.next.outputs.any == 'true'` and the one command that writes next_test_targets.txt";
    const tests = lineAt(ls, NEXT_TEST_ARGS).?;
    if (!stepIs(ls, tests, NEXT_TEST_NAME, &.{ NEXT_TEST_IF, NEXT_TEST_BOUND }))
        return "pr.yml's step `test with Mojo 1.2.0` is not: its name, `if: steps.next_tests.outputs.any == 'true'`, `timeout-minutes: 60`, the buck2-farm action with the test and its remote assertion";
    const tst = lineAt(ls, PR_TEST_NAME) orelse return "pr.yml has no step `test`";
    const macos = lineAt(ls, SELECT_NAME) orelse return "pr.yml does not select the macOS targets";
    if (!(tst < sel and macos > tests))
        return "pr.yml's Mojo 1.2.0 part is not after the step `test` and before the selection of the macOS targets";
    if (!(sel < ids and ids < build and build < standalone and standalone < tests))
        return "pr.yml's Mojo 1.2.0 part is not in the order select, targets to build, build, standalone test targets, test";
    return null;
}

/// Whether `want` are lines of `ls`, one after the other, with `want[1]` at `at`.
fn consecutive(ls: []const []const u8, at: usize, want: []const []const u8) bool {
    if (at == 0 or at - 1 + want.len > ls.len) return false;
    for (want, 0..) |w, i| if (!std.mem.eql(u8, ls[at - 1 + i], w)) return false;
    return true;
}

/// Whether a step starts (`      - `) after line `from` and up to line `to`.
fn stepStartBetween(ls: []const []const u8, from: usize, to: usize) bool {
    var i = from + 1;
    while (i <= to) : (i += 1) if (std.mem.startsWith(u8, ls[i], "      - ")) return true;
    return false;
}

/// Whether the `args:` line at `at` is the step `name`, then `between` in that order, then the buck2-farm
/// action, `with:`, the line itself and the remote assertion, with nothing else in between.
fn stepIs(ls: []const []const u8, at: usize, name: []const u8, between: []const []const u8) bool {
    const first = at -| (3 + between.len);
    if (at < 3 + between.len or !std.mem.eql(u8, ls[first], name)) return false;
    for (between, 0..) |want, i| if (!std.mem.eql(u8, ls[first + 1 + i], want)) return false;
    if (!std.mem.eql(u8, ls[at - 2], BUCK2_FARM) or !std.mem.eql(u8, ls[at - 1], "        with:")) return false;
    return at + 1 < ls.len and std.mem.eql(u8, ls[at + 1], ASSERT);
}

/// The args line of pr.yml's step that configures and analyses the release's macOS set for its platform
/// (release/darwin_analysis.bxl): a `bxl` script that asks for no build, so no action runs and no macOS
/// worker is asked for anything. The one non-comment line of a pull request workflow that may name the
/// macOS set; a `build` or `test` of it, or another spelling, names a macOS platform and is refused.
const ANALYSIS_ARGS = "          args: bxl --config-file release/darwin_analysis.buckconfig komira//release/darwin_analysis.bxl:check";

/// Null if pr.yml analyses the macOS set exactly once, in a buck2-farm step that asserts the run was
/// remote, else the refusal.
fn checkAnalysisStep(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(ar, l);
    const ls = lines.items;
    var at: usize = 0;
    var n: usize = 0;
    for (ls, 0..) |l, i| {
        if (std.mem.eql(u8, l, ANALYSIS_ARGS)) {
            n += 1;
            at = i;
        }
    }
    if (n == 0) return "pr.yml does not analyse the release's macOS set (release/darwin_analysis.bxl): a change that makes it unanalysable would pass its pull request";
    if (n > 1) return "pr.yml analyses the release's macOS set more than once";
    if (at < 2 or !std.mem.eql(u8, ls[at - 1], "        with:") or !std.mem.eql(u8, ls[at - 2], BUCK2_FARM))
        return "pr.yml analyses the macOS set outside the buck2-farm action (a step that ran an action locally would pass)";
    if (at + 1 >= ls.len or !std.mem.eql(u8, ls[at + 1], ASSERT)) return "pr.yml does not assert the analysis of the macOS set remote";
    return null;
}

/// Whether the workflow's `on:` names pull_request, pull_request_target or merge_group (the three
/// events that run a pull request's code before the merge, or its merge commit).
fn runsOnPullRequest(text: []const u8) bool {
    var in_on = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            in_on = std.mem.startsWith(u8, line, "on:");
            if (!in_on) continue;
        }
        if (!in_on or isComment(line)) continue;
        if (std.mem.indexOf(u8, line, "pull_request") != null or std.mem.indexOf(u8, line, "merge_group") != null) return true;
    }
    return false;
}

const MACOS_JOBS = [_][]const u8{ "build-macos-arm64", "testpypi-macos-arm64", "testpypi-smoke-macos-arm64", "testpypi-passed-macos-arm64", "result-testpypi-macos-arm64", "promote-macos-arm64", "pypi-macos-arm64", "pypi-smoke-macos-arm64", "result-pypi-macos-arm64" };
const LINUX_JOBS = [_][]const u8{ "build", "wheel-user-test", "testpypi", "testpypi-smoke", "testpypi-passed", "result-testpypi", "promote", "pypi", "pypi-smoke", "result-pypi" };
/// The jobs of the push half (the TestPyPI chain) and of the promotion; the rest of each name is the job's.
const PUSH_MACOS = [_][]const u8{ "build-macos-arm64", "testpypi-macos-arm64", "testpypi-smoke-macos-arm64", "testpypi-passed-macos-arm64", "result-testpypi-macos-arm64" };
const ON_PUSH = "github.event_name == 'push'";
const NOT_PUSH = "github.event_name != 'push'";
const PYPI_MACOS_BUILD = "build-macos-arm64";
/// The macOS build runs on a push to main alone.
const PYPI_MACOS_BUILD_GATE = "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'";
/// The only gate of a Mac build and of every step after the asking: TestPyPI does not list the wheel.
const PRESENT_GATE = "        if: steps.testpypi_file.outputs.present != 'true'";
const PRESENT_TESTPYPI_ID = "        id: testpypi_file";
const PRESENT_TESTPYPI_RUN = "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\" present --index testpypi --name-file \"$RUNNER_TEMP/pypi-macos-arm64/file_name\" --github-output \"$GITHUB_OUTPUT\"'";
const PRESENT_STEPS = "      - name: the macOS wheel on TestPyPI\n        id: testpypi_file\n" ++ PRESENT_TESTPYPI_RUN ++ "\n";
const DARWIN_PLATFORM = "--target-platforms komira//tools/build/platforms:darwin-arm64";
const PYTHONS_BUILD = "          args: build //python:supported_pythons[macos-arm64] --out ${{ runner.temp }}/pypi-macos-arm64/smoke/pythons.json";
const PYTHONS_OUTPUT = "      matrix: ${{ steps.matrix.outputs.matrix }}";
const PYTHONS_STEP_ID = "        id: matrix";
const PYTHONS_RUN = "        run: '\"$RUNNER_TEMP/pypi-macos-arm64/smoke/pypi_smoke\" matrix --pythons \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pythons.json\" --platform macos-arm64 --github-output \"$GITHUB_OUTPUT\"'";
/// The lines of a macOS smoke job that make it one job per Python of the list its chain built.
fn smokeMatrix(ar: std.mem.Allocator, producer: []const u8) ![4][]const u8 {
    return .{ "    strategy:", "      fail-fast: false", try std.fmt.allocPrint(ar, "      matrix: ${{{{ fromJSON(needs.{s}.outputs.matrix) }}}}", .{producer}), "          python-version: ${{ matrix.python }}" };
}
const MACOS_TARGETS = [_][]const u8{ "//python:komira_wheel_macos_arm64[release]", "//python:wheel_install_test_macos_arm64", "//python:wheel_libs_macos_arm64", "//python:wheel_same_macos_arm64", "//python/smoke:pypi_smoke_macos_arm64" };

/// Whether the `needs:` line names the job `job` (as one of its list items).
fn needsJob(line: []const u8, job: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "    needs:")) return false;
    var tok = std.mem.tokenizeAny(u8, line["    needs:".len..], " ,[]");
    while (tok.next()) |item| if (std.mem.eql(u8, item, job)) return true;
    return false;
}

/// The steps of a job (each from its `      - ` line up to the next), comments already dropped.
fn stepsOf(ar: std.mem.Allocator, job: []const []const u8) ![]const []const []const u8 {
    var out = std.ArrayList([]const []const u8).empty;
    var start: ?usize = null;
    for (job, 0..) |l, i| {
        if (!std.mem.startsWith(u8, l, "      - ")) continue;
        if (start) |s| try out.append(ar, job[s..i]);
        start = i;
    }
    if (start) |s| try out.append(ar, job[s..]);
    return try out.toOwnedSlice(ar);
}

fn isDarwinBuild(step: []const []const u8) bool {
    return startsWithAny(step, "          args: build") and mentions(step, DARWIN_PLATFORM);
}

/// The three flags every stamped build passes, so that both wheels of a run carry one version.
const STAMP_FLAGS = [_][]const u8{ "-c komira.package_stamp=${{ steps.stamp.outputs.build_number }}", "-c komira.package_commit=${{ steps.stamp.outputs.source_commit }}", "-c komira.package_timestamp_ms=${{ steps.stamp.outputs.timestamp_ms }}" };
const STAMP_RUN_TAIL = "/release_json\" stamp --revision \"$GITHUB_SHA\" --github-output \"$GITHUB_OUTPUT\"'";

/// Null if the job `name` of pypi.yml (`text`) stamps as the other build does, else the refusal: a step
/// "the stamp" that runs `release_json stamp --revision "$GITHUB_SHA"`, and every build of a //python
/// target but the Pythons' list passes the three stamp flags.
fn checkStamp(ar: std.mem.Allocator, text: []const u8, name: []const u8) !?[]const u8 {
    const job = try jobOf(ar, text, name);
    var stamp_step = false;
    for (try stepsOf(ar, job)) |step| {
        if (!has(step, "      - name: the stamp")) continue;
        for (step) |l| {
            if (std.mem.startsWith(u8, l, "        run: '\"$RUNNER_TEMP/") and std.mem.endsWith(u8, l, STAMP_RUN_TAIL)) stamp_step = true;
        }
    }
    if (!stamp_step) return try std.fmt.allocPrint(ar, "{s} has no step `the stamp` that runs release_json stamp --revision \"$GITHUB_SHA\": the two wheels of a run would not carry one version", .{name});
    var stamped: usize = 0;
    for (job) |l| {
        if (!std.mem.startsWith(u8, l, "          args: build") or std.mem.indexOf(u8, l, "//python") == null or std.mem.indexOf(u8, l, "supported_pythons") != null) continue;
        for (STAMP_FLAGS) |flag| {
            if (std.mem.indexOf(u8, l, flag) == null) return try std.fmt.allocPrint(ar, "{s} builds a //python target without the stamp flag `{s}`: the two wheels of a run would not carry one version", .{ name, flag });
        }
        stamped += 1;
    }
    if (stamped == 0) return try std.fmt.allocPrint(ar, "{s} builds no stamped //python target", .{name});
    return null;
}

/// Null if pypi.yml (`text`) holds the contract of the macOS wheel's nine jobs beside the Linux wheel's ten,
/// two independent chains in one file, else the refusal. The exact job list is pypi_workflow_test.zig's.
fn checkPypiMacos(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (runsOnPullRequest(text)) return "pypi.yml runs on a pull request (pull_request, pull_request_target or merge_group): it builds the wheels on main alone";
    for (MACOS_JOBS) |name| {
        var n: usize = 0;
        _ = try jobLines(ar, text, name, &n);
        if (n != 1) return try std.fmt.allocPrint(ar, "pypi.yml does not define the macOS job {s} exactly once", .{name});
    }
    for (LINUX_JOBS) |name| {
        var n: usize = 0;
        _ = try jobLines(ar, text, name, &n);
        if (n != 1) return try std.fmt.allocPrint(ar, "pypi.yml does not define the Linux job {s} exactly once", .{name});
    }

    // the two chains do not touch: no needs, no read of a result, no macOS word in a Linux job
    for ([_][]const []const u8{ &LINUX_JOBS, &MACOS_JOBS }, [_]bool{ false, true }) |own, own_macos| {
        for (own) |name| {
            const lines = try jobOf(ar, text, name);
            const others: []const []const u8 = if (own_macos) &LINUX_JOBS else &MACOS_JOBS;
            for (others) |other| {
                const reads = try std.fmt.allocPrint(ar, "needs.{s}.", .{other});
                for (lines) |l| {
                    if (needsJob(l, other)) return try std.fmt.allocPrint(ar, "{s} needs {s}: the {s} chain would wait on the {s} one", .{ name, other, if (own_macos) "macOS" else "Linux", if (own_macos) "Linux" else "macOS" });
                    if (std.mem.indexOf(u8, l, reads) != null) return try std.fmt.allocPrint(ar, "{s} reads the result of {s}: the two chains are independent", .{ name, other });
                }
            }
            if (!own_macos) {
                for (lines) |l| if (namesMacos(l)) return try std.fmt.allocPrint(ar, "{s} names a macOS platform, worker set or runner: only the macOS jobs do", .{name});
            }
        }
    }

    // both builds stamp the same way, so the two wheels of a run carry one version
    if (try checkStamp(ar, text, "build")) |why| return why;
    if (try checkStamp(ar, text, PYPI_MACOS_BUILD)) |why| return why;

    // each half's jobs run on their half's event only, and a chain keeps to its own record and artifacts
    for (MACOS_JOBS) |name| {
        const lines = try jobOf(ar, text, name);
        var want: []const u8 = NOT_PUSH;
        for (PUSH_MACOS) |p| if (std.mem.eql(u8, p, name)) {
            want = ON_PUSH;
        };
        const gate = if (std.mem.eql(u8, name, PYPI_MACOS_BUILD)) PYPI_MACOS_BUILD_GATE else for (lines) |l| {
            if (std.mem.startsWith(u8, l, "    if: ")) break l;
        } else return try std.fmt.allocPrint(ar, "{s} has no condition: it would run in both halves of the run", .{name});
        if (std.mem.indexOf(u8, gate, want) == null) return try std.fmt.allocPrint(ar, "{s} is not gated on {s}: a run is exactly one half", .{ name, want });
        for (lines) |l| {
            if (std.mem.indexOf(u8, l, "key: pypi-passed-") != null and std.mem.indexOf(u8, l, "pypi-passed-macos-arm64-") == null) return try std.fmt.allocPrint(ar, "{s} reads or writes a record that is not the macOS one (pypi-passed-macos-arm64-)", .{name});
            if (std.mem.startsWith(u8, l, "          name: pypi-") and std.mem.indexOf(u8, l, "-macos-arm64-") == null) return try std.fmt.allocPrint(ar, "{s} reads an artifact that is not a macOS one: the chains share no artifact", .{name});
        }
    }
    // the jobs that upload or promote run the Linux driver on a Linux runner, the smoke jobs the macOS one on a Mac
    for ([_][]const u8{ "testpypi-macos-arm64", "testpypi-passed-macos-arm64", "promote-macos-arm64", "pypi-macos-arm64" }) |name| {
        const lines = try jobOf(ar, text, name);
        if (mentions(lines, "pypi_smoke_macos_arm64")) return try std.fmt.allocPrint(ar, "{s} runs the macOS driver on a Linux runner", .{name});
    }
    for ([_][2][]const u8{ .{ "testpypi-smoke-macos-arm64", "build-macos-arm64" }, .{ "pypi-smoke-macos-arm64", "promote-macos-arm64" } }) |pair| {
        const name = pair[0];
        const lines = try jobOf(ar, text, name);
        if (!has(lines, "    runs-on: macos-15")) return try std.fmt.allocPrint(ar, "{s} does not run on macos-15", .{name});
        if (mentions(lines, "smoke/pypi_smoke\"")) return try std.fmt.allocPrint(ar, "{s} runs the Linux driver on a macOS runner", .{name});
        if (!mentions(lines, "smoke/pypi_smoke_macos_arm64\" verify") or !mentions(lines, "smoke/pypi_smoke_macos_arm64\" install")) return try std.fmt.allocPrint(ar, "{s} does not verify and install with the macOS driver", .{name});
        // the quickstart files come from the smoke artifact: no checkout
        if (mentions(lines, "actions/checkout") or mentions(lines, "python/examples")) return try std.fmt.allocPrint(ar, "{s} takes the quickstart from a checkout: it is in the smoke artifact", .{name});
        if (!mentions(lines, "--example \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.py\"")) return try std.fmt.allocPrint(ar, "{s} does not read the quickstart from the smoke artifact", .{name});
        for (try smokeMatrix(ar, pair[1])) |l| {
            if (!has(lines, l)) return try std.fmt.allocPrint(ar, "{s} is not one job per Python of {s}'s list, each run to the end: the line `{s}` is missing", .{ name, pair[1], l });
        }
    }
    // the promotion's job restores the macOS record and has no needs; the upload job needs exactly it
    const promote = try jobOf(ar, text, "promote-macos-arm64");
    if (startsWithAny(promote, "    needs:")) return "promote-macos-arm64 has needs: it starts the promotion";
    if (!has(promote, "          key: pypi-passed-macos-arm64-")) return "promote-macos-arm64 does not restore the newest macOS record (pypi-passed-macos-arm64-)";
    if (!mentions(promote, "--platform macos-arm64") or !mentions(promote, "passed/pythons.json")) return "promote-macos-arm64 does not write the macOS job matrix from the record's list of the Pythons";
    const up = try jobOf(ar, text, "pypi-macos-arm64");
    if (!has(up, "    needs: promote-macos-arm64")) return "pypi-macos-arm64 does not need exactly promote-macos-arm64";
    const result_pypi = try jobOf(ar, text, "result-pypi-macos-arm64");
    if (!mentions(result_pypi, "needs.promote-macos-arm64.result != 'success'")) return "result-pypi-macos-arm64 does not fail a promotion that did not succeed";

    // the build: on the ubuntu runner, joined to the farm with the macOS worker set
    const job = try jobOf(ar, text, PYPI_MACOS_BUILD);
    if (!has(job, "    runs-on: ubuntu-24.04")) return "build-macos-arm64 does not run on ubuntu-24.04 (a hosted macOS runner is not the farm's Macs)";
    if (mentions(job, "runs-on: macos") or mentions(job, "runs-on: [")) return "build-macos-arm64 names a hosted macOS runner";
    if (!has(job, "    environment: build")) return "build-macos-arm64 is not in the environment build";
    if (!has(job, PYPI_MACOS_BUILD_GATE)) return "build-macos-arm64 does not run on a push to main alone (if: github.ref == 'refs/heads/main' && github.event_name == 'push')";
    if (startsWithAny(job, "    needs:")) return "build-macos-arm64 has needs: it waits on another job";
    const connect_at = lineAt(job, FARM_CONNECT) orelse return "build-macos-arm64 does not join the farm";
    if (!has(job, QOS)) return "build-macos-arm64 does not pass farm-qos: batch";
    if (!has(job, DARWIN_PROPS)) return "build-macos-arm64 does not pass the macOS worker properties to farm-connect (darwin-properties)";
    if (!has(job, DARWIN_HOSTS)) return "build-macos-arm64 does not pass the macOS worker hosts to farm-connect (darwin-macos-hosts)";
    if (!has(job, "          tls: ${{ vars.FARM_TLS || 'false' }}")) return "build-macos-arm64 does not pass tls from FARM_TLS";
    for (job, 0..) |line, i| {
        if (std.mem.startsWith(u8, line, "          args: ") and i < connect_at) return "build-macos-arm64 builds before it joins the farm";
    }
    // every step is one command: a check of the buckconfig is the first darwin build's analysis
    if (mentions(job, "run: |") or mentions(job, "run: >")) return "build-macos-arm64 has a multi-line run step: every step is one command";
    if (mentions(job, "--no-remote-cache") or mentions(job, "--isolation-dir")) return "build-macos-arm64 builds with --no-remote-cache or --isolation-dir";

    // every buck2 step is the farm action, asserted remote
    const steps = try stepsOf(ar, job);
    for (steps) |step| {
        if (!mentions(step, "          args: ")) continue;
        if (!has(step, BUCK2_FARM) or !has(step, ASSERT)) return "build-macos-arm64 builds outside the buck2-farm action, or without the remote assertion";
    }

    // the order: the file name, the TestPyPI presence check, then the Mac builds, each gated on it alone
    var present_testpypi: ?usize = null;
    var file_name_at: ?usize = null;
    var first_mac_build: ?usize = null;
    var seen = [_]usize{0} ** MACOS_TARGETS.len;
    for (steps, 0..) |step, i| {
        if (has(step, PRESENT_TESTPYPI_ID) and has(step, PRESENT_TESTPYPI_RUN)) present_testpypi = i;
        if (!isDarwinBuild(step)) continue;
        if (mentions(step, "//python:komira_wheel_macos_arm64[file_name]")) {
            file_name_at = i;
            if (has(step, PRESENT_GATE)) return "build-macos-arm64 builds the wheel's file name behind the present gate: nothing could ask the indexes without it";
            continue;
        }
        var known = false;
        for (MACOS_TARGETS, 0..) |target, k| {
            if (mentions(step, target)) {
                seen[k] += 1;
                known = true;
            }
        }
        if (!known) return "build-macos-arm64 builds a target for macOS that is not the wheel, its install test, its read-back checks, its driver or the wheel's file name";
        if (first_mac_build == null) first_mac_build = i;
    }
    const tp_at = present_testpypi orelse return "build-macos-arm64 does not ask TestPyPI whether it lists the macOS wheel (pypi_smoke present --index testpypi)";
    const name_at = file_name_at orelse return "build-macos-arm64 does not build the macOS wheel's file name before it asks TestPyPI";
    if (name_at > tp_at) return "build-macos-arm64 asks the indexes before it has built the wheel's file name";
    for (seen) |k| if (k != 1) return "build-macos-arm64 does not build each of the macOS wheel, its install test, its read-back checks and its driver exactly once";
    if (first_mac_build.? < tp_at) return "build-macos-arm64 starts a Mac build before the present step";
    for (steps) |step| {
        if (isDarwinBuild(step) and !mentions(step, "[file_name]") and !has(step, PRESENT_GATE)) return "a Mac build of build-macos-arm64 does not carry the present gate";
    }
    for (steps[tp_at + 1 ..]) |step| {
        if (has(step, "      - name: Stop buck2")) continue;
        if (!has(step, PRESENT_GATE)) return "a step of build-macos-arm64 after the present steps does not carry the present gate";
    }
    if (!has(job, "      version: ${{ steps.dist.outputs.version }}")) return "build-macos-arm64 does not publish the version of its dist step as its output";
    // the list of the Pythons the smoke jobs install: built into the smoke directory on every run, before TestPyPI is asked
    var list_at: ?usize = null;
    var list_out_at: ?usize = null;
    for (steps, 0..) |step, i| {
        if (has(step, PYTHONS_BUILD)) list_at = i;
        if (has(step, PYTHONS_STEP_ID) and has(step, PYTHONS_RUN)) list_out_at = i;
    }
    const l_at = list_at orelse return "build-macos-arm64 does not build the list of the supported Pythons for macOS (//python:supported_pythons[macos-arm64])";
    const lo_at = list_out_at orelse return "build-macos-arm64 does not write the job matrix of the supported Pythons to its step output `matrix` (pypi_smoke matrix of the macOS list)";
    if (!has(job, PYTHONS_OUTPUT)) return "build-macos-arm64 does not publish the job matrix of the supported Pythons as its output `matrix`";
    if (l_at > lo_at or lo_at > tp_at) return "build-macos-arm64 makes the list of the supported Pythons after the indexes are asked: a run that builds no wheel would have no list";
    const result = try jobOf(ar, text, "result-testpypi-macos-arm64");
    if (!has(result, "        if: needs.build-macos-arm64.result != 'success'")) return "result-testpypi-macos-arm64 does not fail a run whose macOS build did not succeed, whatever the run's input";
    for (MACOS_JOBS) |name| {
        const lines = try jobOf(ar, text, name);
        for (lines) |l| {
            const trimmed = std.mem.trimLeft(u8, l, " ");
            if (trimmed.len > 0 and trimmed[0] == '#') continue;
            if (std.mem.indexOf(u8, l, "inputs.") != null) return try std.fmt.allocPrint(ar, "{s} reads a run input: the macOS chain is not gated on any input", .{name});
        }
    }
    return null;
}

fn work(ar: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
}

fn readData(ar: std.mem.Allocator, rel: []const []const u8) ![]const u8 {
    const w = try work(ar);
    var parts = std.ArrayList([]const u8).empty;
    try parts.append(ar, w);
    try parts.appendSlice(ar, rel);
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, parts.items), 1 << 22);
}

/// The file names of the directory `sub` of the test's data, sorted.
fn listDir(ar: std.mem.Allocator, sub: []const u8) ![]const []const u8 {
    const path = try std.fs.path.join(ar, &.{ try work(ar), sub });
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var out = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) continue;
        try out.append(ar, try ar.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

/// Fails unless `got` is a refusal that holds `want`.
fn expectMsg(got_or_null: ?[]const u8, want: []const u8) !void {
    const got = got_or_null orelse {
        std.debug.print("accepted a text that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    return expectMsg(try checkMacos(ar, text), want);
}

fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the case's anchor is not in release.yml: {s}\n", .{from});
        return error.NoAnchor;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

/// `text` with `line` (and its newline) added as the first line of the job `release-macos` body.
fn intoJob(ar: std.mem.Allocator, text: []const u8, line: []const u8) ![]const u8 {
    return replaced(ar, text, "  release-macos:\n", try std.fmt.allocPrint(ar, "  release-macos:\n{s}\n", .{line}));
}

fn expectRefusedRelease(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    return expectMsg(try checkRelease(ar, text), want);
}

fn expectRefusedGroups(mac: []const u8, rel: []const u8, want: []const u8) !void {
    return expectMsg(checkGroups(mac, rel), want);
}

test "release-macos.yml holds the contract of the macOS build, in a group of its own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, &.{ "workflows", "release-macos.yml" });
    if (try checkMacos(ar, text)) |why| {
        std.debug.print("release-macos.yml: {s}\n", .{why});
        return error.Refused;
    }
    // never a pull request, a merge group or a pull_request_target
    try t.expect(!runsOnPullRequest(text));
    const rel = try readData(ar, &.{ "workflows", "release.yml" });
    if (checkGroups(text, rel)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
    // and release.yml holds no macOS job
    if (try checkRelease(ar, rel)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "each edit of the real workflows that breaks the macOS build's separation is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, &.{ "workflows", "release-macos.yml" });
    const rel = try readData(ar, &.{ "workflows", "release.yml" });

    // the trigger: a pull request in any of its three spellings, a schedule, a run after another workflow
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n"), "runs on a pull request");
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request_target:\n"), "runs on a pull request");
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n  merge_group:\n"), "runs on a pull request");
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n  schedule:\n    - cron: '0 3 * * *'\n"), "trigger beyond push");
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", "  workflow_dispatch:\n  workflow_run:\n    workflows: [release]\n"), "trigger beyond push");
    try expectRefused(ar, try replaced(ar, text, "  workflow_dispatch:\n", ""), "not triggered by push and workflow_dispatch");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main, 'release/**']\n"), "does not run on push to main");

    // the group: release.yml's own would queue the macOS build behind a release and a release behind it
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: true\n", "  cancel-in-progress: false\n"), "cancel-in-progress: true");
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: true\n", ""), "no cancel-in-progress");
    const rel_group = concurrencyValue(rel, "group").?;
    try expectRefusedGroups(try replaced(ar, text, "  group: release-macos-${{ github.ref }}\n", try std.fmt.allocPrint(ar, "  group: {s}\n", .{rel_group})), rel, "release.yml's concurrency group");
    try expectRefusedGroups(try replaced(ar, text, "  group: release-macos-${{ github.ref }}\n", "  group: release-main\n"), rel, "release-main");
    try expectRefusedGroups(try replaced(ar, text, "concurrency:\n  group: release-macos-${{ github.ref }}\n  cancel-in-progress: true\n", ""), rel, "no concurrency group");

    // release.yml holds no macOS job
    try expectRefusedRelease(ar, try replaced(ar, rel, "  mopm-stage:\n", "  release-macos:\n    runs-on: ubuntu-24.04\n\n  mopm-stage:\n"), "has a job release-macos");
    try expectRefusedRelease(ar, try replaced(ar, rel, "    needs: [release, mopm-stage]\n", "    needs: [release, mopm-stage, release-macos]\n"), "needs release-macos");
    try expectRefusedRelease(ar, try replaced(ar, rel, "    needs: prod-commit\n", "    needs: [prod-commit, release-macos]\n"), "needs release-macos");
    try expectRefusedRelease(ar, try replaced(ar, rel, "    needs: prod-stage\n", "    needs: prod-stage\n    if: needs.release-macos.result == 'success'\n"), "reads the result of release-macos");
    try expectRefusedRelease(ar, try replaced(ar, rel, "          args: build //release/ci:check_release_ref --out", "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 //release/ci:check_release_ref --out"), "outside mopm-stage's macOS keys");
    try expectRefusedRelease(ar, try replaced(ar, rel, "  mopm-stage:\n    runs-on: ubuntu-24.04\n", "  mopm-stage:\n    runs-on: macos-15\n"), "its build of the packages: runs-on: macos-15");
    // the build of the packages, spelled another way (a --target-platforms of the whole build), is not mopm-stage's line
    try expectRefusedRelease(ar, try replaced(ar, rel, PACKAGES_BUILD, PACKAGES_BUILD ++ " --target-platforms komira//tools/build/platforms:darwin-arm64"), "outside mopm-stage's macOS keys");
    // the second Mojo's build with a macOS platform of its own is not mopm-stage's line either: only the Linux row of
    // MOJO_NEXT_PLATFORM is allowed, the release target's transition picks the macOS half
    try expectRefusedRelease(ar, try replaced(ar, rel, PACKAGES_BUILD_NEXT, try std.mem.replaceOwned(u8, ar, PACKAGES_BUILD_NEXT, "linux-x86_64-mojo-1.2.0", "darwin-arm64-mojo-1.2.0")), "outside mopm-stage's macOS keys");
    try expectRefusedRelease(ar, try replaced(ar, rel, "--out ${{ runner.temp }}/mopm-publish/release_staged_verify\n", "--out ${{ runner.temp }}/mopm-publish/release_staged_verify --target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0 --target-platforms komira//tools/build/platforms:darwin-arm64\n"), "outside mopm-stage's macOS keys");
    // the macOS keys in another job, or twice, or missing from mopm-stage
    try expectRefusedRelease(ar, try replaced(ar, rel, "  prod-test:\n", "  prod-test:\n    env:\n" ++ DARWIN_PROPS ++ "\n"), "is mopm-stage's, once");
    try expectRefusedRelease(ar, try replaced(ar, rel, DARWIN_HOSTS ++ "\n", ""), "mopm-stage does not hold `darwin-macos-hosts");
    try expectRefusedRelease(ar, try replaced(ar, rel, PACKAGES_BUILD ++ "\n", ""), "mopm-stage does not hold `args: build --config-file");
    // what mopm-stage holds is accepted, and every line of it is needed
    try t.expect((try checkRelease(ar, rel)) == null);
    inline for (MOPM_STAGE_MACOS) |l| try expectRefusedRelease(ar, try replaced(ar, rel, l ++ "\n", ""), "mopm-stage does not hold");
    // a comment in release.yml may speak of the macOS build
    try t.expect((try checkRelease(ar, try std.fmt.allocPrint(ar, "{s}\n# the macOS build is release-macos.yml\n", .{rel}))) == null);
}

test "each edit of the real release-macos.yml that breaks the macOS build's contract is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, &.{ "workflows", "release-macos.yml" });
    const head = "  release-macos:\n    runs-on: ubuntu-24.04\n";

    // the job exists, once
    try expectRefused(ar, try replaced(ar, text, "  release-macos:\n", "  release-macos-gone:\n"), "has no job release-macos");
    try expectRefused(ar, try std.fmt.allocPrint(ar, "{s}\n  release-macos:\n    runs-on: ubuntu-24.04\n", .{text}), "more than once");

    // on the farm's workers, not a hosted macOS runner
    try expectRefused(ar, try replaced(ar, text, head, "  release-macos:\n    runs-on: macos-15\n"), "does not run on ubuntu-24.04");
    try expectRefused(ar, try replaced(ar, text, head, head ++ "    runs-on: macos-15\n"), "names a hosted macOS runner");
    try expectRefused(ar, try replaced(ar, text, "    environment: build\n    timeout-minutes: 90\n", "    timeout-minutes: 90\n"), "not in the environment build");

    // it does not hold up the Linux path
    try expectRefused(ar, try intoJob(ar, text, "    needs: release"), "waits on another job");
    try expectRefused(ar, try intoJob(ar, text, "    if: github.event_name == 'push'"), "has a condition");
    try expectRefused(ar, try intoJob(ar, text, CONTINUE_ON_ERROR), "would end the run green");
    try expectRefused(ar, try intoJob(ar, text, "    continue-on-error: false"), "would end the run green");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", ""), "no timeout-minutes");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 360\n"), "not bounded at 120");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 0\n"), "not bounded at 120");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 100\n"), "not the 90");

    // the farm connection and its priority
    try expectRefused(ar, try replaced(ar, text, DARWIN_PROPS ++ "\n", ""), "darwin-properties");
    try expectRefused(ar, try replaced(ar, text, DARWIN_HOSTS ++ "\n", ""), "darwin-macos-hosts");
    try expectRefused(ar, try replaced(ar, text, DARWIN_PROPS ++ "\n" ++ DARWIN_HOSTS ++ "\n", ""), "darwin-properties");
    try expectRefused(ar, try replaced(ar, text, "          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}\n          tls: ${{ vars.FARM_TLS || 'false' }}\n          # main's release work queues behind the pull-request checks when the farm is full\n          farm-qos: batch\n      # Without", "          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}\n          tls: ${{ vars.FARM_TLS || 'false' }}\n      # Without"), "farm-qos: batch");
    try expectRefused(ar, try replaced(ar, text, "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}\n          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}\n          tls: ${{ vars.FARM_TLS || 'false' }}\n", "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}\n          macos-library-dirs: ${{ vars.FARM_MACOS_LIBRARY_DIRS }}\n"), "tls from FARM_TLS");
    try expectRefused(ar, try replaced(ar, text, "linux_x86_64_properties darwin_arm64_properties darwin_macos_hosts", "linux_x86_64_properties"), "macOS set and the macOS hosts");
    // the report of a failed build: what buck2 said, the failed step, and no guess
    try expectRefused(ar, try replaced(ar, text, SAID_RUN ++ "\n", ""), "does not read the build's log with buck2_failure");
    try expectRefused(ar, try replaced(ar, text, REPORT_OUTPUT, "      report: ${{ "), "does not pass what buck2 printed");
    try expectRefused(ar, try replaced(ar, text, " || " ++ REPORT_PYTHON, ""), "does not name a failed build step");
    try expectRefused(ar, try replaced(ar, text, " || " ++ REPORT_SET, ""), "does not name a failed build step");
    try expectRefused(ar, try replaced(ar, text, SAID_IF, "        if: failure()"), "exactly when a buck2 step failed");
    try expectRefused(ar, try replaced(ar, text, REPORT_ENV ++ "\n", ""), "does not print the build job's report");
    try expectRefused(ar, try replaced(ar, text, REPORT_ECHO, "              echo \"::error title=release-macos::the macOS build did not pass: ${BUILD_RESULT:-"), "does not print the build job's report");
    try expectRefused(ar, try replaced(ar, text, REPORT_ECHO, "              if [ -n \"$REPORT\" ]; then :; fi\n" ++ REPORT_ECHO), "branches in shell");
    try expectRefused(ar, try replaced(ar, text, "(the checkout or farm-connect failed; the log of the job says why)", "(" ++ GUESS ++ ")"), "guesses at the cause");
    try expectRefused(ar, try replaced(ar, text, "      - name: the buckconfig names the farm and its macOS workers\n", "      - name: no check\n"), "names the macOS workers");

    // the build: the platform, the target, the farm action, asserted
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --keep-going //release:mopm_darwin_libs"), "for --target-platforms komira//tools/build/platforms:darwin-arm64");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --target-platforms komira//tools/build/platforms:linux-x86_64 --keep-going //release:mopm_darwin_libs"), "for --target-platforms komira//tools/build/platforms:darwin-arm64");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:mopm_artifacts"), "exactly one buck2 step");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, BUILD_ARGS ++ " --no-remote-cache"), "does not build //release:mopm_darwin_libs for");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS ++ "\n" ++ ASSERT ++ "\n      # The Python test harness on macOS arm64", BUILD_ARGS ++ "\n      # The Python test harness on macOS arm64"), "does not assert the build remote");
    try expectRefused(ar, try replaced(ar, text, "      - name: build the macOS set\n        id: build\n        uses: ./.github/actions/buck2-farm\n", "      - name: build the macOS set\n        id: build\n        uses: ./.github/actions/other\n"), "outside the buck2-farm action");

    // the run ends failed when the build did not run
    try expectRefused(ar, try replaced(ar, text, "\n  release-macos-result:\n", "\n  release-macos-final:\n"), "has no job release-macos-result");
    try expectRefused(ar, try replaced(ar, text, "    needs: release-macos\n", "    needs: [release-macos, other]\n"), "does not need exactly release-macos");
    try expectRefused(ar, try replaced(ar, text, "    needs: release-macos\n    if: always()\n", "    needs: release-macos\n"), "not if: always()");
    try expectRefused(ar, try replaced(ar, text, "    needs: release-macos\n    if: always()\n", "    needs: release-macos\n    if: failure()\n"), "not if: always()");
    try expectRefused(ar, try replaced(ar, text, "needs.release-macos.result", "needs.release-macos.outcome"), "does not read the result");
    try expectRefused(ar, try replaced(ar, text, RESULT_REASON, "the macOS build ended"), "does not say");
    try expectRefused(ar, try replaced(ar, text, "exit 1 ;;", "exit 0 ;;"), "never fails");
    try expectRefused(ar, try replaced(ar, text, "    needs: release-macos\n    if: always()\n", "    needs: release-macos\n    if: always()\n    continue-on-error: true\n"), "its failure would read as success");

    // nothing publishes from it
    try expectRefused(ar, try replaced(ar, text, "      - name: the macOS build failed\n", "      - run: mopm publish --staged x --registry prod --oidc\n      - name: the macOS build failed\n"), "publishes");
}

test "a workflow that runs on a pull request holds no macOS build, and the real ones hold none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // every workflow of the checkout (the zig_test's data holds each file of .github/workflows)
    var on_pr: usize = 0;
    for (try listDir(ar, "workflows")) |name| {
        const text = try readData(ar, &.{ "workflows", name });
        if (checkPullRequestWorkflow(name, text)) |why| {
            std.debug.print("{s}: {s}\n", .{ name, why });
            return error.MacosInPullRequest;
        }
        if (runsOnPullRequest(text)) on_pr += 1;
        // release-macos.yml is the one with a macOS build of the release, and it runs on no pull request
        if (std.mem.eql(u8, name, "release-macos.yml")) try t.expect(!runsOnPullRequest(text));
        // and so is pypi.yml, which builds both wheels
        if (std.mem.eql(u8, name, "pypi.yml")) try t.expect(!runsOnPullRequest(text));
    }
    // the check reads pr.yml and coverage.yml: were the trigger reader broken, nothing would be read
    try t.expect(on_pr >= 2);
}

test "the reader of pull request workflows sees each macOS line added to the real pr.yml" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    try t.expect(runsOnPullRequest(pr));
    try t.expect(checkPullRequestWorkflow("pr.yml", pr) == null);
    const added = [_][]const u8{
        // a build for macOS spelled other than the macOS part's own line: without its config file, over
        // another list, or with a cold cache
        "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 @targets.txt",
        "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going @${{ runner.temp }}/darwin_targets.txt",
        PR_BUILD_ARGS ++ " --no-remote-cache",
        "          args: build //release:mopm_darwin_libs",
        // the macOS keys under another input name than the part's
        "          darwin-config: ${{ runner.temp }}/darwin.buckconfig",
        "    runs-on: macos-15",
        "          args: build komira//tools/build/mojo:act_darwin",
        "          args: build toolchains//:mojo_compiler_1.1.0_osx-arm64",
        // the analysis line's exception is that line only: a build of the set, or a target platform
        // added to it, is a macOS build
        "          args: build --config-file release/darwin_analysis.buckconfig //release:mopm_darwin_libs",
        "          args: bxl --config-file release/darwin_analysis.buckconfig --target-platforms komira//tools/build/platforms:darwin-arm64 komira//release/darwin_analysis.bxl:check",
        "          args: test --config-file release/darwin_analysis.buckconfig komira//release/darwin_analysis.bxl:check",
        ANALYSIS_ARGS ++ " //release:mopm_darwin_libs",
        // the Mojo 1.2.0 lines' exception is those lines only: a platform of another Mojo or another
        // architecture, or a test of it, is a build for a platform
        "          args: build --keep-going --target-platforms komira//tools/build/platforms:linux-arm64-mojo-1.2.0 @${{ runner.temp }}/targets.txt",
        "          args: build --keep-going --target-platforms komira//tools/build/platforms:darwin-arm64-mojo-1.2.0 @${{ runner.temp }}/targets.txt",
        NEXT_TEST_ARGS ++ " --no-remote-cache --target-platforms komira//tools/build/platforms:darwin-arm64",
    };
    for (added) |line| {
        const bad = try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ pr, line });
        if (checkPullRequestWorkflow("pr.yml", bad) == null) {
            std.debug.print("a pull request workflow with this line was accepted: {s}\n", .{line});
            return error.Accepted;
        }
    }
    // a comment may speak of it, and a workflow that is not run by a pull request may name it
    try t.expect(checkPullRequestWorkflow("pr.yml", try std.fmt.allocPrint(ar, "{s}\n# the macOS build is the workflow release-macos.yml\n", .{pr})) == null);
    // the lines of pr.yml's macOS part are pr.yml's alone: in coverage.yml each is refused
    const coverage = try readData(ar, &.{ "workflows", "coverage.yml" });
    try t.expect(checkPullRequestWorkflow("coverage.yml", coverage) == null);
    // a line of the Mojo 1.2.0 part that carries `--target-platforms` is refused too (its two lines: the build and the test)
    var next_platform_lines: usize = 0;
    for (PR_MOJO_NEXT) |line| {
        if (std.mem.indexOf(u8, line, "--target-platforms") == null) continue;
        next_platform_lines += 1;
        try t.expect(namesMacos(line));
        try t.expect(checkPullRequestWorkflow("coverage.yml", try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ coverage, line })) != null);
    }
    try t.expectEqual(@as(usize, 2), next_platform_lines);
    // a line of the Mojo 1.2.0 platform that is none of pr.yml's own lines is refused in pr.yml: building //x:y
    // with it is not the part's build
    const stray_next = "          args: build --keep-going " ++ MOJO_NEXT_PLATFORM ++ " //x:y";
    try expectMsg(checkPullRequestWorkflow("pr.yml", try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ pr, stray_next })), "names a macOS platform, worker set or runner outside pr.yml's macOS part");
    for (PR_MACOS_PART) |line| {
        if (!namesMacos(line)) continue; // a step name or a bound is no platform
        if (checkPullRequestWorkflow("coverage.yml", try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ coverage, line })) == null) {
            std.debug.print("coverage.yml with a line of pr.yml's macOS part was accepted: {s}\n", .{line});
            return error.Accepted;
        }
    }
    const release = try readData(ar, &.{ "workflows", "release.yml" });
    try t.expect(checkPullRequestWorkflow("release.yml", release) == null);
    // every spelling of the trigger is seen
    try t.expect(runsOnPullRequest("name: x\non: pull_request\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non: [push, pull_request]\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non:\n  merge_group:\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non:\n  pull_request_target:\n    branches: [main]\njobs:\n"));
    try t.expect(!runsOnPullRequest("name: x\non:\n  push:\n    branches: [main]\n  # pull_request\njobs:\n  a:\n    steps:\n      - run: echo pull_request\n"));
}

/// Fails unless the pypi.yml text `text` is refused with `want`.
fn expectRefusedPypi(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    return expectMsg(try checkPypiMacos(ar, text), want);
}

/// The publish workflow of both wheels, as the zig_test's data holds it.
const Pypi = struct { text: []const u8 };

fn readPypi(ar: std.mem.Allocator) !Pypi {
    return .{ .text = try readData(ar, &.{ "workflows", "pypi.yml" }) };
}

/// `text` with the first `from` at or after the header of the job `job` replaced by `to`.
fn inJob(ar: std.mem.Allocator, text: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const header = try std.fmt.allocPrint(ar, "\n  {s}:\n", .{job});
    const start = std.mem.indexOf(u8, text, header) orelse {
        std.debug.print("the case's job is not in the workflow: {s}\n", .{job});
        return error.NoAnchor;
    };
    const at = std.mem.indexOfPos(u8, text, start, from) orelse {
        std.debug.print("the case's anchor is not in job {s} of the workflow: {s}\n", .{ job, from });
        return error.NoAnchor;
    };
    return try std.mem.concat(ar, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

test "pypi.yml holds the contract of the macOS jobs beside the Linux ones, independent of them, and runs on no pull request" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    if (try checkPypiMacos(ar, w.text)) |why| {
        std.debug.print("pypi.yml: {s}\n", .{why});
        return error.Refused;
    }
    try t.expect(!runsOnPullRequest(w.text));
    // a comment of a Linux job may speak of the macOS jobs
    try t.expect((try checkPypiMacos(ar, try inJob(ar, w.text, "build", "    steps:\n", "    steps:\n      # the macOS wheel's jobs are below, darwin-arm64\n"))) == null);
}

test "an edit that gives one build a stamp of its own, so the two wheels of a run would not carry one version, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    const run_tail = "stamp --revision \"$GITHUB_SHA\" --github-output";
    try expectRefusedPypi(ar, try inJob(ar, w.text, "build", run_tail, "stamp --revision \"$GITHUB_REF\" --github-output"), "build has no step `the stamp`");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "build-macos-arm64", run_tail, "stamp --revision HEAD --github-output"), "build-macos-arm64 has no step `the stamp`");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "build-macos-arm64", "      - name: the stamp\n", "      - name: the stamp of the Mac\n"), "build-macos-arm64 has no step `the stamp`");
    for (STAMP_FLAGS) |flag| {
        const with_space = try std.fmt.allocPrint(ar, "{s} ", .{flag});
        try expectRefusedPypi(ar, try inJob(ar, w.text, "build", with_space, ""), "build builds a //python target without the stamp flag");
        try expectRefusedPypi(ar, try inJob(ar, w.text, "build-macos-arm64", with_space, ""), "build-macos-arm64 builds a //python target without the stamp flag");
    }
}

test "an edit that joins the Linux chain and the macOS chain, drops or doubles a job of pypi.yml, or runs it on a pull request, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    // on a pull request or a merge group
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  workflow_dispatch:\n", "\n  pull_request:\n  workflow_dispatch:\n"), "pypi.yml runs on a pull request");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  workflow_dispatch:\n", "\n  merge_group:\n  workflow_dispatch:\n"), "pypi.yml runs on a pull request");
    // a job of either half missing from pypi.yml, or defined twice, is a chain that is not the contract's
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  build-macos-arm64:\n", "\n  build-macos:\n"), "pypi.yml does not define the macOS job build-macos-arm64 exactly once");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  result-pypi:\n", "\n  result-pypi:\n    runs-on: ubuntu-24.04\n\n  result-pypi:\n"), "pypi.yml does not define the Linux job result-pypi exactly once");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  wheel-user-test:\n", "\n  wheel-user:\n"), "pypi.yml does not define the Linux job wheel-user-test exactly once");
    // a Linux job that waits on the macOS build, or on a macOS job in a list
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi", "    needs: [build, wheel-user-test]\n", "    needs: [build, wheel-user-test, build-macos-arm64]\n"), "testpypi needs build-macos-arm64");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "result-testpypi", "    needs: [build, wheel-user-test, testpypi, testpypi-smoke, testpypi-passed]\n", "    needs: [build, wheel-user-test, testpypi, testpypi-smoke, testpypi-passed, result-testpypi-macos-arm64]\n"), "result-testpypi needs result-testpypi-macos-arm64");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi", "    needs: promote\n", "    needs: [promote, promote-macos-arm64]\n"), "pypi needs promote-macos-arm64");
    // the Linux user test of the wheel file is a Linux job: the macOS chain does not wait on it
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi-macos-arm64", "    needs: build-macos-arm64\n", "    needs: [build-macos-arm64, wheel-user-test]\n"), "testpypi-macos-arm64 needs wheel-user-test");
    // a Linux job that reads a macOS job's output or result
    try expectRefusedPypi(ar, try inJob(ar, w.text, "result-testpypi", "    steps:\n", "    steps:\n      - run: echo \"$X\"\n        env:\n          X: ${{ needs.build-macos-arm64.outputs.version }}\n"), "result-testpypi reads the result of build-macos-arm64");
    // a macOS job that waits on the Linux build, on a Linux upload, or reads one's output
    try expectRefusedPypi(ar, try inJob(ar, w.text, "build-macos-arm64", "    runs-on: ubuntu-24.04\n", "    needs: build\n    runs-on: ubuntu-24.04\n"), "build-macos-arm64 needs build");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "    needs: [promote-macos-arm64, pypi-macos-arm64]\n", "    needs: [promote-macos-arm64, pypi-macos-arm64, pypi]\n"), "pypi-smoke-macos-arm64 needs pypi");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "needs.testpypi-macos-arm64.outputs.state == 'differs'\n", "needs.testpypi.outputs.state == 'differs'\n"), "result-testpypi-macos-arm64 reads the result of testpypi");
    // the promotion chain: promote-macos-arm64 waits on the Linux promotion, pypi-macos-arm64 takes the Linux artifact or record
    try expectRefusedPypi(ar, try inJob(ar, w.text, "promote-macos-arm64", "    runs-on: ubuntu-24.04\n", "    needs: promote\n    runs-on: ubuntu-24.04\n"), "promote-macos-arm64 needs promote");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi-macos-arm64", "    needs: promote-macos-arm64\n", "    needs: [promote-macos-arm64, promote]\n"), "pypi-macos-arm64 needs promote");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi-macos-arm64", "needs.promote-macos-arm64.outputs.version }}-macos-arm64-dist", "needs.promote.outputs.version }}-dist"), "pypi-macos-arm64 reads the result of promote");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi-macos-arm64", "-macos-arm64-dist", "-dist"), "pypi-macos-arm64 reads an artifact that is not a macOS one");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi-smoke-macos-arm64", "-macos-arm64-smoke", "-smoke"), "pypi-smoke-macos-arm64 reads an artifact that is not a macOS one");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "promote-macos-arm64", "pypi-passed-macos-arm64-", "pypi-passed-linux-x86_64-"), "promote-macos-arm64 reads or writes a record that is not the macOS one");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi-passed-macos-arm64", "key: pypi-passed-macos-arm64-", "key: pypi-passed-"), "testpypi-passed-macos-arm64 reads or writes a record that is not the macOS one");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "promote-macos-arm64", "key: pypi-passed-macos-arm64-", "key: pypi-passed-macos-arm64-0.1.1"), "promote-macos-arm64 does not restore the newest macOS record");
    // macOS text in a Linux job: a platform word, a runner, a worker set
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi", "      - name: the driver is executable\n", "      - run: echo macos\n      - name: the driver is executable\n"), "testpypi names a macOS platform");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "pypi-smoke", "    runs-on: ubuntu-24.04\n", "    runs-on: macos-15\n"), "pypi-smoke names a macOS platform");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "build", "      - name: Stop buck2\n", "      - name: darwin\n        run: echo darwin-arm64\n      - name: Stop buck2\n"), "build names a macOS platform");
    // each half runs on its own event: the promotion on a push, the TestPyPI chain off a push, or no condition
    try expectRefusedPypi(ar, try inJob(ar, w.text, "promote-macos-arm64", "github.event_name != 'push'", "github.event_name == 'push'"), "promote-macos-arm64 is not gated on github.event_name != 'push'");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi-smoke-macos-arm64", "github.event_name == 'push'", "github.event_name != 'push'"), "testpypi-smoke-macos-arm64 is not gated on github.event_name == 'push'");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "result-pypi-macos-arm64", "    if: always() && github.ref == 'refs/heads/main' && github.event_name != 'push'\n", "    if: always()\n"), "result-pypi-macos-arm64 is not gated on");
    try expectRefusedPypi(ar, try inJob(ar, w.text, "testpypi-passed-macos-arm64", "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'\n", ""), "testpypi-passed-macos-arm64 has no condition");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  result-pypi-macos-arm64:\n", "\n  result-pypi-macos-arm64:\n    runs-on: ubuntu-24.04\n\n  result-pypi-macos-arm64:\n"), "result-pypi-macos-arm64 exactly once");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  promote-macos-arm64:\n", "\n  promote-macos:\n"), "promote-macos-arm64 exactly once");
    try expectRefusedPypi(ar, try replaced(ar, w.text, "\n  pypi-macos-arm64:\n", "\n  pypi-macos:\n"), "pypi-macos-arm64 exactly once");
}

test "an edit of the real pypi.yml that moves the macOS build off the farm's connection is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    const text = w.text;
    // a hosted macOS runner is refused for the build; the Macs are the farm's workers
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "    runs-on: ubuntu-24.04\n", "    runs-on: macos-15\n"), "build-macos-arm64 does not run on ubuntu-24.04");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "    environment: build\n", ""), "not in the environment build");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", PYPI_MACOS_BUILD_GATE ++ "\n", "    if: always()\n"), "does not run on a push to main alone");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", PYPI_MACOS_BUILD_GATE ++ "\n", "    if: github.ref == 'refs/heads/main'\n"), "does not run on a push to main alone");
    try expectRefusedPypi(ar, try inJob(ar, text, "result-testpypi-macos-arm64", "        if: needs.build-macos-arm64.result != 'success'\n", "        if: inputs.flavour == 'bundled' && needs.build-macos-arm64.result != 'success'\n"), "does not fail a run whose macOS build did not succeed");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-macos-arm64", "    environment: pypi\n", "    environment: pypi\n    env:\n      FLAVOUR: ${{ inputs.flavour }}\n"), "reads a run input");
    // the farm connection: the macOS worker set and hosts, batch priority, tls as every caller passes it
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", DARWIN_PROPS ++ "\n", ""), "darwin-properties");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", DARWIN_HOSTS ++ "\n", ""), "darwin-macos-hosts");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", QOS ++ "\n", ""), "farm-qos: batch");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "          tls: ${{ vars.FARM_TLS || 'false' }}\n", ""), "tls from FARM_TLS");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", FARM_CONNECT ++ "\n", "      - name: an early build\n" ++ BUCK2_FARM ++ "\n        with:\n          args: build //release/ci:release_json\n" ++ ASSERT ++ "\n" ++ FARM_CONNECT ++ "\n"), "builds before it joins the farm");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the farm assertion\n", "      - name: a check\n        run: |\n          true\n      - name: build the farm assertion\n"), "multi-line run step");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the macOS smoke driver\n" ++ PRESENT_GATE ++ "\n        uses: ./.github/actions/buck2-farm\n", "      - name: build the macOS smoke driver\n" ++ PRESENT_GATE ++ "\n        uses: ./.github/actions/other\n"), "outside the buck2-farm action");
    // the smoke jobs run on a Mac with the macOS driver, the upload jobs on Linux with the Linux one
    try expectRefusedPypi(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", "smoke/pypi_smoke_macos_arm64\" verify", "smoke/pypi_smoke\" verify"), "testpypi-smoke-macos-arm64 runs the Linux driver on a macOS runner");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "    runs-on: macos-15\n", "    runs-on: ubuntu-24.04\n"), "pypi-smoke-macos-arm64 does not run on macos-15");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-macos-arm64", "smoke/pypi_smoke\" state", "smoke/pypi_smoke_macos_arm64\" state"), "pypi-macos-arm64 runs the macOS driver on a Linux runner");
}

test "an edit of the real pypi.yml that loses the macOS smoke's one job per supported Python is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    const text = w.text;
    // a smoke job with a list of its own, with another job's list, cancelling the others on a failure, or
    // setting up another Python
    const list_line = "      matrix: ${{ fromJSON(needs.build-macos-arm64.outputs.matrix) }}\n";
    try expectRefusedPypi(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", list_line, "      matrix:\n        python: ['3.13.16']\n"), "testpypi-smoke-macos-arm64 is not one job per Python of build-macos-arm64's list");
    // each smoke takes the matrix of its own chain: the PyPI smoke's is promote-macos-arm64's, not the build's or the upload's
    const promote_line = "      matrix: ${{ fromJSON(needs.promote-macos-arm64.outputs.matrix) }}\n";
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", promote_line, list_line), "pypi-smoke-macos-arm64 is not one job per Python of promote-macos-arm64's list");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", promote_line, "      matrix: ${{ fromJSON(needs.pypi-macos-arm64.outputs.matrix) }}\n"), "pypi-smoke-macos-arm64 is not one job per Python of promote-macos-arm64's list");
    try expectRefusedPypi(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", list_line, promote_line), "testpypi-smoke-macos-arm64 is not one job per Python of build-macos-arm64's list");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "      fail-fast: false\n", ""), "pypi-smoke-macos-arm64 is not one job per Python of promote-macos-arm64's list");
    try expectRefusedPypi(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", "          python-version: ${{ matrix.python }}\n", "          python-version: '3.13'\n"), "testpypi-smoke-macos-arm64 is not one job per Python of build-macos-arm64's list");
    // the promotion writes its matrix from the record's list, for the macOS platform
    try expectRefusedPypi(ar, try inJob(ar, text, "promote-macos-arm64", "--platform macos-arm64", "--platform linux-x86_64"), "promote-macos-arm64 does not write the macOS job matrix");
    try expectRefusedPypi(ar, try inJob(ar, text, "promote-macos-arm64", "passed/pythons.json", "passed/other.json"), "promote-macos-arm64 does not write the macOS job matrix");
    // the quickstart is the smoke artifact's: a checkout, or a path of the checkout, is refused
    const checkout = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n";
    try expectRefusedPypi(ar, try inJob(ar, text, "testpypi-smoke-macos-arm64", "    steps:\n", "    steps:\n" ++ checkout), "testpypi-smoke-macos-arm64 takes the quickstart from a checkout");
    try expectRefusedPypi(ar, try inJob(ar, text, "pypi-smoke-macos-arm64", "--example \"$RUNNER_TEMP/pypi-macos-arm64/smoke/quickstart.py\"", "--example python/examples/quickstart.py"), "pypi-smoke-macos-arm64 takes the quickstart from a checkout");
    // the build: no list, the Linux list, no output, or the list behind the present gate (after the asking)
    try expectRefusedPypi(ar, try replaced(ar, text, PYTHONS_BUILD, "          args: build //python:supported_pythons[linux-x86_64] --out ${{ runner.temp }}/pypi-macos-arm64/smoke/pythons.json"), "does not build the list of the supported Pythons for macOS");
    // the list built outside the smoke directory is not in the artifact the smoke jobs and the record carry
    try expectRefusedPypi(ar, try replaced(ar, text, PYTHONS_BUILD, "          args: build //python:supported_pythons[macos-arm64] --out ${{ runner.temp }}/pypi-macos-arm64/pythons.json"), "does not build the list of the supported Pythons for macOS");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", PYTHONS_OUTPUT ++ "\n", ""), "does not publish the job matrix of the supported Pythons as its output `matrix`");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", PYTHONS_STEP_ID ++ "\n", ""), "does not write the job matrix of the supported Pythons to its step output `matrix`");
    const list_steps = "      - name: build the list of the supported Pythons\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PYTHONS_BUILD ++ "\n" ++ ASSERT ++ "\n      - name: the Pythons of the macOS smoke\n" ++ PYTHONS_STEP_ID ++ "\n" ++ PYTHONS_RUN ++ "\n";
    // the matrix written from another list than the one built, or for the Linux runner
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "matrix --pythons \"$RUNNER_TEMP/pypi-macos-arm64/smoke/pythons.json\"", "matrix --pythons python/pythons.json"), "does not write the job matrix of the supported Pythons to its step output `matrix`");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "--platform macos-arm64 --github-output", "--platform linux-x86_64 --github-output"), "does not write the job matrix of the supported Pythons to its step output `matrix`");
    const out_step = "      - name: the Pythons of the macOS smoke\n" ++ PYTHONS_STEP_ID ++ "\n" ++ PYTHONS_RUN ++ "\n";
    const build_step = "      - name: build the list of the supported Pythons\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PYTHONS_BUILD ++ "\n" ++ ASSERT ++ "\n";
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", build_step ++ out_step, out_step ++ build_step), "after the indexes are asked");
    // moved after the asking, behind the present gate as every step there must be
    const gated = "      - name: build the list of the supported Pythons\n" ++ PRESENT_GATE ++ "\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PYTHONS_BUILD ++ "\n" ++ ASSERT ++ "\n      - name: the Pythons of the macOS smoke\n" ++ PRESENT_GATE ++ "\n" ++ PYTHONS_STEP_ID ++ "\n" ++ PYTHONS_RUN ++ "\n";
    const moved = try replaced(ar, try inJob(ar, text, "build-macos-arm64", list_steps, ""), PRESENT_STEPS, PRESENT_STEPS ++ gated);
    try expectRefusedPypi(ar, moved, "after the indexes are asked");
}

test "an edit of the real pypi.yml that lets a Mac build start before the indexes are asked, or run ungated, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const w = try readPypi(ar);
    const text = w.text;
    // the wheel build without the present gate, the install test and the driver with another one
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the macOS wheel\n" ++ PRESENT_GATE ++ "\n", "      - name: build the macOS wheel\n"), "a Mac build of build-macos-arm64 does not carry the present gate");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: the install test on the macOS wheel\n" ++ PRESENT_GATE ++ "\n", "      - name: the install test on the macOS wheel\n        if: github.event_name == 'push'\n"), "a Mac build of build-macos-arm64 does not carry the present gate");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the macOS smoke driver\n" ++ PRESENT_GATE ++ "\n", "      - name: build the macOS smoke driver\n        if: always()\n"), "a Mac build of build-macos-arm64 does not carry the present gate");
    // the gate is exactly TestPyPI's: the two-index gate of an earlier shape, or one more clause, is no longer it
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the macOS wheel\n" ++ PRESENT_GATE ++ "\n", "      - name: build the macOS wheel\n" ++ PRESENT_GATE ++ " || steps.pypi_file.outputs.present != 'true'\n"), "a Mac build of build-macos-arm64 does not carry the present gate");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: keep the dist directory\n" ++ PRESENT_GATE ++ "\n", "      - name: keep the dist directory\n" ++ PRESENT_GATE ++ " && github.ref == 'refs/heads/main'\n"), "a step of build-macos-arm64 after the present steps does not carry the present gate");
    // a step after the asking that is not a build and runs ungated: the dist directory, an artifact
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: the dist directory and the record\n        id: dist\n" ++ PRESENT_GATE ++ "\n", "      - name: the dist directory and the record\n        id: dist\n"), "a step of build-macos-arm64 after the present steps does not carry the present gate");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: keep the drivers and the record\n" ++ PRESENT_GATE ++ "\n", "      - name: keep the drivers and the record\n"), "a step of build-macos-arm64 after the present steps does not carry the present gate");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: build the file name of the macOS wheel\n", "      - name: build the file name of the macOS wheel\n" ++ PRESENT_GATE ++ "\n"), "builds the wheel's file name behind the present gate");
    // the present steps moved after the Mac builds
    const moved = try inJob(ar, try replaced(ar, text, PRESENT_STEPS, ""), "build-macos-arm64", "      - name: Stop buck2\n", PRESENT_STEPS ++ "      - name: Stop buck2\n");
    try expectRefusedPypi(ar, moved, "starts a Mac build before the present step");
    // the present step that is gone, or asks before the file name exists
    try expectRefusedPypi(ar, try replaced(ar, text, "      - name: the macOS wheel on TestPyPI\n        id: testpypi_file\n" ++ PRESENT_TESTPYPI_RUN ++ "\n", ""), "does not ask TestPyPI");
    try expectRefusedPypi(ar, try replaced(ar, try replaced(ar, text, PRESENT_STEPS, ""), "      - name: build the file name of the macOS wheel\n", PRESENT_STEPS ++ "      - name: build the file name of the macOS wheel\n"), "asks the indexes before it has built the wheel's file name");
    try expectRefusedPypi(ar, try replaced(ar, text, "//python:wheel_install_test_macos_arm64\n", "//python:wheel_install_test\n"), "not the wheel, its install test, its read-back checks, its driver or the wheel's file name");
    // the read-back checks dropped from their step, or built twice
    try expectRefusedPypi(ar, try replaced(ar, text, " //python:wheel_libs_macos_arm64 //python:wheel_same_macos_arm64\n", " //python:wheel_libs_macos_arm64\n"), "exactly once");
    const read_back = "      - name: the macOS wheel read back\n";
    const read_back_step = text[std.mem.indexOf(u8, text, read_back).?..std.mem.indexOf(u8, text, "      - name: build the macOS smoke driver\n").?];
    try expectRefusedPypi(ar, try replaced(ar, text, read_back_step, try std.mem.concat(ar, u8, &.{ read_back_step, read_back_step })), "exactly once");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      - name: the macOS wheel read back\n" ++ PRESENT_GATE ++ "\n", "      - name: the macOS wheel read back\n"), "a Mac build of build-macos-arm64 does not carry the present gate");
    try expectRefusedPypi(ar, try replaced(ar, text, "//python/smoke:pypi_smoke_macos_arm64 --out", "//python:komira_wheel_macos_arm64[release] --out"), "exactly once");
    try expectRefusedPypi(ar, try inJob(ar, text, "build-macos-arm64", "      version: ${{ steps.dist.outputs.version }}\n", "      version: 0.1.0\n"), "does not publish the version");
}

test "pr.yml analyses the macOS set once, through the buck2-farm action, and each edit that loses it is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    try t.expect((try checkAnalysisStep(ar, pr)) == null);
    const step = BUCK2_FARM ++ "\n        with:\n" ++ ANALYSIS_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const cases = [_]struct { from: []const u8, to: []const u8, want: []const u8 }{
        // the step deleted: the set is no longer analysed
        .{ .from = step, .to = "", .want = "does not analyse the release's macOS set" },
        // the line commented out
        .{ .from = ANALYSIS_ARGS, .to = "          # args: bxl komira//release/darwin_analysis.bxl:check", .want = "does not analyse the release's macOS set" },
        // twice
        .{ .from = step, .to = step ++ step, .want = "more than once" },
        // run directly, where a local action would not be caught
        .{ .from = BUCK2_FARM ++ "\n        with:\n" ++ ANALYSIS_ARGS, .to = "        run: ./buck2 bxl komira//release/darwin_analysis.bxl:check\n        with:\n" ++ ANALYSIS_ARGS, .want = "outside the buck2-farm action" },
        .{ .from = "        with:\n" ++ ANALYSIS_ARGS, .to = "        env:\n" ++ ANALYSIS_ARGS, .want = "outside the buck2-farm action" },
        // the remote assertion dropped
        .{ .from = ANALYSIS_ARGS ++ "\n" ++ ASSERT, .to = ANALYSIS_ARGS, .want = "does not assert the analysis" },
    };
    for (cases) |c| try expectMsg(try checkAnalysisStep(ar, try replaced(ar, pr, c.from, c.to)), c.want);
}

test "pr.yml's macOS part holds its contract, and each edit that breaks it is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    try t.expect((try checkMacosPart(ar, pr)) == null);
    const build_step = PR_BUILD_NAME ++ "\n" ++ PR_BUILD_IF ++ "\n" ++ PR_BUILD_BOUND ++ "\n" ++ BUCK2_FARM ++ "\n        with:\n" ++ PR_BUILD_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const select_step = SELECT_NAME ++ "\n" ++ BUCK2_FARM ++ "\n        with:\n" ++ SELECT_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const cases = [_]struct { from: []const u8, to: []const u8, want: []const u8 }{
        // a line of the part lost, or written twice
        .{ .from = DARWIN_FILE ++ "\n", .to = "", .want = "0 times, not once, the line of its macOS part: darwin-config-file" },
        .{ .from = build_step, .to = "", .want = "0 times, not once, the line of its macOS part: - name: build for macOS" },
        .{ .from = build_step, .to = build_step ++ build_step, .want = "2 times, not once" },
        // the build unguarded (it would run with an empty list), unbounded, or bounded otherwise
        .{ .from = PR_BUILD_IF ++ "\n", .to = "", .want = "0 times, not once, the line of its macOS part: if: steps.darwin.outputs.any" },
        .{ .from = PR_BUILD_NAME ++ "\n" ++ PR_BUILD_IF ++ "\n" ++ PR_BUILD_BOUND ++ "\n", .to = PR_BUILD_NAME ++ "\n" ++ PR_BUILD_IF ++ "\n", .want = "is not: its name, `if: steps.darwin.outputs.any == 'true'`, `timeout-minutes: 60`" },
        .{ .from = PR_BUILD_BOUND ++ "\n", .to = "        timeout-minutes: 300\n", .want = "`timeout-minutes: 60`" },
        // the build run directly, where a local action would not be caught, or not asserted remote
        .{ .from = PR_BUILD_BOUND ++ "\n" ++ BUCK2_FARM, .to = PR_BUILD_BOUND ++ "\n        run: ./buck2 build @darwin_targets.txt", .want = "the buck2-farm action with the build and its remote assertion" },
        .{ .from = PR_BUILD_ARGS ++ "\n" ++ ASSERT, .to = PR_BUILD_ARGS, .want = "the buck2-farm action with the build and its remote assertion" },
        .{ .from = SELECT_ARGS ++ "\n" ++ ASSERT, .to = SELECT_ARGS, .want = "outside its buck2-farm step `select the macOS targets`" },
        // the macOS file dropped from farm-connect (its keys would go into the machine buckconfig, and
        // every step would configure macOS)
        .{ .from = DARWIN_FILE ++ "\n", .to = "", .want = "the line of its macOS part: darwin-config-file" },
        // the targets written otherwise
        .{ .from = TARGETS_ENV ++ "\n" ++ TARGETS_RUN, .to = TARGETS_RUN ++ "\n" ++ TARGETS_ENV, .want = "is not its name, `id: darwin`, the tool's path and the one command" },
        .{ .from = TARGETS_RUN ++ "\n", .to = "        run: grep -E '^[a-z_]+//[^ ]+$' \"$RUNNER_TEMP/buck2-farm.log\" > \"$RUNNER_TEMP/darwin_targets.txt\"\n", .want = "0 times, not once, the line of its macOS part: run: '\"$DARWIN_TARGETS\" --log" },
        // the tool not built, or built otherwise
        .{ .from = TOOL_NAME ++ "\n" ++ TOOL_ID ++ "\n" ++ TOOL_RUN ++ "\n", .to = "", .want = "0 times, not once, the line of its macOS part: - name: build the macOS targets tool" },
        .{ .from = TOOL_ID ++ "\n" ++ TOOL_RUN, .to = TOOL_RUN ++ "\n" ++ TOOL_ID, .want = "is not its name, `id: darwin_tool` and the build" },
        // the selection removed, or the linux test step renamed
        .{ .from = select_step, .to = "", .want = "0 times" },
        .{ .from = PR_TEST_NAME ++ "\n", .to = "      - name: tests\n", .want = "has no step `test`" },
        // a cold cache
        .{ .from = "      - name: Stop buck2\n", .to = "      - name: cold\n        run: ./buck2 build --no-remote-cache //x:y\n      - name: Stop buck2\n", .want = "--no-remote-cache" },
    };
    for (cases) |c| try expectMsg(try checkMacosPart(ar, try replacedPr(ar, pr, c.from, c.to)), c.want);
    // the macOS file passed to a step other than farm-connect's
    const elsewhere = try replacedPr(ar, try replacedPr(ar, pr, DARWIN_FILE ++ "\n", ""), "      - name: the buckconfig names the farm\n", "      - name: the buckconfig names the farm\n        with:\n" ++ DARWIN_FILE ++ "\n");
    try expectMsg(try checkMacosPart(ar, elsewhere), "passes `darwin-config-file: ${{ runner.temp }}/darwin.buckconfig` outside its farm-connect step");
    // the order: the whole part moved after the analysis step, or the build before the selection
    const analysis_step = BUCK2_FARM ++ "\n        with:\n" ++ ANALYSIS_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const moved = try replacedPr(ar, try replacedPr(ar, pr, build_step, ""), analysis_step, analysis_step ++ build_step);
    try expectMsg(try checkMacosPart(ar, moved), "is not after the step `test` and before the analysis of the macOS set");
    const early = try replacedPr(ar, try replacedPr(ar, pr, build_step, ""), select_step, build_step ++ select_step);
    try expectMsg(try checkMacosPart(ar, early), "in the order select, targets, build");
    // the selection moved before the linux test step (it would read the list before `test` ran, and the
    // macOS part would no longer follow the whole linux part)
    const before_test = try replacedPr(ar, try replacedPr(ar, pr, select_step, ""), PR_TEST_NAME ++ "\n", select_step ++ PR_TEST_NAME ++ "\n");
    try expectMsg(try checkMacosPart(ar, before_test), "is not after the step `test`");
    // the targets step moved before the selection (it would read the log of another step)
    const targets_step = TARGETS_NAME ++ "\n" ++ TARGETS_ID ++ "\n        env:\n" ++ TARGETS_ENV ++ "\n" ++ TARGETS_RUN ++ "\n";
    const targets_first = try replacedPr(ar, try replacedPr(ar, pr, targets_step, ""), select_step, targets_step ++ select_step);
    try expectMsg(try checkMacosPart(ar, targets_first), "in the order select, targets, build");
    // the tool built after the step that runs it (that step would run an empty path)
    const tool_step = TOOL_NAME ++ "\n" ++ TOOL_ID ++ "\n" ++ TOOL_RUN ++ "\n";
    const tool_late = try replacedPr(ar, try replacedPr(ar, pr, tool_step, ""), PR_BUILD_NAME ++ "\n", tool_step ++ PR_BUILD_NAME ++ "\n");
    try expectMsg(try checkMacosPart(ar, tool_late), "builds the macOS targets tool after the step that runs it");
    // a second macOS build, for the next Mojo's platform, is no part of the pull request check (the release
    // builds the macOS libraries with it): a step added to pr.yml that builds darwin_targets.txt for
    // darwin-arm64-mojo-1.2.0 is a line that names a macOS platform outside the part's lines, and is refused
    const second_build = "      - name: build for macOS with Mojo 1.2.0\n" ++ PR_BUILD_IF ++ "\n" ++ PR_BUILD_BOUND ++ "\n" ++ BUCK2_FARM ++ "\n        with:\n" ++
        "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig --target-platforms komira//tools/build/platforms:darwin-arm64-mojo-1.2.0 --keep-going @${{ runner.temp }}/darwin_targets.txt\n" ++ ASSERT ++ "\n";
    try expectMsg(checkPullRequestWorkflow("pr.yml", try replacedPr(ar, pr, build_step, build_step ++ second_build)), "names a macOS platform, worker set or runner outside pr.yml's macOS part");
}

test "pr.yml's Mojo 1.2.0 part on linux holds its contract, and each edit that breaks it is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    try t.expect((try checkMojoNext(ar, pr)) == null);
    const farm = "\n" ++ BUCK2_FARM ++ "\n        with:\n";
    const select_next = NEXT_SELECT_NAME ++ farm ++ NEXT_SELECT_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const targets_step = NEXT_TARGETS_NAME ++ "\n" ++ NEXT_TARGETS_ID ++ "\n" ++ NEXT_TARGETS_RUN ++ "\n";
    const build_step = NEXT_BUILD_NAME ++ "\n" ++ NEXT_BUILD_IF ++ "\n" ++ NEXT_BUILD_BOUND ++ farm ++ NEXT_BUILD_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const standalone_step = NEXT_TESTS_NAME ++ "\n" ++ NEXT_TESTS_ID ++ "\n" ++ NEXT_BUILD_IF ++ "\n" ++ NEXT_TESTS_RUN ++ "\n";
    const test_step = NEXT_TEST_NAME ++ "\n" ++ NEXT_TEST_IF ++ "\n" ++ NEXT_TEST_BOUND ++ farm ++ NEXT_TEST_ARGS ++ "\n" ++ ASSERT ++ "\n";
    const cases = [_]struct { from: []const u8, to: []const u8, want: []const u8 }{
        // a step lost, or written twice
        .{ .from = select_next, .to = "", .want = "0 times, not once, the line of its Mojo 1.2.0 part: - name: select the Mojo 1.2.0 targets" },
        .{ .from = build_step, .to = "", .want = "0 times, not once, the line of its Mojo 1.2.0 part: - name: build with Mojo 1.2.0" },
        .{ .from = test_step, .to = "", .want = "0 times, not once, the line of its Mojo 1.2.0 part: - name: test with Mojo 1.2.0" },
        .{ .from = build_step, .to = build_step ++ build_step, .want = "2 times, not once" },
        // the selection reading another list than the one the step `build` builds
        .{ .from = "mojo_next_affected.args @${{ runner.temp }}/targets.txt", .to = "mojo_next_affected.args @${{ runner.temp }}/test_targets.txt", .want = "0 times, not once, the line of its Mojo 1.2.0 part: args: bxl komira//tools/build/ci/mojo_next.bxl:select" },
        // the selection not run through the action with its assertion
        .{ .from = NEXT_SELECT_ARGS ++ "\n" ++ ASSERT, .to = NEXT_SELECT_ARGS, .want = "selects the Mojo 1.2.0 targets outside its buck2-farm step" },
        // the linux part's own build renamed: the selection would read a list nothing builds
        .{ .from = "          args: build --keep-going @${{ runner.temp }}/targets.txt", .to = "          args: build @${{ runner.temp }}/targets.txt", .want = "`build` does not build the list that the Mojo 1.2.0 selection reads" },
        // the labels' step: its command changed, or a line between its name and its id
        .{ .from = "grep -E '^[a-z_]+//[^ ]+$' \"$RUNNER_TEMP/buck2-farm.log\" > \"$RUNNER_TEMP/next_targets.txt\"", .to = "grep -E '^[a-z_]+//[^ ]+$' \"$RUNNER_TEMP/buck2-farm.log\" > \"$RUNNER_TEMP/targets.txt\"", .want = "0 times, not once, the line of its Mojo 1.2.0 part: run: grep -E" },
        .{ .from = NEXT_TARGETS_NAME ++ "\n" ++ NEXT_TARGETS_ID, .to = NEXT_TARGETS_NAME ++ "\n        if: always()\n" ++ NEXT_TARGETS_ID, .want = "`the Mojo 1.2.0 targets to build` is not its name" },
        // the platform of the build dropped or another's (the step would repeat the Mojo 1.1.0 build)
        .{ .from = NEXT_BUILD_ARGS, .to = "          args: build --keep-going @${{ runner.temp }}/next_targets.txt --target-platforms komira//tools/build/platforms:linux-x86_64", .want = "0 times, not once, the line of its Mojo 1.2.0 part: args: build --keep-going --target-platforms" },
        .{ .from = "linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/next_test_targets.txt", .to = "linux-x86_64 @${{ runner.temp }}/next_test_targets.txt", .want = "0 times, not once, the line of its Mojo 1.2.0 part: args: test --target-platforms" },
        // the build reading the unselected list, or the test another list than the standalone targets
        .{ .from = "linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/next_targets.txt", .to = "linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/targets.txt", .want = "0 times, not once, the line of its Mojo 1.2.0 part: args: build --keep-going --target-platforms" },
        .{ .from = "linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/next_test_targets.txt", .to = "linux-x86_64-mojo-1.2.0 @${{ runner.temp }}/test_targets.txt", .want = "0 times, not once, the line of its Mojo 1.2.0 part: args: test --target-platforms" },
        .{ .from = "grep -v '^tests//' \"$RUNNER_TEMP/next_targets.txt\"", .to = "grep -v '^tests//' \"$RUNNER_TEMP/targets.txt\"", .want = "0 times, not once, the line of its Mojo 1.2.0 part: run: grep -v" },
        // unbounded, the build unguarded or its guard misplaced (it would build an empty list), the
        // standalone step unguarded, the test unguarded
        .{ .from = NEXT_BUILD_BOUND ++ "\n", .to = "", .want = "0 times, not once, the line of its Mojo 1.2.0 part: timeout-minutes: 120" },
        .{ .from = NEXT_BUILD_NAME ++ "\n" ++ NEXT_BUILD_IF ++ "\n", .to = NEXT_BUILD_NAME ++ "\n", .want = "`build with Mojo 1.2.0` is not: its name, `if: steps.next.outputs.any == 'true'`" },
        .{ .from = NEXT_BUILD_NAME ++ "\n" ++ NEXT_BUILD_IF ++ "\n" ++ NEXT_BUILD_BOUND ++ "\n", .to = NEXT_BUILD_NAME ++ "\n" ++ NEXT_BUILD_BOUND ++ "\n" ++ NEXT_BUILD_IF ++ "\n", .want = "`build with Mojo 1.2.0` is not: its name, `if: steps.next.outputs.any == 'true'`" },
        .{ .from = NEXT_TESTS_ID ++ "\n" ++ NEXT_BUILD_IF ++ "\n", .to = NEXT_TESTS_ID ++ "\n", .want = "`the Mojo 1.2.0 standalone test targets` is not its name" },
        .{ .from = NEXT_TEST_IF ++ "\n" ++ NEXT_TEST_BOUND ++ farm ++ NEXT_TEST_ARGS, .to = NEXT_TEST_BOUND ++ farm ++ NEXT_TEST_ARGS, .want = "`test with Mojo 1.2.0` is not: its name, `if: steps.next_tests" },
        // run directly, where a local action would not be caught, or not asserted remote
        .{ .from = NEXT_BUILD_BOUND ++ "\n" ++ BUCK2_FARM, .to = NEXT_BUILD_BOUND ++ "\n        run: ./buck2 build @next_targets.txt", .want = "`build with Mojo 1.2.0` is not: its name" },
        .{ .from = NEXT_TEST_ARGS ++ "\n" ++ ASSERT, .to = NEXT_TEST_ARGS, .want = "`test with Mojo 1.2.0` is not: its name" },
        // a cold cache
        .{ .from = "      - name: Stop buck2\n", .to = "      - name: cold\n        run: ./buck2 build --no-remote-cache //x:y\n      - name: Stop buck2\n", .want = "--no-remote-cache" },
    };
    for (cases) |c| try expectMsg(try checkMojoNext(ar, try replacedPr(ar, pr, c.from, c.to)), c.want);
    // the order: the selection after the build, the test before the build, the standalone tests after the test
    const select_late = try replacedPr(ar, try replacedPr(ar, pr, select_next, ""), build_step, build_step ++ select_next);
    try expectMsg(try checkMojoNext(ar, select_late), "in the order select, targets to build, build, standalone test targets, test");
    const test_first = try replacedPr(ar, try replacedPr(ar, pr, test_step, ""), build_step, test_step ++ build_step);
    try expectMsg(try checkMojoNext(ar, test_first), "in the order select, targets to build, build, standalone test targets, test");
    const standalone_late = try replacedPr(ar, try replacedPr(ar, pr, standalone_step, ""), test_step, test_step ++ standalone_step);
    try expectMsg(try checkMojoNext(ar, standalone_late), "in the order select, targets to build, build, standalone test targets, test");
    // the part after the macOS selection, or before the step `test`
    const all_next = select_next ++ targets_step ++ build_step ++ standalone_step ++ test_step;
    const macos_select = SELECT_NAME ++ farm ++ SELECT_ARGS ++ "\n" ++ ASSERT ++ "\n";
    var without = pr;
    for ([_][]const u8{ select_next, targets_step, build_step, standalone_step, test_step }) |step| without = try replacedPr(ar, without, step, "");
    const after_select = try replacedPr(ar, without, macos_select, macos_select ++ all_next);
    try expectMsg(try checkMojoNext(ar, after_select), "is not after the step `test` and before the selection of the macOS targets");
    const before_test = try replacedPr(ar, without, PR_TEST_NAME ++ "\n", all_next ++ PR_TEST_NAME ++ "\n");
    try expectMsg(try checkMojoNext(ar, before_test), "is not after the step `test` and before the selection of the macOS targets");
}

fn replacedPr(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the case's anchor is not in pr.yml: {s}\n", .{from});
        return error.NoAnchor;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

test "the pull request's check set names neither the macOS set, the macOS wheel's targets nor a macOS runner" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var shards: usize = 0;
    for (try listDir(ar, "ci_targets")) |name| {
        const text = try readData(ar, &.{ "ci_targets", name });
        shards += 1;
        // the shards hold labels only: the macOS set (a darwin-arm64 build of the packages), its
        // definition and a runner of a pull request would each be one of these lines
        if (std.mem.indexOf(u8, text, "mopm_darwin_libs") != null) {
            std.debug.print("{s} names the macOS set\n", .{name});
            return error.MacosSetInCheck;
        }
        for ([_][]const u8{ "komira_wheel_macos_arm64", "wheel_install_test_macos_arm64", "wheel_libs_macos_arm64", "wheel_same_macos_arm64", "pypi_smoke_macos_arm64" }) |target| {
            if (std.mem.indexOf(u8, text, target) != null) {
                std.debug.print("{s} names the macOS wheel target {s}\n", .{ name, target });
                return error.MacosSetInCheck;
            }
        }
        if (std.mem.indexOf(u8, text, "release/darwin_libs") != null or std.mem.indexOf(u8, text, "runs-on") != null or std.mem.indexOf(u8, text, "--target-platforms") != null) {
            std.debug.print("{s} holds a macOS build\n", .{name});
            return error.MacosSetInCheck;
        }
    }
    try t.expect(shards >= 8);
}

/// A DARWIN_EXCLUDED row `    "name": "reason",` has a reason: the quoted value after the name holds
/// a non-whitespace character. `name_end` is the index of the name's closing quote.
fn reasonOk(line: []const u8, name_end: usize) bool {
    const c = std.mem.indexOfScalarPos(u8, line, name_end + 1, ':') orelse return false;
    const v1 = std.mem.indexOfScalarPos(u8, line, c + 1, '"') orelse return false;
    const v2 = std.mem.lastIndexOfScalar(u8, line, '"') orelse return false;
    if (v2 <= v1) return false;
    return std.mem.trim(u8, line[v1 + 1 .. v2], " \t").len > 0;
}

test "a DARWIN_EXCLUDED row with an empty or whitespace-only reason is refused" {
    const empty = "    \"libc\": \"\",";
    const blank = "    \"libc\": \"  \t\",";
    const real = "    \"libc\": \"vendored third_party C\",";
    try t.expect(!reasonOk(empty, std.mem.indexOfScalarPos(u8, empty, 5, '"').?));
    try t.expect(!reasonOk(blank, std.mem.indexOfScalarPos(u8, blank, 5, '"').?));
    try t.expect(reasonOk(real, std.mem.indexOfScalarPos(u8, real, 5, '"').?));
}

test "the macOS set is the packages of packages.bzl minus the excluded ones, in darwin_libs.bzl" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const bzl = try readData(ar, &.{"darwin_libs.bzl"});
    const build = try readData(ar, &.{"release.BUCK"});
    // one definition: the target takes the list of the bzl and nothing else
    try t.expect(std.mem.indexOf(u8, build, "packages = DARWIN_PACKAGES,") != null);
    try t.expect(std.mem.indexOf(u8, bzl, "DARWIN_PACKAGES = darwin_packages()") != null);
    // each member is a `:lib` of src/ built for the platform the workflow names, and the output
    // layout is the macOS one (never the linux one the Linux release stages)
    try t.expect(std.mem.indexOf(u8, bzl, "\"komira//src/{}:lib\".format(p)") != null);
    try t.expect(std.mem.indexOf(u8, bzl, "mojoc_path(\"osx-arm64\", name)") != null);
    try t.expect(std.mem.indexOf(u8, bzl, "linux-64") == null or std.mem.indexOf(u8, bzl, "\"linux-64/") == null);
    // an excluded package that is no package is refused at load
    try t.expect(std.mem.indexOf(u8, bzl, "which is not a package of release/readme_e2e/packages.bzl") != null);
    // every excluded name (none today: `DARWIN_EXCLUDED = {}`) is a package of packages.bzl, with a reason
    const pk = try readData(ar, &.{"packages.bzl"});
    var in_excluded = false;
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "DARWIN_EXCLUDED = {")) {
            in_excluded = !std.mem.endsWith(u8, line, "{}");
            continue;
        }
        if (!in_excluded) continue;
        if (std.mem.eql(u8, line, "}")) break;
        const q1 = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const q2 = std.mem.indexOfScalarPos(u8, line, q1 + 1, '"') orelse continue;
        const name = line[q1 + 1 .. q2];
        const key = try std.fmt.allocPrint(ar, "    \"{s}\": \"", .{name});
        if (std.mem.indexOf(u8, pk, key) == null) {
            std.debug.print("DARWIN_EXCLUDED names {s}, which packages.bzl does not\n", .{name});
            return error.NotAPackage;
        }
        // the reason follows the name and is not empty
        try t.expect(reasonOk(line, q2));
    }
    // the definition is found (a rename of the dict must not let this test pass on nothing)
    try t.expect(std.mem.indexOf(u8, bzl, "\nDARWIN_EXCLUDED = {") != null);
}
