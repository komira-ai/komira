//! The cases of the buck2-farm action (action.yml, next to this file),
//! //:buck2_farm_cases: a `zig_test` run as a build action.
//!
//! The action's own bytes are the subject. The test reads action.yml (the
//! zig_test's `data`, under KOMIRA_TEST_WORK) and checks its shape, then runs
//! its two `run:` lines the way a runner does (`sh -e -o pipefail -c`, with
//! the busybox sh), each with its `env:` filled from the case and
//! GITHUB_STEP_SUMMARY a file of the case, and HOME a directory of the case
//! holding the machine buckconfig farm-connect writes
//! (`.buckconfig.d/farm.buckconfig`), whose `engine_address` is a loopback
//! port of the case's own (port 0): one that listens, so the farm answers at
//! once, or one bound but not listening, so it never answers (with a longest
//! wait of 0 s, so no case sleeps). `./buck2` of a case is
//! `stand_in_buck2` (//tools/build/ci:stand_in_buck2), which plays one
//! recorded buck2 output per call (the tool's fixtures,
//! //tools/build/ci:assert_remote_fixtures, or a log the case derived from
//! one) and exits as the case says, so a case chooses what each run printed
//! and how it ended, and counts the runs. The built tool is the real one
//! (`ASSERT_REMOTE`, an exec tool).
//!
//! What the cases catch, each a defect action.yml or the tool could have:
//!  - a step of pr.yml's check without a `timeout-minutes` of its own under the
//!    job's, which would leave a hang in it bounded only by the job;
//!  - the step's shell is not `bash`, a run line with logic added (`|| true`,
//!    a second command), a `${{ }}` in a run line (script injection), the
//!    tool step dropped or its log differing from the first step's;
//!  - run end to end: a good remote build passes; an action run locally,
//!    a summary missing beside network traffic, and a failed run all fail
//!    the job; a buck2 that fails after printing a good summary fails the
//!    first step, run once; a fully cached run, which prints no summary, passes;
//!  - a cut connection to the farm: a cut, then a pass, is green after two
//!    runs (a build and a test step), the job summary says the farm answered
//!    and the step ran again, and the first log is kept; a cut twice, then a
//!    pass, is green after three runs with two summary lines and both cut
//!    logs kept; a cut three times is red after three runs, never four, and
//!    says the third was cut too; a cut then a real failure is red and names
//!    that failure; a cut while the farm does not answer within the longest
//!    wait is red after one run, the summary saying how long the farm was
//!    unreachable and that the step was not run again, the cut run's log left
//!    where the tool step and later steps read it; a farm config that is
//!    missing, or names no longest wait, ends a cut step with exit 2 and the
//!    reason, never with a run again unbounded, while a passing run or a real
//!    failure never reads it; a compile error, a build with a compile error beside cuts, a
//!    test failure beside a cut and a test whose output prints the cut line
//!    are red after one run, with no first log and nothing in the summary; a
//!    subcommand other than build, test or bxl is never run again; a second
//!    run that ran an action locally is refused by the tool step;
//!  - a job the farm failed to start (`input-unavailable`, a recorded release
//!    build): then a pass, green after two runs, the summary naming the
//!    farm's `input-unavailable` and the failed log kept; three times, red
//!    after three runs, never four, saying the third failed on the farm too;
//!  - a buck2 ended by a signal is never run again, and a second run ended by
//!    one fails saying so; a job summary that cannot be written, a log that
//!    cannot be written and a buck2 that cannot be run end the step with the
//!    reason, never with a run passed over;
//!  - a run that hangs on a dead connection (the watchdog,
//!    tools/build/ci/assert_remote/farm_watchdog.zig): the farm of the case is
//!    then a fake one on its loopback port, served by a thread of the case,
//!    and the farm config sets the watchdog's bound to 2 s. A farm that
//!    accepts the connection, reads the request and then sends nothing with
//!    the socket open is the half-open case: the run is ended, buck2's daemon
//!    stopped (`./buck2 kill`), the reason in the job log and the summary, and
//!    the step run again and green; a buck2 that ignores SIGINT is ended with
//!    SIGKILL once the grace (the bound, 2 s) has passed; three such runs are red after three, never four; one then a
//!    real failure is red naming it; a subcommand other than build, test or
//!    bxl is ended and not run again. A farm that sends a byte every 25 ms is
//!    slow but alive: a run that reads 200 of them, so lasts at least 5 s,
//!    more than twice the bound, is never ended, and a real failure after
//!    talking to it is not run again. Without a farm config there is no
//!    watchdog, and the step says so and runs as before.

const std = @import("std");
const t = std.testing;

