//! The cases of the mopm jobs of release.yml, //:release_workflow_cases:
//! a `zig_test` run as a build action. The workflow's own bytes are the subject
//! (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/release.yml).
//!
//! The publish is continuous: every push to main publishes the set `mopm-stage` staged to the
//! registry `beta` (`beta-stage`, `beta-test`, `beta-commit`, `beta-abort`) and then to the
//! registry `prod` (`prod-stage`, `prod-test`, `prod-commit`, `prod-abort`, `prod-smoke`,
//! `prod-add`). There is no switch: no line of the file, comment or not, names the variable
//! `MOPM_PUBLISH_ENABLED` or `MOPM_BETA_PUBLISH_ENABLED`. What the cases catch:
//!  - beta before prod: `prod-stage` needs `beta-commit` (exactly `release`, `mopm-stage` and
//!    `beta-commit`), so prod publishes only a set beta committed; the beta jobs, each job's
//!    registry and the beta environment are release_publish_group.zig's cases;
//!  - the prod jobs' gate is a push to main alone: a prod job that also runs on a manual run, a
//!    schedule or another ref, or that gains another condition, is red;
//!  - the triggers and the concurrency: `on:` is exactly a push to main and a manual run (no
//!    schedule, no cron, no pull request); a push run is in the group `release-main` and no run
//!    is cancelled, so two pushes never publish to prod at once; a manual run is in no such group;
//!  - the versions: `mopm-stage` (which stages the set prod publishes) gives every member the
//!    version 0.1.<run number> with the version tool, once, before the stage, from
//!    `github.run_number`, and the README e2e of `mopm-stage`, `beta-test` and `prod-test` is given that same
//!    number, so every release is a new version and prod publishes what the e2e passed on;
//!  - the packages of both platforms: `mopm-stage` builds //release:mopm_release_artifacts exactly once,
//!    before the version rewrite (which edits the manifests the build reads), with the macOS keys in the
//!    buckconfig farm-connect writes (`darwin-config-file`) and that this build alone names, so no other
//!    step of the job configures a macOS platform;
//!  - one build of every package per Mojo (1.1.0 and 1.2.0) at the one version of the run: `mopm-stage` builds
//!    the packages once for each (the second on the platform `linux-x86_64-mojo-1.2.0`, into its own
//!    directory), stages with `--artifacts 1.1.0=<dir> --artifacts 1.2.0=<dir>` and no `--compiler`, runs the
//!    README e2e for each Mojo (as do `beta-test` and `prod-test`, each under the 1.2.0 platform for the second run), and `prod-add` runs `release_staged_verify add --mojo`
//!    once for each, so a release that drops a Mojo from any of them is red;
//!  - no secret: no line outside a comment names `MOPM_TOKEN` or `secrets`;
//!  - the workflow's top-level `permissions` is `{}` (a job holds only what it names);
//!  - the prod publish, six jobs under one gate (`prod-stage`, `prod-test`,
//!    `prod-commit`, `prod-abort`, `prod-smoke`, `prod-add`; checkProd says what each must
//!    hold, and the four that stage, test, commit and abort a group hold what
//!    release_publish_group.zig's checkGroup holds for beta too): each job's `needs`, its exact `if:` (the push-to-main gate; the abort job's
//!    `failure() || cancelled()` condition with the gate and
//!    `needs.prod-stage.result != 'skipped'`), its environment (`prod` for the three
//!    that talk to the registry, `build` for the test, none for the smoke and the add), its
//!    exact permissions (`id-token: write` only where a registry identity is exchanged, or
//!    for farm-connect in the test), no secret anywhere in the file, the commands (the
//!    stage with `--oidc --no-commit`, the commit with `--oidc` and neither `--no-commit`
//!    nor `--abort`, the abort with `--abort`, the verify and the e2e on the verified
//!    set in the test, the smoke, the add with the mopm of mopm-stage on the committed
//!    directory), the order of the test's steps, that the test, the smoke and the add
//!    never name a registry-writing verb or the OIDC exchange, and that the smoke and the
//!    add never join the farm (the test joins it for the README e2e).
//!  - after each commit, `beta-served-readmes` and `prod-served-readmes` run the README e2e on what that
//!    registry serves (release_served_readmes.zig says what its cases catch).
//!  - the staged set outlives a rerun: every upload of `mopm-staged-<sha>` (the set `mopm-stage`
//!    hands to the beta and prod jobs), of `mopm-beta-staged-<sha>` (the directory `beta-stage` hands to
//!    `beta-test`, `beta-commit` and `beta-abort`) and of `mopm-prod-staged-<sha>` (the
//!    directory `prod-stage` hands to `prod-test`, `prod-commit` and `prod-abort`) names
//!    `retention-days` from 7 to 14, so `gh run rerun --failed` of a beta or prod job on a later day still
//!    downloads it; an upload of either with no `retention-days`, a value that is not a number, or
//!    one outside that range is red, and an artifact of neither name is not held to it;
//!  - one mopm: every `build toolchains//:mopm_*` label of release.yml and every such label of
//!    docs/ci.md equals `MOPM` of release/readme_e2e/packages.bzl (the mopm the README e2e installs
//!    with is the one the release stages and publishes with), so a bump of one that forgets
//!    the other, or the prose, is red.
//! The reader's own cases are workflow texts written here: each defect above
//! is written into the real text and must be refused with its message.
//!  - no wheel: release.yml holds no job `wheel` or `wheel-user-test`, no setup-python, no
//!    `//python:komira_wheel` target and no `pypi_smoke` (pypi.yml builds the wheel and installs it
//!    as a user does, on every push to main), so a per-merge wheel stage that comes back is red.

const std = @import("std");
const t = std.testing;
const group = @import("release_publish_group.zig");
const served = @import("release_served_readmes.zig");

