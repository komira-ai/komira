//! The jobs that run the README e2e on what a registry serves after its commit, `beta-served-readmes` and
//! `prod-served-readmes`, for //:release_workflow_cases (release_workflow_test.zig imports this file, calls
//! `checkServed` from its `check` and runs its tests).
//!
//! After `beta-commit` and again after `prod-commit`, a job of the environment `build` (the farm's; `id-token: write`
//! for farm-connect only) downloads the set `mopm-stage` kept, runs `release_staged_verify served --stage <registry>`
//! (every file of the plan from that registry's channel and every README from its API, checked against the plan and
//! written to `release/staged_set`), and then the README e2e of every package on that set on the farm. What the cases
//! catch:
//!  - each job is there once with exactly its `needs` (its registry's commit), the push-to-main gate, the
//!    environment `build` and the permissions `contents: read` and `id-token: write`, ignoring no failure;
//!  - the command: `served` of its own registry (`--stage beta` in the beta job, `--stage prod` in the prod job),
//!    on the set `mopm-stage` kept and on no other artifact (a registry's staged directory holds the files before the
//!    commit, not what it serves), writing `release/staged_set` and nothing else writing it, run once;
//!  - the e2e: `-c komira_release.staged=stage` at this run's version, after `served`, asserted remote, the job's one
//!    farm build;
//!  - no line names a registry-writing verb, the OIDC exchange or a hand-made write.
//! Each defect is written into the real release.yml and must be refused with its message.

const std = @import("std");
const t = std.testing;
const wf = @import("release_workflow_test.zig");

const SERVED_REGISTRIES = [_][]const u8{ "beta", "prod" };

/// The one artifact a served job downloads: the plan and READMEs of the set `mopm-stage` kept, and the verify tool.
const STAGED_DOWNLOAD = "          name: mopm-staged-${{ github.sha }}";

fn servedRun(comptime r: []const u8) []const u8 {
    return "        run: '\"$RUNNER_TEMP/" ++ r ++ "-served/release_staged_verify\" served --stage " ++ r ++ " --staged \"$RUNNER_TEMP/" ++ r ++ "-served/staged\" --out release/staged_set --attempts 5 --delay 30'";
}

fn spec(comptime r: []const u8) wf.JobSpec {
    return .{ .name = r ++ "-served-readmes", .needs = "    needs: " ++ r ++ "-commit", .gate = wf.PROD_GATE, .environment = "    environment: build", .id_token = true };
}

fn count(lines: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) {
        n += 1;
    };
    return n;
}

/// Null if the served job of the registry `r` holds its contract (the header), else the refusal.
fn checkOne(ar: std.mem.Allocator, text: []const u8, comptime r: []const u8) !?[]const u8 {
    const name = r ++ "-served-readmes";
    const specs = [_]wf.JobSpec{spec(r)};
    if (try wf.checkJobs(ar, text, &specs)) |why| return why;
    var scratch: usize = 0;
    const job = (try wf.jobLines(ar, text, name, &scratch)).?;
    for (job) |l| {
        if (std.mem.eql(u8, l, specs[0].needs) or std.mem.eql(u8, l, wf.PROD_GATE)) continue;
        for (wf.prod_readonly_forbidden) |word| {
            if (std.ascii.indexOfIgnoreCase(l, word) != null) return name ++ " publishes, yanks, logs in or exchanges an identity: it only reads";
        }
    }
    // the set mopm-stage kept, and no other artifact: a staged directory is the files before the commit
    var downloads: usize = 0;
    for (job) |l| if (std.mem.startsWith(u8, l, "          name: ")) {
        if (!std.mem.eql(u8, l, STAGED_DOWNLOAD)) return name ++ " downloads an artifact other than mopm-staged-<sha>: what it checks must be what the registry serves";
        downloads += 1;
    };
    if (downloads != 1) return name ++ " does not download the set mopm-stage kept (mopm-staged-<sha>) once";
    const download_at = wf.lineAt(job, STAGED_DOWNLOAD).?;
    const served_at = wf.lineAt(job, servedRun(r)) orelse return name ++ " does not run release_staged_verify served --stage " ++ r ++ " on the set mopm-stage kept, writing release/staged_set";
    if (!(download_at < served_at)) return name ++ " runs served before it has the set";
    var runs: usize = 0;
    for (job) |l| if (std.mem.indexOf(u8, l, "release_staged_verify\" ") != null and std.mem.startsWith(u8, l, "        run:")) {
        runs += 1;
    };
    if (runs != 1) return name ++ " runs release_staged_verify more than once";
    // nothing else writes the directory the e2e reads
    if (count(job, "staged_set") != 1) return name ++ " names release/staged_set other than in the one served step";
    const connect_at = wf.lineAt(job, wf.E2E_FARM_CONNECT) orelse return name ++ " does not join the farm";
    const e2e_at = wf.lineAt(job, wf.PROD_E2E_RUN) orelse return name ++ " does not run the e2e on the served set (staged=stage at this run's version)";
    if (!(served_at < e2e_at)) return name ++ " runs the e2e before served wrote the set";
    if (!(connect_at < e2e_at)) return name ++ " runs the e2e before it joins the farm";
    // the e2e is the job's one farm build, and it is asserted remote
    if (count(job, "uses: ./.github/actions/buck2-farm") != 1) return name ++ " has a farm build other than the e2e";
    if (e2e_at + 1 >= job.len or !std.mem.eql(u8, job[e2e_at + 1], wf.E2E_ASSERT) or count(job, "assert-remote:") != 1)
        return name ++ " has a farm step that is not asserted remote";
    return null;
}