const Step = struct {
    shell: []const u8 = "",
    run: []const u8 = "",
    env_args: []const u8 = "", // `args` of env BUCK2_ARGS, a `${{ inputs.args }}`
    log: []const u8 = "", // BUCK2_LOG
    tool: []const u8 = "", // ASSERT_REMOTE
    console: []const u8 = "", // BUCK_CONSOLE
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
        if (std.mem.startsWith(u8, trimmed, "BUCK_CONSOLE: ")) s.console = trimmed["BUCK_CONSOLE: ".len..];
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

test "the two steps are the tool running buck2 and the tool reading its log, each in bash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const steps = try loadSteps(arena.allocator());
    try t.expectEqual(@as(usize, 2), steps.len);
    // bash, never sh: a runner's bash is `bash -eo pipefail`, its sh is `sh -e`
    try t.expectEqualStrings("bash", steps[0].shell);
    try t.expectEqualStrings("bash", steps[1].shell);
    try t.expectEqualStrings("\"$ASSERT_REMOTE\" run --log \"$BUCK2_LOG\" --summary \"$GITHUB_STEP_SUMMARY\" --farm-config \"$HOME/.buckconfig.d/farm.buckconfig\" -- ./buck2 $BUCK2_ARGS", steps[0].run);
    try t.expectEqualStrings("\"$ASSERT_REMOTE\" \"$BUCK2_LOG\"", steps[1].run);
}

test "the inputs reach the steps through env, and both steps name the same log and tool" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const steps = try loadSteps(arena.allocator());
    try t.expectEqualStrings("${{ inputs.args }}", steps[0].env_args);
    try t.expectEqualStrings("${{ inputs.assert-remote }}", steps[0].tool);
    try t.expectEqualStrings("${{ inputs.assert-remote }}", steps[1].tool);
    try t.expectEqualStrings("${{ runner.temp }}/buck2-farm.log", steps[0].log);
    try t.expectEqualStrings(steps[0].log, steps[1].log);
}

test "buck2 runs on the simple console, whose waiting lines name what a stalled build waits on" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const steps = try loadSteps(arena.allocator());
    try t.expectEqualStrings("simple", steps[0].console);
    try t.expectEqualStrings("", steps[1].console);
}

/// The text of the step of pr.yml named `name`: from its `- name:` line to the next step.
fn prStep(text: []const u8, name: []const u8) ![]const u8 {
    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "      - name: {s}\n", .{name});
    const start = std.mem.indexOf(u8, text, head) orelse return error.StepMissing;
    const rest = text[start + head.len - 1 ..]; // keeps the newline that ends the `- name:` line
    const end = std.mem.indexOf(u8, rest, "\n      - ") orelse rest.len;
    return rest[0..end];
}

fn minutes(block: []const u8, indent: []const u8) !?u32 {
    var key_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "\n{s}timeout-minutes: ", .{indent});
    const at = std.mem.indexOf(u8, block, key) orelse return null;
    const v = block[at + key.len ..];
    const nl = std.mem.indexOfScalar(u8, v, '\n') orelse v.len;
    return try std.fmt.parseInt(u32, v[0..nl], 10);
}

test "the pull request check bounds its build and test steps well under the job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const path = try std.fs.path.join(ar, &.{ try workDir(ar), "pr.yml" });
    const text = try std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
    const job = (try minutes(text, "    ")) orelse return error.JobHasNoTimeout;
    const build = (try minutes(try prStep(text, "build"), "        ")) orelse return error.BuildHasNoTimeout;
    const tests = (try minutes(try prStep(text, "test"), "        ")) orelse return error.TestHasNoTimeout;
    // the longest recorded check took 91 minutes end to end: a bound under that is a false red
    try t.expect(build >= 120);
    try t.expect(tests >= 60);
    // and the bounds, with the steps between them, end the job before its own limit
    try t.expect(build + tests < job);
    try t.expect(build * 2 <= job);
}

/// The steps of pr.yml's check (each from its `      - ` line to the next) that
/// set no `timeout-minutes` of their own, or set one not under the job's.
fn unboundedSteps(ar: std.mem.Allocator, text: []const u8, job: u32) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const start = std.mem.indexOf(u8, text, "\n    steps:\n") orelse return error.NoSteps;
    var rest = text[start..];
    while (std.mem.indexOf(u8, rest, "\n      - ")) |at| {
        rest = rest[at + 1 ..];
        const end = std.mem.indexOf(u8, rest[1..], "\n      - ") orelse rest.len - 1;
        const step = rest[0 .. end + 1];
        const nl = std.mem.indexOfScalar(u8, step, '\n') orelse step.len;
        const m = try minutes(step, "        ");
        if (m == null or m.? >= job) try out.append(ar, step[0..nl]);
        rest = rest[1..];
    }
    return out.items;
}

