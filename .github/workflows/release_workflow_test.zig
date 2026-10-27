//! The cases of the mopm jobs of release.yml, //:release_workflow_cases:
//! a `zig_test` run as a build action. The workflow's own bytes are the subject
//! (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/release.yml).
//!
//! The beta publish runs on every push to main and on the nightly schedule, the prod publish only
//! on the nightly schedule from main, and there is no switch:
//! no line of the file, comment or not, names the variable `MOPM_PUBLISH_ENABLED` or
//! `MOPM_BETA_PUBLISH_ENABLED`. `mopm-publish-beta` publishes to the beta registry with the
//! job's GitHub OIDC identity and no secret. What the cases catch:
//!  - the gate: `needs: mopm-stage`, the `if:` with a push or a nightly run, of main, and nothing
//!    else, so a beta job that loses a part of its gate (and publishes from a manual run
//!    or another ref), or loses the nightly (prod would have no beta e2e at its version) or the
//!    push (no beta per push), is red, and so is a job that gains a condition of a repository variable;
//!  - the prod jobs' gate is the nightly run of main alone: a prod job that also runs on a push
//!    or a manual run is red;
//!  - the triggers and the concurrency: `on:` is the one nightly cron, a push to main and a manual
//!    run; a push run and a nightly run share the group `release-main` and none is cancelled;
//!  - the versions: `mopm-stage` (which stages the set prod publishes) and `mopm-stage-beta`
//!    give every member the version 0.1.<run number> with the same tool, before the stage, from
//!    `github.run_number`, and the README e2e of `mopm-stage`, `prod-test` and `mopm-e2e-beta` is
//!    given that same number, so every release is a new version and prod publishes what beta proved;
//!  - `prod-stage` needs `mopm-e2e-beta`: prod stages only a set the beta e2e passed on;
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
//!    names) and its `on:` is the nightly schedule, a push to main and a manual run, nothing else (a
//!    `pull_request_target` or a second branch would reach the jobs).
//!  - the job `mopm-e2e-beta` verifies what the beta publish sent: it needs
//!    `mopm-publish-beta`, has the same gate, runs in the environment `build` (the
//!    farm's; a job holds one) with exactly `contents: read` and `id-token: write`,
//!    reads no secret and publishes nothing, and runs its steps in this order: the
//!    staged plan is downloaded, the farm is joined and `release_beta_fetch` built,
//!    the download and check against the plan (`--stage beta`, the beta index,
//!    `--out release/beta_set`, nothing else names that directory), then the e2e of
//!    every package on that set at this run's version, every farm step asserted remote.
//!  - the prod publish, five jobs under one gate (`prod-stage`, `prod-test`,
//!    `prod-commit`, `prod-abort`, `prod-smoke`; checkProd says what each must hold):
//!    each job's `needs`, its exact `if:` (the nightly-on-main gate; the abort job's
//!    `failure() || cancelled()` condition with the gate and
//!    `needs.prod-stage.result != 'skipped'`), its environment (`prod` for the three
//!    that talk to the registry, `build` for the test, none for the smoke), its exact
//!    permissions (`id-token: write` only where a registry identity is exchanged, or
//!    for farm-connect in the test), no secret anywhere in the file, the commands (the
//!    stage with `--oidc --no-commit`, the commit with `--oidc` and neither `--no-commit`
//!    nor `--abort`, the abort with `--abort`, the verify and the e2e on the verified
//!    set in the test, the smoke), the order of the test's steps, and that the test and
//!    the smoke never name a registry-writing verb or the OIDC exchange.
//!  - one mopm: every `build toolchains//:mopm_*` label of release.yml and every such label of
//!    docs/ci.md equals `MOPM` of release/readme_e2e/packages.bzl (the mopm the README e2e installs
//!    with is the one the release stages and publishes with), so a bump of one that forgets
//!    the other, or the prose, is red.
//! The reader's own cases are workflow texts written here: each defect above
//! is planted in the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const JOB = "mopm-publish-beta";
const OLD_PROD_JOB = "mopm-publish";
const STAGE_JOB = "mopm-stage-beta";
const PROD_STAGE_JOB = "mopm-stage";
const TOOL = "release_beta_version";
const BUILD_TOOL_LINE = "          args: build //tools/build/ci:release_beta_version --out ${{ runner.temp }}/mopm-publish/release_beta_version";
const UPLOAD_TOOL_LINE = "            ${{ runner.temp }}/mopm-publish/release_beta_version";
const REWRITE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version \"0.1.$RUN_NUMBER\"'";
const REWRITE_ENV = "          RUN_NUMBER: ${{ github.run_number }}";
const PROD_REWRITE_RUN = REWRITE_RUN;
const STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts\" --compiler 1.0.0 --out \"$RUNNER_TEMP/mopm-publish/staged_beta\" --registry beta'";
// the beta jobs run on a push to main and on the nightly run; the prod jobs on the nightly run only
const GATE = "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main'";
const E2E_JOB = "mopm-e2e-beta";
const PROD_GATE = "    if: github.event_name == 'schedule' && github.ref == 'refs/heads/main'";
const CRON = "    - cron: '17 3 * * *'";
const CONCURRENCY_GROUP = "  group: release-${{ (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}";
const ABORT_IF = "    if: (failure() || cancelled()) && github.event_name == 'schedule' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'";
const PROD_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry prod --oidc --no-commit'";
const PROD_COMMIT_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc'";
const PROD_ABORT_CMD = "            \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc --abort";
const PROD_STAGED_ARTIFACT = "          name: mopm-prod-staged-${{ github.sha }}";
const PROD_BUILD_VERIFY = "          args: build //tools/build/ci:release_staged_verify --out ${{ runner.temp }}/prod-test/release_staged_verify";
const PROD_VERIFY_RUN = "        run: '\"$RUNNER_TEMP/prod-test/release_staged_verify\" verify --staged \"$RUNNER_TEMP/prod-test/staged\" --out release/staged_set'";
const PROD_E2E_RUN = "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all";
const STAGE_E2E_RUN = PROD_E2E_RUN;
const PROD_REWRITE_NAME = "      - name: every member gets the version of this run";
const PROD_MOPM_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts\" --compiler 1.0.0 --out release/staged_set --registry prod'";
const PROD_SMOKE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.mopm.dev/index/config.json --attempts 5 --delay 30'";
const STAGE_BUILD_VERIFY = "          args: build //tools/build/ci:release_staged_verify --out ${{ runner.temp }}/mopm-publish/release_staged_verify";
const STAGE_UPLOAD_VERIFY = "            ${{ runner.temp }}/mopm-publish/release_staged_verify";
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