/// Null if both served jobs hold their contract, else the refusal.
pub fn checkServed(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    inline for (SERVED_REGISTRIES) |r| {
        if (try checkOne(ar, text, r)) |why| return why;
    }
    return null;
}

test "release.yml holds the contract of the served-readmes jobs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    if (try checkServed(ar, text)) |why| {
        std.debug.print("release.yml: {s}\n", .{why});
        return error.Refused;
    }
    // the whole contract holds too, with these jobs in it
    try t.expect((try wf.check(ar, text)) == null);
}

test "a served job that is missing, twice, or under another needs, gate, environment or permissions is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    const runs = "    runs-on: ubuntu-24.04\n";
    inline for (SERVED_REGISTRIES) |r| {
        const name = r ++ "-served-readmes";
        const head = "  " ++ name ++ ":\n    needs: " ++ r ++ "-commit\n" ++ wf.PROD_GATE ++ "\n" ++ runs ++ "    environment: build\n    timeout-minutes: 120\n    permissions:\n      contents: read\n";
        try wf.expectRefused(ar, try wf.replaced(ar, text, "  " ++ name ++ ":\n", "  " ++ name ++ "-old:\n"), "no job " ++ name);
        try wf.expectRefused(ar, try wf.replaced(ar, text, "  prod-stage:\n", "  " ++ name ++ ":\n" ++ runs ++ "\n  prod-stage:\n"), name ++ " is defined more than once");
        // after its own registry's commit: not before it, not after the other's
        const other = comptime if (std.mem.eql(u8, r, "beta")) "prod" else "beta";
        for ([_][]const u8{ "    needs: " ++ r ++ "-test\n", "    needs: " ++ other ++ "-commit\n", "    needs: [" ++ r ++ "-commit, release]\n", "" }) |w|
            try wf.expectRefused(ar, try wf.replaced(ar, text, head, "  " ++ name ++ ":\n" ++ w ++ head[("  " ++ name ++ ":\n    needs: " ++ r ++ "-commit\n").len..]), name ++ ": needs is not exactly `needs: " ++ r ++ "-commit`");
        // a push to main and nothing else
        for ([_][]const u8{ "    if: always()\n", "    if: github.event_name == 'push'\n", "" }) |w|
            try wf.expectRefused(ar, try wf.replaced(ar, text, head, try wf.swapGate(ar, head, w)), name ++ ": the if is not the expected gate");
        // the farm's environment, never a registry's
        try wf.expectRefused(ar, try wf.replaced(ar, text, head, try std.mem.replaceOwned(u8, ar, head, "    environment: build\n", "    environment: " ++ r ++ "\n")), name ++ ": environment is not `environment: build`");
        // id-token for farm-connect, nothing more
        try wf.expectRefused(ar, try wf.replaced(ar, text, head ++ "      # for farm-connect only: the token Tailscale trusts\n      id-token: write\n", head), name ++ ": id-token: write is missing");
        try wf.expectRefused(ar, try wf.replaced(ar, text, head, head ++ "      packages: read\n"), name ++ ": permissions hold more than they should");
    }
}