test "every step of the pull request check has a bound of its own, under the job's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ try workDir(ar), "pr.yml" }), 1 << 20);
    const job = (try minutes(text, "    ")) orelse return error.JobHasNoTimeout;
    const unbounded = try unboundedSteps(ar, text, job);
    for (unbounded) |l| std.debug.print("no bound of its own: {s}\n", .{l});
    try t.expectEqual(@as(usize, 0), unbounded.len);
    // the reading finds a step that sets none, and one whose bound is the job's
    const without = try std.mem.replaceOwned(u8, ar, text, "      - name: the change\n        timeout-minutes: 10\n", "      - name: the change\n");
    try t.expectEqualStrings("      - name: the change", (try unboundedSteps(ar, without, job))[0]);
    const at_job = try std.mem.replaceOwned(u8, ar, text, "      - name: Stop buck2\n        timeout-minutes: 10\n", "      - name: Stop buck2\n        timeout-minutes: 330\n");
    try t.expectEqualStrings("      - name: Stop buck2", (try unboundedSteps(ar, at_job, job))[0]);
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
        .max_output_bytes = 1 << 22,
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

pub fn recorded(ar: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(ar, "{s}/fixtures/{s}", .{ try workDir(ar), name });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

/// One call of the stand-in buck2: what it prints and how it exits.
pub const Run = struct {
    log: union(enum) {
        /// A recorded log, by file name.
        fixture: []const u8,
        /// A log the case made (a recorded one with lines changed).
        text: []const u8,
    },
    code: u8 = 0,
    /// The signal that ends the call, in place of the exit code.
    signal: ?u8 = null,
    /// The call connects to the farm, sends a request and waits for an answer
    /// that never comes (`stubborn`: with SIGINT ignored), in place of an exit.
    hang: enum { no, yes, stubborn } = .no,
    /// The call connects to the farm, sends a request and reads this many
    /// bytes of its answers before it exits with `code`.
    farm_bytes: ?usize = null,
};

pub fn hanging(log: []const u8) Run {
    return .{ .log = .{ .text = log }, .hang = .yes };
}

/// What a hanging run prints before it waits: buck2's line for an action in
/// `[re_execute]`, as the console prints it every few seconds.
pub const waiting_log = "[2026-11-27T06:15:49.491+00:00] Waiting on komira//src/so:so (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) -- mojo_build_test test_sources [re_execute]\n";

pub fn fixture(name: []const u8, code: u8) Run {
    return .{ .log = .{ .fixture = name }, .code = code };
}

pub fn derived(log: []const u8, code: u8) Run {
    return .{ .log = .{ .text = log }, .code = code };
}

pub const Case = struct {
    /// The exit code of the step that ended the case.
    code: u8,
    /// That step, 1 (the tool running buck2) or 2 (the tool reading the log).
    step: u8,
    /// What step 1 printed, and step 2 if it ran.
    out1: []const u8,
    out2: []const u8,
    /// How many times buck2 ran.
    runs: usize,
    /// How many times `./buck2 kill` ran.
    kills: usize,
    dir: []const u8,

    /// The file `name` of the case's directory, or null if there is none.
    pub fn file(c: Case, ar: std.mem.Allocator, name: []const u8) !?[]const u8 {
        const path = try std.fs.path.join(ar, &.{ c.dir, name });
        return std.fs.cwd().readFileAlloc(ar, path, 1 << 22) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }
};

/// Runs the action's two steps in a directory of the case's own, with
/// `./buck2` the stand-in playing `runs` for `./buck2 <subcommand>`: step 1,
/// and step 2 only if step 1 passed (as a runner skips the later steps of a
/// failed job).
fn runCase(ar: std.mem.Allocator, subcommand: []const u8, runs: []const Run) !Case {
    return runCaseWith(ar, subcommand, runs, .{});
}

/// What a case breaks around the action, to reach the tool's own errors.
pub const Setup = struct {
    /// GITHUB_STEP_SUMMARY is a directory, which cannot be appended to.
    summary_is_dir: bool = false,
    /// BUCK2_LOG is in a directory that does not exist.
    log_dir_missing: bool = false,
    /// There is no `./buck2`.
    no_buck2: bool = false,
    /// The farm the machine buckconfig names, and how the buckconfig is.
    farm: enum {
        /// A listening loopback port: it answers at once.
        answers,
        /// A loopback port bound and not listening, with a longest wait of 0 s.
        never_answers,
        /// No machine buckconfig at all.
        no_config,
        /// A machine buckconfig without `farm_wait_seconds`.
        no_wait,
    } = .answers,
    /// What the farm's port does with a connection once accepted (a farm
    /// that `answers` only); `none` leaves each in the listener's queue.
    serve: Serve = .none,
    /// The watchdog's bound the farm config sets (`dead_connection_seconds`), if any.
    dead_seconds: ?u32 = null,
};

const Serve = enum {
    none,
    /// Reads what the client sends and never sends anything: the half-open case.
    silent,
    /// Sends one byte every 25 ms until the client goes: slow but alive.
    alive,
};

/// The fake farm's side of one connection.
fn answer(stream: std.net.Stream, serve: Serve) void {
    defer stream.close();
    switch (serve) {
        .none => {},
        .silent => {
            var buf: [256]u8 = undefined;
            while (true) {
                const n = stream.read(&buf) catch return;
                if (n == 0) return;
            }
        },
        .alive => while (true) {
            _ = std.posix.send(stream.handle, "o", std.posix.MSG.NOSIGNAL) catch return;
            std.Thread.sleep(25 * std.time.ns_per_ms);
        },
    }
}

/// The fake farm: every connection the listener takes, answered on a thread
/// of its own, until the listener is shut down.
fn serveFarm(server: *std.net.Server, serve: Serve) void {
    while (true) {
        const conn = server.accept() catch return;
        const th = std.Thread.spawn(.{}, answer, .{ conn.stream, serve }) catch {
            conn.stream.close();
            continue;
        };
        th.detach();
    }
}

/// The machine buckconfig farm-connect writes, for a farm at 127.0.0.1:`port`
/// and a longest wait of `wait` (no `[komira_ci]` when null).
fn farmConfig(ar: std.mem.Allocator, port: u16, wait: ?u32, dead: ?u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    if (wait) |s| try out.print(ar, "[komira_ci]\n  farm_wait_seconds = {d}\n", .{s});
    if (dead) |s| try out.print(ar, "[komira_ci]\n  dead_connection_seconds = {d}\n", .{s});
    try out.print(ar, "[buck2_re_client]\n  engine_address = grpc://127.0.0.1:{d}\n  instance_name = main\n  tls = false\n[komira_re]\n  linux_x86_64_properties = OSFamily=Linux\n", .{port});
    return out.items;
}

/// A loopback port of the case's own that refuses every connection: bound, not listening.
fn refusingPort() !struct { fd: std.posix.socket_t, port: u16 } {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    errdefer std.posix.close(fd);
    var addr = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    var len = addr.getOsSockLen();
    try std.posix.getsockname(fd, &addr.any, &len);
    return .{ .fd = fd, .port = addr.getPort() };
}

pub fn runCaseWith(ar: std.mem.Allocator, subcommand: []const u8, runs: []const Run, setup: Setup) !Case {
    const steps = try loadSteps(ar);
    const w = try workDir(ar);
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/case{d}", .{ w, case_no });
    try std.fs.cwd().makePath(dir);
    if (!setup.no_buck2) {
        const buck2 = try std.fs.path.join(ar, &.{ dir, "buck2" });
        try std.fs.cwd().copyFile(try std.process.getEnvVarOwned(ar, "STAND_IN_BUCK2"), std.fs.cwd(), buck2, .{});
        var f = try std.fs.cwd().openFile(buck2, .{});
        try f.chmod(0o755);
        f.close();
    }
    var args = std.ArrayList(u8).empty;
    try args.appendSlice(ar, subcommand);
    for (runs, 0..) |r, i| {
        const path = switch (r.log) {
            .fixture => |n| try std.fmt.allocPrint(ar, "{s}/fixtures/{s}", .{ w, n }),
            .text => |log| p: {
                const p = try std.fmt.allocPrint(ar, "{s}/derived{d}.log", .{ dir, i });
                try std.fs.cwd().writeFile(.{ .sub_path = p, .data = log });
                break :p p;
            },
        };
        if (r.signal) |sig| {
            try args.print(ar, " {s}@sig{d}", .{ path, sig });
        } else if (r.hang == .yes) {
            try args.print(ar, " {s}@hang", .{path});
        } else if (r.hang == .stubborn) {
            try args.print(ar, " {s}@hang-stubborn", .{path});
        } else if (r.farm_bytes) |n| {
            try args.print(ar, " {s}@farm{d}-{d}", .{ path, n, r.code });
        } else {
            try args.print(ar, " {s}@{d}", .{ path, r.code });
        }
    }
    var env = std.process.EnvMap.init(ar);
    try env.put("PATH", try std.process.getEnvVarOwned(ar, "PATH"));
    try env.put("BUCK2_ARGS", args.items);
    try env.put("BUCK2_LOG", try std.fs.path.join(ar, &.{ dir, if (setup.log_dir_missing) "missing/buck2-farm.log" else "buck2-farm.log" }));
    const summary = try std.fs.path.join(ar, &.{ dir, "summary.md" });
    if (setup.summary_is_dir) try std.fs.cwd().makePath(summary);
    try env.put("GITHUB_STEP_SUMMARY", summary);
    try env.put("ASSERT_REMOTE", try std.process.getEnvVarOwned(ar, "ASSERT_REMOTE"));
    // The farm: open for the whole case, closed when it ends.
    try env.put("HOME", dir);
    var listener: ?std.net.Server = null;
    defer if (listener) |*l| l.deinit();
    var refusing: ?std.posix.socket_t = null;
    defer if (refusing) |fd| std.posix.close(fd);
    const config: ?[]const u8 = switch (setup.farm) {
        .answers, .no_wait => c: {
            listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{});
            break :c try farmConfig(ar, listener.?.listen_address.getPort(), if (setup.farm == .answers) 1200 else null, setup.dead_seconds);
        },
        .never_answers => c: {
            const r = try refusingPort();
            refusing = r.fd;
            break :c try farmConfig(ar, r.port, 0, setup.dead_seconds);
        },
        .no_config => null,
    };
    // The fake farm, stopped before the listener is closed: a shut-down
    // listener ends its accept, and each connection's thread ends with its client.
    var server_thread: ?std.Thread = null;
    defer if (server_thread) |th| {
        std.posix.shutdown(listener.?.stream.handle, .both) catch {};
        th.join();
    };
    if (setup.serve != .none) server_thread = try std.Thread.spawn(.{}, serveFarm, .{ &listener.?, setup.serve });
    if (config) |text| {
        const config_dir = try std.fs.path.join(ar, &.{ dir, ".buckconfig.d" });
        try std.fs.cwd().makePath(config_dir);
        try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(ar, &.{ config_dir, "farm.buckconfig" }), .data = text });
    }
    const first = try runLine(ar, dir, steps[0].run, &env);
    var c: Case = .{ .code = first.code, .step = 1, .out1 = first.out, .out2 = "", .runs = 0, .kills = 0, .dir = dir };
    const calls = (try c.file(ar, "stand_in_buck2.calls")) orelse "";
    c.runs = std.mem.count(u8, calls, "\n");
    c.kills = std.mem.count(u8, (try c.file(ar, "stand_in_buck2.kills")) orelse "", "\n");
    if (first.code != 0) return c;
    const second = try runLine(ar, dir, steps[1].run, &env);
    c.code = second.code;
    c.step = 2;
    c.out2 = second.out;
    return c;
}

