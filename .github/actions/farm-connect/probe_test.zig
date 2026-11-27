//! The cases of farm-connect's wait for the farm (the step `refuse unless the
//! farm answers` of action.yml), part of //:farm_connect_cases (action_test.zig
//! imports this file).
//!
//! The step's own script runs with the busybox `sh`, after three shell
//! functions that stand in for the commands it calls, so no case touches the
//! network or sleeps: `date` reads a clock file of the case, `sleep` adds its
//! seconds to it (and records them), and `timeout`, the probe, records its host
//! and port and answers once the clock reaches the case's `answer_from`; a probe
//! it does not answer moves the clock by the case's `cost`, as a connection left
//! unanswered for its 5 s does. The clock starts far from 0, so a step that
//! printed the clock itself instead of the time waited would fail.
//!
//! What the cases catch: a farm that answers the first probe passes with no
//! summary line; one back after three minutes passes with the time it was
//! unreachable in the job summary and a line each minute in the job log; one
//! that never answers fails once the default bound (20 minutes) has passed,
//! with the wait in the summary and the error, never sooner and never with a
//! build; the last sleep is cut to the bound; the probe goes to the host and
//! port of FARM_ADDRESS; an address with no port is refused before any probe.

const std = @import("std");
const t = std.testing;
const at = @import("action_test.zig");

/// The stand-ins, prepended to the step's script.
const STUBS =
    \\date() { cat "$CLOCK"; }
    \\sleep() { echo $(($(cat "$CLOCK") + $1)) > "$CLOCK"; echo "$1" >> "$SLEEPS"; }
    \\timeout() {
    \\  echo "$5 $6" >> "$PROBES"
    \\  now=$(cat "$CLOCK")
    \\  if [ -n "$ANSWER_FROM" ] && [ "$now" -ge "$((START + ANSWER_FROM))" ]; then return 0; fi
    \\  echo $((now + COST)) > "$CLOCK"
    \\  return 1
    \\}
    \\
;

const START = "1800000000";

const Farm = struct {
    /// Seconds after the start from which the farm answers; null: never.
    answer_from: ?u64,
    /// Seconds an unanswered probe takes.
    cost: u64 = 5,
};

const Probed = struct {
    code: u8,
    out: []const u8,
    /// The job summary, or null when nothing was written to it.
    summary: ?[]const u8,
    /// One `<host> <port>` line per probe.
    probes: []const u8,
    /// One line per sleep, its seconds.
    sleeps: []const u8,
};

