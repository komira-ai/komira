//! The cases of the macOS build of the release, //:release_macos_cases: a `zig_test` run as a build
//! action. The subjects are the bytes of the workflows (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/<name>.yml), the shards of the pull request's check set
//! (ci_targets/shard_<n>.bzl) and the macOS set's own definition (darwin_libs.bzl).
//!
//! The decision these hold: the macOS platform is not in the pull request check (the farm has far more
//! Linux cores than Mac ones), and the macOS build is a workflow of its own, release-macos.yml, run once
//! per release (a push to main, a manual run), in a concurrency group of its own so that a stalled Mac
//! build never holds the next release.
//! What the cases catch:
//!  - the workflow release-macos.yml exists, runs on push to main and workflow_dispatch only (never
//!    pull_request, pull_request_target or merge_group, never a schedule), its concurrency group is not
//!    release.yml's and it cancels a running build in favour of a newer push;
//!  - release.yml holds no macOS job: no job `release-macos`, no job `needs` it or reads its result,
//!    and no non-comment line naming a macOS platform, worker set or runner;
//!  - the job `release-macos` of release-macos.yml exists once and builds the macOS set on the farm: it runs on
//!    the ubuntu runner (a macOS runner is refused), joins the farm with the macOS worker set and
//!    hosts and `farm-qos: batch`, passes `--target-platforms komira//tools/build/platforms:darwin-arm64`
//!    to `//release:mopm_darwin_libs` through the buck2-farm action (which fails a step that ran
//!    anything locally), and says in its buckconfig step that the macOS worker keys must be set;
//!  - it does not hold up the Linux path: it `needs` nothing (nothing in release.yml `needs` it, so the prod
//!    publish never waits on it), and it is bounded (`timeout-minutes` at most 120, the longest of the other jobs);
//!  - a failed or skipped macOS build ends the run failed: the job is not `continue-on-error`, and a last job
//!    `release-macos-result` (`needs: release-macos`, `if: always()`) fails with "the macOS build did not run"
//!    when the build's result is skipped, so a run whose build never ran is not green;
//!  - it is not triggered on a pull request: neither macOS-naming workflow's `on:` names one, and no
//!    workflow that runs on a pull request (pr.yml, coverage.yml) has a line, comment or not,
//!    naming darwin, macOS, osx or `--target-platforms`, and none passes the macOS worker set to farm-connect;
//!  - the pull request's check set (ci/targets shards) names neither the macOS set nor a macOS runner;
//!  - the macOS set is the packages of packages.bzl without the excluded ones, in one place: the
//!    set's definition builds each member's `:lib`, and each excluded package is a package.
//! Every defect above is planted in the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const JOB = "release-macos";
const BUILD_ARGS = "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:mopm_darwin_libs";
const FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
const BUCK2_FARM = "        uses: ./.github/actions/buck2-farm";
const ASSERT = "          assert-remote: ${{ steps.assert.outputs.path }}";
const DARWIN_PROPS = "          darwin-properties: ${{ vars.FARM_DARWIN_ARM64_PROPERTIES }}";
const DARWIN_HOSTS = "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}";
const QOS = "          farm-qos: batch";
const BOUND = "    timeout-minutes: 90";
const CONTINUE_ON_ERROR = "    continue-on-error: true";
const RESULT_JOB = "release-macos-result";
const RESULT_REASON = "the macOS build did not run";
const MAX_MINUTES = 120;

fn isComment(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    return trimmed.len > 0 and trimmed[0] == '#';
}

