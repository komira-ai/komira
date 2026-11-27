//! The cases of npm.yml, //:npm_workflow_cases: a `zig_test` run as a build action. The workflow's own bytes
//! are the subject (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/npm.yml).
//!
//! npm.yml builds, tests and publishes the npm packages (docs/ci.md, "npm.yml: publishing the npm packages").
//! npm's trusted publishing trusts this file's name and the environment `npm`, so what a job may hold is the
//! contract. What the cases catch:
//!  - the triggers: `on:` is exactly a push to main with the documentation paths ignored; a pull request, a
//!    pull_request_target, a merge group, a schedule or a manual run anywhere in it is red;
//!  - the top-level `permissions` is `{}`, so a job holds only what it names;
//!  - the jobs are exactly `build`, `test`, `build-macos-arm64`, `publish` and `smoke`, each on the hosted
//!    runner ubuntu-24.04;
//!  - each job's exact `if:` (a push to main; for `publish` also `build` and `test` passed and the gate's
//!    output `true`, and for `smoke` the publish passed, whatever the macOS job did), its exact `needs`
//!    (`test` and `build-macos-arm64` need `build`, `publish` needs those three, `smoke` needs `build` and
//!    `publish`), its environment (`build` for the three farm jobs, `npm` for `publish` alone,
//!    none for `smoke`) and its exact permissions (`contents: read` and `id-token: write` for the farm jobs
//!    and `publish`, `{}` for `smoke`);
//!  - the macOS package: `publish` takes the set with the macOS package exactly when `build-macos-arm64`
//!    succeeded, and the set without it otherwise, and hands that choice on as its output `set`, which
//!    `smoke` downloads (so a re-run cannot point the smoke at another set); only that job keeps that set, after
//!    its install test (//node:install_test_macos_arm64) and then the set's build, with no step it may skip or
//!    pass over (no `continue-on-error`, no step condition but the `always()` of Stop buck2): so the main
//!    package names the macOS package only when its install test passed;
//!  - the gate: `build` reads release/npm_publish.txt with `npm_smoke gate` in the step `gate`, and its output
//!    `publish` is that step's, so the publish cannot run while the file says off;
//!  - the publish: `publish` is the only job that runs `npm_smoke publish`, with the set the build kept, and it
//!    has no checkout, no farm and no build; no other job names the publish command, and `smoke` holds no
//!    identity and reaches no farm;
//!  - no token: no line outside a comment names NPM_TOKEN, NODE_AUTH_TOKEN, an npm auth token or `secrets`.
//! Each defect is written into the real text and must be refused with its exact message.

const std = @import("std");
const t = std.testing;

const JOBS = [_][]const u8{ "build", "test", "build-macos-arm64", "publish", "smoke" };

const MACOS_JOB = "build-macos-arm64";

const ON_BLOCK = [_][]const u8{
    "on:",
    "  push:",
    "    branches: [main]",
    "    paths-ignore:",
    "      - 'docs/**'",
    "      - '**.md'",
};

const PUSH_GATE = "    if: github.ref == 'refs/heads/main' && github.event_name == 'push'";
const PUBLISH_GATE = "    if: ${{ !cancelled() && github.ref == 'refs/heads/main' && github.event_name == 'push' && needs.build.result == 'success' && needs.test.result == 'success' && needs.build.outputs.publish == 'true' }}";
const SMOKE_GATE = "    if: ${{ !cancelled() && github.ref == 'refs/heads/main' && github.event_name == 'push' && needs.publish.result == 'success' && needs.build.outputs.publish == 'true' }}";
const RUNNER = "    runs-on: ubuntu-24.04";

const FARM_PERMISSIONS = [_][]const u8{ "    permissions:", "      contents: read", "      id-token: write" };
const NO_PERMISSIONS = [_][]const u8{"    permissions: {}"};

const GATE_ID = "        id: gate";
const GATE_RUN = "        run: '\"$RUNNER_TEMP/npm/tools/npm_smoke\" gate --file release/npm_publish.txt --github-output \"$GITHUB_OUTPUT\"'";
const GATE_OUTPUT = "      publish: ${{ steps.gate.outputs.publish }}";
const PUBLISH_RUN = "        run: '\"$RUNNER_TEMP/npm/tools/npm_smoke\" publish --set \"$RUNNER_TEMP/npm/set/npm_set.json\" --dir \"$RUNNER_TEMP/npm/set\" --node \"$RUNNER_TEMP/npm/tools/node/bin/node\" --npm \"$RUNNER_TEMP/npm/tools/npm\" --work \"$RUNNER_TEMP/npm/publish\"'";
const PUBLISH_WORD = "npm_smoke\" publish";

