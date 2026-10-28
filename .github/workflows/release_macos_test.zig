//! The cases of the macOS build of the release, //:release_macos_cases: a `zig_test` run as a build
//! action. The subjects are the bytes of the workflows (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/<name>.yml), the shards of the pull request's check set
//! (ci_targets/shard_<n>.bzl) and the macOS set's own definition (darwin_libs.bzl).
//!
//! The CEO's ruling these hold: the macOS platform is not in the pull request check (the farm has
//! hundreds of Linux cores and a few dozen Mac ones), and the macOS build is a job of the release.
//! What the cases catch:
//!  - the job `release-macos` of release.yml exists once and builds the macOS set on the farm: it runs on
//!    the ubuntu runner (a macOS runner is refused), joins the farm with the macOS worker set and
//!    hosts and `farm-qos: batch`, passes `--target-platforms komira//tools/build/platforms:darwin-arm64`
//!    to `//release:mopm_darwin_libs` through the buck2-farm action (which fails a step that ran
//!    anything locally), and says in its buckconfig step that the macOS worker keys must be set;
//!  - it does not hold up the Linux path: it `needs` nothing, no other job `needs` it (so the prod
//!    publish never waits on it), it is `continue-on-error: true` (the stated choice: reported, not
//!    blocking), and it is bounded (`timeout-minutes` at most 120, the longest of the other jobs);
//!  - no other job of release.yml names the macOS platform, a macOS worker set or a macOS runner;
//!  - it is not triggered on a pull request: release.yml's `on:` names no pull_request, and no
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
const NONBLOCKING = "    continue-on-error: true";
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

