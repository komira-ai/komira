//! The jobs that publish the staged set S to one registry as one group, and the beta publish, for
//! //:release_workflow_cases (release_workflow_test.zig imports this file and runs its tests).
//!
//! Every push to main publishes S to the registry `beta` and then to the registry `prod`, each in the
//! same three steps the registry keeps apart: stage (`--no-commit`: every file held in quarantine,
//! nothing visible), test (the bytes the registry holds, checked against the plan and tried by the
//! README e2e), commit; and an abort that ends the open group when one of them failed or the run was
//! cancelled. `checkGroup` holds those four jobs of one registry (`<registry>-stage`, `-test`,
//! `-commit`, `-abort`), for beta and for prod alike. What the cases of the beta publish catch:
//!  - each beta job is there once with exactly its `needs` (`beta-stage` needs `release` and
//!    `mopm-stage`; then the chain; the abort needs all three), its gate (a push to main; the abort's
//!    `failure() || cancelled()` with `needs.beta-stage.result != 'skipped'`), its environment
//!    (`beta` for the three that talk to the registry, `build` for the test) and its permissions
//!    (`contents: read`, and `id-token: write` for the OIDC exchange or farm-connect), ignoring no
//!    failure;
//!  - the commands: the stage with `--registry beta --oidc --no-commit` on the set `mopm-stage` kept,
//!    its directory kept as `mopm-beta-staged-<sha>` even when the stage failed; the test verifying
//!    that directory against the plan and running the e2e on what matched, with no identity; the
//!    commit with `--oidc` and neither `--no-commit` nor `--abort`; the abort with `--abort`;
//!  - the registry: a line of a beta job names `--registry beta` only, a line of any other job names
//!    `--registry prod` only, only the beta stage, commit and abort hold the environment `beta`, and
//!    no job of one registry downloads the other's directory (its `state.json` names the other's group);
//!  - beta before prod: `prod-stage` needs `beta-commit` (release_workflow_test.zig's checkProd).
//! Each defect is written into the real release.yml and must be refused with its message.

const std = @import("std");
const t = std.testing;
const wf = @import("release_workflow_test.zig");

/// The exact lines of one registry's stage, test, commit and abort jobs.
pub const Group = struct {
    /// The registry's name, which is also the prefix of its jobs' names (`beta-stage`, ...).
    registry: []const u8,
    /// The stage's `run:` line: `mopm publish --staged S --registry <r> --oidc --no-commit`.
    stage_run: []const u8,
    /// The `name:` line of the artifact the stage keeps (the directory with `state.json`).
    staged_artifact: []const u8,
    /// The test's build of release_staged_verify.
    build_verify: []const u8,
    /// The test's `release_staged_verify verify --out release/staged_set` line.
    verify_run: []const u8,
    /// The test's README e2e on the verified files.
    e2e_run: []const u8,
    /// The commit's `run:` line.
    commit_run: []const u8,
    /// The abort's command line.
    abort_cmd: []const u8,
};

/// A message about the jobs of the registry `r`: every `{[r]s}` of `fmt` is the registry's name.
fn say(ar: std.mem.Allocator, comptime fmt: []const u8, r: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, fmt, .{ .r = r });
}

fn count(lines: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) {
        n += 1;
    };
    return n;
}

