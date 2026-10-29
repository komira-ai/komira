//! The cases of the mopm jobs of release.yml, //:release_workflow_cases:
//! a `zig_test` run as a build action. The workflow's own bytes are the subject
//! (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/release.yml).
//!
//! The prod publish is continuous: every push to main publishes to the registry `prod`, in the
//! jobs `mopm-stage` and `prod-stage`, `prod-test`, `prod-commit`, `prod-abort`, `prod-smoke`.
//! There is no beta publish and no switch: no line of the file, comment or not, names the
//! variable `MOPM_PUBLISH_ENABLED` or `MOPM_BETA_PUBLISH_ENABLED`. What the cases catch:
//!  - no beta: none of the jobs `mopm-stage-beta`, `mopm-publish-beta` and `mopm-e2e-beta` exists,
//!    and no line outside a comment stages against the registry `beta` or holds the environment
//!    `beta`, so a beta publish that comes back is red;
//!  - the prod jobs' gate is a push to main alone: a prod job that also runs on a manual run, a
//!    schedule or another ref, or that gains another condition, is red;
//!  - `prod-stage` needs exactly `release` and `mopm-stage`;
//!  - the triggers and the concurrency: `on:` is exactly a push to main and a manual run (no
//!    schedule, no cron, no pull request); a push run is in the group `release-main` and no run
//!    is cancelled, so two pushes never publish to prod at once; a manual run is in no such group;
//!  - the versions: `mopm-stage` (which stages the set prod publishes) gives every member the
//!    version 0.1.<run number> with the version tool, once, before the stage, from
//!    `github.run_number`, and the README e2e of `mopm-stage` and `prod-test` is given that same
//!    number, so every release is a new version and prod publishes what the e2e passed on;
//!  - no secret: no line outside a comment names `MOPM_TOKEN` or `secrets`;
//!  - the workflow's top-level `permissions` is `{}` (a job holds only what it names);
//!  - the prod publish, five jobs under one gate (`prod-stage`, `prod-test`,
//!    `prod-commit`, `prod-abort`, `prod-smoke`; checkProd says what each must hold):
//!    each job's `needs`, its exact `if:` (the push-to-main gate; the abort job's
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

const BETA_JOBS = [_][]const u8{ "mopm-stage-beta", "mopm-publish-beta", "mopm-e2e-beta" };
const OLD_PROD_JOB = "mopm-publish";
const PROD_STAGE_JOB = "mopm-stage";
const TOOL = "release_beta_version";
const BUILD_TOOL_LINE = "          args: build //tools/build/ci:release_beta_version --out ${{ runner.temp }}/mopm-publish/release_beta_version";
const REWRITE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version \"0.1.$RUN_NUMBER\"'";
const REWRITE_ENV = "          RUN_NUMBER: ${{ github.run_number }}";
const PROD_REWRITE_RUN = REWRITE_RUN;
// every prod job runs on a push to main, and on nothing else
const PROD_GATE = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'";
const CONCURRENCY_GROUP = "  group: release-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}";
const ABORT_IF = "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'";
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
const E2E_FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
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