/// The set `publish` downloads: the one with the macOS package exactly when the macOS job succeeded; its
/// output `set`, the same choice; and the smoke's download of that output.
const CHOICE = "${{ needs.build-macos-arm64.result == 'success' && format('npm-set-macos-arm64-{0}', github.sha) || format('npm-set-{0}', github.sha) }}";
const SET_CHOICE = "          name: " ++ CHOICE;
const SET_OUTPUT = "      set: " ++ CHOICE;
const SMOKE_SET = "          name: ${{ needs.publish.outputs.set }}";
/// The macOS job's install test, the set it then builds, and the artifact it keeps, in that order.
const MAC_INSTALL_TEST = "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 -c komira_release.mac_tree=true -c komira.package_stamp=${{ needs.build.outputs.build_number }} -c komira.package_commit=${{ needs.build.outputs.source_commit }} -c komira.package_timestamp_ms=${{ needs.build.outputs.timestamp_ms }} //node:install_test_macos_arm64";
const MAC_SET_BUILD = "          args: build -c komira_release.mac_tree=true -c komira.package_stamp=${{ needs.build.outputs.build_number }} -c komira.package_commit=${{ needs.build.outputs.source_commit }} -c komira.package_timestamp_ms=${{ needs.build.outputs.timestamp_ms }} //release:npm_packages_macos_arm64 --out ${{ runner.temp }}/npm/macos-set";
const MAC_KEEP = "          name: npm-set-macos-arm64-${{ github.sha }}";
const MAC_SET_WORD = "npm-set-macos-arm64-";
const STOP_STEP = "      - name: Stop buck2";
const STOP_IF = "        if: always()";
const SMOKE_WORD = "npm_smoke\" smoke";

/// Words no line outside a comment may hold: a token, a secret, a trigger of another event.
const BANNED = [_][]const u8{ "NPM_TOKEN", "NODE_AUTH_TOKEN", "_authToken", "secrets", "pull_request", "merge_group", "workflow_dispatch", "schedule", "self-hosted" };

/// Words a job without a farm or a checkout may not hold.
const FARM_WORDS = [_][]const u8{ "actions/checkout", "farm-connect", "buck2" };

const Want = struct {
    name: []const u8,
    needs: ?[]const u8,
    gate: []const u8,
    environment: ?[]const u8,
    permissions: []const []const u8,
    /// The permissions as the refusal names them.
    permissions_text: []const u8,
    /// No checkout, no farm, no build.
    farmless: bool,
};

const WANT = [_]Want{
    .{ .name = "build", .needs = null, .gate = PUSH_GATE, .environment = "build", .permissions = &FARM_PERMISSIONS, .permissions_text = "contents: read and id-token: write", .farmless = false },
    .{ .name = "test", .needs = "    needs: build", .gate = PUSH_GATE, .environment = "build", .permissions = &FARM_PERMISSIONS, .permissions_text = "contents: read and id-token: write", .farmless = false },
    .{ .name = MACOS_JOB, .needs = "    needs: build", .gate = PUSH_GATE, .environment = "build", .permissions = &FARM_PERMISSIONS, .permissions_text = "contents: read and id-token: write", .farmless = false },
    .{ .name = "publish", .needs = "    needs: [build, test, build-macos-arm64]", .gate = PUBLISH_GATE, .environment = "npm", .permissions = &FARM_PERMISSIONS, .permissions_text = "contents: read and id-token: write", .farmless = true },
    .{ .name = "smoke", .needs = "    needs: [build, publish]", .gate = SMOKE_GATE, .environment = null, .permissions = &NO_PERMISSIONS, .permissions_text = "{}", .farmless = true },
};

fn isComment(line: []const u8) bool {
    const s = std.mem.trimLeft(u8, line, " ");
    return s.len == 0 or s[0] == '#';
}

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimLeft(u8, line, " ").len;
}