const WHEEL_JOBS = [_][]const u8{ "wheel", "wheel-user-test" };
const WHEEL_WORDS = [_][]const u8{ "setup-python", "//python:komira_wheel", "pypi_smoke" };
const OLD_PROD_JOB = "mopm-publish";
const PROD_STAGE_JOB = "mopm-stage";
const TOOL = "release_beta_version";
const BUILD_TOOL_LINE = "          args: build //tools/build/ci:release_beta_version --out ${{ runner.temp }}/mopm-publish/release_beta_version";
const REWRITE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_beta_version\" --workspace-root src --version \"0.1.$RUN_NUMBER\"'";
const REWRITE_ENV = "          RUN_NUMBER: ${{ github.run_number }}";
const PROD_REWRITE_RUN = REWRITE_RUN;
// every beta and prod job runs on a push to main, and on nothing else
pub const PROD_GATE = "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'";
const CONCURRENCY_GROUP = "  group: release-${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'main' || format('ref-{0}', github.ref_name) }}";
const PROD_STAGE_NEEDS = "    needs: [release, mopm-stage, beta-commit]";
const ABORT_IF = "    if: (failure() || cancelled()) && github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.prod-stage.result != 'skipped'";
pub const PROD_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry prod --oidc --no-commit'";
pub const PROD_COMMIT_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc'";
pub const PROD_ABORT_CMD = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$GITHUB_WORKSPACE/mopm-prod/staged\" --registry prod --oidc --abort'";
pub const PROD_STAGED_ARTIFACT = "          name: mopm-prod-staged-${{ github.sha }}";
pub const PROD_BUILD_VERIFY = "          args: build //tools/build/ci:release_staged_verify --out ${{ runner.temp }}/prod-test/release_staged_verify";
pub const PROD_VERIFY_RUN = "        run: '\"$RUNNER_TEMP/prod-test/release_staged_verify\" verify --staged \"$RUNNER_TEMP/prod-test/staged\" --out release/staged_set'";
pub const PROD_E2E_RUN = "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all";
const STAGE_E2E_RUN = PROD_E2E_RUN;
// The same e2e with Mojo 1.2.0: the platform names every Mojo rule's compiler, and the staged set holds both builds.
const NEXT_PLATFORM = "--target-platforms komira//tools/build/platforms:linux-x86_64-mojo-1.2.0";
pub const PROD_E2E_NEXT = "          args: build " ++ NEXT_PLATFORM ++ " -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all";
const STAGE_E2E_NEXT = PROD_E2E_NEXT;
const PROD_REWRITE_NAME = "      - name: every member gets the version of this run";
const PROD_MOPM_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"1.1.0=$RUNNER_TEMP/mopm-publish/artifacts-1.1.0\" --artifacts \"1.2.0=$RUNNER_TEMP/mopm-publish/artifacts-1.2.0\" --out release/staged_set --registry prod'";
const PROD_SMOKE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.mopm.dev/index/config.json --attempts 5 --delay 30'";
const PROD_ADD_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" add --staged \"$RUNNER_TEMP/prod-add/committed\" --mopm \"$RUNNER_TEMP/mopm-publish/mopm\" --work \"$RUNNER_TEMP/prod-add/work-1.1.0\" --mojo 1.1.0'";
const PROD_ADD_NEXT_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" add --staged \"$RUNNER_TEMP/prod-add/committed\" --mopm \"$RUNNER_TEMP/mopm-publish/mopm\" --work \"$RUNNER_TEMP/prod-add/work-1.2.0\" --mojo 1.2.0'";
// The packages of both platforms in the one directory `mopm stage --artifacts` reads; the only step that names the
// buckconfig of the macOS keys (MAC_CONFIG_INPUT writes it), so no other step of mopm-stage configures a macOS platform.
const PACKAGES_BUILD = "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig -c komira_release.mac_tree=true //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts-1.1.0";
// The same build with Mojo 1.2.0, into the directory of that compiler (`mopm stage --artifacts 1.2.0=<directory>`).
const PACKAGES_BUILD_NEXT = "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig -c komira_release.mac_tree=true " ++ NEXT_PLATFORM ++ " //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts-1.2.0";
const MAC_CONFIG_INPUT = "          darwin-config-file: ${{ runner.temp }}/darwin.buckconfig";
const MAC_CONFIG_FILE = "darwin.buckconfig";
const STAGE_BUILD_VERIFY = "          args: build //tools/build/ci:release_staged_verify --out ${{ runner.temp }}/mopm-publish/release_staged_verify";
const STAGE_UPLOAD_VERIFY = "            ${{ runner.temp }}/mopm-publish/release_staged_verify";
pub const E2E_FARM_CONNECT = "      - uses: ./.github/actions/farm-connect";
pub const E2E_ASSERT = "          assert-remote: ${{ steps.assert.outputs.path }}";
// The artifacts a prod job downloads from an earlier job of the same run. A rerun of a failed prod job (after
// a registry 429 near the start of a UTC day, say) downloads them again, so each is kept long enough for a
// rerun on a later day, and no longer than the release set itself (14 days).
const STAGED_ARTIFACTS = [_][]const u8{ "mopm-staged-", "mopm-beta-staged-", "mopm-prod-staged-" };
const UPLOAD_STEP = "      - uses: actions/upload-artifact@";
const STAGED_RETENTION_MIN: u32 = 7;
const STAGED_RETENTION_MAX: u32 = 14;

