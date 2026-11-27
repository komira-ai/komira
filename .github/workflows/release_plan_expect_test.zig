//! The cases of the whole-set check of release.yml, //:release_plan_expect_cases: a `zig_test` run as a build
//! action. The workflow's own bytes are the subject (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows/).
//!
//! `mopm-stage` holds the plan `mopm stage` wrote to the set the release builds before anything reaches the
//! registry. What the cases catch:
//!  - `mopm-stage` builds //release:mopm_plan_expectation exactly once, on the farm (asserted remote), before
//!    `mopm stage`;
//!  - the step `the staged set is every package on every platform` is in `mopm-stage`, once, and is exactly its
//!    name and its `run:` (`release_staged_verify expect --staged release/staged_set --expect <the expectation
//!    built>`): no `if:`, no `continue-on-error`, no `|| true`, so a short set fails the job, and the job
//!    itself has no `continue-on-error`;
//!  - it is the step right after `mopm stage`, so it runs before the README e2e and before the staged set is
//!    kept for `prod-stage`;
//!  - `beta-stage` and `prod-stage`, the two jobs that open a group on a registry, need `mopm-stage`, so a
//!    failed check stops the run before a group is opened on either registry.
//! Each defect is written into the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const STAGE_JOB = "mopm-stage";
const BUILD_EXPECTATION = "          args: build //release:mopm_plan_expectation --out ${{ runner.temp }}/mopm-publish/plan_expectation.json";
const ASSERT = "          assert-remote: ${{ steps.assert.outputs.path }}";
const MOPM_STAGE_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/mopm\" stage --workspace-root src --artifacts \"$RUNNER_TEMP/mopm-publish/artifacts\" --compiler 1.1.0 --out release/staged_set --registry prod'";
const EXPECT_NAME = "      - name: the staged set is every package on every platform";
const EXPECT_RUN = "        run: '\"$RUNNER_TEMP/mopm-publish/release_staged_verify\" expect --staged release/staged_set --expect \"$RUNNER_TEMP/mopm-publish/plan_expectation.json\"'";
const BETA_STAGE_NEEDS = "    needs: [release, mopm-stage]";
const PROD_STAGE_NEEDS = "    needs: [release, mopm-stage, beta-commit]";
const STEP_START = "      - ";

/// The lines of the job `name` of the `jobs:` map (a key at two spaces of indent), without comment lines and
/// blank lines, or null if there is no such job. Counts the jobs of that name in `count`.
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

fn countOf(lines: []const []const u8, exact: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| if (std.mem.eql(u8, l, exact)) {
        n += 1;
    };
    return n;
}

fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

/// The index of the first line of the step after the one holding line `at`, or `lines.len`.
fn nextStep(lines: []const []const u8, at: usize) usize {
    var i = at + 1;
    while (i < lines.len and !std.mem.startsWith(u8, lines[i], STEP_START)) i += 1;
    return i;
}

/// Null if release.yml holds the whole-set check as the header says, else the refusal.
fn check(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var n: usize = 0;
    const job = (try jobLines(ar, text, STAGE_JOB, &n)) orelse return "release.yml has no job mopm-stage";
    if (n != 1) return "mopm-stage is defined more than once";
    for (job) |l| if (std.mem.startsWith(u8, l, "    continue-on-error")) return "mopm-stage ignores a failure of its own (continue-on-error): a short set would not stop the run";

    if (countOf(job, BUILD_EXPECTATION) != 1) return "mopm-stage does not build //release:mopm_plan_expectation exactly once";
    const build_at = lineAt(job, BUILD_EXPECTATION).?;
    if (build_at + 1 >= job.len or !std.mem.eql(u8, job[build_at + 1], ASSERT)) return "mopm-stage builds the plan expectation without asserting it ran on the farm";

    const stage_at = lineAt(job, MOPM_STAGE_RUN) orelse return "mopm-stage does not run mopm stage into release/staged_set";
    if (build_at > stage_at) return "mopm-stage builds the plan expectation after mopm stage";

    var names: usize = 0;
    var runs: usize = 0;
    for (job) |l| {
        if (std.mem.indexOf(u8, l, "release_staged_verify\" expect") != null) runs += 1;
        if (std.mem.eql(u8, l, EXPECT_NAME)) names += 1;
    }
    if (names == 0 or runs == 0) return "mopm-stage does not check the staged plan against the expectation (release_staged_verify expect)";
    if (names != 1 or runs != 1) return "mopm-stage checks the staged plan against the expectation more than once";
    const name_at = lineAt(job, EXPECT_NAME).?;
    const end = nextStep(job, name_at);
    const step = job[name_at..end];
    for (step) |l| {
        if (std.mem.indexOf(u8, l, "|| true") != null or std.mem.indexOf(u8, l, "continue-on-error") != null)
            return "the whole-set check ignores its failure (|| true or continue-on-error)";
        if (std.mem.startsWith(u8, l, "        if:")) return "the whole-set check has a condition: it must run on every run of mopm-stage";
    }
    if (step.len != 2 or !std.mem.eql(u8, step[1], EXPECT_RUN))
        return "the whole-set check is not exactly `release_staged_verify expect --staged release/staged_set --expect` with the expectation built in this job";
    if (nextStep(job, stage_at) != name_at) return "the whole-set check is not the step right after mopm stage: the e2e or the kept set would come before it";

    var bn: usize = 0;
    const beta_stage = (try jobLines(ar, text, "beta-stage", &bn)) orelse return "release.yml has no job beta-stage";
    if (countOf(beta_stage, BETA_STAGE_NEEDS) != 1) return "beta-stage does not need mopm-stage: a group could be opened before the whole-set check";
    var pn: usize = 0;
    const prod_stage = (try jobLines(ar, text, "prod-stage", &pn)) orelse return "release.yml has no job prod-stage";
    if (countOf(prod_stage, PROD_STAGE_NEEDS) != 1) return "prod-stage does not need mopm-stage: a group could be opened before the whole-set check";
    return null;
}

fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, "workflows", "release.yml" }), 1 << 20);
}

/// `text` with the one occurrence of `from` replaced by `to`.
fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.count(u8, text, from) != 1) {
        std.debug.print("the case's anchor is not in release.yml exactly once: {s}\n", .{from});
        return error.AnchorNotOnce;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, want: []const u8) !void {
    const why = (try check(ar, text)) orelse return error.TestExpectedRefusal;
    if (!std.mem.eql(u8, why, want)) {
        std.debug.print("refusal was '{s}', wanted '{s}'\n", .{ why, want });
        return error.TestWrongRefusal;
    }
}

const EXPECT_STEP = EXPECT_NAME ++ "\n" ++ EXPECT_RUN ++ "\n";

test "release.yml checks the staged plan against the expectation right after mopm stage, in mopm-stage" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    if (try check(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.TestUnexpectedRefusal;
    }
}

test "a release.yml without the whole-set step is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try expectRefused(ar, try replaced(ar, text, EXPECT_STEP, ""), "mopm-stage does not check the staged plan against the expectation (release_staged_verify expect)");
}

test "a whole-set step that ignores its failure is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    const want = "the whole-set check ignores its failure (|| true or continue-on-error)";
    const or_true = EXPECT_RUN[0 .. EXPECT_RUN.len - 1] ++ " || true'";
    try expectRefused(ar, try replaced(ar, text, EXPECT_RUN ++ "\n", or_true ++ "\n"), want);
    try expectRefused(ar, try replaced(ar, text, EXPECT_STEP, EXPECT_NAME ++ "\n        continue-on-error: true\n" ++ EXPECT_RUN ++ "\n"), want);
}

test "a mopm-stage that ignores a failure of its own is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try expectRefused(ar, try replaced(ar, text, "  mopm-stage:\n", "  mopm-stage:\n    continue-on-error: true\n"), "mopm-stage ignores a failure of its own (continue-on-error): a short set would not stop the run");
}

test "a whole-set step with a condition is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try expectRefused(ar, try replaced(ar, text, EXPECT_STEP, EXPECT_NAME ++ "\n        if: github.event_name == 'push'\n" ++ EXPECT_RUN ++ "\n"), "the whole-set check has a condition: it must run on every run of mopm-stage");
}

test "a whole-set step on another directory or another expectation is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    const want = "the whole-set check is not exactly `release_staged_verify expect --staged release/staged_set --expect` with the expectation built in this job";
    try expectRefused(ar, try std.mem.replaceOwned(u8, ar, text, "expect --staged release/staged_set", "expect --staged release/other"), want);
    try expectRefused(ar, try std.mem.replaceOwned(u8, ar, text, "--expect \"$RUNNER_TEMP/mopm-publish/plan_expectation.json\"", "--expect release/plan.json"), want);
}

test "a whole-set step after the README e2e, or a second one, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    // after the README e2e step, before the dry-run that follows it
    const dry_run = "      - name: mopm publish --staged --dry-run\n";
    const moved = try replaced(ar, try replaced(ar, text, EXPECT_STEP, ""), dry_run, EXPECT_STEP ++ dry_run);
    try expectRefused(ar, moved, "the whole-set check is not the step right after mopm stage: the e2e or the kept set would come before it");
    try expectRefused(ar, try replaced(ar, text, EXPECT_STEP, EXPECT_STEP ++ EXPECT_STEP), "mopm-stage checks the staged plan against the expectation more than once");
}

test "an expectation that is not built, built twice, not on the farm, or built after mopm stage is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try expectRefused(ar, try replaced(ar, text, BUILD_EXPECTATION ++ "\n", ""), "mopm-stage does not build //release:mopm_plan_expectation exactly once");
    try expectRefused(ar, try replaced(ar, text, BUILD_EXPECTATION ++ "\n", BUILD_EXPECTATION ++ "\n" ++ BUILD_EXPECTATION ++ "\n"), "mopm-stage does not build //release:mopm_plan_expectation exactly once");
    try expectRefused(ar, try replaced(ar, text, BUILD_EXPECTATION ++ "\n" ++ ASSERT ++ "\n", BUILD_EXPECTATION ++ "\n"), "mopm-stage builds the plan expectation without asserting it ran on the farm");
    const build_step = "      - name: build the plan expectation\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ BUILD_EXPECTATION ++ "\n" ++ ASSERT ++ "\n";
    const stage_step = "      - name: mopm stage\n" ++ MOPM_STAGE_RUN ++ "\n";
    const late = try replaced(ar, try replaced(ar, text, build_step, ""), stage_step, stage_step ++ build_step);
    try expectRefused(ar, late, "mopm-stage builds the plan expectation after mopm stage");
}

test "a beta-stage or prod-stage that does not need mopm-stage is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try expectRefused(ar, try replaced(ar, text, BETA_STAGE_NEEDS ++ "\n", "    needs: [release]\n"), "beta-stage does not need mopm-stage: a group could be opened before the whole-set check");
    try expectRefused(ar, try replaced(ar, text, PROD_STAGE_NEEDS ++ "\n", "    needs: [release, beta-commit]\n"), "prod-stage does not need mopm-stage: a group could be opened before the whole-set check");
}