pub fn has(out: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, out, part) != null;
}

pub fn show(c: Case) void {
    std.debug.print("step {d}, code {d}, {d} run(s), {d} kill(s)\nstep 1:\n{s}\nstep 2:\n{s}\n", .{ c.step, c.code, c.runs, c.kills, c.out1, c.out2 });
}

fn expectPasses(runs: []const Run) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCase(arena.allocator(), "build", runs);
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    // the tool step ran, and said so
    try t.expect(std.mem.startsWith(u8, c.out2, "assert_remote: ok"));
}

test "a build the farm ran passes both steps" {
    try expectPasses(&.{fixture("build_remote.log", 0)});
}

test "a bxl run the farm ran passes" {
    try expectPasses(&.{fixture("bxl_remote.log", 0)});
}

test "a fully cached run, which prints no summary, passes" {
    try expectPasses(&.{fixture("build_cached.log", 0)});
}

/// The case must fail in step 2 (the tool) with `message` in what it printed.
fn expectToolRefuses(runs: []const Run, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCase(arena.allocator(), "build", runs);
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(has(c.out2, message));
}

test "a local action fails the job at the tool step and names the count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.replaceOwned(u8, a, try recorded(a, "build_remote.log"), "local: 0)", "local: 3)");
    try expectToolRefuses(&.{derived(log, 0)}, "3 action(s) ran locally");
}