/// The lines of the job `name` of the `jobs:` map (a key at two spaces of
/// indent), without comment lines and blank lines, or null if there is no such
/// job. Counts the jobs of that name in `count`.
pub fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8, count: *usize) !?[]const []const u8 {
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

pub fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

pub fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

pub fn mentions(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

/// Null if the workflow text holds the contract, else the refusal.
pub fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    // no switch: the prod publish runs on every push. The names are refused anywhere in the file,
    // in a comment too, so the file cannot describe a switch that is not there.
    if (std.mem.indexOf(u8, text, "MOPM_PUBLISH_ENABLED") != null) return "release.yml names MOPM_PUBLISH_ENABLED: the prod publish has no switch";
    if (std.mem.indexOf(u8, text, "MOPM_BETA_PUBLISH_ENABLED") != null) return "release.yml names MOPM_BETA_PUBLISH_ENABLED: the beta publish has no switch";
    // no wheel stage: pypi.yml builds the wheel and installs it as a user does, on every push
    for (WHEEL_JOBS) |name| {
        var wn: usize = 0;
        if ((try jobLines(ar, text, name, &wn)) != null) return try std.fmt.allocPrint(ar, "the job {s} is still there: pypi.yml tests the wheel, release.yml holds no wheel stage", .{name});
    }
    var wit = std.mem.splitScalar(u8, text, '\n');
    while (wit.next()) |l| {
        const code = std.mem.trim(u8, l, " ");
        if (code.len == 0 or code[0] == '#') continue;
        for (WHEEL_WORDS) |word| {
            if (std.mem.indexOf(u8, code, word) != null) return try std.fmt.allocPrint(ar, "a line names {s}: release.yml holds no wheel stage", .{word});
        }
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
    // the packages of both platforms, built once, before the rewrite edits the manifests the build reads, with the
    // macOS keys in a file of their own that only this step names
    var package_builds: usize = 0;
    var next_builds: usize = 0;
    var config_lines: usize = 0;
    for (prod_stage) |l| {
        if (std.mem.eql(u8, l, PACKAGES_BUILD)) package_builds += 1;
        if (std.mem.eql(u8, l, PACKAGES_BUILD_NEXT)) next_builds += 1;
        if (std.mem.indexOf(u8, l, MAC_CONFIG_FILE) != null) config_lines += 1;
    }
    if (package_builds != 1) return "mopm-stage does not build the packages of both platforms (//release:mopm_release_artifacts, with the macOS keys' buckconfig) exactly once";
    if (next_builds != 1) return "mopm-stage does not build the packages of both platforms for the second Mojo (--target-platforms ...mojo-1.2.0, into artifacts-1.2.0) exactly once";
    if (lineAt(prod_stage, PACKAGES_BUILD).? > prod_rewrite_at) return "mopm-stage builds the packages after it rewrites their versions: the build would read the rewritten manifests";
    if (lineAt(prod_stage, PACKAGES_BUILD_NEXT).? > prod_rewrite_at) return "mopm-stage builds the packages for the second Mojo after it rewrites their versions: the build would read the rewritten manifests";
    if (lineAt(prod_stage, MAC_CONFIG_INPUT) == null) return "mopm-stage's farm connection writes the macOS keys into the machine buckconfig (no darwin-config-file): every step of the job would configure a macOS platform";
    if (config_lines != 3) return "a step of mopm-stage other than the two builds of the packages names the macOS keys' buckconfig: only those builds configure a macOS platform";
    const stage_e2e_at = lineAt(prod_stage, STAGE_E2E_RUN) orelse return "mopm-stage does not run the e2e on the staged set at this run's version (staged=stage, beta_version=0.1.<run number>)";
    if (stage_e2e_at < prod_stage_at) return "mopm-stage runs the e2e before it stages";
    const stage_e2e_next_at = lineAt(prod_stage, STAGE_E2E_NEXT) orelse return "mopm-stage does not run the e2e on the staged set for the second Mojo (--target-platforms ...mojo-1.2.0, staged=stage, beta_version=0.1.<run number>)";
    if (stage_e2e_next_at < prod_stage_at) return "mopm-stage runs the e2e for the second Mojo before it stages";

    if (try checkProd(ar, text, prod_stage)) |why| return why;
    if (try group.checkBeta(ar, text)) |why| return why;
    if (try checkStagedRetention(ar, text)) |why| return why;
    if (try served.checkServed(ar, text)) |why| return why;

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


/// One job's `needs`, gate, environment and permissions: the prod jobs below and the beta jobs of
/// release_publish_group.zig.
pub const JobSpec = struct {
    name: []const u8,
    needs: []const u8,
    gate: []const u8,
    /// The exact `environment:` line, or null: the job holds none.
    environment: ?[]const u8,
    /// Whether the job holds `id-token: write` besides `contents: read`.
    id_token: bool,
};

/// The six jobs of the prod publish. What each must hold is below; `prod_stage` is the job `mopm-stage`
/// (it builds the verify tool and hands it on in its artifact).
const prod_jobs = [_]JobSpec{
    .{ .name = "prod-stage", .needs = PROD_STAGE_NEEDS, .gate = PROD_GATE, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-test", .needs = "    needs: prod-stage", .gate = PROD_GATE, .environment = "    environment: build", .id_token = true },
    .{ .name = "prod-commit", .needs = "    needs: prod-test", .gate = PROD_GATE, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-abort", .needs = "    needs: [prod-stage, prod-test, prod-commit]", .gate = ABORT_IF, .environment = "    environment: prod", .id_token = true },
    .{ .name = "prod-smoke", .needs = "    needs: prod-commit", .gate = PROD_GATE, .environment = null, .id_token = false },
    .{ .name = "prod-add", .needs = "    needs: [prod-commit, prod-smoke]", .gate = PROD_GATE, .environment = null, .id_token = false },
};

/// What none of the lines of the test, smoke and add jobs may contain: they send nothing to a registry and
/// ask for no identity (a mopm verb that writes, the OIDC exchange, a hand-made PUT or POST).
pub const prod_readonly_forbidden = [_][]const u8{ "mopm publish", "--oidc", "--abort", "--no-commit", "yank", "login", "curl", "wget", "-X PUT", "-X POST", "--request", "--data", "--upload-file" };

fn countPerms(job: []const []const u8) usize {
    var perms: usize = 0;
    for (job) |l| {
        if (std.mem.startsWith(u8, l, "      ") and !std.mem.startsWith(u8, l, "       ") and
            (std.mem.indexOf(u8, l, ": read") != null or std.mem.indexOf(u8, l, ": write") != null)) perms += 1;
    }
    return perms;
}

/// Null if every job of `specs` is there once with exactly its needs, gate, environment and permissions and
/// ignores no failure, else the refusal.
pub fn checkJobs(ar: std.mem.Allocator, text: []const u8, specs: []const JobSpec) !?[]const u8 {
    for (specs) |spec| {
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
    return null;
}

/// The stage, test, commit and abort of the prod group (release_publish_group.zig's checkGroup).
const PROD_GROUP = group.Group{
    .registry = "prod",
    .stage_run = PROD_STAGE_RUN,
    .staged_artifact = PROD_STAGED_ARTIFACT,
    .build_verify = PROD_BUILD_VERIFY,
    .verify_run = PROD_VERIFY_RUN,
    .e2e_run = PROD_E2E_RUN,
    .e2e_next_run = PROD_E2E_NEXT,
    .commit_run = PROD_COMMIT_RUN,
    .abort_cmd = PROD_ABORT_CMD,
};

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

    // prod stages only a set beta committed: prod-stage's needs name beta-commit
    var pn: usize = 0;
    const prod_stage = (try jobLines(ar, text, "prod-stage", &pn)) orelse return "no job prod-stage";
    var needs_beta = false;
    for (prod_stage) |l| if (std.mem.startsWith(u8, l, "    needs:") and std.mem.indexOf(u8, l, "beta-commit") != null) {
        needs_beta = true;
    };
    if (!needs_beta) return "prod-stage does not need beta-commit: prod would publish a set beta did not commit";

    if (try checkJobs(ar, text, &prod_jobs)) |why| return why;
    if (try group.checkGroup(ar, text, PROD_GROUP)) |why| return why;

    var scratch: usize = 0;
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

    const add = (try jobLines(ar, text, "prod-add", &scratch)).?;
    for (add) |l| {
        if (std.mem.eql(u8, l, "    needs: [prod-commit, prod-smoke]") or std.mem.eql(u8, l, PROD_GATE)) continue;
        for (prod_readonly_forbidden) |w| {
            if (std.ascii.indexOfIgnoreCase(l, w) != null) return "prod-add yanks, publishes or exchanges an identity: it only adds and installs";
        }
    }
    if (mentions(add, "farm") or mentions(add, "buck2")) return "prod-add joins the farm or runs buck2";
    const add_at = lineAt(add, PROD_ADD_RUN) orelse return "prod-add does not run release_staged_verify add with the mopm of mopm-stage on the committed directory";
    const add_next_at = lineAt(add, PROD_ADD_NEXT_RUN) orelse return "prod-add does not run release_staged_verify add for the second Mojo (--mojo 1.2.0) on the committed directory";
    const add_dl = lineAt(add, "          name: mopm-prod-committed-${{ github.sha }}") orelse return "prod-add does not download the committed directory";
    if (!(add_dl < add_at and add_dl < add_next_at)) return "prod-add adds before it has the committed directory";
    var add_runs: usize = 0;
    for (add) |l| if (std.mem.indexOf(u8, l, "release_staged_verify\" add ") != null) {
        add_runs += 1;
    };
    if (add_runs != 2) return "prod-add runs release_staged_verify other than once for each Mojo (1.1.0 and 1.2.0)";
    return null;
}

/// Null if every upload of a staged artifact (STAGED_ARTIFACTS) keeps it from STAGED_RETENTION_MIN to
/// STAGED_RETENTION_MAX days and each is uploaded, else the refusal. A step is the `upload-artifact` line
/// and the lines after it indented deeper than the step's dash; comment and blank lines are skipped. The
/// artifact's name and retention are the `with:` keys; an upload step whose `uses:` is not its first line is
/// not read (release.yml writes none).
fn checkStagedRetention(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var uploads = [_]usize{0} ** STAGED_ARTIFACTS.len;
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const code = std.mem.trim(u8, l, " ");
        if (code.len == 0 or code[0] == '#') continue;
        try lines.append(ar, l);
    }
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        if (!std.mem.startsWith(u8, lines.items[i], UPLOAD_STEP)) continue;
        var name: ?[]const u8 = null;
        var retention: ?[]const u8 = null;
        var j = i + 1;
        while (j < lines.items.len and std.mem.startsWith(u8, lines.items[j], "        ")) : (j += 1) {
            // the keys of `with:` (ten spaces), never the step's own `name:` (eight)
            const l = lines.items[j];
            if (!std.mem.startsWith(u8, l, "          ") or l.len > 10 and l[10] == ' ') continue;
            const field = l[10..];
            if (std.mem.startsWith(u8, field, "name:")) name = std.mem.trim(u8, field["name:".len..], " '\"");
            if (std.mem.startsWith(u8, field, "retention-days:")) retention = std.mem.trim(u8, field["retention-days:".len..], " '\"");
        }
        const n = name orelse continue;
        for (STAGED_ARTIFACTS, 0..) |prefix, k| {
            if (!std.mem.startsWith(u8, n, prefix)) continue;
            uploads[k] += 1;
            const r = retention orelse return try std.fmt.allocPrint(ar, "the upload of {s} names no retention-days: it is kept 90 days, not {d} to {d}", .{ n, STAGED_RETENTION_MIN, STAGED_RETENTION_MAX });
            const days = std.fmt.parseInt(u32, r, 10) catch return try std.fmt.allocPrint(ar, "the upload of {s} has retention-days {s}, not a number of days", .{ n, r });
            if (days < STAGED_RETENTION_MIN or days > STAGED_RETENTION_MAX)
                return try std.fmt.allocPrint(ar, "the upload of {s} has retention-days {d}, not {d} to {d}: a rerun of a failed prod job on a later day must still download it", .{ n, days, STAGED_RETENTION_MIN, STAGED_RETENTION_MAX });
        }
    }
    for (STAGED_ARTIFACTS, 0..) |prefix, k| {
        if (uploads[k] == 0) return try std.fmt.allocPrint(ar, "no upload-artifact step uploads {s}<sha>", .{prefix});
    }
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

pub fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "workflows", "release.yml" });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

pub fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const got = (try check(ar, text)) orelse {
        std.debug.print("accepted a workflow that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

pub fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
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

test "each defect written into the real release.yml (beta, switch, triggers, versions) is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);

    // no switch: a variable condition, a comment that names one, either spelling, is refused
    try expectRefused(ar, try replaced(ar, text, PROD_GATE ++ "\n", PROD_GATE ++ " && vars.MOPM_PUBLISH_ENABLED == 'true'\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, PROD_GATE ++ "\n", PROD_GATE ++ " && vars.MOPM_BETA_PUBLISH_ENABLED == 'true'\n"), "MOPM_BETA_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_PUBLISH_ENABLED\n"), "MOPM_PUBLISH_ENABLED");
    try expectRefused(ar, try replaced(ar, text, "name: release\n", "name: release\n# gated on MOPM_BETA_PUBLISH_ENABLED\n"), "MOPM_BETA_PUBLISH_ENABLED");

    // S is staged against prod, and only the beta jobs name the registry beta: mopm-stage and prod-stage
    // on beta are refused
    try expectRefused(ar, try replaced(ar, text, " --out release/staged_set --registry prod'\n", " --out release/staged_set --registry beta'\n"), "mopm-stage does not stage against prod");
    try expectRefused(ar, try replaced(ar, text, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged release/staged_set --registry prod --dry-run'\n", "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged release/staged_set --registry beta --dry-run'\n"), "mopm-stage names a registry other than prod");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry beta --oidc --no-commit'"), "prod-stage does not run publish --staged --registry prod --oidc --no-commit");
    // a comment may name the registry beta anywhere; a line names it only in a beta job
    try t.expect((try check(ar, try replaced(ar, text, "name: release\n", "name: release\n# --registry beta and environment: beta are the beta jobs'\n"))) == null);

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
    const stage_e2e_tail = "\n          assert-remote: ${{ steps.assert.outputs.path }}\n      - name: the README e2e against the staged set for Mojo 1.2.0";
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN ++ stage_e2e_tail, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_attempt }} //release/readme_e2e/verify:all" ++ stage_e2e_tail), "mopm-stage does not run the e2e on the staged set at this run's version");
    // and the e2e with Mojo 1.2.0 is there too, at that version, on the platform of that Mojo, after the stage
    const stage_e2e_next_tail = "\n          assert-remote: ${{ steps.assert.outputs.path }}\n      # Reads plan.json";
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_NEXT ++ stage_e2e_next_tail, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all" ++ stage_e2e_next_tail), "mopm-stage does not run the e2e on the staged set for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_NEXT ++ stage_e2e_next_tail, "          args: build " ++ NEXT_PLATFORM ++ " -c komira_release.staged=stage //release/readme_e2e/verify:all" ++ stage_e2e_next_tail), "mopm-stage does not run the e2e on the staged set for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_NEXT ++ stage_e2e_next_tail, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} " ++ NEXT_PLATFORM ++ " //release/readme_e2e/verify:all" ++ stage_e2e_next_tail), "mopm-stage does not run the e2e on the staged set for the second Mojo");
    // the stage packs a build for each Mojo: `--artifacts 1.1.0=<dir> --artifacts 1.2.0=<dir>`, no `--compiler`
    try expectRefused(ar, try replaced(ar, text, PROD_MOPM_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts-1.1.0\" --compiler 1.1.0 --out release/staged_set --registry prod'"), "does not stage against prod");
    try expectRefused(ar, try replaced(ar, text, PROD_MOPM_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"1.1.0=$RUNNER_TEMP/mopm-publish/artifacts-1.1.0\" --out release/staged_set --registry prod'"), "does not stage against prod");
    try expectRefused(ar, try replaced(ar, text, PROD_MOPM_STAGE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"1.1.0=$RUNNER_TEMP/mopm-publish/artifacts-1.1.0\" --artifacts \"1.2.0=$RUNNER_TEMP/mopm-publish/artifacts-1.1.0\" --out release/staged_set --registry prod'"), "does not stage against prod");
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

test "release.yml holds no wheel stage, and a wheel job or a wheel line written back in is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    inline for (WHEEL_JOBS) |name| {
        var n: usize = 0;
        try t.expect((try jobLines(ar, text, name, &n)) == null);
        try expectRefused(ar, try replaced(ar, text, "  prod-stage:\n", "  " ++ name ++ ":\n    runs-on: ubuntu-24.04\n\n  prod-stage:\n"), "still there");
    }
    inline for (WHEEL_WORDS) |word| {
        try t.expect(std.mem.indexOf(u8, text, "uses: " ++ word) == null);
        try expectRefused(ar, try replaced(ar, text, "  prod-stage:\n", "  prod-stage:\n    # x\n    env: " ++ word ++ "\n"), word);
    }
    // a comment may say where the wheel is tested; a line may not hold a wheel stage
    try t.expect((try check(ar, try replaced(ar, text, "name: release\n", "name: release\n# the wheel: pypi.yml, pypi_smoke, setup-python\n"))) == null);
}