/// The lines of the job `name` of `jobs:` (a key at two spaces of indent), without comments and
/// blank lines, or null. Counts the jobs of that name in `count`.
fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8, count: *usize) !?[]const []const u8 {
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
            inside = std.mem.eql(u8, trimmed[0 .. trimmed.len - 1], name);
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

/// The names of the jobs of `jobs:`, in order.
fn jobNames(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
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
        if (indent == 2 and std.mem.endsWith(u8, trimmed, ":")) try out.append(ar, trimmed[0 .. trimmed.len - 1]);
    }
    return try out.toOwnedSlice(ar);
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

/// Whether a non-comment line of `lines` names a macOS platform, worker set or runner.
fn namesMacos(line: []const u8) bool {
    const words = [_][]const u8{ "darwin", "macos", "osx", "target-platforms" };
    for (words) |w| if (std.ascii.indexOfIgnoreCase(line, w) != null) return true;
    return false;
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
        if (isComment(line)) continue;
        if (namesMacos(line)) return "release.yml names a macOS platform, worker set or runner: only release-macos.yml does";
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

    // not on a pull request, and nothing publishes from it
    if (mentions(job, "pull_request")) return "release-macos names pull_request";
    if (mentions(job, "mopm publish") or mentions(job, "--oidc")) return "release-macos publishes";
    return null;
}

/// Null if a workflow that runs on a pull request holds no macOS build, else the refusal. A workflow that
/// does not run on a pull request is not read here (null).
fn checkPullRequestWorkflow(text: []const u8) ?[]const u8 {
    if (!runsOnPullRequest(text)) return null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        if (namesMacos(line)) return "a workflow that runs on a pull request names a macOS platform, worker set or runner (the macOS build is the workflow release-macos.yml)";
    }
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

/// The file names of the directory `sub` of the test's data, sorted, as an iterator.
const Names = struct {
    items: []const []const u8,
    at: usize = 0,
    fn next(self: *Names) ?[]const u8 {
        if (self.at >= self.items.len) return null;
        defer self.at += 1;
        return self.items[self.at];
    }
};

fn listDir(ar: std.mem.Allocator, sub: []const u8) !Names {
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
    return .{ .items = out.items };
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const got = (try checkMacos(ar, text)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
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
    const got = (try checkRelease(ar, text)) orelse {
        std.debug.print("accepted a release.yml that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

fn expectRefusedGroups(mac: []const u8, rel: []const u8, want: []const u8) !void {
    const got = checkGroups(mac, rel) orelse {
        std.debug.print("accepted concurrency groups that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
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
    try expectRefusedRelease(ar, try replaced(ar, rel, "          args: build //release/ci:check_release_ref --out", "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 //release/ci:check_release_ref --out"), "only release-macos.yml does");
    try expectRefusedRelease(ar, try replaced(ar, rel, "  mopm-stage:\n    runs-on: ubuntu-24.04\n", "  mopm-stage:\n    runs-on: macos-15\n"), "only release-macos.yml does");
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
    try expectRefused(ar, try replaced(ar, text, "      - name: the buckconfig names the farm and its macOS workers\n", "      - name: no check\n"), "names the macOS workers");

    // the build: the platform, the target, the farm action, asserted
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --keep-going //release:mopm_darwin_libs"), "for --target-platforms komira//tools/build/platforms:darwin-arm64");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --target-platforms komira//tools/build/platforms:linux-x86_64 --keep-going //release:mopm_darwin_libs"), "for --target-platforms komira//tools/build/platforms:darwin-arm64");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going //release:mopm_artifacts"), "exactly one buck2 step");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS, BUILD_ARGS ++ " --no-remote-cache"), "does not build //release:mopm_darwin_libs for");
    try expectRefused(ar, try replaced(ar, text, BUILD_ARGS ++ "\n" ++ ASSERT ++ "\n      - name: the macOS build failed", BUILD_ARGS ++ "\n      - name: the macOS build failed"), "does not assert the build remote");
    try expectRefused(ar, try replaced(ar, text, "      - name: build the macOS set\n        uses: ./.github/actions/buck2-farm\n", "      - name: build the macOS set\n        uses: ./.github/actions/other\n"), "outside the buck2-farm action");

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
    var names = try listDir(ar, "workflows");
    while (names.next()) |name| {
        const text = try readData(ar, &.{ "workflows", name });
        if (checkPullRequestWorkflow(text)) |why| {
            std.debug.print("{s}: {s}\n", .{ name, why });
            return error.MacosInPullRequest;
        }
        if (runsOnPullRequest(text)) on_pr += 1;
        // release-macos.yml is the one with the macOS build, and it runs on no pull request
        if (std.mem.eql(u8, name, "release-macos.yml")) try t.expect(!runsOnPullRequest(text));
    }
    // the check reads pr.yml and coverage.yml: were the trigger reader broken, nothing would be read
    try t.expect(on_pr >= 2);
}

test "the reader of pull request workflows sees each macOS defect planted in the real pr.yml" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    try t.expect(runsOnPullRequest(pr));
    try t.expect(checkPullRequestWorkflow(pr) == null);
    const planted = [_][]const u8{
        "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 @targets.txt",
        "          darwin-properties: ${{ vars.FARM_DARWIN_ARM64_PROPERTIES }}",
        "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}",
        "          args: build //release:mopm_darwin_libs",
        "    runs-on: macos-15",
        "          args: build komira//tools/build/mojo:act_darwin",
        "          args: build toolchains//:mojo_compiler_1.0.0_osx-arm64",
    };
    for (planted) |line| {
        const bad = try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ pr, line });
        if (checkPullRequestWorkflow(bad) == null) {
            std.debug.print("a pull request workflow with this line was accepted: {s}\n", .{line});
            return error.Accepted;
        }
    }
    // a comment may speak of it, and a workflow that is not run by a pull request may name it
    try t.expect(checkPullRequestWorkflow(try std.fmt.allocPrint(ar, "{s}\n# the macOS build is the workflow release-macos.yml\n", .{pr})) == null);
    const release = try readData(ar, &.{ "workflows", "release.yml" });
    try t.expect(checkPullRequestWorkflow(release) == null);
    // every spelling of the trigger is seen
    try t.expect(runsOnPullRequest("name: x\non: pull_request\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non: [push, pull_request]\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non:\n  merge_group:\njobs:\n"));
    try t.expect(runsOnPullRequest("name: x\non:\n  pull_request_target:\n    branches: [main]\njobs:\n"));
    try t.expect(!runsOnPullRequest("name: x\non:\n  push:\n    branches: [main]\n  # pull_request\njobs:\n  a:\n    steps:\n      - run: echo pull_request\n"));
}

test "the pull request's check set names neither the macOS set nor a macOS runner" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var shards: usize = 0;
    var names = try listDir(ar, "ci_targets");
    while (names.next()) |name| {
        const text = try readData(ar, &.{ "ci_targets", name });
        shards += 1;
        // the shards hold labels only: the macOS set (a darwin-arm64 build of the packages), its
        // definition and a runner of a pull request would each be one of these lines
        if (std.mem.indexOf(u8, text, "mopm_darwin_libs") != null) {
            std.debug.print("{s} names the macOS set\n", .{name});
            return error.MacosSetInCheck;
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
    const empty = "    \"komira_libc\": \"\",";
    const blank = "    \"komira_libc\": \"  \t\",";
    const real = "    \"komira_libc\": \"vendored third_party C\",";
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
    try t.expect(std.mem.indexOf(u8, bzl, "\"osx-arm64/\" + name") != null);
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