/// Null if the stage, test, commit and abort jobs of `g.registry` hold their commands and their order,
/// else the refusal. The needs, gates, environments and permissions are `wf.checkJobs`'.
pub fn checkGroup(ar: std.mem.Allocator, text: []const u8, g: Group) !?[]const u8 {
    const r = g.registry;
    var scratch: usize = 0;

    const stage = (try wf.jobLines(ar, text, try say(ar, "{[r]s}-stage", r), &scratch)) orelse return try say(ar, "no job {[r]s}-stage", r);
    if (wf.mentions(stage, "farm") or wf.mentions(stage, "buck2")) return try say(ar, "{[r]s}-stage joins the farm or runs buck2", r);
    const stage_at = wf.lineAt(stage, g.stage_run) orelse return try say(ar, "{[r]s}-stage does not run publish --staged --registry {[r]s} --oidc --no-commit", r);
    if (wf.mentions(stage, "--dry-run") or wf.mentions(stage, "--abort")) return try say(ar, "{[r]s}-stage publishes with --dry-run or --abort", r);
    if (count(stage, "mopm\" publish") != 1) return try say(ar, "{[r]s}-stage runs mopm publish more than once", r);
    // the directory is kept even when the step failed, so the abort job can end a group
    const keep_at = wf.lineAt(stage, g.staged_artifact) orelse return try say(ar, "{[r]s}-stage does not keep the staged directory (mopm-{[r]s}-staged)", r);
    if (!(stage_at < keep_at)) return try say(ar, "{[r]s}-stage keeps the directory before it stages", r);
    if (keep_at < 3 or !std.mem.eql(u8, stage[keep_at - 3], "      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1") or !std.mem.eql(u8, stage[keep_at - 2], "        if: always()"))
        return try say(ar, "{[r]s}-stage keeps the directory only when the stage succeeded (the artifact step needs if: always())", r);

    const tst = (try wf.jobLines(ar, text, try say(ar, "{[r]s}-test", r), &scratch)) orelse return try say(ar, "no job {[r]s}-test", r);
    const test_needs = try say(ar, "    needs: {[r]s}-stage", r);
    for (tst) |l| {
        if (std.mem.eql(u8, l, test_needs) or std.mem.eql(u8, l, wf.PROD_GATE)) continue;
        for (wf.prod_readonly_forbidden) |word| {
            if (std.ascii.indexOfIgnoreCase(l, word) != null) return try say(ar, "{[r]s}-test publishes, yanks, logs in or exchanges an identity", r);
        }
    }
    // the files under test are the ones the stage kept, never the set mopm-stage made
    if (wf.mentions(tst, "mopm-staged-")) return try say(ar, "{[r]s}-test takes the set of mopm-stage, not the one {[r]s}-stage uploaded", r);
    const download_at = wf.lineAt(tst, g.staged_artifact) orelse return try say(ar, "{[r]s}-test does not download the set {[r]s}-stage uploaded", r);
    const connect_at = wf.lineAt(tst, wf.E2E_FARM_CONNECT) orelse return try say(ar, "{[r]s}-test does not join the farm", r);
    const tool_at = wf.lineAt(tst, g.build_verify) orelse return try say(ar, "{[r]s}-test does not build release_staged_verify", r);
    const verify_at = wf.lineAt(tst, g.verify_run) orelse return try say(ar, "{[r]s}-test does not verify the staged files against the plan (release_staged_verify verify --out release/staged_set)", r);
    const e2e_at = wf.lineAt(tst, g.e2e_run) orelse return try say(ar, "{[r]s}-test does not run the e2e on the verified set (staged=stage at this run's version)", r);
    if (!(connect_at < tool_at and tool_at < verify_at)) return try say(ar, "{[r]s}-test verifies before the farm is joined and the tool built", r);
    if (!(download_at < verify_at)) return try say(ar, "{[r]s}-test verifies before it has the files", r);
    if (!(verify_at < e2e_at)) return try say(ar, "{[r]s}-test runs the e2e before the verification", r);
    // nothing else may write the directory the e2e reads
    if (count(tst, "staged_set") != 1) return try say(ar, "{[r]s}-test names release/staged_set other than in the one verify step", r);
    var verify_runs: usize = 0;
    for (tst) |l| if (std.mem.indexOf(u8, l, "release_staged_verify\"") != null and std.mem.startsWith(u8, l, "        run:")) {
        verify_runs += 1;
    };
    if (verify_runs != 1) return try say(ar, "{[r]s}-test runs release_staged_verify more than once", r);
    var asserted: usize = 0;
    for (tst) |l| if (std.mem.eql(u8, l, wf.E2E_ASSERT)) {
        asserted += 1;
    };
    if (asserted != 2) return try say(ar, "{[r]s}-test has a farm step that is not asserted remote", r);

    const commit = (try wf.jobLines(ar, text, try say(ar, "{[r]s}-commit", r), &scratch)) orelse return try say(ar, "no job {[r]s}-commit", r);
    if (wf.mentions(commit, "farm") or wf.mentions(commit, "buck2")) return try say(ar, "{[r]s}-commit joins the farm or runs buck2", r);
    const commit_at = wf.lineAt(commit, g.commit_run) orelse return try say(ar, "{[r]s}-commit does not run publish --staged --registry {[r]s} --oidc on the directory {[r]s}-stage kept", r);
    if (wf.mentions(commit, "--no-commit") or wf.mentions(commit, "--abort") or wf.mentions(commit, "--dry-run")) return try say(ar, "{[r]s}-commit does not commit: it names --no-commit, --abort or --dry-run", r);
    const commit_dl = wf.lineAt(commit, g.staged_artifact) orelse return try say(ar, "{[r]s}-commit does not download the directory {[r]s}-stage kept (with its state.json)", r);
    if (!(commit_dl < commit_at)) return try say(ar, "{[r]s}-commit publishes before it has the directory", r);
    if (count(commit, "mopm\" publish") != 1) return try say(ar, "{[r]s}-commit runs mopm publish more than once", r);

    const abort = (try wf.jobLines(ar, text, try say(ar, "{[r]s}-abort", r), &scratch)) orelse return try say(ar, "no job {[r]s}-abort", r);
    if (wf.mentions(abort, "farm") or wf.mentions(abort, "buck2")) return try say(ar, "{[r]s}-abort joins the farm or runs buck2", r);
    // each step is one command: whether there is a group to end is the step's if:, never shell logic
    if (wf.mentions(abort, "run: |")) return try say(ar, "{[r]s}-abort runs shell logic in a run: block: each step is one command, and the step's if: says whether there is a group to end", r);
    if (!wf.has(abort, g.abort_cmd)) return try say(ar, "{[r]s}-abort does not run publish --staged --registry {[r]s} --oidc --abort", r);
    if (wf.mentions(abort, "--no-commit") or wf.mentions(abort, "--dry-run") or wf.mentions(abort, "yank")) return try say(ar, "{[r]s}-abort stages, dry-runs or yanks", r);
    const abort_dl = wf.lineAt(abort, g.staged_artifact) orelse return try say(ar, "{[r]s}-abort does not download the directory {[r]s}-stage kept (the state.json names the group)", r);
    // hashFiles reads the workspace only, so the directory whose state.json it asks about is there
    if (abort_dl + 1 >= abort.len or !std.mem.eql(u8, abort[abort_dl + 1], try say(ar, "          path: ${{{{ github.workspace }}}}/mopm-{[r]s}/staged", r)))
        return try say(ar, "{[r]s}-abort does not download the directory to ${{{{ github.workspace }}}}/mopm-{[r]s}/staged: hashFiles in a step's if: reads the workspace only", r);
    if (count(abort, "mopm\" publish") != 1) return try say(ar, "{[r]s}-abort runs mopm publish more than once", r);
    // the abort runs exactly when there is a state.json (a group to end); without one, a step says so
    const cmd_at = wf.lineAt(abort, g.abort_cmd).?;
    if (cmd_at == 0 or !std.mem.eql(u8, abort[cmd_at - 1], try say(ar, "        if: hashFiles('mopm-{[r]s}/staged/state.json') != ''", r)))
        return try say(ar, "{[r]s}-abort does not end the group only when state.json is there (its step's if: hashFiles('mopm-{[r]s}/staged/state.json') != '')", r);
    if (!wf.has(abort, try say(ar, "        if: hashFiles('mopm-{[r]s}/staged/state.json') == ''", r)))
        return try say(ar, "{[r]s}-abort has no step for a directory without state.json (if: hashFiles('mopm-{[r]s}/staged/state.json') == '')", r);
    return null;
}