/// `head` with its prod gate line replaced by `to` (a whole line with its newline, or nothing).
pub fn swapGate(ar: std.mem.Allocator, head: []const u8, to: []const u8) ![]const u8 {
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
    const stage_head = PROD_STAGE_NEEDS ++ nl ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const test_head = "    needs: prod-stage\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: build\n";
    const commit_head = "    needs: prod-test\n" ++ PROD_GATE ++ nl ++ runs ++ "    environment: prod\n";
    const smoke_head = "    needs: prod-commit\n" ++ PROD_GATE ++ nl ++ runs ++ "    timeout-minutes: 30\n";
    const abort_head = "    needs: [prod-stage, prod-test, prod-commit]\n" ++ ABORT_IF ++ nl ++ runs ++ "    environment: prod\n";
    const add_head = "    needs: [prod-commit, prod-smoke]\n" ++ PROD_GATE ++ nl ++ runs ++ "    timeout-minutes: 30\n";

    // the old token job is not back, and no job reads a secret
    try expectRefused(ar, try replaced(ar, text, "  prod-stage:\n", "  mopm-publish:\n    runs-on: ubuntu-24.04\n\n  prod-stage:\n"), "still there");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_RUN ++ nl, "        env:\n          MOPM_TOKEN: x\n" ++ PROD_STAGE_RUN ++ nl), "reads a secret");
    try expectRefused(ar, try replaced(ar, text, PROD_VERIFY_RUN ++ nl, "        env:\n          X: ${{ secrets.OTHER }}\n" ++ PROD_VERIFY_RUN ++ nl), "reads a secret");
    // the verify tool is built once by mopm-stage and handed on
    try expectRefused(ar, try replaced(ar, text, STAGE_BUILD_VERIFY ++ nl, ""), "build release_staged_verify once");
    try expectRefused(ar, try replaced(ar, text, STAGE_UPLOAD_VERIFY ++ nl, ""), "hand release_staged_verify");

    // the gate of each job, and the whole if
    const gates = [_][]const u8{ stage_head, test_head, commit_head, smoke_head, add_head };
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
    // prod stages only after the release build, the e2e of mopm-stage and the beta commit: exactly those three
    const stage_needs = PROD_STAGE_NEEDS ++ nl;
    // without beta-commit, prod would publish a set beta did not commit (or did not stage at all)
    const stage_needs_no_beta = [_][]const u8{
        "    needs: [release, mopm-stage]\n",
        "    needs: [release, mopm-stage, beta-test]\n",
        "    needs: [release, mopm-stage, beta-stage]\n",
        "    needs: [release, mopm-stage, beta-abort]\n",
        "",
    };
    inline for (stage_needs_no_beta) |w| try expectRefused(ar, try replaced(ar, text, stage_head, w ++ stage_head[stage_needs.len..]), "prod-stage does not need beta-commit: prod would publish a set beta did not commit");
    // beta-commit, but not exactly the three
    const stage_needs_wrong = [_][]const u8{
        "    needs: beta-commit\n",
        "    needs: [release, beta-commit]\n",
        "    needs: [mopm-stage, beta-commit]\n",
        "    needs: [release, mopm-stage, beta-commit, prod-test]\n",
    };
    inline for (stage_needs_wrong) |w| try expectRefused(ar, try replaced(ar, text, stage_head, w ++ stage_head[stage_needs.len..]), "prod-stage: needs is not exactly `needs: [release, mopm-stage, beta-commit]`");
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
    // prod-test runs the e2e for the second Mojo too, on the same verified set at the version of the run
    const e2e_next_step = "      - name: the README e2e against the staged files for Mojo 1.2.0\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ PROD_E2E_NEXT ++ nl ++ E2E_ASSERT ++ nl;
    try expectRefused(ar, try replaced(ar, text, e2e_next_step, ""), "does not run the e2e on the verified set for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PROD_E2E_NEXT, "          args: build -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all"), "for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, verify_step ++ e2e_step ++ e2e_next_step, e2e_next_step ++ verify_step ++ e2e_step), "runs the e2e for the second Mojo before the verification");
    try expectRefused(ar, try replaced(ar, text, e2e_next_step, e2e_next_step ++ "        continue-on-error: true\n"), "prod-test ignores a failure");
    try expectRefused(ar, try replaced(ar, text, verify_step, verify_step ++ "      - run: cp x release/staged_set/y\n"), "other than in the one verify step");
    try expectRefused(ar, try replaced(ar, text, verify_step, verify_step ++ verify_step), "other than in the one verify step");
    try expectRefused(ar, try replaced(ar, text, PROD_E2E_RUN ++ nl ++ E2E_ASSERT ++ nl, PROD_E2E_RUN ++ nl), "not asserted remote");
    try expectRefused(ar, try replaced(ar, text, PROD_BUILD_VERIFY ++ nl ++ E2E_ASSERT ++ nl, PROD_BUILD_VERIFY ++ nl), "not asserted remote");
    try expectRefused(ar, try replaced(ar, text, e2e_step, e2e_step ++ "        continue-on-error: true\n"), "prod-test ignores a failure");
    const writers = [_][]const u8{ "mopm publish --staged x --registry prod", "mopm yank hashing 0.1.1", "mopm login --registry prod", "curl -X PUT https://x.test/y", "curl --request POST https://x.test/y", "wget --post-data=x https://x.test/y", "mopm-x --oidc" };
    inline for (writers) |cmd| try expectRefused(ar, try replaced(ar, text, e2e_step, "      - run: " ++ cmd ++ "\n" ++ e2e_step), "prod-test publishes, yanks");

    // the commit: the same command without --no-commit, on the directory prod-stage kept, with an identity of its own
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod --oidc --no-commit'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-prod/staged\" --registry prod'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$RUNNER_TEMP/mopm-publish/staged\" --registry prod --oidc'"), "prod-commit does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, PROD_COMMIT_RUN ++ nl ++ "      - run: \"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged x --registry prod --oidc --abort"), "prod-commit does not commit");
    try expectRefused(ar, try replaced(ar, text, "          name: mopm-prod-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n", "          name: mopm-prod-nothing-${{ github.sha }}\n          path: ${{ runner.temp }}/mopm-prod/staged\n      - name: mopm is executable\n        run: chmod +x \"$RUNNER_TEMP/mopm-publish/mopm\"\n      - name: mopm publish --staged --oidc\n"), "prod-commit does not download the directory");
    try expectRefused(ar, try replaced(ar, text, PROD_COMMIT_RUN, PROD_COMMIT_RUN ++ nl ++ "      - run: ./buck2 build //x"), "prod-commit joins the farm");

    // the abort: --abort, on the directory with the state, once
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$GITHUB_WORKSPACE/mopm-prod/staged\" --registry prod --oidc'"), "prod-abort does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" publish --staged \"$GITHUB_WORKSPACE/mopm-prod/staged\" --registry prod --oidc --abort --no-commit'"), "prod-abort does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_ABORT_CMD, PROD_ABORT_CMD ++ "\n            mopm yank --group g --registry prod --reason x"), "stages, dry-runs or yanks");

    // the smoke: reads the committed directory and the prod index, and only reads
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.beta.mopm.dev/index/config.json --attempts 5 --delay 30'"), "prod-smoke does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" smoke --staged \"$RUNNER_TEMP/prod-smoke/committed\" --config-url https://api.mopm.dev/index/config.json --attempts 5 --delay 30 || true'"), "prod-smoke ignores a failure");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - run: mopm yank --group g --registry prod --reason x"), "only reads");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - run: ./mopm publish --staged x --registry prod --oidc"), "only reads");
    try expectRefused(ar, try replaced(ar, text, PROD_SMOKE_RUN, PROD_SMOKE_RUN ++ "\n      - uses: ./.github/actions/farm-connect"), "prod-smoke joins the farm");

    // the add: after the commit and the smoke, no environment and no identity, the pinned mopm on the committed
    // directory, once, and it only adds and installs
    try expectRefused(ar, try replaced(ar, text, add_head, "    needs: prod-commit\n" ++ add_head["    needs: [prod-commit, prod-smoke]\n".len..]), "prod-add: needs");
    try expectRefused(ar, try replaced(ar, text, add_head, "    needs: [prod-test, prod-smoke]\n" ++ add_head["    needs: [prod-commit, prod-smoke]\n".len..]), "prod-add: needs");
    try expectRefused(ar, try replaced(ar, text, add_head, add_head[0 .. add_head.len - "    timeout-minutes: 30\n".len] ++ "    environment: prod\n    timeout-minutes: 30\n"), "prod-add holds an environment");
    try expectRefused(ar, try replaced(ar, text, add_head ++ "    permissions:\n      contents: read\n", add_head ++ "    permissions:\n      contents: read\n      id-token: write\n"), "prod-add: id-token: write is held");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" add --staged \"$RUNNER_TEMP/mopm-publish/staged\" --mopm \"$RUNNER_TEMP/mopm-publish/mopm\" --work \"$RUNNER_TEMP/prod-add/work\"'"), "prod-add does not run");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" add --staged \"$RUNNER_TEMP/prod-add/committed\" --mopm mopm --work \"$RUNNER_TEMP/prod-add/work\"'"), "prod-add does not run");

    // mopm-stage builds the packages of both platforms, before the rewrite, with the macOS keys in a file of their own
    const linux_only = "          args: build //release:mopm_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts";
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD, linux_only), "does not build the packages of both platforms");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD, "          args: build //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts"), "does not build the packages of both platforms");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD, PACKAGES_BUILD ++ nl ++ PACKAGES_BUILD), "does not build the packages of both platforms");
    // the second Mojo's build: once, on the platform of that Mojo, into the directory `mopm stage` reads for it, before the rewrite
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD_NEXT, PACKAGES_BUILD_NEXT ++ nl ++ PACKAGES_BUILD_NEXT), "for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD_NEXT, try replaced(ar, PACKAGES_BUILD_NEXT, " " ++ NEXT_PLATFORM, "")), "for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD_NEXT, try replaced(ar, PACKAGES_BUILD_NEXT, "artifacts-1.2.0", "artifacts-1.1.0")), "for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD_NEXT, try replaced(ar, PACKAGES_BUILD_NEXT, " -c komira_release.mac_tree=true", "")), "for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD_NEXT ++ nl, ""), "for the second Mojo");
    // without the gate the target is incompatible, and the build would build nothing of either platform
    try expectRefused(ar, try replaced(ar, text, PACKAGES_BUILD, "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig //release:mopm_release_artifacts --out ${{ runner.temp }}/mopm-publish/artifacts"), "does not build the packages of both platforms");
    try expectRefused(ar, try replaced(ar, text, MAC_CONFIG_INPUT ++ nl, ""), "no darwin-config-file");
    try expectRefused(ar, try replaced(ar, text, STAGE_E2E_RUN, "          args: build --config-file ${{ runner.temp }}/darwin.buckconfig -c komira_release.staged=stage -c komira_release.beta_version=0.1.${{ github.run_number }} //release/readme_e2e/verify:all"), "names the macOS keys' buckconfig");
    const rewrite_step = PROD_REWRITE_NAME ++ "\n        env:\n" ++ REWRITE_ENV ++ "\n" ++ PROD_REWRITE_RUN ++ "\n";
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, rewrite_step, ""), "      - name: build the packages\n", rewrite_step ++ "      - name: build the packages\n"), "the packages after it rewrites");
    try expectRefused(ar, try replaced(ar, try replaced(ar, text, rewrite_step, ""), "      - name: build the packages for Mojo 1.2.0\n", rewrite_step ++ "      - name: build the packages for Mojo 1.2.0\n"), "for the second Mojo after it rewrites");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ " || true"), "prod-add ignores a failure");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ "\n        continue-on-error: true"), "prod-add ignores a failure");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ "\n      - run: ./mopm publish --staged x --registry prod --oidc"), "it only adds and installs");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ "\n      - run: mopm login"), "it only adds and installs");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ "\n      - uses: ./.github/actions/farm-connect"), "prod-add joins the farm");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_RUN, PROD_ADD_RUN ++ nl ++ PROD_ADD_RUN), "other than once for each Mojo");
    // one add for each Mojo of the release: the second one cannot be dropped, repeated for the first Mojo, or be for another
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_NEXT_RUN ++ nl, ""), "does not run release_staged_verify add for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_NEXT_RUN, PROD_ADD_RUN), "does not run release_staged_verify add for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_NEXT_RUN, try replaced(ar, PROD_ADD_NEXT_RUN, "--mojo 1.2.0", "--mojo 1.1.0")), "does not run release_staged_verify add for the second Mojo");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_NEXT_RUN, PROD_ADD_NEXT_RUN ++ " || true"), "prod-add ignores a failure");
    try expectRefused(ar, try replaced(ar, text, PROD_ADD_NEXT_RUN, PROD_ADD_NEXT_RUN ++ nl ++ PROD_ADD_NEXT_RUN), "other than once for each Mojo");
    const add_dl = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n          name: mopm-prod-committed-${{ github.sha }}\n          path: ${{ runner.temp }}/prod-add/committed\n";
    try expectRefused(ar, try replaced(ar, text, add_dl, "      - name: early\n" ++ PROD_ADD_RUN ++ nl ++ add_dl), "adds before it has the committed directory");
    try expectRefused(ar, try replaced(ar, text, "          name: mopm-prod-committed-${{ github.sha }}\n          path: ${{ runner.temp }}/prod-add/committed\n", "          name: mopm-prod-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/prod-add/committed\n"), "prod-add does not download the committed directory");
}