/// The lines of the top-level key `key` (the key's own line and the indented lines under it), comments and
/// blank lines left out; null when there is no such key.
fn topBlock(ar: std.mem.Allocator, text: []const u8, key: []const u8) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        if (indentOf(line) == 0) {
            inside = std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':';
            if (inside) found = true;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

/// The names of the jobs (the keys at two spaces of indent under `jobs:`), in order.
fn jobNames(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const jobs = (try topBlock(ar, text, "jobs")) orelse return out.toOwnedSlice(ar);
    for (jobs[1..]) |line| {
        if (indentOf(line) == 2 and std.mem.endsWith(u8, line, ":")) try out.append(ar, line[2 .. line.len - 1]);
    }
    return out.toOwnedSlice(ar);
}

/// The lines of job `name` under `jobs:`, comments and blank lines left out; null when there is none.
fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8) !?[]const []const u8 {
    const jobs = (try topBlock(ar, text, "jobs")) orelse return null;
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    for (jobs[1..]) |line| {
        if (indentOf(line) == 2) {
            inside = line.len == name.len + 3 and std.mem.eql(u8, line[2 .. line.len - 1], name) and line[line.len - 1] == ':';
            if (inside) found = true;
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

/// The lines of the job's key `key` (at four spaces): its own line and the deeper lines under it.
fn jobKey(ar: std.mem.Allocator, job: []const []const u8, key: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    for (job) |line| {
        if (indentOf(line) <= 4) {
            const s = line[indentOf(line)..];
            inside = indentOf(line) == 4 and std.mem.startsWith(u8, s, key) and s.len > key.len and s[key.len] == ':';
        }
        if (inside) try out.append(ar, line);
    }
    return out.toOwnedSlice(ar);
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

fn mentions(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

/// The index of the first line of `lines` that is exactly `exact`.
fn indexOfLine(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

/// Null if the macOS job keeps its set only after its install test passed, else the refusal: the install
/// test, then the set's build, then the artifact, and no step it may skip or pass over.
fn macosRefusal(job: []const []const u8) ?[]const u8 {
    const tested = indexOfLine(job, MAC_INSTALL_TEST) orelse return "npm.yml: build-macos-arm64 does not run the macOS install test (//node:install_test_macos_arm64) on the farm's macOS workers";
    const built = indexOfLine(job, MAC_SET_BUILD) orelse return "npm.yml: build-macos-arm64 does not build //release:npm_packages_macos_arm64 from the build job's stamp";
    const kept = indexOfLine(job, MAC_KEEP) orelse return "npm.yml: build-macos-arm64 does not keep the set with the macOS package";
    if (!(tested < built and built < kept)) return "npm.yml: build-macos-arm64 keeps the set with the macOS package before its install test passed: the install test, the set's build and the artifact are in that order";
    if (mentions(job, "continue-on-error")) return "npm.yml: build-macos-arm64 has continue-on-error: a failed install test would leave the job green and the set kept";
    for (job, 0..) |line, i| {
        if (indentOf(line) < 6 or !std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "if:")) continue;
        if (!(std.mem.eql(u8, line, STOP_IF) and i > 0 and std.mem.eql(u8, job[i - 1], STOP_STEP)))
            return "npm.yml: a step of build-macos-arm64 has a condition: only Stop buck2 runs always(), and no step of the install test or the set is skipped";
    }
    return null;
}

/// Null if the workflow text holds the contract, else the refusal.
pub fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (isComment(line)) continue;
        for (BANNED) |word| {
            if (std.mem.indexOf(u8, line, word) != null) return try std.fmt.allocPrint(ar, "npm.yml:{d} names {s}: the workflow runs on a push to main alone, on a hosted runner, and holds no token or secret", .{ n, word });
        }
    }
    const on = (try topBlock(ar, text, "on")) orelse return "npm.yml has no on:";
    if (!sameLines(on, &ON_BLOCK)) return "npm.yml: on: is not exactly a push to main with docs/** and **.md ignored";
    const perms = (try topBlock(ar, text, "permissions")) orelse return "npm.yml has no top-level permissions: a job would hold the repository's default token";
    if (!sameLines(perms, &.{"permissions: {}"})) return "npm.yml: the top-level permissions are not {}";

    const names = try jobNames(ar, text);
    if (!sameLines(names, &JOBS)) return try std.fmt.allocPrint(ar, "npm.yml: the jobs are {s}, not build, test, build-macos-arm64, publish, smoke", .{try std.mem.join(ar, ", ", names)});

    for (WANT) |w| {
        const job = (try jobLines(ar, text, w.name)).?;
        if (!has(job, RUNNER)) return try std.fmt.allocPrint(ar, "npm.yml: {s} does not run on the hosted runner ubuntu-24.04", .{w.name});
        const gate = try jobKey(ar, job, "if");
        if (!sameLines(gate, &.{w.gate})) return try std.fmt.allocPrint(ar, "npm.yml: the condition of {s} is not `{s}`", .{ w.name, std.mem.trimLeft(u8, w.gate, " ") });
        const needs = try jobKey(ar, job, "needs");
        if (w.needs) |want| {
            if (!sameLines(needs, &.{want})) return try std.fmt.allocPrint(ar, "npm.yml: {s} does not have `{s}`", .{ w.name, std.mem.trimLeft(u8, want, " ") });
        } else if (needs.len != 0) return try std.fmt.allocPrint(ar, "npm.yml: {s} needs another job", .{w.name});
        const env = try jobKey(ar, job, "environment");
        if (w.environment) |e| {
            const line = try std.fmt.allocPrint(ar, "    environment: {s}", .{e});
            if (!sameLines(env, &.{line})) return try std.fmt.allocPrint(ar, "npm.yml: {s} does not run in the environment {s}", .{ w.name, e });
        } else if (env.len != 0) return try std.fmt.allocPrint(ar, "npm.yml: {s} runs in an environment: it holds no identity", .{w.name});
        const permissions = try jobKey(ar, job, "permissions");
        if (!sameLines(permissions, w.permissions)) return try std.fmt.allocPrint(ar, "npm.yml: the permissions of {s} are not exactly {s}", .{ w.name, w.permissions_text });
        if (w.farmless) {
            for (FARM_WORDS) |word| {
                if (mentions(job, word)) return try std.fmt.allocPrint(ar, "npm.yml: {s} names {s}: it has no checkout, no farm and no build", .{ w.name, word });
            }
        }
        const runs_publish = mentions(job, PUBLISH_WORD);
        if (std.mem.eql(u8, w.name, "publish")) {
            if (!has(job, PUBLISH_RUN)) return "npm.yml: publish does not run npm_smoke publish on the set the build kept";
        } else if (runs_publish) return try std.fmt.allocPrint(ar, "npm.yml: {s} runs npm_smoke publish: only the job publish publishes", .{w.name});
        if (std.mem.eql(u8, w.name, "smoke") and !mentions(job, SMOKE_WORD)) return "npm.yml: smoke does not run npm_smoke smoke";
        // the set with the macOS package: taken by the publish and the smoke exactly when the macOS job
        // succeeded, and kept by that job alone
        const takes = std.mem.eql(u8, w.name, "publish");
        if (takes and !(has(job, SET_CHOICE) and has(job, SET_OUTPUT))) return "npm.yml: publish does not take the set with the macOS package exactly when build-macos-arm64 succeeded, and the set without it otherwise, and hand that choice on as its output set";
        if (std.mem.eql(u8, w.name, "smoke") and !has(job, SMOKE_SET)) return "npm.yml: smoke does not download the set the publish took (needs.publish.outputs.set)";
        for (job) |line| {
            if (std.mem.indexOf(u8, line, MAC_SET_WORD) == null) continue;
            const ok = if (takes) std.mem.eql(u8, line, SET_CHOICE) or std.mem.eql(u8, line, SET_OUTPUT) else std.mem.eql(u8, w.name, MACOS_JOB) and std.mem.eql(u8, line, MAC_KEEP);
            if (!ok) return try std.fmt.allocPrint(ar, "npm.yml: {s} names the set with the macOS package other than as its keeper (build-macos-arm64) or the publish's choice", .{w.name});
        }
    }
    if (macosRefusal((try jobLines(ar, text, MACOS_JOB)).?)) |why| return why;

    // the gate: the build job's output `publish` is the gate step's, which reads the committed file
    const build = (try jobLines(ar, text, "build")).?;
    if (!has(build, GATE_OUTPUT)) return "npm.yml: the output publish of build is not the gate step's (steps.gate.outputs.publish)";
    var gate_steps: usize = 0;
    var gate_ids: usize = 0;
    for (build, 0..) |line, i| {
        if (std.mem.eql(u8, std.mem.trimLeft(u8, line, " "), "id: gate")) gate_ids += 1;
        if (!std.mem.eql(u8, line, GATE_RUN)) continue;
        gate_steps += 1;
        if (i == 0 or !std.mem.eql(u8, build[i - 1], GATE_ID)) return "npm.yml: the step that reads release/npm_publish.txt is not the step gate";
    }
    if (gate_steps != 1) return "npm.yml: build does not read release/npm_publish.txt with npm_smoke gate once";
    if (gate_ids != 1) return "npm.yml: build has a second step gate";
    return null;
}

fn read(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, "workflows", "npm.yml" }), 1 << 20);
}