fn runProbe(ar: std.mem.Allocator, values: []const at.Value, farm: Farm) !Probed {
    const action = try at.loadAction(ar);
    const s = try at.step(action, at.PROBE);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(ar, ".");
    const clock = try std.fs.path.join(ar, &.{ dir, "clock" });
    try std.fs.cwd().writeFile(.{ .sub_path = clock, .data = START ++ "\n" });
    var env = std.process.EnvMap.init(ar);
    try env.put("PATH", try std.process.getEnvVarOwned(ar, "PATH"));
    for (s.env) |e| try env.put(e.name, if (e.input) |in| try at.valueOf(action, values, in) else e.literal);
    try env.put("GITHUB_STEP_SUMMARY", try std.fs.path.join(ar, &.{ dir, "summary.md" }));
    try env.put("CLOCK", clock);
    try env.put("START", START);
    try env.put("PROBES", try std.fs.path.join(ar, &.{ dir, "probes" }));
    try env.put("SLEEPS", try std.fs.path.join(ar, &.{ dir, "sleeps" }));
    try env.put("ANSWER_FROM", if (farm.answer_from) |f| try std.fmt.allocPrint(ar, "{d}", .{f}) else "");
    try env.put("COST", try std.fmt.allocPrint(ar, "{d}", .{farm.cost}));
    const script = try std.mem.concat(ar, u8, &.{ STUBS, s.run.? });
    const r = try std.process.Child.run(.{
        .allocator = ar,
        .argv = &.{ "sh", "-e", "-c", script },
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{
        .code = code,
        .out = try std.mem.concat(ar, u8, &.{ r.stdout, r.stderr }),
        .summary = tmp.dir.readFileAlloc(ar, "summary.md", 1 << 20) catch null,
        .probes = tmp.dir.readFileAlloc(ar, "probes", 1 << 20) catch "",
        .sleeps = tmp.dir.readFileAlloc(ar, "sleeps", 1 << 20) catch "",
    };
}

fn show(p: Probed) void {
    std.debug.print("exit {d}\nout:\n{s}\nsummary:\n{?s}\nsleeps:\n{s}\n", .{ p.code, p.out, p.summary, p.sleeps });
}

test "a farm that answers the first probe: on at once, nothing in the job summary" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try runProbe(arena.allocator(), &.{}, .{ .answer_from = 0 });
    errdefer show(p);
    try t.expectEqual(@as(u8, 0), p.code);
    try t.expectEqualStrings("the farm answers on its port\n", p.out);
    try t.expect(p.summary == null);
    // the probe goes to FARM_ADDRESS's host and port
    try t.expectEqualStrings("re.example.com 8980\n", p.probes);
    try t.expectEqualStrings("", p.sleeps);
}

test "a farm back after three minutes: on, the time unreachable in the job summary, a line each minute" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try runProbe(arena.allocator(), &.{}, .{ .answer_from = 185 });
    errdefer show(p);
    try t.expectEqual(@as(u8, 0), p.code);
    // probes start at 0, 10, 20, ...: each unanswered one takes 5 s, then 5 s of sleep
    const line = "farm-connect: farm unreachable for 3 min 10 s; went on when it answered (probe 20)\n";
    try t.expectEqualStrings(line, p.summary orelse "<no summary>");
    try t.expectEqualStrings(
        "farm-connect: the farm has not answered for 1 min 5 s; waiting up to 20 min 0 s\n" ++
            "farm-connect: the farm has not answered for 2 min 5 s; waiting up to 20 min 0 s\n" ++
            "farm-connect: the farm has not answered for 3 min 5 s; waiting up to 20 min 0 s\n" ++
            line,
        p.out,
    );
    try t.expectEqual(@as(usize, 20), std.mem.count(u8, p.probes, "\n"));
}

test "a farm that never answers: refused once the default 20 minutes have passed, the wait in the summary and the error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try runProbe(arena.allocator(), &.{}, .{ .answer_from = null });
    errdefer show(p);
    try t.expectEqual(@as(u8, 1), p.code);
    // the probe that starts at the bound (1200 s) is the last; it takes its 5 s
    try t.expectEqualStrings("farm-connect: farm unreachable for 20 min 5 s, the longest wait; not building\n", p.summary orelse "<no summary>");
    try t.expect(std.mem.indexOf(u8, p.out, "::error title=farm-connect::the farm does not answer from this job after joining the tailnet: unreachable for 20 min 5 s, the longest wait (farm-wait-minutes 20). Not building") != null);
    try t.expectEqual(@as(usize, 121), std.mem.count(u8, p.probes, "\n"));
    try t.expectEqual(@as(usize, 19), std.mem.count(u8, p.out, "has not answered for"));
    try t.expect(std.mem.indexOf(u8, p.out, "farm-connect: the farm has not answered for 19 min 5 s; waiting up to 20 min 0 s\n") != null);
}

test "the last sleep is cut to the bound, and a probe starts at the bound" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // a probe of 3 s: probes start at 0, 8, ..., 56; after the one at 56 the bound is 1 s away
    const p = try runProbe(arena.allocator(), &.{.{ .name = "farm-wait-minutes", .value = "1" }}, .{ .answer_from = null, .cost = 3 });
    errdefer show(p);
    try t.expectEqual(@as(u8, 1), p.code);
    try t.expectEqualStrings("5\n5\n5\n5\n5\n5\n5\n1\n", p.sleeps);
    try t.expectEqual(@as(usize, 9), std.mem.count(u8, p.probes, "\n"));
    try t.expectEqualStrings("farm-connect: farm unreachable for 1 min 3 s, the longest wait; not building\n", p.summary orelse "<no summary>");
}

test "an address with no port is refused before any probe" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try runProbe(arena.allocator(), &.{.{ .name = "farm-address", .value = "grpc://re.example.com" }}, .{ .answer_from = 0 });
    errdefer show(p);
    try t.expectEqual(@as(u8, 1), p.code);
    try t.expect(std.mem.indexOf(u8, p.out, "FARM_ADDRESS has no numeric port") != null);
    try t.expectEqualStrings("", p.probes);
}