const BETA_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta --oidc --no-commit'";
const BETA_STAGED_ARTIFACT = "          name: mopm-beta-staged-${{ github.sha }}";
const BETA_BUILD_VERIFY = "          args: build //tools/build/ci:release_staged_verify --out ${{ runner.temp }}/beta-test/release_staged_verify";
const BETA_VERIFY_RUN = "        run: '\"$RUNNER_TEMP/beta-test/release_staged_verify\" verify --staged \"$RUNNER_TEMP/beta-test/staged\" --out release/staged_set'";
const BETA_COMMIT_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-beta/staged\" --registry beta --oidc'";
const BETA_ABORT_CMD = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$GITHUB_WORKSPACE/mopm-beta/staged\" --registry beta --oidc --abort'";
const BETA_ABORT_IF = "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.beta-stage.result != 'skipped'";

const BETA_GROUP = Group{
    .registry = "beta",
    .stage_run = BETA_STAGE_RUN,
    .staged_artifact = BETA_STAGED_ARTIFACT,
    .build_verify = BETA_BUILD_VERIFY,
    .verify_run = BETA_VERIFY_RUN,
    // the same e2e line as prod-test's and mopm-stage's: the same set, at the version of this run
    .e2e_run = wf.PROD_E2E_RUN,
    .commit_run = BETA_COMMIT_RUN,
    .abort_cmd = BETA_ABORT_CMD,
};