/// The real text with `from` (which must be in it once) replaced by `to`.
fn edit(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, from));
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const got = (try check(ar, text)) orelse {
        std.debug.print("accepted; wanted the refusal: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, got);
}

/// The text of job `name` in the real file, from its key line to the next job's.
fn jobText(text: []const u8, name: []const u8) ![]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "\n  {s}:\n", .{name});
    const start = std.mem.indexOf(u8, text, key) orelse return error.NoJob;
    var end = text.len;
    for (JOBS) |other| {
        var other_buf: [64]u8 = undefined;
        const other_key = try std.fmt.bufPrint(&other_buf, "\n  {s}:\n", .{other});
        if (std.mem.indexOfPos(u8, text, start + 1, other_key)) |at| {
            if (at > start and at < end) end = at;
        }
    }
    // the comment lines above the next job belong to it
    return text[start..end];
}

/// The real text with `from` replaced by `to` inside job `name` only.
fn editJob(ar: std.mem.Allocator, text: []const u8, name: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const job = try jobText(text, name);
    const start = @intFromPtr(job.ptr) - @intFromPtr(text.ptr);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, job, from));
    const changed = try std.mem.replaceOwned(u8, ar, job, from, to);
    return std.mem.concat(ar, u8, &.{ text[0..start], changed, text[start + job.len ..] });
}

