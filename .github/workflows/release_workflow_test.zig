//! The cases of the job `mopm-publish-beta` of release.yml, //:release_workflow_cases:
//! a `zig_test` run as a build action. The workflow's own bytes are the subject
//! (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/release.yml).
//!
//! The job publishes to the beta registry with the job's GitHub OIDC identity
//! and no secret, and ships off. What the cases catch:
//!  - the gate: `needs: mopm-stage`, the `if:` with a push to main and the
//!    repository variable `MOPM_BETA_PUBLISH_ENABLED` equal to `true`, so a job
//!    that loses a part of its gate (and publishes on every run) is red;
//!  - the identity: `environment: beta` and exactly the permissions
//!    `contents: read` and `id-token: write`, so a job that cannot ask the
//!    runner for an ID token, or that holds more, is red;
//!  - no secret: no line outside a comment names `MOPM_TOKEN` or `secrets.`,
//!    and no job joins the farm;
//!  - the command: `publish --staged <dir> --oidc --registry beta`, never
//!    `--dry-run` (a job that stops sending) and never another registry;
//!  - the prod job keeps its token and gains no `id-token`;
//!  - the set published to beta is planned against beta: `mopm-stage-beta`
//!    stages with `--registry beta` (never prod), under the same gate, with no
//!    environment, no `id-token`, no secret and no farm, and `mopm-publish-beta`
//!    needs it and publishes the set it staged;
//!  - the workflow's top-level `permissions` is `{}` (a job holds only what it
//!    names) and its `on:` is a push to main and a manual run, nothing else (a
//!    `pull_request_target` or a second branch would reach the jobs).
//!  - the job `mopm-e2e-beta` verifies what the beta publish sent: it needs
//!    `mopm-publish-beta`, has the same gate, runs in the environment `build` (the
//!    farm's; a job holds one) with exactly `contents: read` and `id-token: write`,
//!    reads no secret and publishes nothing, and runs its steps in this order: the
//!    staged plan is downloaded, the farm is joined and `release_beta_fetch` built,
//!    the download and check against the plan (`--stage beta`, the beta index,
//!    `--out release/beta_set`, nothing else names that directory), then the e2e of
//!    every package on that set at this run's version, every farm step asserted remote.
//! The reader's own cases are workflow texts written here: each defect above
//! is planted in the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const JOB = "mopm-publish-beta";
const PROD_JOB = "mopm-publish";
const STAGE_JOB = "mopm-stage-beta";
const PROD_STAGE_JOB = "mopm-stage";
const TOOL = "release_beta_version";
const BUILD_TOOL_LINE = "          args: build //tools/build/ci:release_beta_version --out ${{ runner.temp }}/mopm-publish/release_beta_version";
const UPLOAD_TOOL_LINE = "            ${{ runner.temp }}/mopm-publish/release_beta_version";
const REWRITE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version \"0.1.$RUN_NUMBER\"'";
const REWRITE_ENV = "          RUN_NUMBER: ${{ github.run_number }}";
const STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts\" --compiler 1.0.0 --out \"$RUNNER_TEMP/mopm-publish/staged_beta\" --registry beta'";
const GATE = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'";
const E2E_JOB = "mopm-e2e-beta";
const E2E_DOWNLOAD_NAME = "          name: mopm-staged-beta-${{ github.sha }}";
const E2E_FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
const E2E_BUILD_FETCH = "          args: build //tools/build/ci:release_beta_fetch --out ${{ runner.temp }}/mopm-e2e-beta/release_beta_fetch";
const E2E_FETCH_RUN = "        run: '\"$RUNNER_TEMP/mopm-e2e-beta/release_beta_fetch\" --staged \"$RUNNER_TEMP/mopm-e2e-beta/staged_beta\" --config-url https://api.beta.mopm.dev/index/config.json --stage beta --out release/beta_set'";
const E2E_RUN = "          args: build -c komira_release.staged=beta -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all";
const E2E_ASSERT = "          assert-remote: ${{ steps.assert.outputs.path }}";

/// The lines of the job `name` of the `jobs:` map (a key at two spaces of
/// indent), without comment lines and blank lines, or null if there is no such
/// job. Counts the jobs of that name in `count`.
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