/// Null if release.yml's macOS job holds its contract, else the refusal.
fn checkMacos(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    const job = (try jobLines(ar, text, JOB, &n)) orelse return "release.yml has no job release-macos";
    if (n != 1) return "release-macos is defined more than once";

    // on the farm's macOS workers, never a hosted macOS runner: the job itself runs on ubuntu
    if (!has(job, "    runs-on: ubuntu-24.04")) return "release-macos does not run on ubuntu-24.04 (a hosted macOS runner is not the farm's Macs)";
    if (mentions(job, "runs-on: macos") or mentions(job, "runs-on: [")) return "release-macos names a hosted macOS runner";
    if (!has(job, "    environment: build")) return "release-macos is not in the environment build (the claim the farm's trust was set for)";

    // it does not hold up the Linux path
    if (startsWithAny(job, "    needs:")) return "release-macos has needs: it waits on another job";
    if (startsWithAny(job, "    if:")) return "release-macos has a condition: it runs on every release run";
    if (!has(job, NONBLOCKING)) return "release-macos is not continue-on-error: true (the choice is: reported, not blocking)";
    const bound = (for (job) |l| {
        if (std.mem.startsWith(u8, l, "    timeout-minutes: ")) break std.fmt.parseInt(u32, std.mem.trim(u8, l["    timeout-minutes: ".len..], " "), 10) catch return "release-macos: timeout-minutes is not a number";
    } else return "release-macos has no timeout-minutes (a stalled macOS build would hold the next release)");
    if (bound == 0 or bound > MAX_MINUTES) return "release-macos: timeout-minutes is not bounded at 120 or less";
    if (!has(job, BOUND)) return "release-macos: timeout-minutes is not the 90 the comment and docs/ci.md state";
    const names = try jobNames(ar, text);
    for (names) |other| {
        if (std.mem.eql(u8, other, JOB)) continue;
        var m: usize = 0;
        const lines = (try jobLines(ar, text, other, &m)).?;
        for (lines) |l| {
            if (std.mem.startsWith(u8, l, "    needs:") and std.mem.indexOf(u8, l, JOB) != null)
                return try std.fmt.allocPrint(ar, "{s} needs release-macos: the Linux path would wait on the macOS build", .{other});
            if (std.mem.indexOf(u8, l, "needs." ++ JOB) != null)
                return try std.fmt.allocPrint(ar, "{s} reads the result of release-macos: the Linux path would depend on the macOS build", .{other});
        }
        // the macOS platform, worker set and runner are named by this job only
        for (lines) |l| {
            if (namesMacos(l)) return try std.fmt.allocPrint(ar, "{s} names a macOS platform, worker set or runner: only release-macos does", .{other});
        }
    }

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
        if (namesMacos(line)) return "a workflow that runs on a pull request names a macOS platform, worker set or runner (the macOS build is a job of release.yml)";
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
        std.debug.print("accepted a release.yml that must be refused with: {s}\n", .{want});
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

test "release.yml holds the contract of the macOS build" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, &.{ "workflows", "release.yml" });
    if (try checkMacos(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
    // the job is the macOS build the CEO asked for, and the workflow still has no pull_request trigger
    try t.expect(!runsOnPullRequest(text));
}

test "each edit of the real release.yml that breaks the macOS build's contract is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, &.{ "workflows", "release.yml" });
    const head = "  release-macos:\n    runs-on: ubuntu-24.04\n";

    // the job exists, once
    try expectRefused(ar, try replaced(ar, text, "  release-macos:\n", "  release-macos-gone:\n"), "has no job release-macos");
    try expectRefused(ar, try replaced(ar, text, "  mopm-stage:\n", "  release-macos:\n    runs-on: ubuntu-24.04\n\n  mopm-stage:\n"), "more than once");

    // on the farm's workers, not a hosted macOS runner
    try expectRefused(ar, try replaced(ar, text, head, "  release-macos:\n    runs-on: macos-15\n"), "does not run on ubuntu-24.04");
    try expectRefused(ar, try replaced(ar, text, head, head ++ "    runs-on: macos-15\n"), "names a hosted macOS runner");
    try expectRefused(ar, try replaced(ar, text, "    environment: build\n    timeout-minutes: 90\n", "    timeout-minutes: 90\n"), "not in the environment build");

    // it does not hold up the Linux path
    try expectRefused(ar, try intoJob(ar, text, "    needs: release"), "waits on another job");
    try expectRefused(ar, try intoJob(ar, text, "    if: github.event_name == 'push'"), "has a condition");
    try expectRefused(ar, try replaced(ar, text, NONBLOCKING ++ "\n", ""), "not continue-on-error: true");
    try expectRefused(ar, try replaced(ar, text, NONBLOCKING ++ "\n", "    continue-on-error: false\n"), "not continue-on-error: true");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", ""), "no timeout-minutes");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 360\n"), "not bounded at 120");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 0\n"), "not bounded at 120");
    try expectRefused(ar, try replaced(ar, text, BOUND ++ "\n", "    timeout-minutes: 100\n"), "not the 90");
    // nothing waits on it: not the prod publish, not any other job
    try expectRefused(ar, try replaced(ar, text, "    needs: [release, mopm-stage]\n", "    needs: [release, mopm-stage, release-macos]\n"), "needs release-macos");
    try expectRefused(ar, try replaced(ar, text, "    needs: prod-commit\n", "    needs: [prod-commit, release-macos]\n"), "needs release-macos");
    try expectRefused(ar, try replaced(ar, text, "    needs: prod-stage\n", "    needs: prod-stage\n    if: needs.release-macos.result == 'success'\n"), "reads the result of release-macos");

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

    // no other job names the macOS platform
    try expectRefused(ar, try replaced(ar, text, "          args: build //release/ci:check_release_ref --out", "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 //release/ci:check_release_ref --out"), "only release-macos does");
    try expectRefused(ar, try replaced(ar, text, "  mopm-stage:\n    runs-on: ubuntu-24.04\n", "  mopm-stage:\n    runs-on: macos-15\n"), "only release-macos does");

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
        // release.yml is the one with the macOS build, and it runs on no pull request
        if (std.mem.eql(u8, name, "release.yml")) try t.expect(!runsOnPullRequest(text));
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
    try t.expect(checkPullRequestWorkflow(try std.fmt.allocPrint(ar, "{s}\n# the macOS build is a job of release.yml\n", .{pr})) == null);
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
    // every excluded name is a package of packages.bzl, and every one names the native target that excludes it
    const pk = try readData(ar, &.{"packages.bzl"});
    var in_excluded = false;
    var excluded: usize = 0;
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "DARWIN_EXCLUDED = {")) {
            in_excluded = true;
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
        try t.expect(std.mem.indexOf(u8, line, ":native_") != null);
        excluded += 1;
    }
    try t.expect(excluded >= 1);
}