const beta_jobs = [_]wf.JobSpec{
    .{ .name = "beta-stage", .needs = "    needs: [release, mopm-stage]", .gate = wf.PROD_GATE, .environment = "    environment: beta", .id_token = true },
    .{ .name = "beta-test", .needs = "    needs: beta-stage", .gate = wf.PROD_GATE, .environment = "    environment: build", .id_token = true },
    .{ .name = "beta-commit", .needs = "    needs: beta-test", .gate = wf.PROD_GATE, .environment = "    environment: beta", .id_token = true },
    .{ .name = "beta-abort", .needs = "    needs: [beta-stage, beta-test, beta-commit]", .gate = BETA_ABORT_IF, .environment = "    environment: beta", .id_token = true },
};

/// Whether `rest`, the text right after `--registry `, starts with the whole word `want` (a letter,
/// digit, `-` or `_` after it makes another name).
fn namesRegistry(rest: []const u8, want: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, want)) return false;
    if (rest.len == want.len) return true;
    const next = rest[want.len];
    return !(std.ascii.isAlphanumeric(next) or next == '-' or next == '_');
}

/// Null if every job names only its own registry and holds only its own registry's environment and
/// artifacts, else the refusal. A job whose name starts with `beta-` is a beta job; every other job
/// (`release`, `mopm-stage`, the prod jobs) is prod's: `mopm stage` plans S against prod.
fn checkRegistries(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var job: []const u8 = "";
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
            job = trimmed[0 .. trimmed.len - 1];
            continue;
        }
        const beta = std.mem.startsWith(u8, job, "beta-");
        const own = if (beta) "beta" else "prod";
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, "--registry ")) |at| {
            from = at + "--registry ".len;
            if (!namesRegistry(line[from..], own))
                return try std.fmt.allocPrint(ar, "{s} names a registry other than {s}: {s}", .{ job, own, if (beta) "a beta job publishes to beta only" else "only the beta jobs name the registry beta" });
        }
        if (!beta and std.mem.eql(u8, line, "    environment: beta"))
            return try std.fmt.allocPrint(ar, "{s} holds the environment beta: only beta-stage, beta-commit and beta-abort do", .{job});
        const other = if (beta) "mopm-prod-" else "mopm-beta-";
        if (std.mem.indexOf(u8, line, other) != null)
            return try std.fmt.allocPrint(ar, "{s} takes an artifact of the other registry ({s}...): its state.json names that registry's group", .{ job, other });
    }
    return null;
}

/// Null if the beta publish holds its contract, else the refusal.
pub fn checkBeta(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (try wf.checkJobs(ar, text, &beta_jobs)) |why| return why;
    if (try checkRegistries(ar, text)) |why| return why;
    return checkGroup(ar, text, BETA_GROUP);
}