test "npm.yml holds the contract (the real file)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try check(ar, try read(ar))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a trigger other than the push to main, or top-level permissions other than {}, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    const push = "  push:\n    branches: [main]\n";
    try expectRefused(ar, try edit(ar, text, push, "  pull_request:\n" ++ push), try banned(ar, text, "  push:", "pull_request"));
    try expectRefused(ar, try edit(ar, text, push, "  workflow_dispatch:\n" ++ push), try banned(ar, text, "  push:", "workflow_dispatch"));
    try expectRefused(ar, try edit(ar, text, "      - '**.md'\n", "      - '**.md'\n  release:\n    types: [published]\n"), "npm.yml: on: is not exactly a push to main with docs/** and **.md ignored");
    try expectRefused(ar, try edit(ar, text, "    branches: [main]\n", "    branches: [main, 'release/**']\n"), "npm.yml: on: is not exactly a push to main with docs/** and **.md ignored");
    try expectRefused(ar, try edit(ar, text, "      - '**.md'\n", ""), "npm.yml: on: is not exactly a push to main with docs/** and **.md ignored");
    try expectRefused(ar, try edit(ar, text, "\npermissions: {}\n", "\n"), "npm.yml has no top-level permissions: a job would hold the repository's default token");
    try expectRefused(ar, try edit(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: read\n"), "npm.yml: the top-level permissions are not {}");
}

test "the jobs are exactly build, test, build-macos-arm64, publish and smoke, each on the hosted runner" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    try expectRefused(ar, try std.fmt.allocPrint(ar, "{s}\n  stage:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n", .{text}), "npm.yml: the jobs are build, test, build-macos-arm64, publish, smoke, stage, not build, test, build-macos-arm64, publish, smoke");
    try expectRefused(ar, try edit(ar, text, "\n  smoke:\n", "\n  smoke-registry:\n"), "npm.yml: the jobs are build, test, build-macos-arm64, publish, smoke-registry, not build, test, build-macos-arm64, publish, smoke");
    try expectRefused(ar, try editJob(ar, text, "publish", RUNNER ++ "\n", "    runs-on: ubuntu-latest\n"), "npm.yml: publish does not run on the hosted runner ubuntu-24.04");
    try expectRefused(ar, try editJob(ar, text, "build", RUNNER ++ "\n", "    runs-on: [self-hosted, linux]\n"), try banned(ar, text, RUNNER, "self-hosted"));
    // the macOS job on a hosted Mac: the farm's Macs build it, reached from the Linux runner
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, RUNNER ++ "\n", "    runs-on: macos-15\n"), "npm.yml: build-macos-arm64 does not run on the hosted runner ubuntu-24.04");
}