test "a log with no summary beside network traffic fails the job" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try std.mem.replaceOwned(u8, a, try recorded(a, "build_remote.log"), "Commands:", "Actions:");
    try expectToolRefuses(&.{derived(log, 0)}, "no `Commands:` summary line");
}

test "a failed run that exited 0 fails the job" {
    try expectToolRefuses(&.{fixture("build_failed_unknown_target.log", 0)}, "BUILD FAILED");
}

test "a buck2 that exits non-zero after a good summary fails the first step, run once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCase(arena.allocator(), "build", &.{ fixture("build_remote.log", 1), fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    // the good summary was printed (and copied to the job log), so only the exit code made it fail
    try t.expect(has(c.out1, "local: 0)"));
    try t.expect(has(c.out1, "buck2-farm: not run again: no failed action or test in the log"));
}

// ---- a cut connection to the farm ------------------------------------------------

const summary_line = "buck2-farm: the first run of `build` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)); the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log\n";
const summary_line_second = "buck2-farm: the second run of `build` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)); the farm answered at once; ran again (run 3 of at most 3); the second run's log is buck2-farm.second.log\n";

/// The lines of `log` from the first holding `marker` to the empty line after it.
fn firstBlock(log: []const u8, marker: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, log, marker) orelse return error.NoSuchBlock;
    const start = (std.mem.lastIndexOfScalar(u8, log[0..at], '\n') orelse return error.NoSuchBlock) + 1;
    const end = std.mem.indexOfPos(u8, log, start, "\n\n") orelse return error.NoSuchBlock;
    return log[start .. end + 2];
}