test "release.yml holds the contract of the beta publish" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    if (try checkBeta(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "a beta job that is missing, twice, or under another gate, needs, environment or permissions is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    const nl = "\n";
    const runs = "    runs-on: ubuntu-24.04\n";
    const stage_head = "  beta-stage:\n    needs: [release, mopm-stage]\n" ++ wf.PROD_GATE ++ nl ++ runs ++ "    environment: beta\n";
    const test_head = "  beta-test:\n    needs: beta-stage\n" ++ wf.PROD_GATE ++ nl ++ runs ++ "    environment: build\n";
    const commit_head = "  beta-commit:\n    needs: beta-test\n" ++ wf.PROD_GATE ++ nl ++ runs ++ "    environment: beta\n";
    const abort_head = "  beta-abort:\n    needs: [beta-stage, beta-test, beta-commit]\n" ++ BETA_ABORT_IF ++ nl ++ runs ++ "    environment: beta\n";

    // each job is there, once
    inline for (.{ "beta-stage", "beta-test", "beta-commit", "beta-abort" }) |name| {
        try wf.expectRefused(ar, try wf.replaced(ar, text, "  " ++ name ++ ":\n", "  " ++ name ++ "-old:\n"), "no job " ++ name);
        try wf.expectRefused(ar, try wf.replaced(ar, text, "  prod-stage:\n", "  " ++ name ++ ":\n    runs-on: ubuntu-24.04\n\n  prod-stage:\n"), name ++ " is defined more than once");
    }
    // the gate of each: a push to main and nothing else
    for ([_][]const u8{ stage_head, test_head, commit_head }) |head| {
        const wrong = [_][]const u8{
            "    if: github.event_name == 'push'\n",
            "    if: github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'push' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'\n",
            "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.X == 'true'\n",
            "    if: always()\n",
            "",
        };
        for (wrong) |w| try wf.expectRefused(ar, try wf.replaced(ar, text, head, try wf.swapGate(ar, head, w)), "the if is not the expected gate");
    }
    // the abort: a failure or a cancel, the gate, and a stage that ran
    const abort_wrong = [_][]const u8{
        "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.beta-stage.result != 'skipped'\n",
        "    if: failure() && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.beta-stage.result != 'skipped'\n",
        "    if: (failure() || cancelled()) && needs.beta-stage.result != 'skipped'\n",
        "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main'\n",
        "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n",
    };
    for (abort_wrong) |w| try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_IF ++ nl, w), "beta-abort: the if is not the expected gate");
    // the needs: the set mopm-stage tried after the release build, then the chain, and the abort sees all three
    const stage_needs = "  beta-stage:\n    needs: [release, mopm-stage]\n";
    for ([_][]const u8{ "  beta-stage:\n    needs: mopm-stage\n", "  beta-stage:\n    needs: [release]\n", "  beta-stage:\n" }) |w|
        try wf.expectRefused(ar, try wf.replaced(ar, text, stage_needs, w), "beta-stage: needs is not exactly `needs: [release, mopm-stage]`");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "  beta-test:\n    needs: beta-stage\n", "  beta-test:\n    needs: [beta-stage, release]\n"), "beta-test: needs");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "  beta-commit:\n    needs: beta-test\n", "  beta-commit:\n    needs: beta-stage\n"), "beta-commit: needs");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "    needs: [beta-stage, beta-test, beta-commit]\n", "    needs: [beta-stage, beta-commit]\n"), "beta-abort: needs");
    // the environments: beta for the three that talk to the registry, build for the test
    try wf.expectRefused(ar, try wf.replaced(ar, text, stage_head, stage_head[0 .. stage_head.len - "    environment: beta\n".len] ++ "    environment: prod\n"), "beta-stage: environment is not `environment: beta`");
    try wf.expectRefused(ar, try wf.replaced(ar, text, commit_head, commit_head[0 .. commit_head.len - "    environment: beta\n".len]), "beta-commit: environment is not `environment: beta`");
    try wf.expectRefused(ar, try wf.replaced(ar, text, abort_head, abort_head[0 .. abort_head.len - "    environment: beta\n".len] ++ "    environment: build\n"), "beta-abort: environment is not `environment: beta`");
    try wf.expectRefused(ar, try wf.replaced(ar, text, test_head, test_head[0 .. test_head.len - "    environment: build\n".len] ++ "    environment: beta\n"), "beta-test: environment is not `environment: build`");
    // the permissions: id-token for the exchange (or farm-connect), nothing more
    const stage_perms = stage_head ++ "    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n";
    try wf.expectRefused(ar, try wf.replaced(ar, text, stage_perms, stage_head ++ "    timeout-minutes: 30\n    permissions:\n      contents: read\n"), "beta-stage: id-token: write is missing");
    try wf.expectRefused(ar, try wf.replaced(ar, text, stage_perms, stage_perms ++ "      packages: write\n"), "beta-stage: permissions hold more than they should");
    const commit_perms = commit_head ++ "    timeout-minutes: 60\n    permissions:\n      contents: read\n";
    try wf.expectRefused(ar, try wf.replaced(ar, text, commit_perms, commit_head ++ "    timeout-minutes: 60\n    permissions:\n      contents: write\n"), "beta-commit: permissions are not contents: read");
}