test "each edit of a served job's steps that breaks the contract is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try wf.readWorkflow(ar);
    const nl = "\n";
    inline for (SERVED_REGISTRIES) |r| {
        const name = r ++ "-served-readmes";
        const other = comptime if (std.mem.eql(u8, r, "beta")) "prod" else "beta";
        const run = servedRun(r);
        const served_step = "      - name: download what " ++ r ++ " serves and check it against the plan\n" ++ run ++ nl;
        const e2e_step = "      - name: the README e2e against what " ++ r ++ " serves\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ wf.PROD_E2E_RUN ++ nl ++ wf.E2E_ASSERT ++ nl;
        const download = "          name: mopm-staged-${{ github.sha }}\n          path: ${{ runner.temp }}/" ++ r ++ "-served\n";
        // served of its own registry, on the set mopm-stage kept, into release/staged_set
        try wf.expectRefused(ar, try wf.replaced(ar, text, served_step, ""), name ++ " does not run release_staged_verify served --stage " ++ r);
        try wf.expectRefused(ar, try wf.replaced(ar, text, run, try std.mem.replaceOwned(u8, ar, run, "--stage " ++ r, "--stage " ++ other)), name ++ " does not run release_staged_verify served --stage " ++ r);
        try wf.expectRefused(ar, try wf.replaced(ar, text, run, try std.mem.replaceOwned(u8, ar, run, " --out release/staged_set", " --out x")), name ++ " does not run release_staged_verify served --stage " ++ r);
        try wf.expectRefused(ar, try wf.replaced(ar, text, run, try std.mem.replaceOwned(u8, ar, run, " served ", " verify ")), name ++ " does not run release_staged_verify served --stage " ++ r);
        try wf.expectRefused(ar, try wf.replaced(ar, text, served_step, served_step ++ served_step), name ++ " runs release_staged_verify more than once");
        try wf.expectRefused(ar, try wf.replaced(ar, text, served_step, served_step ++ "      - run: cp x release/staged_set/y\n"), name ++ " names release/staged_set other than in the one served step");
        // the set mopm-stage kept, before served, and no other artifact
        try wf.expectRefused(ar, try wf.replaced(ar, text, download, "          name: mopm-" ++ r ++ "-committed-${{ github.sha }}\n          path: ${{ runner.temp }}/" ++ r ++ "-served\n"), name ++ " downloads an artifact other than mopm-staged-<sha>");
        try wf.expectRefused(ar, try wf.replaced(ar, text, served_step, served_step ++ "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n" ++ download), name ++ " does not download the set mopm-stage kept (mopm-staged-<sha>) once");
        const dl_step = "      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1\n        with:\n" ++ download;
        try wf.expectRefused(ar, try wf.replaced(ar, try wf.replaced(ar, text, dl_step, ""), e2e_step, e2e_step ++ dl_step), name ++ " runs served before it has the set");
        // the e2e at this run's version, after served, on the farm, asserted
        try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, ""), name ++ " does not run the e2e on the served set");
        try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - name: the README e2e against what " ++ r ++ " serves\n        uses: ./.github/actions/buck2-farm\n        with:\n          args: build -c komira_release.staged=stage //release/readme_e2e/verify:all\n" ++ wf.E2E_ASSERT ++ nl), name ++ " does not run the e2e on the served set");
        try wf.expectRefused(ar, try wf.replaced(ar, try wf.replaced(ar, text, served_step, ""), e2e_step, e2e_step ++ served_step), name ++ " runs the e2e before served wrote the set");
        try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - name: the README e2e against what " ++ r ++ " serves\n        uses: ./.github/actions/buck2-farm\n        with:\n" ++ wf.PROD_E2E_RUN ++ nl), name ++ " has a farm step that is not asserted remote");
        try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - name: build something else\n        uses: ./.github/actions/buck2-farm\n        with:\n          args: build //x\n" ++ wf.E2E_ASSERT ++ nl ++ e2e_step), name ++ " has a farm build other than the e2e");
        try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, e2e_step ++ "        continue-on-error: true\n"), name ++ " ignores a failure");
        try wf.expectRefused(ar, try wf.replaced(ar, text, run, run[0 .. run.len - 1] ++ " || true'"), name ++ " ignores a failure");
        // it only reads: no write to a registry, no identity
        const writers = [_][]const u8{ "mopm publish --staged x --registry " ++ r, "mopm yank hashing 0.1.1", "mopm login", "curl -X PUT https://x.test/y", "mopm-x --oidc" };
        inline for (writers) |cmd| try wf.expectRefused(ar, try wf.replaced(ar, text, e2e_step, "      - run: " ++ cmd ++ "\n" ++ e2e_step), name ++ " publishes, yanks, logs in or exchanges an identity");
    }
}