/// Null if the job `mopm-e2e-beta` holds its contract, else the refusal: it verifies what the
/// beta publish sent and sends nothing itself.
fn checkE2e(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    const job = (try jobLines(ar, text, E2E_JOB, &n)) orelse return "no job mopm-e2e-beta";
    if (n != 1) return "mopm-e2e-beta is defined more than once";
    if (!has(job, "    needs: mopm-publish-beta")) return "e2e-beta needs is not exactly mopm-publish-beta";
    if (!has(job, GATE)) return "e2e-beta: the if is not the push-to-main and MOPM_BETA_PUBLISH_ENABLED gate";
    if (!has(job, "    environment: build")) return "e2e-beta environment is not build (the farm's)";
    if (!has(job, "    permissions:") or !has(job, "      contents: read") or !has(job, "      id-token: write"))
        return "e2e-beta permissions are not contents: read and id-token: write";
    var perms: usize = 0;
    for (job) |l| {
        if (std.mem.startsWith(u8, l, "      ") and !std.mem.startsWith(u8, l, "       ") and
            (std.mem.indexOf(u8, l, ": read") != null or std.mem.indexOf(u8, l, ": write") != null)) perms += 1;
    }
    if (perms != 2) return "e2e-beta permissions hold more than contents and id-token";
    // it sends nothing and holds no credential
    if (mentions(job, "MOPM_TOKEN") or mentions(job, "secrets.")) return "e2e-beta reads a secret";
    for (job) |l| {
        if (std.mem.eql(u8, l, "    needs: mopm-publish-beta")) continue;
        if (std.mem.indexOf(u8, l, "publish") != null or std.mem.indexOf(u8, l, "--oidc") != null) return "e2e-beta publishes or runs mopm";
    }
    if (mentions(job, "environment: beta")) return "e2e-beta holds the beta environment";
    // the order: the plan, the farm, the tool, the download and check, then the e2e
    const download_at = lineAt(job, E2E_DOWNLOAD_NAME) orelse return "e2e-beta does not download the staged beta plan (mopm-staged-beta)";
    const connect_at = lineAt(job, E2E_FARM_CONNECT) orelse return "e2e-beta does not join the farm";
    const tool_at = lineAt(job, E2E_BUILD_FETCH) orelse return "e2e-beta does not build release_beta_fetch";
    const fetch_at = lineAt(job, E2E_FETCH_RUN) orelse return "e2e-beta does not download and check against the plan (release_beta_fetch with --stage beta)";
    const run_at = lineAt(job, E2E_RUN) orelse return "e2e-beta does not run the e2e on the downloaded set (staged=beta at this run's version)";
    if (!(download_at < fetch_at)) return "e2e-beta checks before it has the plan";
    if (!(connect_at < tool_at and tool_at < fetch_at)) return "e2e-beta fetches before the farm is joined and the tool built";
    if (!(fetch_at < run_at)) return "e2e-beta runs the e2e before the download and check";
    // nothing between the check and the e2e may touch the set, and nothing else may write it
    var writers: usize = 0;
    for (job) |l| {
        if (std.mem.indexOf(u8, l, "beta_set") != null) writers += 1;
    }
    if (writers != 1) return "e2e-beta names release/beta_set other than in the one download step";
    var fetch_runs: usize = 0;
    for (job) |l| {
        if (std.mem.indexOf(u8, l, "release_beta_fetch") != null and std.mem.startsWith(u8, l, "        run:")) fetch_runs += 1;
    }
    if (fetch_runs != 1) return "e2e-beta runs release_beta_fetch more than once";
    // the one `|| true` is the daemon stop at the end, which must not fail the job
    for (job) |l| {
        if (std.mem.indexOf(u8, l, "|| true") != null and !std.mem.eql(u8, l, "        run: ./buck2 kill || true")) return "e2e-beta ignores a failure";
    }
    if (mentions(job, "continue-on-error")) return "e2e-beta ignores a failure";
    // both farm steps are asserted to run remotely
    var asserted: usize = 0;
    for (job) |l| {
        if (std.mem.eql(u8, l, E2E_ASSERT)) asserted += 1;
    }
    if (asserted != 2) return "e2e-beta has a farm step that is not asserted remote";
    return null;
}