test "a beta job on the wrong registry, environment or artifact, and a prod job on beta's, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    // a beta job that publishes to prod, or to a registry whose name only starts with beta
    const beta_wrong = "a beta job publishes to beta only";
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry prod --oidc --no-commit'"), "beta-stage names a registry other than beta: " ++ beta_wrong);
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta2 --oidc --no-commit'"), "beta-stage names a registry other than beta: " ++ beta_wrong);
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta-old --oidc --no-commit'"), "beta-stage names a registry other than beta: " ++ beta_wrong);
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-beta/staged\" --registry prod --oidc'"), "beta-commit names a registry other than beta: " ++ beta_wrong);
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_CMD, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$GITHUB_WORKSPACE/mopm-beta/staged\" --registry prod --oidc --abort'"), "beta-abort names a registry other than beta: " ++ beta_wrong);
    // a second registry on a line that also names beta
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, BETA_COMMIT_RUN[0 .. BETA_COMMIT_RUN.len - 1] ++ " --registry prod'"), "beta-commit names a registry other than beta: " ++ beta_wrong);
    // a line of the beta test that reads prod
    const verify_step = "      - name: check the files beta holds against the plan\n" ++ BETA_VERIFY_RUN ++ "\n";
    try wf.expectRefused(ar, try wf.replaced(ar, text, verify_step, verify_step ++ "      - run: mopm search json --registry prod\n"), "beta-test names a registry other than beta: " ++ beta_wrong);
    // a job other than the beta jobs on the registry beta: mopm-stage's dry-run, the smoke of prod
    const prod_wrong = "only the beta jobs name the registry beta";
    try wf.expectRefused(ar, try wf.replaced(ar, text, "release/staged_set --registry prod --dry-run'", "release/staged_set --registry beta --dry-run'"), "mopm-stage names a registry other than prod: " ++ prod_wrong);
    try wf.expectRefused(ar, try wf.replaced(ar, text, "      - name: the prod channel serves the published files\n", "      - run: mopm search json --registry beta\n      - name: the prod channel serves the published files\n"), "prod-smoke names a registry other than prod: " ++ prod_wrong);
    // the environment beta outside the beta stage, commit and abort
    try wf.expectRefused(ar, try wf.replaced(ar, text, "  mopm-stage:\n    runs-on: ubuntu-24.04\n    environment: build\n", "  mopm-stage:\n    runs-on: ubuntu-24.04\n    environment: beta\n"), "mopm-stage holds the environment beta: only beta-stage, beta-commit and beta-abort do");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "  release:\n    runs-on: ubuntu-24.04\n    environment: build\n", "  release:\n    runs-on: ubuntu-24.04\n    environment: beta\n"), "release holds the environment beta: only beta-stage, beta-commit and beta-abort do");
    // the other registry's directory: its state.json names the other registry's group
    try wf.expectRefused(ar, try wf.replaced(ar, text, "          name: mopm-prod-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n", "          name: mopm-beta-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n"), "prod-commit does not download the directory prod-stage kept");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "      - name: mopm publish --staged --oidc\n", "      - run: ls mopm-beta-staged-x\n      - name: mopm publish --staged --oidc\n"), "prod-commit takes an artifact of the other registry (mopm-beta-...)");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "      - name: mopm publish --staged --registry beta --oidc\n", "      - run: ls mopm-prod-staged-x\n      - name: mopm publish --staged --registry beta --oidc\n"), "beta-commit takes an artifact of the other registry (mopm-prod-...)");
    // a comment may name either registry anywhere
    try t.expect((try wf.check(ar, try wf.replaced(ar, text, "  beta-test:\n", "  beta-test:\n    # --registry prod, environment: prod, mopm-prod-staged\n"))) == null);
}