/// What no line of the e2e job may contain: it sends nothing to a registry (a mopm verb that writes, the
/// OIDC exchange, a hand-made PUT or POST).
const e2e_forbidden = [_][]const u8{ "publish", "--oidc", "yank", "login", "curl", "wget", "-X PUT", "-X POST", "--request", "--data", "--upload-file" };

/// Null if the job `mopm-e2e-beta` holds its contract, else the refusal: it verifies what the
/// beta publish sent and sends nothing itself.
fn checkE2e(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    const job = (try jobLines(ar, text, E2E_JOB, &n)) orelse return "no job mopm-e2e-beta";
    if (n != 1) return "mopm-e2e-beta is defined more than once";
    if (!has(job, "    needs: mopm-publish-beta")) return "e2e-beta needs is not exactly mopm-publish-beta";
    if (!has(job, GATE)) return "e2e-beta: the if is not the beta gate (push or nightly, on main)";
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
    // any reference to the secrets context, in any spelling (`secrets.X`, `secrets['X']`, `toJSON(secrets)`,
    // `secrets: inherit`), and the registry token
    for (job) |l| {
        if (std.ascii.indexOfIgnoreCase(l, "secrets") != null or std.mem.indexOf(u8, l, "MOPM_TOKEN") != null) return "e2e-beta reads a secret";
    }
    for (job) |l| {
        if (std.mem.eql(u8, l, "    needs: mopm-publish-beta") or std.mem.eql(u8, l, GATE)) continue;
        for (e2e_forbidden) |w| {
            if (std.ascii.indexOfIgnoreCase(l, w) != null) return "e2e-beta publishes, yanks, logs in or writes to a registry";
        }
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
    // no switch: the beta publish runs per push and nightly, the prod publish nightly. The names are refused
    // anywhere in the file, in a comment too, so the file cannot describe a switch that is not there.
    if (std.mem.indexOf(u8, text, "MOPM_PUBLISH_ENABLED") != null) return "release.yml names MOPM_PUBLISH_ENABLED: the prod publish has no switch";
    if (std.mem.indexOf(u8, text, "MOPM_BETA_PUBLISH_ENABLED") != null) return "release.yml names MOPM_BETA_PUBLISH_ENABLED: the beta publish has no switch";
    var n: usize = 0;
    const job = (try jobLines(ar, text, JOB, &n)) orelse return "no job mopm-publish-beta";
    if (n != 1) return "mopm-publish-beta is defined more than once";
    if (!has(job, "    needs: mopm-stage-beta")) return "needs is not exactly mopm-stage-beta";
    if (!has(job, GATE))
        return "the if is not the beta gate (push or nightly, on main)";
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
    if (!has(stage, GATE)) return "stage-beta: the if is not the beta gate (push or nightly, on main)";
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

    // prod stages the versions beta stages: `mopm-stage` builds the tool once (and hands it to the
    // beta job), runs it once on its own checkout with the run number before it stages, and tries
    // the staged set at that version
    var psn: usize = 0;
    const prod_stage = (try jobLines(ar, text, PROD_STAGE_JOB, &psn)) orelse return "no job mopm-stage";
    if (psn != 1) return "mopm-stage is defined more than once";
    var builds: usize = 0;
    for (prod_stage) |l| {
        if (std.mem.indexOf(u8, l, TOOL) == null) continue;
        if (std.mem.eql(u8, l, BUILD_TOOL_LINE)) {
            builds += 1;
        } else if (!std.mem.eql(u8, l, UPLOAD_TOOL_LINE) and !std.mem.eql(u8, l, PROD_REWRITE_RUN)) {
            return "mopm-stage names release_beta_version other than to build it, run it with the run number and hand it on";
        }
    }
    if (builds != 1) return "mopm-stage does not build release_beta_version once for the beta job";
    if (lineAt(prod_stage, UPLOAD_TOOL_LINE) == null) return "mopm-stage does not hand release_beta_version to the beta job";
    const build_at = lineAt(prod_stage, BUILD_TOOL_LINE).?;
    const prod_stage_at = lineAt(prod_stage, PROD_MOPM_STAGE_RUN) orelse return "mopm-stage does not stage against prod with --out release/staged_set";
    const prod_rewrite_at = lineAt(prod_stage, PROD_REWRITE_RUN) orelse return "mopm-stage does not give the members 0.1.<run number> (release_beta_version): prod would publish fixed versions";
    if (prod_rewrite_at > prod_stage_at) return "mopm-stage runs release_beta_version after mopm stage";
    if (prod_rewrite_at < build_at) return "mopm-stage runs release_beta_version before it builds it";
    if (prod_rewrite_at < 3 or !std.mem.eql(u8, prod_stage[prod_rewrite_at - 2], "        env:") or !std.mem.eql(u8, prod_stage[prod_rewrite_at - 1], REWRITE_ENV) or
        !std.mem.eql(u8, prod_stage[prod_rewrite_at - 3], PROD_REWRITE_NAME)) return "mopm-stage: the rewrite step does not take the run number from github.run_number in its env";
    var prod_tool_runs: usize = 0;
    for (prod_stage) |l| {
        if (std.mem.indexOf(u8, l, TOOL) != null and std.mem.startsWith(u8, l, "        run:")) prod_tool_runs += 1;
    }
    if (prod_tool_runs != 1) return "mopm-stage runs release_beta_version more than once";
    if (mentions(prod_stage, "git push") or mentions(prod_stage, "git commit")) return "mopm-stage commits or pushes what it rewrote";
    const stage_e2e_at = lineAt(prod_stage, STAGE_E2E_RUN) orelse return "mopm-stage does not run the e2e on the staged set at this run's version (staged=stage, beta_version=0.1.<run number>)";
    if (stage_e2e_at < prod_stage_at) return "mopm-stage runs the e2e before it stages";

    if (try checkE2e(ar, text)) |why| return why;
    if (try checkProd(ar, text, prod_stage)) |why| return why;

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
    // the keys, not the comments between them
    var real = std.ArrayList([]const u8).empty;
    for (keys.items) |k| if (k[0] != '#') try real.append(ar, k);
    if (real.items.len != 3 or !std.mem.eql(u8, real.items[0], "schedule:") or !std.mem.eql(u8, real.items[1], "push:") or !std.mem.eql(u8, real.items[2], "workflow_dispatch:"))
        return "on: is not exactly schedule, push and workflow_dispatch";
    // one nightly cron, and nothing else under schedule
    var crons: usize = 0;
    for (on) |l| if (std.mem.indexOf(u8, l, "cron:") != null and std.mem.trim(u8, l, " ")[0] != '#') {
        crons += 1;
    };
    if (crons != 1 or !has(on, CRON)) return "on: schedule is not the one nightly cron";
    // a nightly run and a push run share one concurrency group and none is cancelled by another
    var gn: usize = 0;
    const conc = (try topLines(ar, text, "concurrency:", &gn)) orelse return "no concurrency block";
    if (gn != 1 or !has(conc, CONCURRENCY_GROUP)) return "concurrency: a push and a nightly run are not in one release-main group";
    if (!has(conc, "  cancel-in-progress: false")) return "concurrency: a running release is cancelled";
    if (!has(on, "    branches: [main]")) return "on: push is not branches: [main]";
    if (mentions(on, "pull_request")) return "on: names a pull_request trigger";
    return null;
}


/// The five jobs of the prod publish. What each must hold is below; `prod_stage` is the job `mopm-stage`
/// (it builds the verify tool and hands it on in its artifact).
const ProdJob = struct {
    name: []const u8,
    needs: []const u8,
    gate: []const u8,
    /// The exact `environment:` line, or null: the job holds none.
    environment: ?[]const u8,
    /// Whether the job holds `id-token: write` besides `contents: read`.
    id_token: bool,
};

const prod_jobs = [_]ProdJob{
    .{ .name = "prod-stage", .needs = "    needs: [release, mopm-stage, mopm-e2e-beta]", .gate = PROD_GATE, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-test", .needs = "    needs: prod-stage", .gate = PROD_GATE, .environment = "    environment: build", .id_token = true },
    .{ .name = "prod-commit", .needs = "    needs: prod-test", .gate = PROD_GATE, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-abort", .needs = "    needs: [prod-stage, prod-test, prod-commit]", .gate = ABORT_IF, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-smoke", .needs = "    needs: prod-commit", .gate = PROD_GATE, .environment = null, .id_token = false },
};

/// What none of the lines of the test and smoke jobs may contain: they send nothing to a registry and
/// ask for no identity (a mopm verb that writes, the OIDC exchange, a hand-made PUT or POST).
const prod_readonly_forbidden = [_][]const u8{ "mopm publish", "--oidc", "--abort", "--no-commit", "yank", "login", "curl", "wget", "-X PUT", "-X POST", "--request", "--data", "--upload-file" };

fn countPerms(job: []const []const u8) usize {
    var perms: usize = 0;
    for (job) |l| {
        if (std.mem.startsWith(u8, l, "      ") and !std.mem.startsWith(u8, l, "       ") and
            (std.mem.indexOf(u8, l, ": read") != null or std.mem.indexOf(u8, l, ": write") != null)) perms += 1;
    }
    return perms;
}

/// Null if the prod publish holds its contract, else the refusal.
fn checkProd(ar: std.mem.Allocator, text: []const u8, stage_job: []const []const u8) !?[]const u8 {
    // the token path is gone: no job reads a secret, and the old job is not there
    var old: usize = 0;
    if ((try jobLines(ar, text, OLD_PROD_JOB, &old)) != null) return "the job mopm-publish (the registry token) is still there";
    var lit = std.mem.splitScalar(u8, text, '\n');
    while (lit.next()) |l| {
        const trimmed = std.mem.trim(u8, l, " ");
        if (trimmed.len > 0 and trimmed[0] == '#') continue;
        if (std.ascii.indexOfIgnoreCase(l, "secrets") != null or std.mem.indexOf(u8, l, "MOPM_TOKEN") != null) return "release.yml reads a secret";
    }
    // mopm-stage builds the verify tool once and hands it on
    var builds: usize = 0;
    for (stage_job) |l| if (std.mem.eql(u8, l, STAGE_BUILD_VERIFY)) {
        builds += 1;
    };
    if (builds != 1) return "mopm-stage does not build release_staged_verify once for the prod jobs";
    if (lineAt(stage_job, STAGE_UPLOAD_VERIFY) == null) return "mopm-stage does not hand release_staged_verify to the prod jobs";

    for (prod_jobs) |spec| {
        var n: usize = 0;
        const job = (try jobLines(ar, text, spec.name, &n)) orelse return try std.fmt.allocPrint(ar, "no job {s}", .{spec.name});
        if (n != 1) return try std.fmt.allocPrint(ar, "{s} is defined more than once", .{spec.name});
        if (!has(job, spec.needs)) return try std.fmt.allocPrint(ar, "{s}: needs is not exactly `{s}`", .{ spec.name, std.mem.trim(u8, spec.needs, " ") });
        if (!has(job, spec.gate)) return try std.fmt.allocPrint(ar, "{s}: the if is not the expected gate", .{spec.name});
        var ifs: usize = 0;
        for (job) |l| if (std.mem.startsWith(u8, l, "    if:")) {
            ifs += 1;
        };
        if (ifs != 1) return try std.fmt.allocPrint(ar, "{s}: the if is not exactly one line", .{spec.name});
        if (spec.environment) |env| {
            if (!has(job, env)) return try std.fmt.allocPrint(ar, "{s}: environment is not `{s}`", .{ spec.name, std.mem.trim(u8, env, " ") });
            var envs: usize = 0;
            for (job) |l| if (std.mem.startsWith(u8, l, "    environment:")) {
                envs += 1;
            };
            if (envs != 1) return try std.fmt.allocPrint(ar, "{s}: holds more than one environment", .{spec.name});
        } else if (mentions(job, "environment:")) {
            return try std.fmt.allocPrint(ar, "{s} holds an environment", .{spec.name});
        }
        if (!has(job, "    permissions:") or !has(job, "      contents: read")) return try std.fmt.allocPrint(ar, "{s}: permissions are not contents: read", .{spec.name});
        if (has(job, "      id-token: write") != spec.id_token) return try std.fmt.allocPrint(ar, "{s}: id-token: write is {s}", .{ spec.name, if (spec.id_token) "missing" else "held" });
        if (countPerms(job) != (if (spec.id_token) @as(usize, 2) else 1)) return try std.fmt.allocPrint(ar, "{s}: permissions hold more than they should", .{spec.name});
        if (mentions(job, "continue-on-error")) return try std.fmt.allocPrint(ar, "{s} ignores a failure", .{spec.name});
        for (job) |l| {
            if (std.mem.indexOf(u8, l, "|| true") != null and !std.mem.eql(u8, l, "        run: ./buck2 kill || true")) return try std.fmt.allocPrint(ar, "{s} ignores a failure", .{spec.name});
        }
    }

    var scratch: usize = 0;
    const stage = (try jobLines(ar, text, "prod-stage", &scratch)).?;
    if (mentions(stage, "farm") or mentions(stage, "buck2")) return "prod-stage joins the farm or runs buck2";
    const stage_at = lineAt(stage, PROD_STAGE_RUN) orelse return "prod-stage does not run publish --staged --registry prod --oidc --no-commit";
    if (mentions(stage, "--dry-run") or mentions(stage, "--abort")) return "prod-stage publishes with --dry-run or --abort";
    var stage_runs: usize = 0;
    for (stage) |l| if (std.mem.indexOf(u8, l, "mopm\" publish") != null) {
        stage_runs += 1;
    };
    if (stage_runs != 1) return "prod-stage runs mopm publish more than once";
    // the directory is kept even when the step failed, so the abort job can end a group
    const keep_at = lineAt(stage, PROD_STAGED_ARTIFACT) orelse return "prod-stage does not keep the staged directory (mopm-prod-staged)";
    if (!(stage_at < keep_at)) return "prod-stage keeps the directory before it stages";
    if (keep_at < 3 or !std.mem.eql(u8, stage[keep_at - 3], "      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1") or !std.mem.eql(u8, stage[keep_at - 2], "        if: always()"))
        return "prod-stage keeps the directory only when the stage succeeded (the artifact step needs if: always())";

    const tst = (try jobLines(ar, text, "prod-test", &scratch)).?;
    for (tst) |l| {
        if (std.mem.eql(u8, l, "    needs: prod-stage") or std.mem.eql(u8, l, PROD_GATE)) continue;
        for (prod_readonly_forbidden) |w| {
            if (std.ascii.indexOfIgnoreCase(l, w) != null) return "prod-test publishes, yanks, logs in or exchanges an identity";
        }
    }
    // the files under test are the ones prod-stage kept, never the set mopm-stage made
    if (mentions(tst, "mopm-staged-")) return "prod-test takes the set of mopm-stage, not the one prod-stage uploaded";
    const download_at = lineAt(tst, PROD_STAGED_ARTIFACT) orelse return "prod-test does not download the set prod-stage uploaded";
    const connect_at = lineAt(tst, E2E_FARM_CONNECT) orelse return "prod-test does not join the farm";
    const tool_at = lineAt(tst, PROD_BUILD_VERIFY) orelse return "prod-test does not build release_staged_verify";
    const verify_at = lineAt(tst, PROD_VERIFY_RUN) orelse return "prod-test does not verify the staged files against the plan (release_staged_verify verify --out release/staged_set)";
    const e2e_at = lineAt(tst, PROD_E2E_RUN) orelse return "prod-test does not run the e2e on the verified set (staged=stage at this run's version)";
    if (!(connect_at < tool_at and tool_at < verify_at)) return "prod-test verifies before the farm is joined and the tool built";
    if (!(download_at < verify_at)) return "prod-test verifies before it has the files";
    if (!(verify_at < e2e_at)) return "prod-test runs the e2e before the verification";
    // nothing else may write the directory the e2e reads
    var writers: usize = 0;
    for (tst) |l| if (std.mem.indexOf(u8, l, "staged_set") != null) {
        writers += 1;
    };
    if (writers != 1) return "prod-test names release/staged_set other than in the one verify step";
    var verify_runs: usize = 0;
    for (tst) |l| if (std.mem.indexOf(u8, l, "release_staged_verify\"") != null and std.mem.startsWith(u8, l, "        run:")) {
        verify_runs += 1;
    };
    if (verify_runs != 1) return "prod-test runs release_staged_verify more than once";
    var asserted: usize = 0;
    for (tst) |l| if (std.mem.eql(u8, l, E2E_ASSERT)) {
        asserted += 1;
    };
    if (asserted != 2) return "prod-test has a farm step that is not asserted remote";

    const commit = (try jobLines(ar, text, "prod-commit", &scratch)).?;
    if (mentions(commit, "farm") or mentions(commit, "buck2")) return "prod-commit joins the farm or runs buck2";
    const commit_at = lineAt(commit, PROD_COMMIT_RUN) orelse return "prod-commit does not run publish --staged --registry prod --oidc on the directory prod-stage kept";
    if (mentions(commit, "--no-commit") or mentions(commit, "--abort") or mentions(commit, "--dry-run")) return "prod-commit does not commit: it names --no-commit, --abort or --dry-run";
    const commit_dl = lineAt(commit, PROD_STAGED_ARTIFACT) orelse return "prod-commit does not download the directory prod-stage kept (with its state.json)";
    if (!(commit_dl < commit_at)) return "prod-commit publishes before it has the directory";
    var commit_runs: usize = 0;
    for (commit) |l| if (std.mem.indexOf(u8, l, "mopm\" publish") != null) {
        commit_runs += 1;
    };
    if (commit_runs != 1) return "prod-commit runs mopm publish more than once";

    const abort = (try jobLines(ar, text, "prod-abort", &scratch)).?;
    if (mentions(abort, "farm") or mentions(abort, "buck2")) return "prod-abort joins the farm or runs buck2";
    if (!has(abort, PROD_ABORT_CMD)) return "prod-abort does not run publish --staged --registry prod --oidc --abort";
    if (mentions(abort, "--no-commit") or mentions(abort, "--dry-run") or mentions(abort, "yank")) return "prod-abort stages, dry-runs or yanks";
    if (lineAt(abort, PROD_STAGED_ARTIFACT) == null) return "prod-abort does not download the directory prod-stage kept (the state.json names the group)";
    var abort_runs: usize = 0;
    for (abort) |l| if (std.mem.indexOf(u8, l, "mopm\" publish") != null) {
        abort_runs += 1;
    };
    if (abort_runs != 1) return "prod-abort runs mopm publish more than once";

    const smoke = (try jobLines(ar, text, "prod-smoke", &scratch)).?;
    for (smoke) |l| {
        if (std.mem.eql(u8, l, "    needs: prod-commit") or std.mem.eql(u8, l, PROD_GATE)) continue;
        for (prod_readonly_forbidden) |w| {
            if (std.ascii.indexOfIgnoreCase(l, w) != null) return "prod-smoke yanks, publishes or exchanges an identity: it only reads";
        }
    }
    if (mentions(smoke, "farm") or mentions(smoke, "buck2")) return "prod-smoke joins the farm or runs buck2";
    if (!has(smoke, PROD_SMOKE_RUN)) return "prod-smoke does not run release_staged_verify smoke against the prod index with the committed directory";
    if (lineAt(smoke, "          name: mopm-prod-committed-${{ github.sha }}") == null) return "prod-smoke does not download the committed directory";
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

test "release.yml holds the contract of the beta and prod publish jobs" {
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
    const gate = GATE ++ "\n";
    const cmd = " --oidc --registry beta'\n";

    // the gate (the line every beta and prod job shares) that lost its push, its main, or the whole if,
    // or that got another condition
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'push'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.ref == 'refs/heads/main'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && github.actor != ''\n"), "gate");
    // the beta jobs run on a push AND on the nightly run: push only (no beta for the nightly set, so prod
    // would have no beta e2e at its version), nightly only (no beta per push), or a manual run too
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name == 'schedule' && github.ref == 'refs/heads/main'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: (github.event_name == 'push' || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'\n"), "gate");
    // one beta job at a time carrying another job's gate: the beta publish gated like prod, or the stage ungated
    try expectRefused(ar, try replaced(ar, text, "    needs: mopm-stage-beta\n" ++ gate, "    needs: mopm-stage-beta\n" ++ PROD_GATE ++ "\n"), "the if is not the beta gate");
    try expectRefused(ar, try replaced(ar, text, "    needs: mopm-stage\n" ++ gate, "    needs: mopm-stage\n" ++ PROD_GATE ++ "\n"), "stage-beta: the if");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: always()\n"), "gate");
    try expectRefused(ar, try replaced(ar, text, gate, ""), "gate");
    // no switch: a variable condition, a comment that names one, either spelling, is refused
    try expectRefused(ar, try replaced(ar, text, gate, "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n"), "MOPM_BETA_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, gate, "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && vars.MOPM_PUBLISH_ENABLED == 'true'\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_PUBLISH_ENABLED\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_BETA_PUBLISH_ENABLED\n"), "MOPM_BETA_PUBLISH_ENABLED");
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
    // the prod stage job (mopm-stage) runs it too: with the run number, before its stage, once
    const prod_rewrite_step = PROD_REWRITE_NAME ++ "\n        env:\n" ++ REWRITE_ENV ++ "\n" ++ REWRITE_RUN ++ "\n";
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, ""), "prod would publish fixed versions");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n        env:\n" ++ REWRITE_ENV ++ "\n        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version 0.1.0'\n"), "other than to build it");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n        env:\n          RUN_NUMBER: ${{ github.run_attempt }}\n" ++ REWRITE_RUN ++ "\n"), "mopm-stage: the rewrite step does not take the run number");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n" ++ REWRITE_RUN ++ "\n"), "mopm-stage: the rewrite step does not take the run number");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step ++ "      # STAGE. Packs", prod_rewrite_step ++ prod_rewrite_step ++ "      # STAGE. Packs"), "more than once");
    try expectRefused(ar, try replaced(ar, text, PROD_REWRITE_NAME ++ "\n", "      - run: git push origin HEAD\n" ++ PROD_REWRITE_NAME ++ "\n"), "commits or pushes");
    // the rewrite after the stage, and before the tool is built
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, prod_rewrite_step, ""), PROD_MOPM_STAGE_RUN ++ "\n", PROD_MOPM_STAGE_RUN ++ "\n" ++ prod_rewrite_step), "runs release_beta_version after mopm stage");
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, prod_rewrite_step, ""), "      - name: build the beta version tool\n", prod_rewrite_step ++ "      - name: build the beta version tool\n"), "before it builds it");
    // the e2e of mopm-stage is at that version
    const stage_e2e_tail = "\n          assert-remote: ${{ steps.assert.outputs.path }}\n      # Reads plan.json";
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_attempt }} //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    try expectRefused(ar, try replaced(ar, text, BUILD_TOOL_LINE ++ "\n", ""), "does not build release_beta_version once");
    try expectRefused(ar, try replaced(ar, text, UPLOAD_TOOL_LINE ++ "\n", ""), "hand release_beta_version");
    // publish takes the set staged for prod instead of the beta one
    try expectRefused(ar, try replaced(ar, text, "publish --staged \"$RUNNER_TEMP/mopm-publish/staged_beta\" --oidc", "publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --oidc"), "publish command");
    // top-level permissions and the triggers
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions is not");
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\n"), "exactly once");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request_target:\n  workflow_dispatch:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n  workflow_call:\n"), "on: is not exactly");
    // the nightly schedule: it is there, once, and is the one cron
    try expectRefused(ar, try replaced(ar, text, "  schedule:\n" ++ CRON ++ "\n", ""), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, CRON ++ "\n", CRON ++ "\n    - cron: '17 15 * * *'\n"), "one nightly cron");
    try expectRefused(ar, try replaced(ar, text, CRON ++ "\n", "    - cron: '17 3 * * 1'\n"), "one nightly cron");
    try expectRefused(ar, try replaced(ar, text, CRON ++ "\n", ""), "one nightly cron");
    // a manual run never publishes: no manual run is in the release group, and a push or nightly run
    // is in one group that no other run cancels
    try expectRefused(ar, try replaced(ar, text, CONCURRENCY_GROUP, "  group: release-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, CONCURRENCY_GROUP, "  group: release-${{ github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: true\n"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main, 'release/**']\n"), "branches");
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
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    if: github.event_name == 'push'\n    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
    try expectRefused(ar, try replaced(ar, text, head, need ++ "    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n" ++ env_build), "e2e-beta: the if");
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
    try expectRefused(ar, try replaced(ar, text, run_step, "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry beta\n" ++ run_step), "publishes, yanks");
    try expectRefused(ar, try replaced(ar, text, run_step, "      - run: mopm-x --oidc\n" ++ run_step), "publishes, yanks");
    // every spelling of the secrets context, and every verb that writes to a registry
    const secret_spellings = [_][]const u8{ "          X: ${{ secrets['OTHER'] }}\n", "          X: ${{ toJSON(secrets) }}\n", "          X: ${{ SECRETS.OTHER }}\n", "          X: ${{ secrets }}\n" };
    inline for (secret_spellings) |line| try expectRefused(ar, try replaced(ar, text, fetch_step, fetch_name ++ "        env:\n" ++ line ++ E2E_FETCH_RUN ++ "\n"), "reads a secret");
    try expectRefused(ar, try replaced(ar, text, E2E_FETCH_RUN ++ "\n", E2E_FETCH_RUN ++ "\n        secrets: inherit\n"), "reads a secret");
    const writers = [_][]const u8{ "mopm publish --staged x", "mopm yank komira_hash 0.1.1", "mopm login --registry beta", "curl -X PUT https://x.test/y", "curl -X POST https://x.test/y", "curl --request POST https://x.test/y", "wget --post-data=x https://x.test/y" };
    inline for (writers) |cmd| try expectRefused(ar, try replaced(ar, text, run_step, "      - run: " ++ cmd ++ "\n" ++ run_step), "publishes, yanks");
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

/// `head` with its prod gate line replaced by `to` (a whole line with its newline, or nothing).
fn swapGate(ar: std.mem.Allocator, head: []const u8, to: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, head, PROD_GATE).?;
    return std.mem.concat(ar, u8, &.{ head[0..at], to, head[at + PROD_GATE.len + 1 ..] });
}

test "each edit of the prod jobs of the real release.yml that breaks the contract is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    const runs = "    runs-on: ubuntu-24.04\n";
    const nl = "\n";
    const stage_head = "    needs: [release, mopm-stage, mopm-e2e-beta]\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const test_head = "    needs: prod-stage\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: build\n";
    const commit_head = "    needs: prod-test\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const smoke_head = "    needs: prod-commit\n" ++ PROD_GATE ++ nl ++ runs ++ "    timeout-minutes: 30\n";
    const abort_head = "    needs: [prod-stage, prod-test, prod-commit]\n" ++ ABORT_IF ++ nl ++ runs ++ "    environment: prod\n";

    // the old token job is not back, and no job reads a secret
    try expectRefused(ar, try replaced(ar, text, "  mopm-stage-beta:\n", "  mopm-publish:\n    runs-on: ubuntu-24.04\n\n  mopm-stage-beta:\n"), "still there");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN ++ nl, "        env:\n          MOPM_TOKEN: x\n" ++ PROD_STAGE_RUN ++ nl), "reads a secret");
    try expectRefused(ar, try replaced(ar, text, PROD_VERIFY_RUN ++ nl, "        env:\n          X: ${{ secrets.OTHER }}\n" ++ PROD_VERIFY_RUN ++ nl), "reads a secret");
    // the verify tool is built once by mopm-stage and handed on
    try expectRefused(ar, try replaced(ar, text, STAGE_BUILD_VERIFY ++ nl, ""), "build release_staged_verify once");
    try expectRefused(ar, try replaced(ar, text, STAGE_UPLOAD_VERIFY ++ nl, ""), "hand release_staged_verify");

    // the gate of each job, and the whole if
    const gates = [_][]const u8{ stage_head, test_head, commit_head, smoke_head };
    for (gates) |head| {
        const wrong = [_][]const u8{
            "    if: github.event_name == 'push'\n",
            "    if: github.event_name == 'schedule'\n",
            "    if: github.ref == 'refs/heads/main'\n",
            // prod on a push too (every push would publish to prod), or on a manual run
            "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'\n",
            "    if: always()\n",
            "",
        };
        for (wrong) |w| try expectRefused(ar, try replaced(ar, text, head, try swapGate(ar, head, w)), "the if is not the expected gate");
    }
    // the dependencies: the chain, and the abort sees all three jobs that can fail
    // prod stages only a set the beta e2e passed on: the dependency is not droppable
    try expectRefused(ar, try replaced(ar, text, stage_head, "    needs: [release, mopm-stage]\n" ++ stage_head["    needs: [release, mopm-stage, mopm-e2e-beta]\n".len..]), "prod-stage: needs");
    try expectRefused(ar, try replaced(ar, text, stage_head, "    needs: [release, mopm-stage, mopm-publish-beta]\n" ++ stage_head["    needs: [release, mopm-stage, mopm-e2e-beta]\n".len..]), "prod-stage: needs");
    try expectRefused(ar, try replaced(ar, text, test_head, "    needs: [prod-stage, release]\n" ++ test_head["    needs: prod-stage\n".len..]), "prod-test: needs");
    try expectRefused(ar, try replaced(ar, text, commit_head, "    needs: prod-stage\n" ++ commit_head["    needs: prod-test\n".len..]), "prod-commit: needs");
    try expectRefused(ar, try replaced(ar, text, smoke_head, "    needs: prod-test\n" ++ smoke_head["    needs: prod-commit\n".len..]), "prod-smoke: needs");
    try expectRefused(ar, try replaced(ar, text, abort_head, "    needs: prod-stage\n" ++ abort_head["    needs: [prod-stage, prod-test, prod-commit]\n".len..]), "prod-abort: needs");
    try expectRefused(ar, try replaced(ar, text, abort_head, "    needs: [prod-stage, prod-commit]\n" ++ abort_head["    needs: [prod-stage, prod-test, prod-commit]\n".len..]), "prod-abort: needs");
    // the abort condition: a failure or a cancel, the gate, and a stage that ran
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: github.event_name == 'schedule' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: always() && github.event_name == 'schedule' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && github.event_name == 'schedule' && github.ref == 'refs/heads/main'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: failure() && github.event_name == 'schedule' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, ABORT_IF ++ " && vars.MOPM_PUBLISH_ENABLED == 'true'\n"), "MOPM_PUBLISH_ENABLED");

    // the environments: prod for the registry, build for the test, none for the smoke
    try expectRefused(ar, try replaced(ar, text, stage_head, stage_head[0 .. stage_head.len - "    environment: prod\n".len] ++ "    environment: beta\n"), "prod-stage: environment");
    try expectRefused(ar, try replaced(ar, text, commit_head, commit_head[0 .. commit_head.len - "    environment: prod\n".len]), "prod-commit: environment");
    try expectRefused(ar, try replaced(ar, text, abort_head, abort_head[0 .. abort_head.len - "    environment: prod\n".len] ++ "    environment: build\n"), "prod-abort: environment");
    try expectRefused(ar, try replaced(ar, text, test_head, test_head[0 .. test_head.len - "    environment: build\n".len] ++ "    environment: prod\n"), "prod-test: environment");
    try expectRefused(ar, try replaced(ar, text, test_head, test_head[0 .. test_head.len - "    environment: build\n".len]), "prod-test: environment");
    try expectRefused(ar, try replaced(ar, text, smoke_head, smoke_head[0 .. smoke_head.len - "    timeout-minutes: 30\n".len] ++ "    environment: prod\n    timeout-minutes: 30\n"), "prod-smoke holds an environment");

    // the permissions: id-token where an identity is exchanged, nothing more anywhere
    const perms_commit = "    timeout-minutes: 60\n    permissions:\n      contents: read\n      id-token: write\n";
    try expectRefused(ar, try replaced(ar, text, perms_commit, "    timeout-minutes: 60\n    permissions:\n      contents: read\n"), "prod-commit: id-token: write is missing");
    try expectRefused(ar, try replaced(ar, text, perms_commit, perms_commit ++ "      packages: write\n"), "prod-commit: permissions hold more");
    const perms_smoke = "    timeout-minutes: 30\n    permissions:\n      contents: read\n    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-publish\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-prod-committed";
    try expectRefused(ar, try replaced(ar, text, perms_smoke, "    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n" ++ perms_smoke["    timeout-minutes: 30\n    permissions:\n      contents: read\n".len..]), "prod-smoke: id-token: write is held");
    const perms_stage = "    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n    steps:\n      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-publish\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc --no-commit";
    try expectRefused(ar, try replaced(ar, text, perms_stage, "    timeout-minutes: 30\n    permissions:\n      contents: read\n    steps:" ++ perms_stage["    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n    steps:".len..]), "prod-stage: id-token: write is missing");
    try expectRefused(ar, try replaced(ar, text, perms_stage, "    timeout-minutes: 30\n    permissions:\n      contents: write\n      id-token: write\n    steps:" ++ perms_stage["    timeout-minutes: 30\n    permissions:\n      contents: read\n      id-token: write\n    steps:".len..]), "prod-stage: permissions are not contents: read");

    // the stage: --oidc --no-commit, once, no farm, and the directory kept even on a failed step
    try expectRefused(ar, try replaced(ar, text, " --registry prod --oidc --no-commit'\n", " --registry prod --oidc'\n"), "prod-stage does not run");
    try expectRefused(ar, try replaced(ar, text, " --registry prod --oidc --no-commit'\n", " --registry prod --no-commit'\n"), "prod-stage does not run");
    try expectRefused(ar, try replaced(ar, text, " --registry prod --oidc --no-commit'\n", " --registry beta --oidc --no-commit'\n"), "prod-stage does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN ++ nl, PROD_STAGE_RUN ++ nl ++ "      - run: ./buck2 build //x\n"), "prod-stage joins the farm");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN ++ nl, PROD_STAGE_RUN ++ nl ++ "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry prod --oidc --no-commit\n"), "more than once");
    try expectRefused(ar, try replaced(ar, text, "        if: always()\n        with:\n" ++ PROD_STAGED_ARTIFACT, "        with:\n" ++ PROD_STAGED_ARTIFACT), "needs if: always()");
    try expectRefused(ar, try replaced(ar, text, "        if: always()\n        with:\n" ++ PROD_STAGED_ARTIFACT, "        if: success()\n        with:\n" ++ PROD_STAGED_ARTIFACT), "needs if: always()");

    // the test: the files prod-stage kept, verified, then the e2e on what was verified; no identity
    const tst_download = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n" ++ PROD_STAGED_ARTIFACT ++ "\n          path: ${{ runner.temp }}/prod-test/staged\n";
    const tool_step = "      - name: build the staged-set verify tool\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PROD_BUILD_VERIFY ++ nl ++ E2E_ASSERT ++ nl;
    const verify_step = "      - name: check the staged files against the plan\n" ++ PROD_VERIFY_RUN ++ nl;
    const e2e_step = "      - name: the README e2e against the staged files\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PROD_E2E_RUN ++ nl ++ E2E_ASSERT ++ nl;
    try expectRefused(ar, try replaced(ar, text, tst_download, ""), "does not download the set prod-stage uploaded");
    try expectRefused(ar, try replaced(ar, text, tst_download, "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/prod-test/staged\n"), "not the one prod-stage uploaded");
    const without_download = try replaced(ar, text, tst_download, "");
    try expectRefused(ar, try replaced(ar, without_download, verify_step, verify_step ++ tst_download), "before it has the files");
    try expectRefused(ar, try replaced(ar, text, verify_step, ""), "does not verify the staged files");
    try expectRefused(ar, try replaced(ar, text, PROD_VERIFY_RUN, "        run: '\"$RUNNER_TEMP/prod-test/release_staged_verify\" verify --staged \"$RUNNER_TEMP/prod-test/staged\" --out release/elsewhere'"), "does not verify the staged files");
    try expectRefused(ar, try replaced(ar, text, PROD_VERIFY_RUN, "        run: '\"$RUNNER_TEMP/prod-test/release_staged_verify\" verify --staged \"$RUNNER_TEMP/prod-test/staged\" --out release/staged_set || true'"), "prod-test ignores a failure");
    try expectRefused(ar, try replaced(ar, text, tool_step ++ verify_step, verify_step ++ tool_step), "verifies before the farm is joined and the tool built");
    try expectRefused(ar, try replaced(ar, text, verify_step ++ e2e_step, e2e_step ++ verify_step), "runs the e2e before the verification");
    const e2e_args = "-c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all\n";
    try expectRefused(ar, try replaced(ar, text, e2e_step, try replaced(ar, e2e_step, e2e_args, "//release/readme_e2e/verify:all\n")), "does not run the e2e on the verified set");
    try expectRefused(ar, try replaced(ar, text, e2e_step, try replaced(ar, e2e_step, e2e_args, "-c komira_release.staged=beta -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all\n")), "does not run the e2e on the verified set");
    // prod-test's e2e is at the version of the run, the one the set was staged at
    try expectRefused(ar, try replaced(ar, text, e2e_step, try replaced(ar, e2e_step, e2e_args, "-c komira_release.staged=stage //release/readme_e2e/verify:all\n")), "does not run the e2e on the verified set");
    try expectRefused(ar, try replaced(ar, text, e2e_step, try replaced(ar, e2e_step, e2e_args, "-c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_attempt }} //release/readme_e2e/verify:all\n")), "does not run the e2e on the verified set");
    try expectRefused(ar, try replaced(ar, text, verify_step, verify_step ++ "      - run: cp x release/staged_set/y\n"), "other than in the one verify step");
    try expectRefused(ar, try replaced(ar, text, verify_step, verify_step ++ verify_step), "other than in the one verify step");
    try expectRefused(ar, try replaced(ar, text, PROD_E2E_RUN ++ nl ++ E2E_ASSERT ++ nl, PROD_E2E_RUN ++ nl), "not asserted remote");
    try expectRefused(ar, try replaced(ar, text, PROD_BUILD_VERIFY ++ nl ++ E2E_ASSERT ++ nl, PROD_BUILD_VERIFY ++ nl), "not asserted remote");
    try expectRefused(ar, try replaced(ar, text, e2e_step, e2e_step ++ "        continue-on-error: true\n"), "prod-test ignores a failure");
    const writers = [_][]const u8{ "mopm publish --staged x --registry prod", "mopm yank komira_hash 0.1.1", "mopm login --registry prod", "curl -X PUT https://x.test/y", "curl --request POST https://x.test/y", "wget --post-data=x https://x.test/y", "mopm-x --oidc" };
    inline for (writers) |cmd| try expectRefused(ar, try replaced(ar, text, e2e_step, "      - run: " ++ cmd ++ "\n" ++ e2e_step), "prod-test publishes, yanks");

    // the commit: the same command without --no-commit, on the directory prod-stage kept, with an identity of its own
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc --no-commit'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry prod --oidc'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, PROD_COMMIT_RUN ++ nl ++ "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry prod --oidc --abort"), "prod-commit does not commit");
    try expectRefused(ar, try replaced(ar, text, "          name: mopm-prod-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n", "          name: mopm-prod-nothing-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n"), "prod-commit does not download the directory");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, PROD_COMMIT_RUN ++ nl ++ "      - run: ./buck2 build //x"), "prod-commit joins the farm");

    // the abort: --abort, on the directory with the state, once
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, "            \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc"), "prod-abort does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, "            \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc --abort --no-commit"), "prod-abort does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, PROD_ABORT_CMD ++ "\n            mopm yank --group g --registry prod --reason x"), "stages, dry-runs or yanks");

    // the smoke: reads the committed directory and the prod index, and only reads
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.beta.mopm.dev/index/config.json --attempts 5 --delay 30'"), "prod-smoke does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.mopm.dev/index/config.json --attempts 5 --delay 30 || true'"), "prod-smoke ignores a failure");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - run: mopm yank --group g --registry prod --reason x"), "only reads");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - run: ./mopm publish --staged x --registry prod --oidc"), "only reads");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - uses: ./.github/actions/farm-connect"), "prod-smoke joins the farm");
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