test "an upload of the staged set kept fewer than 7 or more than 14 days, or with no number, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    // the upload of mopm-stage (the set), of beta-stage and of prod-stage (each a directory with
    // state.json); each anchor is the one upload of that artifact in release.yml
    // (the lines `before` and `after` the retention line, which the case replaces)
    const dir_tail = "          path: ${{ runner.temp }}/mopm-publish/staged\n          if-no-files-found: error\n";
    const Case = struct { before: []const u8, name: []const u8, after: []const u8 };
    const cases = [_]Case{
        .{ .before = "", .name = "mopm-staged-", .after = "      - name: Stop buck2\n" },
        .{ .before = "          name: mopm-beta-staged-${{ github.sha }}\n" ++ dir_tail, .name = "mopm-beta-staged-", .after = "" },
        .{ .before = PROD_STAGED_ARTIFACT ++ "\n" ++ dir_tail, .name = "mopm-prod-staged-", .after = "" },
    };
    for (cases) |case| {
        const c = .{
            .anchor = try std.mem.concat(ar, u8, &.{ case.before, "          retention-days: 7\n", case.after }),
            .name = case.name,
            .rest = try std.mem.concat(ar, u8, &.{ case.before, case.after }),
            .before = case.before,
            .after = case.after,
        };
        // the boundaries are kept
        for ([_][]const u8{ "7", "14" }) |days| {
            const edited = try replaced(ar, text, c.anchor, try std.fmt.allocPrint(ar, "{s}          retention-days: {s}\n{s}", .{ c.before, days, c.after }));
            if (try check(ar, edited)) |why| {
                std.debug.print("{s} kept {s} days was refused: {s}\n", .{ c.name, days, why });
                return error.Refused;
            }
        }
        // one day (the value before), one below the floor, zero, one above the ceiling, and the default 90
        for ([_][]const u8{ "1", "6", "0", "15", "90" }) |days| {
            const edited = try replaced(ar, text, c.anchor, try std.fmt.allocPrint(ar, "{s}          retention-days: {s}\n{s}", .{ c.before, days, c.after }));
            const want = try std.fmt.allocPrint(ar, "the upload of {s}${{{{ github.sha }}}} has retention-days {s}, not 7 to 14: a rerun of a failed prod job on a later day must still download it", .{ c.name, days });
            try t.expectEqualStrings(want, (try check(ar, edited)) orelse return error.Accepted);
        }
        // no retention-days: GitHub keeps it 90 days
        try t.expectEqualStrings(
            try std.fmt.allocPrint(ar, "the upload of {s}${{{{ github.sha }}}} names no retention-days: it is kept 90 days, not 7 to 14", .{c.name}),
            (try check(ar, try replaced(ar, text, c.anchor, c.rest))) orelse return error.Accepted,
        );
        // an expression or a word is not a number of days
        try t.expectEqualStrings(
            try std.fmt.allocPrint(ar, "the upload of {s}${{{{ github.sha }}}} has retention-days ${{{{ vars.KEEP }}}}, not a number of days", .{c.name}),
            (try check(ar, try replaced(ar, text, c.anchor, try std.fmt.allocPrint(ar, "{s}          retention-days: ${{{{ vars.KEEP }}}}\n{s}", .{ c.before, c.after })))) orelse return error.Accepted,
        );
        // a comment between the fields does not end the step
        const commented = try replaced(ar, text, c.anchor, try std.fmt.allocPrint(ar, "{s}          # kept for a rerun\n          retention-days: 1\n{s}", .{ c.before, c.after }));
        try expectRefused(ar, commented, "has retention-days 1, not 7 to 14");
    }
    // a second upload of the set, by another ref of the action and with the default retention, is refused
    const second = "      - uses: actions/upload-artifact@v7\n        with:\n          name: mopm-staged-${{ github.sha }}-again\n          path: x\n";
    try expectRefused(ar, try replaced(ar, text, "      - name: Stop buck2\n        if: always()\n        run: ./buck2 kill || true\n\n  # THE BETA PUBLISH", second ++ "      - name: Stop buck2\n        if: always()\n        run: ./buck2 kill || true\n\n  # THE BETA PUBLISH"), "names no retention-days");
    // an upload of none of those names is not held to the range: the release set and the committed
    // directories keep 14 days, and each at 1 is accepted
    try t.expect((try check(ar, try replaced(ar, text, "          name: release-${{ github.sha }}\n          path: ${{ runner.temp }}/release\n          if-no-files-found: error\n          retention-days: 14\n", "          name: release-${{ github.sha }}\n          path: ${{ runner.temp }}/release\n          if-no-files-found: error\n          retention-days: 1\n"))) == null);
    try t.expect((try check(ar, try replaced(ar, text, "          retention-days: 14\n          overwrite: true\n", "          retention-days: 1\n          overwrite: true\n"))) == null);
}

