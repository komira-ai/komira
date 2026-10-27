//! The cases of the buck2-farm action (action.yml, next to this file),
//! //:buck2_farm_cases: a `zig_test` run as a build action.
//!
//! The action's own bytes are the subject. The test reads action.yml (the
//! zig_test's `data`, under KOMIRA_TEST_WORK) and checks its shape, then runs
//! its two `run:` lines the way a runner does (`sh -e -o pipefail -c`, with
//! the busybox sh), each with its `env:` filled from the case. `./buck2` of a
//! case is `stand_in_buck2` (//tools/build/ci:assert_remote), which prints a
//! recorded buck2 output (the tool's fixtures,
//! //tools/build/ci:assert_remote_fixtures) and exits 0, or 1 when told to, so
//! a case chooses what buck2 printed and whether it then failed. The built
//! tool is the real one (`ASSERT_REMOTE`, an exec tool).
//!
//! What the cases catch, each a defect action.yml could have:
//!  - the step's shell is not `bash` (a runner's `sh` has no pipefail, so a
//!    failing buck2 piped to tee would pass), a run line with logic added
//!    (`|| true`, a second command), a `${{ }}` in a run line (script
//!    injection), the tool step dropped or its log differing from the
//!    pipeline's;
//!  - run end to end: a good remote build passes; an action run locally,
//!    a summary missing beside network traffic, and a failed run all fail
//!    the job; a buck2 that fails after printing a good summary fails the
//!    first step; a fully cached run, which prints no summary, passes.

const std = @import("std");
const t = std.testing;

const Step = struct {
    shell: []const u8 = "",
    run: []const u8 = "",
    env_args: []const u8 = "", // `args` of env BUCK2_ARGS, a `${{ inputs.args }}`
    log: []const u8 = "", // BUCK2_LOG
    tool: []const u8 = "", // ASSERT_REMOTE
};

fn parseSteps(ar: std.mem.Allocator, text: []const u8) ![]Step {
    var steps = std.ArrayList(Step).empty;
    var in_runs = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0 and l[0] != ' ' and l[0] != '#') in_runs = std.mem.eql(u8, l, "runs:");
        if (!in_runs) continue;
        if (std.mem.startsWith(u8, l, "    - ")) try steps.append(ar, .{});
        if (steps.items.len == 0) continue;
        const s = &steps.items[steps.items.len - 1];
        const trimmed = std.mem.trimLeft(u8, l, " -");
        if (std.mem.startsWith(u8, trimmed, "shell: ")) s.shell = trimmed["shell: ".len..];
        if (std.mem.startsWith(u8, trimmed, "run: ")) s.run = unquote(trimmed["run: ".len..]);
        if (std.mem.startsWith(u8, trimmed, "BUCK2_ARGS: ")) s.env_args = trimmed["BUCK2_ARGS: ".len..];
        if (std.mem.startsWith(u8, trimmed, "BUCK2_LOG: ")) s.log = trimmed["BUCK2_LOG: ".len..];
        if (std.mem.startsWith(u8, trimmed, "ASSERT_REMOTE: ")) s.tool = trimmed["ASSERT_REMOTE: ".len..];
    }
    return steps.items;
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '\'' and v[v.len - 1] == '\'') return v[1 .. v.len - 1];
    return v;
}

fn loadSteps(ar: std.mem.Allocator) ![]Step {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "action.yml" });
    return parseSteps(ar, try std.fs.cwd().readFileAlloc(ar, path, 1 << 20));
}

// ---- the shape ---------------------------------------------------------------

test "the two steps are the invocation and the tool, each in bash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const steps = try loadSteps(arena.allocator());
    try t.expectEqual(@as(usize, 2), steps.len);
    // bash, never sh: a runner's bash is `bash -eo pipefail`, its sh is `sh -e`
    try t.expectEqualStrings("bash", steps[0].shell);
    try t.expectEqualStrings("bash", steps[1].shell);
    try t.expectEqualStrings("./buck2 $BUCK2_ARGS 2>&1 | tee \"$BUCK2_LOG\"", steps[0].run);
    try t.expectEqualStrings("\"$ASSERT_REMOTE\" \"$BUCK2_LOG\"", steps[1].run);
}

test "the inputs reach the steps through env, and both steps name the same log" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const steps = try loadSteps(arena.allocator());
    try t.expectEqualStrings("${{ inputs.args }}", steps[0].env_args);
    try t.expectEqualStrings("${{ inputs.assert-remote }}", steps[1].tool);
    try t.expectEqualStrings("${{ runner.temp }}/buck2-farm.log", steps[0].log);
    try t.expectEqualStrings(steps[0].log, steps[1].log);
}

test "no run line holds an expression" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for (try loadSteps(arena.allocator())) |s| try t.expect(std.mem.indexOf(u8, s.run, "${{") == null);
}

// ---- the lines, run -------------------------------------------------------------

const Outcome = struct { code: u8, out: []const u8 };

