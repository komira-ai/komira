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
//! The reader's own cases are workflow texts written here: each defect above
//! is planted in the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const JOB = "mopm-publish-beta";
const PROD_JOB = "mopm-publish";
const STAGE_JOB = "mopm-stage-beta";
const GATE = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'";

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

fn mentions(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
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
    if (!has(stage, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts\" --compiler 1.0.0 --out \"$RUNNER_TEMP/mopm-publish/staged_beta\" --registry beta'"))
        return "stage-beta does not stage against beta with --out staged_beta";
    if (mentions(stage, "--registry prod")) return "stage-beta names the prod registry";

    var pn: usize = 0;
    const prod = (try jobLines(ar, text, PROD_JOB, &pn)) orelse return "no job mopm-publish";
    if (pn != 1) return "mopm-publish is defined more than once";
    if (!mentions(prod, "MOPM_TOKEN: ${{ secrets.MOPM_TOKEN }}")) return "the prod job lost its token";
    if (mentions(prod, "id-token")) return "the prod job gained id-token";

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
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm stage against beta", "      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n        env:\n          T: ${{ secrets.MOPM_TOKEN }}\n      - name: mopm stage against beta"), "stage-beta reads a secret");
    try expectRefused(ar, try replaced(ar, text, "      - name: mopm stage against beta\n", "      - run: ./buck2 build //x\n      - name: mopm stage against beta\n"), "stage-beta joins");
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