test "a workflow with no upload of one of the staged artifacts is refused by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expectEqualStrings("no upload-artifact step uploads mopm-staged-<sha>", (try checkStagedRetention(ar, "jobs:\n  a:\n    steps:\n      - run: true\n")) orelse return error.Accepted);
    const only_set = "      - uses: actions/upload-artifact@x\n        with:\n          name: mopm-staged-1\n          retention-days: 7\n";
    try t.expectEqualStrings("no upload-artifact step uploads mopm-beta-staged-<sha>", (try checkStagedRetention(ar, only_set)) orelse return error.Accepted);
    const beta_dir = "      - uses: actions/upload-artifact@x\n        with:\n          name: mopm-beta-staged-1\n          retention-days: 7\n";
    try t.expectEqualStrings("no upload-artifact step uploads mopm-prod-staged-<sha>", (try checkStagedRetention(ar, only_set ++ beta_dir)) orelse return error.Accepted);
    // the step's own name is not the artifact's
    const step_named = "      - uses: actions/upload-artifact@x\n        name: mopm-beta-staged-step\n        with:\n          name: other-1\n" ++ only_set;
    try t.expectEqualStrings("no upload-artifact step uploads mopm-beta-staged-<sha>", (try checkStagedRetention(ar, step_named)) orelse return error.Accepted);
    const step_named_bad = "      - uses: actions/upload-artifact@x\n        name: keep the set\n        with:\n          name: mopm-staged-3\n          retention-days: 1\n";
    try t.expectEqualStrings("the upload of mopm-staged-3 has retention-days 1, not 7 to 14: a rerun of a failed prod job on a later day must still download it", (try checkStagedRetention(ar, step_named_bad)) orelse return error.Accepted);
    // a step with no name is not a staged upload; the next step's dash ends a step
    const both = "      - uses: actions/upload-artifact@x\n        with:\n          path: y\n      - name: other\n        with:\n          name: mopm-staged-2\n" ++ only_set ++ beta_dir ++
        "      - uses: actions/upload-artifact@x\n        with:\n          name: \"mopm-prod-staged-1\"\n          retention-days: '14'\n";
    try t.expect((try checkStagedRetention(ar, both)) == null);
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
    const pin = "toolchains//:mopm_0_0_101";
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_101 --out x", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("a toolchains//:mopm_0_0_101, b toolchains//:mopm_0_0_101.", pin, "w", &buf)) == null);
    try t.expect((try mopmDrift("args: build toolchains//:mopm_0_0_81 --out x", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("toolchains//:mopm_0_0_101 then toolchains//:mopm_0_0_8", pin, "w", &buf)) != null);
    try t.expect((try mopmDrift("no label here", pin, "w", &buf)) != null);
    try t.expectEqualStrings("toolchains//:mopm_0_0_101", mopmPin("X = 1\nMOPM = \"toolchains//:mopm_0_0_101\"\n").?);
    try t.expect(mopmPin("# MOPM = \"x\"\n") == null);
}

test {
    // the beta jobs' cases, and checkGroup, which the prod jobs share
    _ = @import("release_publish_group.zig");
    // the cases of the jobs that run the README e2e on what each registry serves after its commit
    _ = @import("release_served_readmes.zig");
}