/// Null if the workflow text holds the contract, else the refusal.
fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    // no switch: the prod publish runs on every push. The names are refused anywhere in the file,
    // in a comment too, so the file cannot describe a switch that is not there.
    if (std.mem.indexOf(u8, text, "MOPM_PUBLISH_ENABLED") != null) return "release.yml names MOPM_PUBLISH_ENABLED: the prod publish has no switch";
    if (std.mem.indexOf(u8, text, "MOPM_BETA_PUBLISH_ENABLED") != null) return "release.yml names MOPM_BETA_PUBLISH_ENABLED: there is no beta publish and no switch";
    // no beta publish: no beta job, and no line that stages against or holds the beta registry
    for (BETA_JOBS) |name| {
        var bn: usize = 0;
        if ((try jobLines(ar, text, name, &bn)) != null) return try std.fmt.allocPrint(ar, "the beta job {s} is still there: komira does not publish to beta", .{name});
    }
    var bit = std.mem.splitScalar(u8, text, '\n');
    while (bit.next()) |l| {
        const trimmed = std.mem.trim(u8, l, " ");
        if (trimmed.len > 0 and trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, l, "--registry beta") != null or std.mem.indexOf(u8, l, "environment: beta") != null)
            return "release.yml stages against or publishes to the registry beta: komira does not publish to beta";
    }

    // the prod set is staged by `mopm-stage`: it builds the version tool once, runs it once on its
    // own checkout with the run number before it stages, and tries the staged set at that version
    var psn: usize = 0;
    const prod_stage = (try jobLines(ar, text, PROD_STAGE_JOB, &psn)) orelse return "no job mopm-stage";
    if (psn != 1) return "mopm-stage is defined more than once";
    // it runs on every push and on a manual run: no condition of its own
    for (prod_stage) |l| {
        if (std.mem.startsWith(u8, l, "    if:")) return "mopm-stage has a condition: it runs on every push and on a manual run";
    }
    var builds: usize = 0;
    for (prod_stage) |l| {
        if (std.mem.indexOf(u8, l, TOOL) == null) continue;
        if (std.mem.eql(u8, l, BUILD_TOOL_LINE)) {
            builds += 1;
        } else if (!std.mem.eql(u8, l, PROD_REWRITE_RUN)) {
            return "mopm-stage names release_beta_version other than to build it and run it with the run number";
        }
    }
    if (builds != 1) return "mopm-stage does not build release_beta_version once";
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
    if (real.items.len != 2 or !std.mem.eql(u8, real.items[0], "push:") or !std.mem.eql(u8, real.items[1], "workflow_dispatch:"))
        return "on: is not exactly push and workflow_dispatch";
    // no schedule and no cron, even under another key
    for (on) |l| {
        const trimmed = std.mem.trim(u8, l, " ");
        if (trimmed.len > 0 and trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, l, "cron") != null or std.mem.indexOf(u8, l, "schedule") != null) return "on: names a schedule or a cron";
    }
    // a push run is in one concurrency group and no run is cancelled by another
    var gn: usize = 0;
    const conc = (try topLines(ar, text, "concurrency:", &gn)) orelse return "no concurrency block";
    if (gn != 1 or !has(conc, CONCURRENCY_GROUP)) return "concurrency: a push is not in the release-main group (and a manual run in no such group)";
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
    .{ .name = "prod-stage", .needs = "    needs: [release, mopm-stage]", .gate = PROD_GATE, .environment = "    environment: prod", .id_token = true },
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