/// Null if the workflow text holds the contract, else the refusal.
fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    const job = (try jobLines(ar, text, JOB, &n)) orelse return "no job mopm-publish-beta";
    if (n != 1) return "mopm-publish-beta is defined more than once";
    if (!has(job, "    needs: mopm-stage-beta")) return "needs is not exactly mopm-stage-beta";
    if (!has(job, GATE))
        return "the if is not the push-to-main and MOPM_BETA_PUBLISH_ENABLED gate";
    if (!has(job, "    environment: beta")) return "environment is not beta";
    if (!has(job, "    permissions:") or !has(job, "      contents: read") or !has(job, "      id-token: write"))
        return "permissions are not contents: read and id-token: write";
    var perms: usize = 0;
    for (job) |l| {
        if (std.mem.startsWith(u8, l, "      ") and !std.mem.startsWith(u8, l, "       ") and
            (std.mem.indexOf(u8, l, ": read") != null or std.mem.indexOf(u8, l, ": write") != null)) perms += 1;
    }
    if (perms != 2) return "permissions hold more than contents and id-token";
    if (mentions(job, "MOPM_TOKEN")) return "the job names MOPM_TOKEN";
    if (mentions(job, "secrets.")) return "the job reads a secret";
    if (mentions(job, "farm") or mentions(job, "buck2")) return "the job joins the farm or runs buck2";
    if (!has(job, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged_beta\" --oidc --registry beta'"))
        return "the publish command is not publish --staged --oidc --registry beta";
    if (mentions(job, "--dry-run")) return "the job publishes with --dry-run";

    var sn: usize = 0;
    const stage = (try jobLines(ar, text, STAGE_JOB, &sn)) orelse return "no job mopm-stage-beta";
    if (sn != 1) return "mopm-stage-beta is defined more than once";
    if (!has(stage, "    needs: mopm-stage")) return "stage-beta needs is not exactly mopm-stage";
    if (!has(stage, GATE)) return "stage-beta: the if is not the push-to-main and MOPM_BETA_PUBLISH_ENABLED gate";
    if (mentions(stage, "environment:")) return "stage-beta holds an environment";
    if (mentions(stage, "id-token")) return "stage-beta holds id-token";
    if (!has(stage, "    permissions:") or !has(stage, "      contents: read")) return "stage-beta permissions are not contents: read";
    if (mentions(stage, "MOPM_TOKEN") or mentions(stage, "secrets.")) return "stage-beta reads a secret";
    if (mentions(stage, "farm") or mentions(stage, "buck2")) return "stage-beta joins the farm or runs buck2";
    const stage_at = lineAt(stage, STAGE_RUN) orelse return "stage-beta does not stage against beta with --out staged_beta";
    if (mentions(stage, "--registry prod")) return "stage-beta names the prod registry";
    // a version of its own for every push: the members are rewritten to 0.1.<run number>
    // on the job's checkout, before the stage, and nothing is written back
    const rewrite_at = lineAt(stage, REWRITE_RUN) orelse return "stage-beta does not give the members 0.1.<run number> (release_beta_version)";
    if (rewrite_at > stage_at) return "stage-beta runs release_beta_version after mopm stage";
    if (!has(stage, REWRITE_ENV)) return "stage-beta does not take the run number from github.run_number";
    if (rewrite_at < 3 or !std.mem.eql(u8, stage[rewrite_at - 2], "        env:") or !std.mem.eql(u8, stage[rewrite_at - 1], REWRITE_ENV)) return "stage-beta: the rewrite step has no env";
    var tool_runs: usize = 0;
    for (stage) |l| {
        if (std.mem.indexOf(u8, l, TOOL) != null and std.mem.indexOf(u8, l, "        run:") == 0 and
            !std.mem.startsWith(u8, l, "        run: chmod +x ")) tool_runs += 1;
    }
    if (tool_runs != 1) return "stage-beta runs release_beta_version more than once";
    if (mentions(stage, "git push") or mentions(stage, "git commit")) return "stage-beta commits or pushes what it rewrote";

    // prod keeps the real versions: its job builds the tool for the beta job's artifact and
    // never runs it
    var psn: usize = 0;
    const prod_stage = (try jobLines(ar, text, PROD_STAGE_JOB, &psn)) orelse return "no job mopm-stage";
    if (psn != 1) return "mopm-stage is defined more than once";
    var builds: usize = 0;
    for (prod_stage) |l| {
        if (std.mem.indexOf(u8, l, TOOL) == null) continue;
        if (std.mem.eql(u8, l, BUILD_TOOL_LINE)) {
            builds += 1;
        } else if (!std.mem.eql(u8, l, UPLOAD_TOOL_LINE)) {
            return "mopm-stage names release_beta_version other than to build it and hand it on: prod keeps the real versions";
        }
    }
    if (builds != 1) return "mopm-stage does not build release_beta_version once for the beta job";
    if (lineAt(prod_stage, UPLOAD_TOOL_LINE) == null) return "mopm-stage does not hand release_beta_version to the beta job";

    var pn: usize = 0;
    const prod = (try jobLines(ar, text, PROD_JOB, &pn)) orelse return "no job mopm-publish";
    if (pn != 1) return "mopm-publish is defined more than once";
    if (!mentions(prod, "MOPM_TOKEN: ${{ secrets.MOPM_TOKEN }}")) return "the prod job lost its token";
    if (mentions(prod, "id-token")) return "the prod job gained id-token";

    if (try checkE2e(ar, text)) |why| return why;

    // top-level permissions and the triggers
    var tp: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "permissions:")) {
            if (!std.mem.eql(u8, l, "permissions: {}")) return "top-level permissions is not {}";
            tp += 1;
        }
    }
    if (tp != 1) return "top-level permissions: {} is not present exactly once";
    var cn: usize = 0;
    const on = (try topLines(ar, text, "on:", &cn)) orelse return "no on: block";
    if (cn != 1) return "on: is defined more than once";
    var keys = std.ArrayList([]const u8).empty;
    for (on) |l| {
        if (l.len > 2 and l[0] == ' ' and l[1] == ' ' and l[2] != ' ') try keys.append(ar, std.mem.trim(u8, l, " "));
    }
    if (keys.items.len != 2 or !std.mem.eql(u8, keys.items[0], "push:") or !std.mem.eql(u8, keys.items[1], "workflow_dispatch:"))
        return "on: is not exactly push and workflow_dispatch";
    if (!has(on, "    branches: [main]")) return "on: push is not branches: [main]";
    if (mentions(on, "pull_request")) return "on: names a pull_request trigger";
    return null;
}