/// `log` without each block whose first line holds `marker`.
fn dropBlocks(a: std.mem.Allocator, log: []const u8, marker: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var dropping = false;
    var it = std.mem.splitScalar(u8, log, '\n');
    var first = true;
    while (it.next()) |l| {
        if (has(l, marker)) dropping = true;
        if (dropping) {
            if (l.len == 0) dropping = false;
            continue;
        }
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, l);
    }
    return out.toOwnedSlice(a);
}

/// The recorded build with a compile error and cuts, without its cuts: a compile error alone.
pub fn compileError(a: std.mem.Allocator) ![]u8 {
    const log = try dropBlocks(a, try recorded(a, "build_cut_and_compile_error.log"), "Action failed: komira//tools/build/proto-codegen");
    try t.expect(!has(log, "RE channel error"));
    return log;
}

/// The recorded test failure with one recorded cut block before it.
fn testFailureAndCut(a: std.mem.Allocator) ![]u8 {
    const cut = try firstBlock(try recorded(a, "build_cut.log"), "Action failed: ");
    const failed = try recorded(a, "test_failed.log");
    const at = std.mem.indexOf(u8, failed, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail:") orelse return error.NoFail;
    return std.mem.concat(a, u8, &.{ failed[0..at], cut, failed[at..] });
}

test "a cut, then a pass: green after two runs, the job summary says so, and the first log is kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqualStrings(summary_line, (try c.file(a, "summary.md")).?);
    try t.expect(has(c.out1, summary_line));
    try t.expect(has(c.out1, "buck2-farm: the second run passed\n"));
    // both runs reached the job log; the first is kept whole, the tool step read the second
    try t.expect(has(c.out1, "RE channel error: code: "));
    try t.expectEqualStrings(try recorded(a, "build_cut.log"), (try c.file(a, "buck2-farm.first.log")).?);
    try t.expectEqualStrings(try recorded(a, "build_remote.log"), (try c.file(a, "buck2-farm.log")).?);
    try t.expect(std.mem.startsWith(u8, c.out2, "assert_remote: ok"));
}

test "a test step cut, then a pass: green after two runs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cut = try firstBlock(try recorded(a, "build_cut.log"), "Action failed: ");
    const log = try std.mem.concat(a, u8, &.{ cut, "Tests finished: Pass 3. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n1 BUILDS FAILED\n" });
    const c = try runCase(a, "test", &.{ derived(log, 2), fixture("test_cached_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqualStrings("buck2-farm: the first run of `test` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 1 failed block(s)); the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log\n", (try c.file(a, "summary.md")).?);
}

test "a cut twice, then a pass: green after three runs, a summary line for each cut, both cut logs kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_cut.log", 2), fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 3), c.runs);
    try t.expectEqualStrings(summary_line ++ summary_line_second, (try c.file(a, "summary.md")).?);
    try t.expect(has(c.out1, "buck2-farm: the third run passed\n"));
    try t.expectEqualStrings(try recorded(a, "build_cut.log"), (try c.file(a, "buck2-farm.first.log")).?);
    try t.expectEqualStrings(try recorded(a, "build_cut.log"), (try c.file(a, "buck2-farm.second.log")).?);
    try t.expectEqualStrings(try recorded(a, "build_remote.log"), (try c.file(a, "buck2-farm.log")).?);
    try t.expect(std.mem.startsWith(u8, c.out2, "assert_remote: ok"));
}