test "publish and smoke run only when the gate is true, and each job's needs are exact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    // the gate dropped from the publish or the smoke
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_GATE ++ "\n", PUSH_GATE ++ "\n"), "npm.yml: the condition of publish is not `" ++ PUBLISH_GATE[4..] ++ "`");
    try expectRefused(ar, try editJob(ar, text, "smoke", SMOKE_GATE ++ "\n", PUSH_GATE ++ "\n"), "npm.yml: the condition of smoke is not `" ++ SMOKE_GATE[4..] ++ "`");
    // the publish after a failed install test, and the smoke after a failed publish
    try expectRefused(ar, try editJob(ar, text, "publish", " && needs.test.result == 'success'", ""), "npm.yml: the condition of publish is not `" ++ PUBLISH_GATE[4..] ++ "`");
    try expectRefused(ar, try editJob(ar, text, "smoke", " && needs.publish.result == 'success'", ""), "npm.yml: the condition of smoke is not `" ++ SMOKE_GATE[4..] ++ "`");
    // the publish waiting on the macOS job to pass: a failed Mac would stop the Linux packages too
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_GATE ++ "\n", PUBLISH_GATE[0 .. PUBLISH_GATE.len - 3] ++ " && needs.build-macos-arm64.result == 'success' }}\n"), "npm.yml: the condition of publish is not `" ++ PUBLISH_GATE[4..] ++ "`");
    // a gate that is always true, and a second condition line
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_GATE ++ "\n", PUSH_GATE ++ " && (needs.build.outputs.publish == 'true' || true)\n"), "npm.yml: the condition of publish is not `" ++ PUBLISH_GATE[4..] ++ "`");
    try expectRefused(ar, try editJob(ar, text, "publish", "    environment: npm\n", "    environment: npm\n    if: always()\n"), "npm.yml: the condition of publish is not `" ++ PUBLISH_GATE[4..] ++ "`");
    // the build and the test run on every push
    try expectRefused(ar, try editJob(ar, text, "test", PUSH_GATE ++ "\n", PUBLISH_GATE ++ "\n"), "npm.yml: the condition of test is not `" ++ PUSH_GATE[4..] ++ "`");
    // the publish without the install test, the smoke before the publish
    try expectRefused(ar, try editJob(ar, text, "publish", "    needs: [build, test, build-macos-arm64]\n", "    needs: [build, build-macos-arm64]\n"), "npm.yml: publish does not have `needs: [build, test, build-macos-arm64]`");
    try expectRefused(ar, try editJob(ar, text, "smoke", "    needs: [build, publish]\n", "    needs: [build, test]\n"), "npm.yml: smoke does not have `needs: [build, publish]`");
    // the publish not waiting for the macOS job, whose result chooses the set
    try expectRefused(ar, try editJob(ar, text, "publish", "    needs: [build, test, build-macos-arm64]\n", "    needs: [build, test]\n"), "npm.yml: publish does not have `needs: [build, test, build-macos-arm64]`");
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "    needs: build\n", ""), "npm.yml: build-macos-arm64 does not have `needs: build`");
    try expectRefused(ar, try editJob(ar, text, "build", RUNNER ++ "\n", RUNNER ++ "\n    needs: test\n"), "npm.yml: build needs another job");
}

test "the publish gate is the committed file, read by the step gate whose output the build job hands on" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    try expectRefused(ar, try edit(ar, text, GATE_OUTPUT ++ "\n", "      publish: 'true'\n"), "npm.yml: the output publish of build is not the gate step's (steps.gate.outputs.publish)");
    try expectRefused(ar, try edit(ar, text, "--file release/npm_publish.txt", "--file release/npm_names.txt"), "npm.yml: build does not read release/npm_publish.txt with npm_smoke gate once");
    try expectRefused(ar, try edit(ar, text, GATE_ID ++ "\n", "        id: gate_file\n"), "npm.yml: the step that reads release/npm_publish.txt is not the step gate");
    try expectRefused(ar, try edit(ar, text, "        id: stamp\n", "        id: gate\n"), "npm.yml: build has a second step gate");
}

test "each job's environment and permissions are exact: npm and id-token for the publish, the farm's for build and test, nothing for the smoke" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    try expectRefused(ar, try editJob(ar, text, "publish", "    environment: npm\n", "    environment: build\n"), "npm.yml: publish does not run in the environment npm");
    try expectRefused(ar, try editJob(ar, text, "build", "    environment: build\n", "    environment: npm\n"), "npm.yml: build does not run in the environment build");
    try expectRefused(ar, try editJob(ar, text, "test", "    environment: build\n", ""), "npm.yml: test does not run in the environment build");
    try expectRefused(ar, try editJob(ar, text, "smoke", "    permissions: {}\n", "    environment: npm\n    permissions: {}\n"), "npm.yml: smoke runs in an environment: it holds no identity");
    try expectRefused(ar, try editJob(ar, text, "smoke", "    permissions: {}\n", "    permissions:\n      id-token: write\n"), "npm.yml: the permissions of smoke are not exactly {}");
    try expectRefused(ar, try editJob(ar, text, "publish", "      contents: read\n", "      contents: write\n"), "npm.yml: the permissions of publish are not exactly contents: read and id-token: write");
    try expectRefused(ar, try editJob(ar, text, "test", "      id-token: write\n", "      id-token: write\n      packages: write\n"), "npm.yml: the permissions of test are not exactly contents: read and id-token: write");
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "    environment: build\n", "    environment: npm\n"), "npm.yml: build-macos-arm64 does not run in the environment build");
}