/// The lines of the top-level key `key` (a line at column 0, e.g. `on:`), up to the next
/// top-level line, without comment and blank lines.
fn topLines(ar: std.mem.Allocator, text: []const u8, key: []const u8, count: *usize) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != ' ') {
            inside = std.mem.eql(u8, line, key);
            if (inside) {
                count.* += 1;
                found = true;
            }
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "workflows", "release.yml" });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const got = (try check(ar, text)) orelse {
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

test "release.yml holds the contract of mopm-publish-beta" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    if (try check(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "each defect planted in the real release.yml is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    const gate = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n";
    const cmd = " --oidc --registry beta'\n";

    // a gate that lost its variable, its push, its main, or the whole if
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'push' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED != ''\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, ""), "gate");
    // the stage dependency
    try expectRefused(ar, try replaced(ar, text, "    needs: mopm-stage-beta\n", ""), "needs");
    try expectRefused(ar, try replaced(ar, text, "    needs: mopm-stage-beta\n", "    needs: mopm-stage\n"), "needs");
    // the identity
    try expectRefused(ar, try replaced(ar, text, "      id-token: write\n    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n", "    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n"), "permissions");
    try expectRefused(ar, try replaced(ar, text, "    environment: beta\n", "    environment: prod\n"), "environment");
    try expectRefused(ar, try replaced(ar, text, "    environment: beta\n", ""), "environment");
    // more permissions than the two
    try expectRefused(ar, try replaced(ar, text, "      id-token: write\n    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n", "      id-token: write\n      packages: write\n    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n"), "more than");
    // a secret in the job
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm publish --staged --oidc\n", "      - name: mopm publish --staged --oidc\n        env:\n          MOPM_TOKEN: x\n"), "MOPM_TOKEN");
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm publish --staged --oidc\n", "      - name: mopm publish --staged --oidc\n        env:\n          X: ${{ secrets.OTHER }}\n"), "secret");
    // the farm
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm publish --staged --oidc\n", "      - uses: ./.github/actions/farm-connect\n      - name: mopm publish --staged --oidc\n"), "farm");
    // the command
    try expectRefused(ar, try replaced(ar, text, cmd, " --registry beta'\n"), "command");
    try expectRefused(ar, try replaced(ar, text, cmd, " --oidc --registry prod'\n"), "command");
    try expectRefused(ar, try replaced(ar, text, cmd, " --oidc --registry beta --dry-run'\n"), "command");
    // the beta stage job: planned against beta, same gate, no identity, no secret, no farm
    const stage_cmd = "--out \"$RUNNER_TEMP/mopm-publish/staged_beta\" --registry beta'\n";
    try expectRefused(ar, try replaced(ar, text, stage_cmd, "--out \"$RUNNER_TEMP/mopm-publish/staged_beta\" --registry prod'\n"), "stage-beta");
    try expectRefused(ar, try replaced(ar, text, stage_cmd, "--out \"$RUNNER_TEMP/mopm-publish/staged_beta\"'\n"), "stage-beta");
    try expectRefused(ar, try replaced(ar, text, "    needs: mopm-stage\n    if:", "    needs: mopm-stage\n    # gate removed\n    xif:"), "stage-beta");
    try expectRefused(ar, try replaced(ar, text, "    timeout-minutes: 30\n    permissions:\n      contents: read\n    steps:\n      - uses: actions/checkout", "    timeout-minutes: 30\n    environment: beta\n    permissions:\n      contents: read\n    steps:\n      - uses: actions/checkout"), "stage-beta holds an environment");
    try expectRefused(ar, try replaced(ar, text, "    timeout-minutes: 30\n    permissions:\n      contents: read\n    steps:\n      - uses: actions/checkout", "    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n    steps:\n      - uses: actions/checkout"), "stage-beta holds id-token");
    try expectRefused(ar, try replaced(ar, text, "      - name: the beta version tool is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/release_beta_version\"\n", "      - name: the beta version tool is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/release_beta_version\"\n        env:\n          T: ${{ secrets.MOPM_TOKEN }}\n"), "stage-beta reads a secret");
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm stage against beta\n", "      - run: ./buck2 build //x\n      - name: mopm stage against beta\n"), "stage-beta joins");
    // the beta version: the rewrite is there, before the stage, with the run number, once
    const rewrite_step = "      - name: every member gets the beta version\n        env:\n" ++ REWRITE_ENV ++ "\n" ++ REWRITE_RUN ++ "\n";
    try expectRefused(ar, try replaced(ar, text, rewrite_step, ""), "does not give the members");
    try expectRefused(ar, try replaced(ar, text, REWRITE_RUN ++ "\n", "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version 0.1.0'\n"), "does not give the members");
    try expectRefused(ar, try replaced(ar, text, REWRITE_RUN ++ "\n", "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version \"0.1.$RUN_NUMBER\" || true'\n"), "does not give the members");
    try expectRefused(ar, try replaced(ar, text, REWRITE_ENV ++ "\n", "          RUN_NUMBER: ${{ github.run_attempt }}\n"), "run number");
    try expectRefused(ar, try replaced(ar, text, rewrite_step ++ "      - name: mopm stage against beta\n" ++ STAGE_RUN ++ "\n", "      - name: mopm stage against beta\n" ++ STAGE_RUN ++ "\n" ++ rewrite_step), "after mopm stage");
    try expectRefused(ar, try replaced(ar, text, REWRITE_RUN ++ "\n", REWRITE_RUN ++ "\n      - run: git push origin HEAD\n"), "pushes");
    // the prod stage job never runs it, and no other job runs it either
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm stage\n        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage", "      - run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version 0.1.1'\n      - name: mopm stage\n        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage"), "prod keeps the real versions");
    try expectRefused(ar, try replaced(ar, text, BUILD_TOOL_LINE ++ "\n", ""), "does not build release_beta_version once");
    try expectRefused(ar, try replaced(ar, text, UPLOAD_TOOL_LINE ++ "\n", ""), "hand release_beta_version");
    // publish takes the set staged for prod instead of the beta one
    try expectRefused(ar, try replaced(ar, text, "publish --staged \"$RUNNER_TEMP/mopm-publish/staged_beta\" --oidc", "publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --oidc"), "publish command");
    // top-level permissions and the triggers
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions is not");
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\n"), "exactly once");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request_target:\n  workflow_dispatch:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n  schedule:\n    - cron: '0 0 * * *'\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main, 'release/**']\n"), "branches");
    // the prod job
    try expectRefused(ar, try replaced(ar, text, "          MOPM_TOKEN: ${{ secrets.MOPM_TOKEN }}\n", ""), "lost its token");
}