test "release.yml holds the contract of the continuous prod publish" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    if (try check(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
}

test "each defect planted in the real release.yml (beta, switch, triggers, versions) is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);

    // no switch: a variable condition, a comment that names one, either spelling, is refused
    try expectRefused(ar, try replaced(ar, text, PROD_GATE ++ "\n", PROD_GATE ++ " && vars.MOPM_PUBLISH_ENABLED == 'true'\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, PROD_GATE ++ "\n", PROD_GATE ++ " && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n"), "MOPM_BETA_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_PUBLISH_ENABLED\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_BETA_PUBLISH_ENABLED\n"), "MOPM_BETA_PUBLISH_ENABLED");

    // no beta: each beta job that existed, and any line that stages against or holds the beta registry
    inline for (BETA_JOBS) |name| {
        try expectRefused(ar, try replaced(ar, text, "  prod-stage:\n", "  " ++ name ++ ":\n    runs-on: ubuntu-24.04\n\n  prod-stage:\n"), "still there");
    }
    try expectRefused(ar, try replaced(ar, text, " --out release/staged_set --registry prod'\n", " --out release/staged_set --registry beta'\n"), "registry beta");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta --oidc --no-commit'"), "registry beta");
    try expectRefused(ar, try replaced(ar, text, "    environment: build\n    timeout-minutes: 120\n    permissions:\n      contents: read\n      # for farm-connect only: the token Tailscale trusts\n      id-token: write\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ github.sha }}\n          persist-credentials: false\n      - uses: actions/download-artifact", "    environment: beta\n    timeout-minutes: 120\n    permissions:\n      contents: read\n      # for farm-connect only: the token Tailscale trusts\n      id-token: write\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: ${{ github.sha }}\n          persist-credentials: false\n      - uses: actions/download-artifact"), "registry beta");
    // a comment may say that there is no beta; a line may not do it
    try t.expect((try check(ar, try replaced(ar, text, "name: release\n", "name: release\n# no --registry beta and no environment: beta here\n"))) == null);

    // the version of this run: the rewrite is there, with the run number, before the stage, once
    const prod_rewrite_step = PROD_REWRITE_NAME ++ "\n        env:\n" ++ REWRITE_ENV ++ "\n" ++ REWRITE_RUN ++ "\n";
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, ""), "prod would publish fixed versions");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n        env:\n" ++ REWRITE_ENV ++ "\n        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version 0.1.0'\n"), "other than to build it");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n        env:\n          RUN_NUMBER: ${{ github.run_attempt }}\n" ++ REWRITE_RUN ++ "\n"), "mopm-stage: the rewrite step does not take the run number");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step, PROD_REWRITE_NAME ++ "\n" ++ REWRITE_RUN ++ "\n"), "mopm-stage: the rewrite step does not take the run number");
    try expectRefused(ar, try replaced(ar, text, prod_rewrite_step ++ "      # STAGE. Packs", prod_rewrite_step ++ prod_rewrite_step ++ "      # STAGE. Packs"), "more than once");
    try expectRefused(ar, try replaced(ar, text, PROD_REWRITE_NAME ++ "\n", "      - run: git push origin HEAD\n" ++ PROD_REWRITE_NAME ++ "\n"), "commits or pushes");
    // the rewrite after the stage, and before the tool is built
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, prod_rewrite_step, ""), PROD_MOPM_STAGE_RUN ++ "\n", PROD_MOPM_STAGE_RUN ++ "\n" ++ prod_rewrite_step), "runs release_beta_version after mopm stage");
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, prod_rewrite_step, ""), "      - name: build the version tool\n", prod_rewrite_step ++ "      - name: build the version tool\n"), "before it builds it");
    try expectRefused(ar, try replaced(ar, text, BUILD_TOOL_LINE ++ "\n", ""), "does not build release_beta_version once");
    // the e2e of mopm-stage is at that version
    const stage_e2e_tail = "\n          assert-remote: ${{ steps.assert.outputs.path }}\n      # Reads plan.json";
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_attempt }} //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    // mopm-stage runs on every push and on a manual run: it takes no condition
    try expectRefused(ar, try replaced(ar, text, "  mopm-stage:\n    runs-on: ubuntu-24.04\n", "  mopm-stage:\n    if: github.event_name == 'push'\n    runs-on: ubuntu-24.04\n"), "mopm-stage has a condition");

    // top-level permissions and the triggers
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\npermissions:\n  contents: write\n"), "top-level permissions is not");
    try expectRefused(ar, try replaced(ar, text, "\npermissions: {}\n", "\n"), "exactly once");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  pull_request_target:\n  workflow_dispatch:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "\n  workflow_dispatch:\n", "\n  workflow_dispatch:\n  workflow_call:\n"), "on: is not exactly");
    // no schedule: the nightly one that was removed, any cron, another spelling of it
    try expectRefused(ar, try replaced(ar, text, "\n  push:\n", "\n  schedule:\n    - cron: '17 3 * * *'\n  push:\n"), "on: is not exactly");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main]\n    cron: '17 3 * * *'\n"), "schedule or a cron");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main]\n    schedule: x\n"), "schedule or a cron");
    // a manual run never publishes: no manual run is in the release group, and a push run is in
    // one group that no other run cancels
    try expectRefused(ar, try replaced(ar, text, CONCURRENCY_GROUP, "  group: release-${{ (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, CONCURRENCY_GROUP, "  group: release-${{ github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, CONCURRENCY_GROUP, "  group: release-${{ github.run_id }}"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: false\n", "  cancel-in-progress: true\n"), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "  cancel-in-progress: false\n", ""), "concurrency");
    try expectRefused(ar, try replaced(ar, text, "    branches: [main]\n", "    branches: [main, 'release/**']\n"), "branches");
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
    const stage_head = "    needs: [release, mopm-stage]\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const test_head = "    needs: prod-stage\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: build\n";
    const commit_head = "    needs: prod-test\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const smoke_head = "    needs: prod-commit\n" ++ PROD_GATE ++ nl ++ runs ++ "    timeout-minutes: 30\n";
    const abort_head = "    needs: [prod-stage, prod-test, prod-commit]\n" ++ ABORT_IF ++ nl ++ runs ++ "    environment: prod\n";

    // the old token job is not back, and no job reads a secret
    try expectRefused(ar, try replaced(ar, text, "  prod-stage:\n", "  mopm-publish:\n    runs-on: ubuntu-24.04\n\n  prod-stage:\n"), "still there");
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
            // prod on the old nightly gate alone, on a manual run too, or with another condition
            "    if: github.event_name == 'schedule' && github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'push' || github.event_name == 'schedule') && github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'push' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'\n",
            "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && vars.X == 'true'\n",
            "    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'\n",
            "    if: (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'\n",
            "    if: always()\n",
            "",
        };
        for (wrong) |w| try expectRefused(ar, try replaced(ar, text, head, try swapGate(ar, head, w)), "the if is not the expected gate");
    }
    // the dependencies: the chain, and the abort sees all three jobs that can fail
    // prod stages only after the release build and the e2e of mopm-stage: exactly those two, no beta
    const stage_needs = "    needs: [release, mopm-stage]\n";
    const stage_needs_wrong = [_][]const u8{
        "    needs: [release, mopm-stage, mopm-e2e-beta]\n",
        "    needs: [release, mopm-stage, mopm-publish-beta]\n",
        "    needs: [release]\n",
        "    needs: mopm-stage\n",
        "    needs: [mopm-stage, release, prod-test]\n",
        "",
    };
    inline for (stage_needs_wrong) |w| try expectRefused(ar, try replaced(ar, text, stage_head, w ++ stage_head[stage_needs.len..]), "prod-stage: needs");
    try expectRefused(ar, try replaced(ar, text, test_head, "    needs: [prod-stage, release]\n" ++ test_head["    needs: prod-stage\n".len..]), "prod-test: needs");
    try expectRefused(ar, try replaced(ar, text, commit_head, "    needs: prod-stage\n" ++ commit_head["    needs: prod-test\n".len..]), "prod-commit: needs");
    try expectRefused(ar, try replaced(ar, text, smoke_head, "    needs: prod-test\n" ++ smoke_head["    needs: prod-commit\n".len..]), "prod-smoke: needs");
    try expectRefused(ar, try replaced(ar, text, abort_head, "    needs: prod-stage\n" ++ abort_head["    needs: [prod-stage, prod-test, prod-commit]\n".len..]), "prod-abort: needs");
    try expectRefused(ar, try replaced(ar, text, abort_head, "    needs: [prod-stage, prod-commit]\n" ++ abort_head["    needs: [prod-stage, prod-test, prod-commit]\n".len..]), "prod-abort: needs");
    // the abort condition: a failure or a cancel, the gate, and a stage that ran
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: always() && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: failure() && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, "    if: (failure() || cancelled()) && github.event_name == 'schedule' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'\n"), "prod-abort: the if");
    try expectRefused(ar, try replaced(ar, text, ABORT_IF ++ nl, ABORT_IF ++ " && vars.MOPM_PUBLISH_ENABLED == 'true'\n"), "MOPM_PUBLISH_ENABLED");

    // the environments: prod for the registry, build for the test, none for the smoke
    try expectRefused(ar, try replaced(ar, text, stage_head, stage_head[0 .. stage_head.len - "    environment: prod\n".len] ++ "    environment: build\n"), "prod-stage: environment");
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
    try expectRefused(ar, try replaced(ar, text, " --registry prod --oidc --no-commit'\n", " --registry gamma --oidc --no-commit'\n"), "prod-stage does not run");
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
    const pin = "toolchains//:mopm_0_0_86";
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_86 --out x", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("a toolchains//:mopm_0_0_86, b toolchains//:mopm_0_0_86.", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_81 --out x", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("toolchains//:mopm_0_0_86 then toolchains//:mopm_0_0_8", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("no label here", pin, "w", &buf)) != null);
    try t.expectEqualStrings("toolchains//:mopm_0_0_86", mopmPin("X = 1\nMOPM = \"toolchains//:mopm_0_0_86\"\n").?);
    try t.expect(mopmPin("# MOPM = \"x\"\n") == null);
}