test "each edit of a beta command that breaks the contract is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    const nl = "\n";
    // the stage: --oidc --no-commit, once, no farm, and the directory kept even on a failed step
    try wf.expectRefused(ar, try wf.replaced(ar, text, " --registry beta --oidc --no-commit'\n", " --registry beta --oidc'\n"), "beta-stage does not run publish --staged --registry beta --oidc --no-commit");
    try wf.expectRefused(ar, try wf.replaced(ar, text, " --registry beta --oidc --no-commit'\n", " --registry beta --no-commit'\n"), "beta-stage does not run publish --staged --registry beta --oidc --no-commit");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN ++ nl, BETA_STAGE_RUN ++ nl ++ "      - run: ./buck2 build //x\n"), "beta-stage joins the farm or runs buck2");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN ++ nl, BETA_STAGE_RUN ++ nl ++ "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry beta --oidc --no-commit\n"), "beta-stage runs mopm publish more than once");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_STAGE_RUN ++ nl, BETA_STAGE_RUN ++ " --dry-run" ++ nl), "beta-stage does not run publish");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "        if: always()\n        with:\n" ++ BETA_STAGED_ARTIFACT, "        with:\n" ++ BETA_STAGED_ARTIFACT), "beta-stage keeps the directory only when the stage succeeded");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "        if: always()\n        with:\n" ++ BETA_STAGED_ARTIFACT, "        if: success()\n        with:\n" ++ BETA_STAGED_ARTIFACT), "beta-stage keeps the directory only when the stage succeeded");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "        if: always()\n        with:\n" ++ BETA_STAGED_ARTIFACT, "        if: always()\n        with:\n          name: mopm-beta-kept-${{ github.sha }}"), "beta-stage does not keep the staged directory (mopm-beta-staged)");

    // the test: the files beta-stage kept, verified, then the e2e on what was verified; no identity
    const tst_download = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n" ++ BETA_STAGED_ARTIFACT ++ "\n          path: ${{ runner.temp }}/beta-test/staged\n";
    const tool_step = "      - name: build the staged-set verify tool\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ BETA_BUILD_VERIFY ++ nl ++ wf.E2E_ASSERT ++ nl;
    const verify_step = "      - name: check the files beta holds against the plan\n" ++ BETA_VERIFY_RUN ++ nl;
    const e2e_step = "      - name: the README e2e against the files beta holds\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ wf.PROD_E2E_RUN ++ nl ++ wf.E2E_ASSERT ++ nl;
    try wf.expectRefused(ar, try wf.replaced(ar, text, tst_download, ""), "beta-test does not download the set beta-stage uploaded");
    try wf.expectRefused(ar, try wf.replaced(ar, text, tst_download, "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/beta-test/staged\n"), "beta-test takes the set of mopm-stage, not the one beta-stage uploaded");
    try wf.expectRefused(ar, try wf.replaced(ar, try wf.replaced(ar, text, tst_download, ""), verify_step, verify_step ++ tst_download), "beta-test verifies before it has the files");
    try wf.expectRefused(ar, try wf.replaced(ar, text, verify_step, ""), "beta-test does not verify the staged files against the plan");
    try wf.expectRefused(ar, try wf.replaced(ar, text, tool_step ++ verify_step, verify_step ++ tool_step), "beta-test verifies before the farm is joined and the tool built");
    try wf.expectRefused(ar, try wf.replaced(ar, text, verify_step ++ e2e_step, e2e_step ++ verify_step), "beta-test runs the e2e before the verification");
    try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, ""), "beta-test does not run the e2e on the verified set");
    try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - name: the README e2e against the files beta holds\n        uses: ./.github/actions/buck2-farm\n        with:\n          args: build -c komira_release.staged=stage //release/readme_e2e/verify:all\n" ++ wf.E2E_ASSERT ++ nl), "beta-test does not run the e2e on the verified set");
    try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - name: the README e2e against the files beta holds\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ wf.PROD_E2E_RUN ++ nl), "beta-test has a farm step that is not asserted remote");
    try wf.expectRefused(ar, try wf.replaced(ar, text, verify_step, verify_step ++ "      - run: cp x release/staged_set/y\n"), "beta-test names release/staged_set other than in the one verify step");
    try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, e2e_step ++ "        continue-on-error: true\n"), "beta-test ignores a failure");
    const writers = [_][]const u8{ "mopm publish --staged x --registry beta", "mopm yank hashing 0.1.1", "mopm login --registry beta", "curl -X PUT https://x.test/y", "mopm-x --oidc" };
    inline for (writers) |cmd| try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - run: " ++ cmd ++ "\n" ++ e2e_step), "beta-test publishes, yanks, logs in or exchanges an identity");

    // the commit: the same command without --no-commit, on the directory beta-stage kept
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, BETA_COMMIT_RUN[0 .. BETA_COMMIT_RUN.len - 1] ++ " --no-commit'"), "beta-commit does not run publish --staged --registry beta --oidc");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-beta/staged\" --registry beta'"), "beta-commit does not run publish --staged --registry beta --oidc");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta --oidc'"), "beta-commit does not run publish --staged --registry beta --oidc");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, BETA_COMMIT_RUN ++ nl ++ "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry beta --oidc --abort"), "beta-commit does not commit: it names --no-commit, --abort or --dry-run");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_COMMIT_RUN, BETA_COMMIT_RUN ++ nl ++ "      - run: ./buck2 build //x"), "beta-commit joins the farm or runs buck2");
    try wf.expectRefused(ar, try wf.replaced(ar, text, "          name: mopm-beta-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-beta/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --registry beta --oidc\n", "          name: mopm-beta-nothing-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-beta/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --registry beta --oidc\n"), "beta-commit does not download the directory beta-stage kept (with its state.json)");

    // the abort: --abort, on the directory with the state, once, and nothing else
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_CMD, BETA_ABORT_CMD[0 .. BETA_ABORT_CMD.len - " --abort'".len] ++ "'"), "beta-abort does not run publish --staged --registry beta --oidc --abort");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_CMD, BETA_ABORT_CMD ++ "\n            mopm yank --group g --registry beta --reason x"), "beta-abort stages, dry-runs or yanks");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_CMD, BETA_ABORT_CMD ++ "\n      - run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry beta --oidc --abort'"), "beta-abort runs mopm publish more than once");
    try wf.expectRefused(ar, try wf.replaced(ar, text, BETA_ABORT_CMD, BETA_ABORT_CMD ++ " || true"), "beta-abort ignores a failure");
}