test "the publish takes the set with the macOS package exactly when build-macos-arm64 succeeded, and the smoke reads its choice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    // always the set with the macOS package: a failed macOS job would leave the publish nothing to take,
    // and a main package naming a package whose install test failed
    const refused = "npm.yml: publish does not take the set with the macOS package exactly when build-macos-arm64 succeeded, and the set without it otherwise, and hand that choice on as its output set";
    try expectRefused(ar, try editJob(ar, text, "publish", SET_CHOICE ++ "\n", "          name: npm-set-macos-arm64-${{ github.sha }}\n"), refused);
    // the set with it unless the macOS job failed: a cancelled or skipped one would still choose it
    const not_failed = "          name: ${{ needs.build-macos-arm64.result != 'failure' && format('npm-set-macos-arm64-{0}', github.sha) || format('npm-set-{0}', github.sha) }}\n";
    try expectRefused(ar, try editJob(ar, text, "publish", SET_CHOICE ++ "\n", not_failed), refused);
    // the choice not handed on, or another choice handed on than the one the publish took
    try expectRefused(ar, try editJob(ar, text, "publish", SET_OUTPUT ++ "\n", ""), refused);
    try expectRefused(ar, try editJob(ar, text, "publish", SET_OUTPUT ++ "\n", "      set: npm-set-${{ github.sha }}\n"), refused);
    // the smoke always on the set without it, or choosing again from the macOS job's result, which a re-run
    // of failed jobs can change after the publish: it would hold the registry to another set than the publish's
    const smoke_refused = "npm.yml: smoke does not download the set the publish took (needs.publish.outputs.set)";
    try expectRefused(ar, try editJob(ar, text, "smoke", SMOKE_SET ++ "\n", "          name: npm-set-${{ github.sha }}\n"), smoke_refused);
    try expectRefused(ar, try editJob(ar, text, "smoke", SMOKE_SET ++ "\n", SET_CHOICE ++ "\n"), smoke_refused);
    // a second keeper of the set with the macOS package
    const keep = "      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1\n        with:\n" ++ MAC_KEEP ++ "\n          path: x\n      - name: Stop buck2\n";
    try expectRefused(ar, try editJob(ar, text, "test", "      - name: Stop buck2\n", keep), "npm.yml: test names the set with the macOS package other than as its keeper (build-macos-arm64) or the publish's choice");
}

test "the macOS job keeps its set only after its install test passed on the farm's macOS workers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    // the install test left out, or another target in its place
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, " //node:install_test_macos_arm64\n", " //node:package_macos_arm64\n"), "npm.yml: build-macos-arm64 does not run the macOS install test (//node:install_test_macos_arm64) on the farm's macOS workers");
    // built for the Linux platform: the install test would not run on a Mac
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "args: build --target-platforms komira//tools/build/platforms:darwin-arm64 -c", "args: build -c"), "npm.yml: build-macos-arm64 does not run the macOS install test (//node:install_test_macos_arm64) on the farm's macOS workers");
    // the set from another stamp, and no set kept
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "-c komira.package_stamp=${{ needs.build.outputs.build_number }} -c komira.package_commit=${{ needs.build.outputs.source_commit }} -c komira.package_timestamp_ms=${{ needs.build.outputs.timestamp_ms }} //release:npm_packages_macos_arm64", "//release:npm_packages_macos_arm64"), "npm.yml: build-macos-arm64 does not build //release:npm_packages_macos_arm64 from the build job's stamp");
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, MAC_KEEP ++ "\n", "          name: npm-macos-${{ github.sha }}\n"), "npm.yml: build-macos-arm64 does not keep the set with the macOS package");
    // the set built and kept before the install test ran
    const job = try jobText(text, MACOS_JOB);
    const test_at = std.mem.indexOf(u8, job, "      - name: the install test of the macOS package").?;
    const set_at = std.mem.indexOf(u8, job, "      - name: build the npm packages with the macOS package").?;
    const stop_at = std.mem.indexOf(u8, job, STOP_STEP ++ "\n").?;
    // the install test's step (and the comment above the set's build) moved to just before Stop buck2
    const test_step = job[test_at..set_at];
    const moved = try std.mem.concat(ar, u8, &.{ job[0..test_at], job[set_at..stop_at], test_step, job[stop_at..] });
    try expectRefused(ar, try std.mem.replaceOwned(u8, ar, text, job, moved), "npm.yml: build-macos-arm64 keeps the set with the macOS package before its install test passed: the install test, the set's build and the artifact are in that order");
    // a failed install test passed over, or the install test skipped
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "      - name: the install test of the macOS package on each pinned Node.js, on the farm's macOS workers\n", "      - name: the install test of the macOS package on each pinned Node.js, on the farm's macOS workers\n        continue-on-error: true\n"), "npm.yml: build-macos-arm64 has continue-on-error: a failed install test would leave the job green and the set kept");
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "      - name: the install test of the macOS package on each pinned Node.js, on the farm's macOS workers\n", "      - name: the install test of the macOS package on each pinned Node.js, on the farm's macOS workers\n        if: false\n"), "npm.yml: a step of build-macos-arm64 has a condition: only Stop buck2 runs always(), and no step of the install test or the set is skipped");
    try expectRefused(ar, try editJob(ar, text, MACOS_JOB, "      - name: build the npm packages with the macOS package\n", "      - name: build the npm packages with the macOS package\n        if: always()\n"), "npm.yml: a step of build-macos-arm64 has a condition: only Stop buck2 runs always(), and no step of the install test or the set is skipped");
}