test "a cut three times: red after three runs, never a fourth, saying the third run was cut too" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_cut.log", 2), fixture("build_cut.log", 2), fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code); // buck2's own exit code
    try t.expectEqual(@as(usize, 3), c.runs);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the third run was cut too: the connection to the farm was cut in each of 3 runs (buck2's `RE channel error`); not run again\n"));
    try t.expectEqualStrings(summary_line ++ summary_line_second, (try c.file(a, "summary.md")).?);
    try t.expect((try c.file(a, "buck2-farm.first.log")) != null);
    try t.expect((try c.file(a, "buck2-farm.second.log")) != null);
    // the third run's log stays where the tool step and later steps read it
    try t.expectEqualStrings(try recorded(a, "build_cut.log"), (try c.file(a, "buck2-farm.log")).?);
}

// ---- a job the farm failed to start ---------------------------------------------

const unavailable_summary = "buck2-farm: the first run of `build` had jobs the farm failed to start (the farm's `input-unavailable` in each of 2 failed block(s)); the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log\n";
const unavailable_summary_second = "buck2-farm: the second run of `build` had jobs the farm failed to start (the farm's `input-unavailable` in each of 2 failed block(s)); the farm answered at once; ran again (run 3 of at most 3); the second run's log is buck2-farm.second.log\n";

test "a job the farm failed to start, then a pass: green after two runs, the summary names input-unavailable, the first log kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, "build", &.{ fixture("build_input_unavailable.log", 2), fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqualStrings(unavailable_summary, (try c.file(a, "summary.md")).?);
    try t.expect(has(c.out1, unavailable_summary));
    try t.expect(has(c.out1, "buck2-farm: the second run passed\n"));
    try t.expectEqualStrings(try recorded(a, "build_input_unavailable.log"), (try c.file(a, "buck2-farm.first.log")).?);
    try t.expectEqualStrings(try recorded(a, "build_remote.log"), (try c.file(a, "buck2-farm.log")).?);
    try t.expect(std.mem.startsWith(u8, c.out2, "assert_remote: ok"));
}

test "a job the farm failed to start three times: red after three runs, never a fourth, saying the third failed on the farm too" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = fixture("build_input_unavailable.log", 2);
    const c = try runCase(a, "build", &.{ u, u, u, fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code); // buck2's own exit code
    try t.expectEqual(@as(usize, 3), c.runs);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the third run failed on the farm too, as each of 3 runs did: it had jobs the farm failed to start (the farm's `input-unavailable` in each of 2 failed block(s)); not run again\n"));
    try t.expectEqualStrings(unavailable_summary ++ unavailable_summary_second, (try c.file(a, "summary.md")).?);
    try t.expectEqualStrings(try recorded(a, "build_input_unavailable.log"), (try c.file(a, "buck2-farm.log")).?);
}

test "a cut while the farm does not answer within the longest wait: red after one run, the summary names the wait" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCaseWith(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_remote.log", 0) }, .{ .farm = .never_answers });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code); // buck2's own exit code
    try t.expectEqual(@as(usize, 1), c.runs);
    const line = "buck2-farm: the first run of `build` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)); farm unreachable for 0 min 0 s, the longest wait; not run again\n";
    try t.expectEqualStrings(line, (try c.file(a, "summary.md")).?);
    try t.expect(std.mem.endsWith(u8, c.out1, line ++ "buck2-farm: FAILED: the farm did not answer within the longest wait\n"));
    // not run again, so the cut run's log is not moved
    try t.expect((try c.file(a, "buck2-farm.first.log")) == null);
    try t.expectEqualStrings(try recorded(a, "build_cut.log"), (try c.file(a, "buck2-farm.log")).?);
}

/// A cut step whose farm config cannot give a farm: exit 2 after one run, `why` said, no summary.
fn expectNoFarm(setup: Setup, why: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCaseWith(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_remote.log", 0) }, setup);
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expect(has(c.out1, why));
    try t.expect((try c.file(a, "summary.md")) == null);
    try t.expect((try c.file(a, "buck2-farm.first.log")) == null);
}

test "a cut with no machine buckconfig ends the step with exit 2, not run again" {
    try expectNoFarm(.{ .farm = .no_config }, "buck2-farm: not run again: cannot read the farm config ");
}

test "a cut with a machine buckconfig that names no longest wait ends the step with exit 2, not run again" {
    try expectNoFarm(.{ .farm = .no_wait }, "names no farm: it has no farm_wait_seconds under [komira_ci]\n");
}

test "a passing run passes without the farm config, with no watchdog and a line saying so" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCaseWith(arena.allocator(), "build", &.{fixture("build_remote.log", 0)}, .{ .farm = .no_config });
    errdefer show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expect(has(c.out1, "buck2-farm: no watchdog on the connection to the farm: cannot read the farm config "));
    try t.expectEqual(@as(usize, 0), c.kills);
}

test "a real failure is final without the farm config, with buck2's own exit code" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCaseWith(a, "build", &.{ derived(try compileError(a), 3), fixture("build_remote.log", 0) }, .{ .farm = .no_config });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 3), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expect(has(c.out1, "buck2-farm: not run again: a failure that is not a cut connection: "));
}