test "each defect planted in the mopm-e2e-beta job of the real release.yml is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    const need = "    needs: mopm-publish-beta\n";
    const env_build = "    environment: build\n";
    const head = need ++ GATE ++ "\n    runs-on: ubuntu-24.04\n" ++ env_build;
    const perms_tail = "      # for farm-connect only: the token Tailscale trusts\n      id-token: write\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ github.sha }}\n          persist-credentials: false\n      - uses: actions/download-artifact";
    const steps_head = "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ github.sha }}\n          persist-credentials: false\n      - uses: actions/download-artifact";
    const fetch_name = "      - name: download what beta serves and check it against the plan\n";
    const fetch_step = fetch_name ++ E2E_FETCH_RUN ++ "\n";
    const tool_step = "      - name: build the beta fetch tool\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ E2E_BUILD_FETCH ++ "\n" ++ E2E_ASSERT ++ "\n";
    const run_step = "      - name: the README e2e against the downloaded set\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ E2E_RUN ++ "\n" ++ E2E_ASSERT ++ "\n";
    const download_step = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n" ++ E2E_DOWNLOAD_NAME ++ "\n          path: ${{ runner.temp }}/mopm-e2e-beta/staged_beta\n";

    // the dependency: after the publish, and only it
    try expectRefused(ar, try replaced(ar, text, head, head[need.len..]), "e2e-beta needs");
    try expectRefused(ar, try replaced(ar, text, head, "    needs: mopm-stage-beta\n" ++ head[need.len..]), "e2e-beta needs");
    try expectRefused(ar, try replaced(ar, text, head, "    needs: [mopm-publish-beta, release]\n" ++ head[need.len..]), "e2e-beta needs");
    // the gate: each part, and the whole if
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    if: github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    if: always()\n    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
    // the environment: the farm's, not beta's or none
    try expectRefused(ar, try replaced(ar, text, head, head[0 .. head.len - env_build.len] ++ "    environment: beta\n"), "environment is not build");
    try expectRefused(ar, try replaced(ar, text, head, head[0 .. head.len - env_build.len]), "environment is not build");
    // the permissions: exactly contents and id-token
    try expectRefused(ar, try replaced(ar, text, perms_tail, steps_head), "e2e-beta permissions are not");
    try expectRefused(ar, try replaced(ar, text, perms_tail, "      id-token: write\n      packages: write\n" ++ steps_head), "more than contents");
    // it sends nothing and holds no credential
    try expectRefused(ar, try replaced(ar, text, fetch_step, fetch_name ++ "        env:\n          MOPM_TOKEN: x\n" ++ E2E_FETCH_RUN ++ "\n"), "reads a secret");
    try expectRefused(ar, try replaced(ar, text, fetch_step, fetch_name ++ "        env:\n          X: ${{ secrets.OTHER }}\n" ++ E2E_FETCH_RUN ++ "\n"), "reads a secret");
    try expectRefused(ar, try replaced(ar, text, run_step, "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry beta\n" ++ run_step), "publishes or runs mopm");
    try expectRefused(ar, try replaced(ar, text, run_step, "      - run: mopm-x --oidc\n" ++ run_step), "publishes or runs mopm");
    // the order: the plan, the farm and the tool, the download and check, then the e2e
    try expectRefused(ar, try replaced(ar, text, download_step, ""), "does not download the staged beta plan");
    const without_download = try replaced(ar, text, download_step, "");
    try expectRefused(ar, try replaced(ar, without_download, fetch_step, fetch_step ++ download_step), "checks before it has the plan");
    try expectRefused(ar, try replaced(ar, text, tool_step ++ fetch_step, fetch_step ++ tool_step), "fetches before the farm is joined and the tool built");
    try expectRefused(ar, try replaced(ar, text, fetch_step ++ run_step, run_step ++ fetch_step), "before the download and check");
    try expectRefused(ar, try replaced(ar, text, fetch_step, ""), "does not download and check");
    // the download and check: the beta stage, the beta index, the plan's directory, no escape
    try expectRefused(ar, try replaced(ar, text, "--stage beta --out release/beta_set'", "--stage prod --out release/beta_set'"), "does not download and check");
    try expectRefused(ar, try replaced(ar, text, "--stage beta --out release/beta_set'", "--stage beta --out release/beta_set || true'"), "does not download and check");
    try expectRefused(ar, try replaced(ar, text, "https://api.beta.mopm.dev/index/config.json", "https://api.mopm.dev/index/config.json"), "does not download and check");
    try expectRefused(ar, try replaced(ar, text, "staged_beta\" --config-url", "staged\" --config-url"), "does not download and check");
    try expectRefused(ar, try replaced(ar, text, fetch_step, fetch_step ++ "      - run: cp x release/beta_set/y\n"), "beta_set other than");
    try expectRefused(ar, try replaced(ar, text, fetch_step, fetch_step ++ fetch_step), "beta_set other than");
    // the e2e: the downloaded set, at this run's version, all packages, on the farm, failing the job
    try expectRefused(ar, try replaced(ar, text, "-c komira_release.staged=beta -c komira_release.beta_version", "-c komira_release.staged=stage -c komira_release.beta_version"), "does not run the e2e");
    try expectRefused(ar, try replaced(ar, text, "-c komira_release.staged=beta -c komira_release.beta_version=0.1.${{ github.run_number }} //", "-c komira_release.staged=beta //"), "does not run the e2e");
    try expectRefused(ar, try replaced(ar, text, "beta_version=0.1.${{ github.run_number }}", "beta_version=0.1.${{ github.run_attempt }}"), "does not run the e2e");
    try expectRefused(ar, try replaced(ar, text, "beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all", "beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:komira_hash"), "does not run the e2e");
    try expectRefused(ar, try replaced(ar, text, E2E_RUN ++ "\n" ++ E2E_ASSERT ++ "\n", E2E_RUN ++ "\n"), "not asserted remote");
    try expectRefused(ar, try replaced(ar, text, E2E_RUN ++ "\n" ++ E2E_ASSERT ++ "\n", E2E_RUN ++ "\n" ++ E2E_ASSERT ++ "\n        continue-on-error: true\n"), "ignores a failure");
    try expectRefused(ar, try replaced(ar, text, E2E_BUILD_FETCH ++ "\n" ++ E2E_ASSERT ++ "\n", E2E_BUILD_FETCH ++ "\n"), "not asserted remote");
}

test "a comment naming MOPM_TOKEN does not count, a line does" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var n: usize = 0;
    const lines = (try jobLines(ar, "jobs:\n  a:\n    # MOPM_TOKEN\n    x: 1\n  b:\n    y: MOPM_TOKEN\n", "a", &n)).?;
    try t.expect(!mentions(lines, "MOPM_TOKEN"));
    n = 0;
    const b = (try jobLines(ar, "jobs:\n  a:\n    # MOPM_TOKEN\n    x: 1\n  b:\n    y: MOPM_TOKEN\n", "b", &n)).?;
    try t.expect(mentions(b, "MOPM_TOKEN"));
    n = 0;
    try t.expect((try jobLines(ar, "jobs:\n  a:\n    x: 1\n", "c", &n)) == null);
}