test "an abort that runs shell logic, ends a group without state.json, or keeps its directory outside the workspace is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    inline for (.{ .{ "beta", BETA_ABORT_CMD }, .{ "prod", wf.PROD_ABORT_CMD } }) |c| {
        const r = c[0];
        const cmd = c[1] ++ "\n";
        const if_state = "        if: hashFiles('mopm-" ++ r ++ "/staged/state.json') != ''\n";
        const if_none = "        if: hashFiles('mopm-" ++ r ++ "/staged/state.json') == ''\n";
        // the check in shell, as the abort steps were written before
        const shell = "        run: |\n          if [ -f \"$GITHUB_WORKSPACE/mopm-" ++ r ++ "/staged/state.json\" ]; then\n    " ++ cmd ++ "          fi\n";
        try wf.expectRefused(ar, try wf.replaced(ar, text, if_state ++ cmd, shell), r ++ "-abort runs shell logic in a run: block");
        // the abort with no condition, or asking about another file
        try wf.expectRefused(ar, try wf.replaced(ar, text, if_state ++ cmd, cmd), r ++ "-abort does not end the group only when state.json is there");
        try wf.expectRefused(ar, try wf.replaced(ar, text, if_state ++ cmd, "        if: hashFiles('mopm-" ++ r ++ "/staged/plan.json') != ''\n" ++ cmd), r ++ "-abort does not end the group only when state.json is there");
        // no step says that there was nothing to end
        try wf.expectRefused(ar, try wf.replaced(ar, text, if_none, ""), r ++ "-abort has no step for a directory without state.json");
        // the directory where hashFiles cannot see it
        try wf.expectRefused(ar, try wf.replaced(ar, text, "          path: ${{ github.workspace }}/mopm-" ++ r ++ "/staged\n", "          path: ${{ runner.temp }}/mopm-" ++ r ++ "/staged\n"), r ++ "-abort does not download the directory to ${{ github.workspace }}/mopm-" ++ r ++ "/staged");
    }
}

test "a registry name is a whole word after --registry" {
    try t.expect(namesRegistry("beta", "beta"));
    try t.expect(namesRegistry("beta --oidc'", "beta"));
    try t.expect(namesRegistry("beta'", "beta"));
    try t.expect(!namesRegistry("beta2 --oidc", "beta"));
    try t.expect(!namesRegistry("beta-old", "beta"));
    try t.expect(!namesRegistry("beta_x", "beta"));
    try t.expect(!namesRegistry("prod", "beta"));
    try t.expect(!namesRegistry("bet", "beta"));
    try t.expect(!namesRegistry("", "beta"));
}