test "only the publish job publishes, and it and the smoke have no checkout, no farm and no build" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    const step = "      - name: publish early\n" ++ PUBLISH_RUN ++ "\n";
    try expectRefused(ar, try editJob(ar, text, "test", "      - name: Stop buck2\n", step ++ "      - name: Stop buck2\n"), "npm.yml: test runs npm_smoke publish: only the job publish publishes");
    try expectRefused(ar, try editJob(ar, text, "build", "      - name: Stop buck2\n", step ++ "      - name: Stop buck2\n"), "npm.yml: build runs npm_smoke publish: only the job publish publishes");
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_RUN ++ "\n", "        run: npm publish --access public\n"), "npm.yml: publish does not run npm_smoke publish on the set the build kept");
    try expectRefused(ar, try editJob(ar, text, "publish", "    steps:\n", "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n"), "npm.yml: publish names actions/checkout: it has no checkout, no farm and no build");
    try expectRefused(ar, try editJob(ar, text, "smoke", "    steps:\n", "    steps:\n      - uses: ./.github/actions/farm-connect\n"), "npm.yml: smoke names farm-connect: it has no checkout, no farm and no build");
    try expectRefused(ar, try editJob(ar, text, "publish", "    steps:\n", "    steps:\n      - run: ./buck2 build //release:npm_packages\n"), "npm.yml: publish names buck2: it has no checkout, no farm and no build");
    try expectRefused(ar, try editJob(ar, text, "smoke", "npm_smoke\" smoke", "npm_smoke\" verify"), "npm.yml: smoke does not run npm_smoke smoke");
}

test "no token and no secret: a line outside a comment that names one is refused, and a comment may" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try read(ar);
    // a token from a variable, or from a secret, in the publish's environment
    const env = "        env:\n          NODE_AUTH_TOKEN: ${{ vars.TOKEN }}\n" ++ PUBLISH_RUN ++ "\n";
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_RUN ++ "\n", env), try bannedAt(ar, lineStarting(text, PUBLISH_RUN) + 1, "NODE_AUTH_TOKEN"));
    const secret = "        env:\n          TOKEN: ${{ secrets.NPM_TOKEN }}\n" ++ PUBLISH_RUN ++ "\n";
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_RUN ++ "\n", secret), try bannedAt(ar, lineStarting(text, PUBLISH_RUN) + 1, "NPM_TOKEN"));
    try expectRefused(ar, try editJob(ar, text, "smoke", "    permissions: {}\n", "    permissions: {}\n    env:\n      GH: ${{ secrets.GITHUB_TOKEN }}\n"), try bannedAt(ar, lineStarting(text, "  smoke:") + 7, "secrets"));
    // a token written into an npmrc
    try expectRefused(ar, try editJob(ar, text, "publish", PUBLISH_RUN ++ "\n", "        run: echo \"//registry.npmjs.org/:_authToken=x\" > .npmrc\n" ++ PUBLISH_RUN ++ "\n"), try bannedAt(ar, lineStarting(text, PUBLISH_RUN), "_authToken"));
    // the header says there is no NPM_TOKEN: a comment is not a use
    try t.expect(std.mem.indexOf(u8, text, "No NPM_TOKEN exists") != null);
}

/// The number of the first line of `text` that is exactly `line`.
fn lineStarting(text: []const u8, line: []const u8) usize {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        n += 1;
        if (std.mem.eql(u8, l, line)) return n;
    }
    unreachable;
}

/// The refusal of a line `n` that names `word`.
fn bannedAt(ar: std.mem.Allocator, n: usize, word: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, "npm.yml:{d} names {s}: the workflow runs on a push to main alone, on a hosted runner, and holds no token or secret", .{ n, word });
}

/// The refusal of a line naming `word` written where the line `at` of the real text was.
fn banned(ar: std.mem.Allocator, text: []const u8, at: []const u8, word: []const u8) ![]const u8 {
    return bannedAt(ar, lineStarting(text, at), word);
}
