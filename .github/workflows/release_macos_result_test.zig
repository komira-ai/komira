//! The step `the macOS build ran and passed` of release-macos.yml's job release-macos-result, run: part
//! of //:release_macos_cases (release_macos_test.zig imports this file). The step's `run: |` script is
//! taken from the workflow's own bytes (the zig_test's `data`, under KOMIRA_TEST_WORK/workflows) and run
//! with the busybox `sh -e` (the launcher's PATH; the runner uses bash -e, and the script is POSIX sh),
//! with BUILD_RESULT and REPORT set as the step's `env:` sets them from the build job. Each case compares
//! the exit status and the whole output.
//!
//! What the cases catch:
//!  - a build that succeeded passes and prints nothing;
//!  - a skipped build fails with "the macOS build did not run";
//!  - a build job cancelled while the run went on (its timeout-minutes ran out) fails with "the macOS
//!    build was cancelled while the run went on", so an arm that only warns, or warns and exits 0, fails;
//!  - a failed build fails with the build job's report as it is, and with no report (the checkout or
//!    farm-connect failed) with the message that says so;
//!  - a result GitHub does not give today falls to the failing arm, never to a pass.

const std = @import("std");
const t = std.testing;

const JOB = "  release-macos-result:";
const STEP = "      - name: the macOS build ran and passed";
const RUN = "        run: |";
/// The indent of the lines of the step's block scalar.
const BODY = "          ";

/// The `run: |` script of the step STEP of the job JOB, dedented, or an error naming what is missing.
fn resultScript(ar: std.mem.Allocator, text: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var in_job = false;
    var in_step = false;
    var in_run = false;
    var out = std.ArrayList(u8).empty;
    while (it.next()) |line| {
        if (in_run) {
            if (line.len == 0 or std.mem.startsWith(u8, line, BODY)) {
                if (line.len > 0) try out.appendSlice(ar, line[BODY.len..]);
                try out.append(ar, '\n');
                continue;
            }
            break;
        }
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ' and line[2] != '#') {
            in_job = std.mem.eql(u8, line, JOB);
            in_step = false;
            continue;
        }
        if (!in_job) continue;
        if (std.mem.startsWith(u8, line, "      - ")) {
            in_step = std.mem.eql(u8, line, STEP);
            continue;
        }
        if (in_step and std.mem.eql(u8, line, RUN)) in_run = true;
    }
    if (out.items.len == 0) {
        std.debug.print("release-macos.yml has no `run: |` script in the step `the macOS build ran and passed` of release-macos-result\n", .{});
        return error.NoResultScript;
    }
    return out.items;
}

const Outcome = struct { code: u8, out: []const u8 };

/// Runs the result step's script with the build job's result and report.
fn runResult(ar: std.mem.Allocator, script: []const u8, result: []const u8, report: []const u8) !Outcome {
    var env = std.process.EnvMap.init(ar);
    try env.put("PATH", try std.process.getEnvVarOwned(ar, "PATH"));
    try env.put("BUILD_RESULT", result);
    try env.put("REPORT", report);
    const r = try std.process.Child.run(.{
        .allocator = ar,
        .argv = &.{ "sh", "-e", "-c", script },
        .env_map = &env,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = try std.mem.concat(ar, u8, &.{ r.stdout, r.stderr }) };
}

fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ w, "workflows", "release-macos.yml" }), 1 << 22);
}

fn expectResult(script: []const u8, result: []const u8, report: []const u8, code: u8, out: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runResult(arena.allocator(), script, result, report);
    if (o.code != code) std.debug.print("BUILD_RESULT={s}: exit {d}, want {d}; output:\n{s}\n", .{ result, o.code, code, o.out });
    try t.expectEqual(code, o.code);
    try t.expectEqualStrings(out, o.out);
}

const SKIPPED = "::error title=release-macos::the macOS build did not run: its job was skipped (a condition of the job was false, or an earlier job it waits on did not succeed)\n";
const CANCELLED = "::error title=release-macos::the macOS build was cancelled while the run went on: it ran past its timeout-minutes (a stalled build)\n";
const REPORT = "step `build the macOS set` failed; buck2's output ends:%0AAction failed: komira//src/x:lib";
const FAILED = "::error title=release-macos::the macOS build did not pass: " ++ REPORT ++ "\n";
const FAILED_EARLY = "::error title=release-macos::the macOS build did not pass: its job ended failure before the buckconfig check (the checkout or farm-connect failed; the log of the job says why)\n";

test "release-macos-result passes a build that succeeded and fails every other result with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const script = try resultScript(ar, try readWorkflow(ar));

    try expectResult(script, "success", "", 0, "");
    try expectResult(script, "skipped", "", 1, SKIPPED);
    // a build job cancelled while the run went on ran out its timeout-minutes: it fails, it does not warn
    try expectResult(script, "cancelled", "", 1, CANCELLED);
    try expectResult(script, "failure", REPORT, 1, FAILED);
    try expectResult(script, "failure", "", 1, FAILED_EARLY);
    // a result GitHub does not give today is not a pass
    try expectResult(script, "timed_out", "", 1, "::error title=release-macos::the macOS build did not pass: its job ended timed_out before the buckconfig check (the checkout or farm-connect failed; the log of the job says why)\n");
}

test "the reader of the result step refuses a workflow without it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readWorkflow(ar);
    try t.expectError(error.NoResultScript, resultScript(ar, try std.mem.replaceOwned(u8, ar, text, STEP ++ "\n", "      - name: another step\n")));
    try t.expectError(error.NoResultScript, resultScript(ar, try std.mem.replaceOwned(u8, ar, text, JOB ++ "\n", "  release-macos-other:\n")));
}