const MOPM_PREFIX = "toolchains//:mopm_";

/// The label `MOPM = "..."` of packages.bzl, or null.
fn mopmPin(bzl: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MOPM = \"")) continue;
        const rest = line["MOPM = \"".len..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }
    return null;
}

/// Null when every `toolchains//:mopm_<version>` mention of `text` (a label of `what`) is the pin
/// and there is at least one; else a message. A mention is the prefix and the run of
/// digits and underscores after it.
fn mopmDrift(text: []const u8, pin: []const u8, what: []const u8, out: *[160]u8) !?[]const u8 {
    var from: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, MOPM_PREFIX)) |at| {
        var end = at + MOPM_PREFIX.len;
        while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == '_')) end += 1;
        const label = text[at..end];
        if (!std.mem.eql(u8, label, pin)) return try std.fmt.bufPrint(out, "{s} names {s} but MOPM of packages.bzl is {s}", .{ what, label, pin });
        seen += 1;
        from = end;
    }
    if (seen == 0) return try std.fmt.bufPrint(out, "{s} names no mopm toolchain label", .{what});
    return null;
}

test "the mopm release.yml builds and docs/ci.md names is the MOPM of packages.bzl" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const bzl = try std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, "packages.bzl" }), 1 << 20);
    const doc = try std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, "ci.md" }), 1 << 22);
    const pin = mopmPin(bzl) orelse return error.NoPin;
    var buf: [160]u8 = undefined;
    if (try mopmDrift(try readWorkflow(ar), pin, "release.yml", &buf)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Drift;
    }
    if (try mopmDrift(doc, pin, "docs/ci.md", &buf)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Drift;
    }
}

test "a mopm label that differs from the pin, or none, is refused" {
    var buf: [160]u8 = undefined;
    const pin = "toolchains//:mopm_0_0_81";
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_81 --out x", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("a toolchains//:mopm_0_0_81, b toolchains//:mopm_0_0_81.", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_73 --out x", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("toolchains//:mopm_0_0_81 then toolchains//:mopm_0_0_8", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("no label here", pin, "w", &buf)) != null);
    try t.expectEqualStrings("toolchains//:mopm_0_0_81", mopmPin("X = 1\nMOPM = \"toolchains//:mopm_0_0_81\"\n").?);
    try t.expect(mopmPin("# MOPM = \"x\"\n") == null);
}