test "a cut, then a real failure: red, naming the failure of the second run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), derived(try compileError(a), 3) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 3), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the second run failed: a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))\n"));
}

/// The case must fail in step 1 after one run, with buck2's exit code and
/// `why` after `not run again: `, keeping no first log and writing no summary.
fn expectNotRunAgain(subcommand: []const u8, first: Run, why: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCase(a, subcommand, &.{ first, fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(first.code, c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    const want = try std.fmt.allocPrint(a, "buck2-farm: not run again: {s}\n", .{why});
    try t.expect(std.mem.endsWith(u8, c.out1, want));
    try t.expect((try c.file(a, "buck2-farm.first.log")) == null);
    try t.expect((try c.file(a, "summary.md")) == null);
}

test "a compile error is not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectNotRunAgain("build", derived(try compileError(arena.allocator()), 3), "a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))");
}

test "a build with a compile error beside cuts is red after one run" {
    try expectNotRunAgain("build", fixture("build_cut_and_compile_error.log", 3), "a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))");
}

test "one real test failure and one cut: red after one run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectNotRunAgain("test", derived(try testFailureAndCut(arena.allocator()), 32), "a failure that is not a cut connection: [2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: komira//src/komira_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a failed test whose output prints buck2's cut line is not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cut_line = "[2026-10-25T13:04:11.131+00:00] Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: \"h2 protocol error\", source: None)\n";
    const log = try std.mem.replaceOwned(u8, a, try recorded(a, "test_failed.log"), "[2026-10-25T13:04:11.131+00:00] GATED TEST FAILED", cut_line ++ "[2026-10-25T13:04:11.131+00:00] GATED TEST FAILED");
    try expectNotRunAgain("test", derived(log, 32), "a failure that is not a cut connection: [2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: komira//src/komira_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a subcommand other than build, test or bxl is never run again, even after a cut" {
    try expectNotRunAgain("run", fixture("build_cut.log", 2), "`run` is not build, test or bxl");
}

test "a second run that ran an action locally is refused at the tool step" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = try std.mem.replaceOwned(u8, a, try recorded(a, "build_remote.log"), "local: 0)", "local: 3)");
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), derived(local, 0) });
    errdefer show(c);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(has(c.out2, "3 action(s) ran locally"));
}

// ---- a killed buck2, and the tool's own errors ----------------------------------

test "a buck2 ended by a signal is not run again, even when its output reads as a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var killed = fixture("build_cut.log", 0);
    killed.signal = 9;
    const c = try runCase(a, "build", &.{ killed, fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 137), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: not run again: buck2 was ended by signal 9\n"));
    try t.expect((try c.file(a, "buck2-farm.first.log")) == null);
    try t.expect((try c.file(a, "summary.md")) == null);
}

test "a cut, then a second run ended by a signal: red after two runs, saying so" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var killed = fixture("build_remote.log", 0);
    killed.signal = 9;
    const c = try runCase(a, "build", &.{ fixture("build_cut.log", 2), killed, fixture("build_remote.log", 0) });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 137), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the second run was ended by signal 9\n"));
}

test "a job summary that cannot be written stops the step before the second run, with exit 2" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try runCaseWith(a, "build", &.{ fixture("build_cut.log", 2), fixture("build_remote.log", 0) }, .{ .summary_is_dir = true });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expect(has(c.out1, "buck2-farm: cannot write the job summary "));
}

test "a log that cannot be written stops the step before buck2 runs, with exit 2" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCaseWith(arena.allocator(), "build", &.{fixture("build_remote.log", 0)}, .{ .log_dir_missing = true });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 2), c.code);
    try t.expectEqual(@as(usize, 0), c.runs);
    try t.expect(has(c.out1, "buck2-farm: cannot run the command or write "));
}

test "a buck2 that cannot be run fails the step with 127 and is not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try runCaseWith(arena.allocator(), "build", &.{fixture("build_remote.log", 0)}, .{ .no_buck2 = true });
    errdefer show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 127), c.code);
    try t.expect(has(c.out1, "assert_remote run: cannot run ./buck2: FileNotFound\n"));
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: not run again: an error outside the failed actions and tests: assert_remote run: cannot run ./buck2: FileNotFound\n"));
}

// The cases of a run that hangs on a dead connection to the farm.
test {
    _ = @import("watchdog_cases.zig");
}