fn runLine(ar: std.mem.Allocator, dir: []const u8, line: []const u8, env: *std.process.EnvMap) !Outcome {
    const r = try std.process.Child.run(.{
        .allocator = ar,
        .argv = &.{ "sh", "-e", "-o", "pipefail", "-c", line },
        .cwd = dir,
        .env_map = env,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = try std.mem.concat(ar, u8, &.{ r.stdout, r.stderr }) };
}

var case_no: usize = 0;

fn workDir(ar: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
}

fn recorded(ar: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(ar, "{s}/fixtures/{s}", .{ try workDir(ar), name });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

const Which = union(enum) {
    /// A recorded log by file name, optionally with a buck2 that then fails.
    fixture: []const u8,
    fixture_then_fail: []const u8,
    /// A log made by the case (a recorded one with a line changed).
    derived: []const u8,
};

/// Runs the action's two steps in a directory of the case's own, with
/// `./buck2` the stand-in: step 1, and step 2 only if step 1 passed (as a
/// runner skips the later steps of a failed job). The output starts with the
/// step that produced it.
fn runCase(ar: std.mem.Allocator, which: Which) !Outcome {
    const steps = try loadSteps(ar);
    const w = try workDir(ar);
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/case{d}", .{ w, case_no });
    try std.fs.cwd().makePath(dir);
    const buck2 = try std.fs.path.join(ar, &.{ dir, "buck2" });
    try std.fs.cwd().copyFile(try std.process.getEnvVarOwned(ar, "STAND_IN_BUCK2"), std.fs.cwd(), buck2, .{});
    var f = try std.fs.cwd().openFile(buck2, .{});
    try f.chmod(0o755);
    f.close();
    var args: []const u8 = undefined;
    switch (which) {
        .fixture => |n| args = try std.fmt.allocPrint(ar, "{s}/fixtures/{s}", .{ w, n }),
        .fixture_then_fail => |n| args = try std.fmt.allocPrint(ar, "{s}/fixtures/{s} --fail", .{ w, n }),
        .derived => |text| {
            const p = try std.fs.path.join(ar, &.{ dir, "derived.log" });
            try std.fs.cwd().writeFile(.{ .sub_path = p, .data = text });
            args = p;
        },
    }
    var env = std.process.EnvMap.init(ar);
    try env.put("PATH", try std.process.getEnvVarOwned(ar, "PATH"));
    try env.put("BUCK2_ARGS", args);
    try env.put("BUCK2_LOG", try std.fs.path.join(ar, &.{ dir, "buck2-farm.log" }));
    try env.put("ASSERT_REMOTE", try std.process.getEnvVarOwned(ar, "ASSERT_REMOTE"));
    const first = try runLine(ar, dir, steps[0].run, &env);
    if (first.code != 0) return .{ .code = first.code, .out = try std.fmt.allocPrint(ar, "step 1: {s}", .{first.out}) };
    const second = try runLine(ar, dir, steps[1].run, &env);
    return .{ .code = second.code, .out = try std.fmt.allocPrint(ar, "step 2: {s}", .{second.out}) };
}

fn expectPasses(which: Which) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runCase(arena.allocator(), which);
    if (o.code != 0) std.debug.print("{s}\n", .{o.out});
    try t.expectEqual(@as(u8, 0), o.code);
    // the tool step ran, and said so
    try t.expect(std.mem.startsWith(u8, o.out, "step 2: assert_remote: ok"));
}

test "a build the farm ran passes both steps" {
    try expectPasses(.{ .fixture = "build_remote.log" });
}

test "a bxl run the farm ran passes" {
    try expectPasses(.{ .fixture = "bxl_remote.log" });
}

test "a fully cached run, which prints no summary, passes" {
    try expectPasses(.{ .fixture = "build_cached.log" });
}

/// The case must fail in step 2 (the tool) with `message` in what it printed.
fn expectToolRefuses(which: Which, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runCase(arena.allocator(), which);
    if (o.code == 0 or !std.mem.startsWith(u8, o.out, "step 2: ") or std.mem.indexOf(u8, o.out, message) == null) {
        std.debug.print("code {d}: {s}\n", .{ o.code, o.out });
        return error.TestUnexpectedResult;
    }
    try t.expectEqual(@as(u8, 1), o.code);
}

test "a local action fails the job at the tool step and names the count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.replaceOwned(u8, a, try recorded(a, "build_remote.log"), "local: 0)", "local: 3)");
    try expectToolRefuses(.{ .derived = log }, "3 action(s) ran locally");
}

test "a log with no summary beside network traffic fails the job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.replaceOwned(u8, a, try recorded(a, "build_remote.log"), "Commands:", "Actions:");
    try expectToolRefuses(.{ .derived = log }, "no `Commands:` summary line");
}

test "a failed run that exited 0 fails the job" {
    try expectToolRefuses(.{ .fixture = "build_failed_unknown_target.log" }, "BUILD FAILED");
}

test "a buck2 that exits non-zero after a good summary fails the first step" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try runCase(arena.allocator(), .{ .fixture_then_fail = "build_remote.log" });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expect(std.mem.startsWith(u8, o.out, "step 1: "));
    // the good summary was printed (and tee'd), so only pipefail made it fail
    try t.expect(std.mem.indexOf(u8, o.out, "local: 0)") != null);
}
