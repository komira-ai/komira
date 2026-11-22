//! The cases of the pull request's check on both of its events, //:pr_workflow_cases: a `zig_test`
//! run as a build action. The subjects are the bytes of the workflows (the zig_test's `data`, under
//! KOMIRA_TEST_WORK/workflows/<name>.yml) and of docs/ci.md (KOMIRA_TEST_WORK/ci.md).
//!
//! The decision these hold: main takes pull requests only through GitHub's merge queue, and the one
//! required status check, `check`, is the job `check` of pr.yml for a pull request and for a merge
//! group alike (docs/ci.md, "The merge queue"). A required check that never reports on a merge group
//! holds the queue until its timeout, and one whose job is skipped there counts as passed, so the queue
//! would merge what nothing built.
//! What the cases catch:
//!  - pr.yml's `on:` is exactly `pull_request` into main and `merge_group` of type `checks_requested`
//!    into main: no merge group trigger, another event, type or branch is refused;
//!  - the job `check` exists once, and its `if:` lets every merge group through (and a pull request only
//!    from a branch of this repository); a step's `if:` never names the event, so no step is left out
//!    of one event's run;
//!  - the concurrency group falls back to the ref when there is no pull request number, so merge groups
//!    never share one group and cancel each other;
//!  - the change is written by the change tool (tools/build/ci/change, whose own cases run its choice
//!    of base: HEAD^1 of a pull request's merge commit, the base_sha of a merge group): the job builds
//!    the tool before the step, and the step runs it alone, with the event, the merge group's
//!    base_sha and the output directory; the job never reads the moving `pull_request.base.sha`;
//!  - the job's `timeout-minutes` is below the queue's `check_response_timeout_minutes` that docs/ci.md
//!    sets, so a stalled check ends red before the queue gives up on it;
//!  - no other workflow has a job `check`, so the required context has one source.
//! Every defect above is planted in the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const JOB = "check";
const ON = [_][]const u8{
    "  pull_request:",
    "    branches: [main]",
    "  merge_group:",
    "    types: [checks_requested]",
    "    branches: [main]",
};
const CONDITION = "    if: github.event_name == 'merge_group' || github.event.pull_request.head.repo.full_name == github.repository";
const GROUP = "pr-${{ github.event.pull_request.number || github.ref }}";
const GROUP_BASE = "          GROUP_BASE: ${{ github.event.merge_group.base_sha }}";
const BUILD_CHANGE = "        run: echo \"path=$(./buck2 build komira//tools/build/ci:change --show-full-simple-output)\" >> \"$GITHUB_OUTPUT\"";
const CHANGE_ID = "        id: change";
const CHANGE_PATH = "          CHANGE: ${{ steps.change.outputs.path }}";
const RUN_CHANGE = "        run: '\"$CHANGE\" --event \"$GITHUB_EVENT_NAME\" --group-base \"$GROUP_BASE\" --out \"$RUNNER_TEMP\"'";
const QUEUE_TIMEOUT_KEY = "\"check_response_timeout_minutes\": ";

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimLeft(u8, line, " ").len;
}

/// The lines under the top-level key `key:` (without comments and blank lines), or null when the
/// workflow has no such key.
fn topLines(ar: std.mem.Allocator, text: []const u8, key: []const u8) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (line[0] != ' ') {
            inside = line.len == key.len + 1 and std.mem.startsWith(u8, line, key) and line[key.len] == ':';
            if (inside) found = true;
            continue;
        }
        if (inside) try out.append(ar, line);
    }
    if (!found) return null;
    return try out.toOwnedSlice(ar);
}

/// The ids of the jobs of `jobs:` (keys at two spaces of indent), in order.
fn jobIds(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const lines = (try topLines(ar, text, "jobs")) orelse return out.toOwnedSlice(ar);
    for (lines) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (indentOf(line) == 2 and std.mem.endsWith(u8, trimmed, ":")) try out.append(ar, trimmed[0 .. trimmed.len - 1]);
    }
    return out.toOwnedSlice(ar);
}

/// The lines of the job `name` (without comments and blank lines), or null; `count` is how many jobs
/// have that id.
fn jobLines(ar: std.mem.Allocator, text: []const u8, name: []const u8, count: *usize) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const lines = (try topLines(ar, text, "jobs")) orelse return null;
    var inside = false;
    var found = false;
    for (lines) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (indentOf(line) == 2 and std.mem.endsWith(u8, trimmed, ":")) {
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

/// The lines of the step whose `- name:` is `name` (its name line first), up to the next step.
fn stepLines(job: []const []const u8, name: []const u8) ?[]const []const u8 {
    var start: ?usize = null;
    for (job, 0..) |line, i| {
        const is_step = std.mem.startsWith(u8, line, "      - ");
        if (start) |s| {
            if (is_step) return job[s..i];
        } else if (is_step and std.mem.eql(u8, std.mem.trim(u8, line["      - ".len..], " "), name)) {
            start = i;
        }
    }
    if (start) |s| return job[s..];
    return null;
}

fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

fn mentions(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

/// The value of `key` under the top-level `concurrency:`, or null.
fn concurrencyValue(ar: std.mem.Allocator, text: []const u8, key: []const u8) !?[]const u8 {
    const lines = (try topLines(ar, text, "concurrency")) orelse return null;
    for (lines) |line| {
        const rest = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, rest, key) and rest.len > key.len and rest[key.len] == ':') return std.mem.trim(u8, rest[key.len + 1 ..], " ");
    }
    return null;
}

/// The job's own `timeout-minutes` (at four spaces), or null.
fn jobMinutes(job: []const []const u8) !?u32 {
    const key = "    timeout-minutes: ";
    for (job) |line| if (std.mem.startsWith(u8, line, key)) return try std.fmt.parseInt(u32, line[key.len..], 10);
    return null;
}

/// The queue's `check_response_timeout_minutes` as docs/ci.md sets it, or null.
fn queueTimeout(doc: []const u8) !?u32 {
    const at = std.mem.indexOf(u8, doc, QUEUE_TIMEOUT_KEY) orelse return null;
    const v = doc[at + QUEUE_TIMEOUT_KEY.len ..];
    var end: usize = 0;
    while (end < v.len and std.ascii.isDigit(v[end])) end += 1;
    if (end == 0) return null;
    return try std.fmt.parseInt(u32, v[0..end], 10);
}

/// Null if pr.yml holds the check's contract on both events (against the queue timeout of `doc`),
/// else the refusal.
fn checkPr(ar: std.mem.Allocator, text: []const u8, doc: []const u8) !?[]const u8 {
    const on = (try topLines(ar, text, "on")) orelse return "pr.yml has no on:";
    if (!mentions(on, "merge_group")) return "pr.yml does not run on a merge group: the required check would never report there and would hold the queue";
    if (on.len != ON.len) return "pr.yml's on: is not exactly pull_request into main and merge_group of type checks_requested into main";
    for (on, ON) |got, want| if (!std.mem.eql(u8, got, want)) return "pr.yml's on: is not exactly pull_request into main and merge_group of type checks_requested into main";

    var count: usize = 0;
    const job = (try jobLines(ar, text, JOB, &count)) orelse return "pr.yml has no job check: the required context check would never report";
    if (count != 1) return "pr.yml has more than one job check";
    var ifs: usize = 0;
    for (job) |line| {
        if (std.mem.startsWith(u8, line, "    if:")) ifs += 1;
        if (indentOf(line) > 4 and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " -"), "if:") and std.mem.indexOf(u8, line, "github.event") != null)
            return "a step of the job check has an if: on the event: that step would be left out of one event's run";
    }
    if (ifs != 1 or !has(job, CONDITION)) return "the job check's if: does not let every merge group through: a skipped job counts as passed, and the queue would merge what nothing built";

    const group = (try concurrencyValue(ar, text, "group")) orelse return "pr.yml has no concurrency group";
    if (!std.mem.eql(u8, group, GROUP)) return "pr.yml's concurrency group is not the pull request number with the ref as fallback: merge groups would share one group and cancel each other";

    const tool = stepLines(job, "name: build the change tool") orelse return "the job check does not build the change tool";
    if (!has(tool, CHANGE_ID) or !has(tool, BUILD_CHANGE)) return "the job check does not build the change tool";
    const change = stepLines(job, "name: the change") orelse return "the job check has no step the change";
    if (!has(change, GROUP_BASE)) return "the step the change does not read the merge group's base_sha";
    // the base of each event is chosen by the tool (tools/build/ci/change, whose cases run it);
    // the step runs it, and nothing else, with the event, the group base and where to write
    var runs: usize = 0;
    for (change) |line| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "run:")) runs += 1;
    }
    if (runs != 1 or !has(change, CHANGE_PATH) or !has(change, RUN_CHANGE)) return "the step the change does not run the change tool, alone, with the event, the group base and the output directory";
    if (@intFromPtr(tool.ptr) > @intFromPtr(change.ptr)) return "the job check runs the change before it builds the change tool";
    if (mentions(job, "pull_request.base.sha")) return "the job check reads pull_request.base.sha, which is main when the event fired, not the change base";

    const minutes = (try jobMinutes(job)) orelse return "the job check has no timeout-minutes";
    const limit = (try queueTimeout(doc)) orelse return "docs/ci.md sets no check_response_timeout_minutes for the queue";
    if (minutes >= limit) return "the job check's timeout-minutes is not below the queue's check_response_timeout_minutes: the queue would give up before the check ends";
    return null;
}

/// Null if no workflow other than pr.yml has a job `check`, else the refusal.
fn checkOneSource(ar: std.mem.Allocator, name: []const u8, text: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "pr.yml")) return null;
    for (try jobIds(ar, text)) |id| if (std.mem.eql(u8, id, JOB)) return "a workflow other than pr.yml has a job check: the required context would have two sources";
    return null;
}

fn readData(ar: std.mem.Allocator, rel: []const []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    var parts = std.ArrayList([]const u8).empty;
    try parts.append(ar, w);
    try parts.appendSlice(ar, rel);
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, parts.items), 1 << 22);
}

fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the case's anchor is not in the text: {s}\n", .{from});
        return error.NoAnchor;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

/// `text` with the step that starts at `step` (up to the next step) moved to just before `before`.
fn moved(ar: std.mem.Allocator, text: []const u8, step: []const u8, before: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, text, step) orelse return error.NoAnchor;
    const rest = text[start + step.len ..];
    const end = start + step.len + (std.mem.indexOf(u8, rest, "\n      - ") orelse return error.NoAnchor) + 1;
    const block = text[start..end];
    const without = try std.mem.concat(ar, u8, &.{ text[0..start], text[end..] });
    return replaced(ar, without, before, try std.mem.concat(ar, u8, &.{ block, before }));
}

fn expectRefused(ar: std.mem.Allocator, text: []const u8, doc: []const u8, want: []const u8) !void {
    const got = (try checkPr(ar, text, doc)) orelse {
        std.debug.print("accepted a pr.yml that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "the real pr.yml reports the check on a pull request and on a merge group, and no other workflow has a job check" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    const doc = try readData(ar, &.{"ci.md"});
    if (try checkPr(ar, pr, doc)) |why| {
        std.debug.print("pr.yml: {s}\n", .{why});
        return error.Refused;
    }
    const path = try std.fs.path.join(ar, &.{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), "workflows" });
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var read: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".yml")) continue;
        read += 1;
        if (try checkOneSource(ar, e.name, try dir.readFileAlloc(ar, e.name, 1 << 22))) |why| {
            std.debug.print("{s}: {s}\n", .{ e.name, why });
            return error.Refused;
        }
    }
    // pr.yml, coverage.yml, release.yml and the others are read: an empty directory proves nothing
    try t.expect(read >= 3);
}

test "each edit of the real pr.yml that leaves a merge group without the check is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const pr = try readData(ar, &.{ "workflows", "pr.yml" });
    const doc = try readData(ar, &.{"ci.md"});
    // the trigger
    try expectRefused(ar, try replaced(ar, pr, "  merge_group:\n    types: [checks_requested]\n    branches: [main]\n", ""), doc, "does not run on a merge group");
    try expectRefused(ar, try replaced(ar, pr, "    types: [checks_requested]\n    branches: [main]\n", "    types: [checks_requested]\n"), doc, "on: is not exactly");
    try expectRefused(ar, try replaced(ar, pr, "    types: [checks_requested]\n", ""), doc, "on: is not exactly");
    try expectRefused(ar, try replaced(ar, pr, "    types: [checks_requested]\n", "    types: [destroyed]\n"), doc, "on: is not exactly");
    try expectRefused(ar, try replaced(ar, pr, "  merge_group:\n", "  push:\n  merge_group:\n"), doc, "on: is not exactly");
    try expectRefused(ar, try replaced(ar, pr, "    branches: [main]\n", "    branches: [main, release]\n"), doc, "on: is not exactly");
    // the job's condition: today's pull-request-only condition skips every merge group
    try expectRefused(ar, try replaced(ar, pr, CONDITION ++ "\n", "    if: github.event.pull_request.head.repo.full_name == github.repository\n"), doc, "does not let every merge group through");
    try expectRefused(ar, try replaced(ar, pr, CONDITION ++ "\n", "    if: github.event_name == 'pull_request'\n"), doc, "does not let every merge group through");
    try expectRefused(ar, try replaced(ar, pr, CONDITION ++ "\n", ""), doc, "does not let every merge group through");
    try expectRefused(ar, try replaced(ar, pr, CONDITION ++ "\n", CONDITION ++ "\n    if: false\n"), doc, "does not let every merge group through");
    // a step left out of one event
    try expectRefused(ar, try replaced(ar, pr, "      - name: build\n", "      - name: build\n        if: github.event_name == 'pull_request'\n"), doc, "a step of the job check has an if: on the event");
    // the job itself
    try expectRefused(ar, try replaced(ar, pr, "\n  check:\n", "\n  build:\n"), doc, "has no job check");
    try expectRefused(ar, try std.fmt.allocPrint(ar, "{s}\n  check:\n    runs-on: ubuntu-24.04\n", .{pr}), doc, "more than one job check");
    // the concurrency group: the pull request number alone is empty on every merge group
    try expectRefused(ar, try replaced(ar, pr, "  group: " ++ GROUP ++ "\n", "  group: pr-${{ github.event.pull_request.number }}\n"), doc, "merge groups would share one group");
    try expectRefused(ar, try replaced(ar, pr, "  group: " ++ GROUP ++ "\n", ""), doc, "has no concurrency group");
    // the change base
    try expectRefused(ar, try replaced(ar, pr, GROUP_BASE ++ "\n", "          GROUP_BASE: ${{ github.event.merge_group.head_sha }}\n"), doc, "does not read the merge group's base_sha");
    // the change tool: built, and run alone with the event, the group base and the output directory
    try expectRefused(ar, try replaced(ar, pr, "      - name: build the change tool\n", "      - name: build the tools\n"), doc, "does not build the change tool");
    try expectRefused(ar, try replaced(ar, pr, BUILD_CHANGE ++ "\n", "        run: echo \"path=$(./buck2 build komira//tools/build/ci:assert_remote --show-full-simple-output)\" >> \"$GITHUB_OUTPUT\"\n"), doc, "does not build the change tool");
    try expectRefused(ar, try replaced(ar, pr, CHANGE_ID ++ "\n", "        id: tool\n"), doc, "does not build the change tool");
    try expectRefused(ar, try replaced(ar, pr, RUN_CHANGE ++ "\n", "        run: '\"$CHANGE\" --event pull_request --group-base \"$GROUP_BASE\" --out \"$RUNNER_TEMP\"'\n"), doc, "does not run the change tool");
    try expectRefused(ar, try replaced(ar, pr, RUN_CHANGE ++ "\n", "        run: '\"$CHANGE\" --event \"$GITHUB_EVENT_NAME\" --group-base \"\" --out \"$RUNNER_TEMP\"'\n"), doc, "does not run the change tool");
    try expectRefused(ar, try replaced(ar, pr, RUN_CHANGE ++ "\n", "        run: git diff --name-only HEAD^1...HEAD > \"$RUNNER_TEMP/changed.txt\"\n"), doc, "does not run the change tool");
    try expectRefused(ar, try replaced(ar, pr, RUN_CHANGE ++ "\n", RUN_CHANGE ++ "\n        run: git diff --name-only HEAD^1...HEAD > \"$RUNNER_TEMP/changed.txt\"\n"), doc, "does not run the change tool");
    try expectRefused(ar, try replaced(ar, pr, CHANGE_PATH ++ "\n", "          CHANGE: ./change\n"), doc, "does not run the change tool");
    try expectRefused(ar, try moved(ar, pr, "      - name: build the change tool\n", "      - name: select the affected targets\n"), doc, "before it builds the change tool");
    try expectRefused(ar, try replaced(ar, pr, "      - name: the change\n", "      - name: the files\n"), doc, "has no step the change");
    try expectRefused(ar, try replaced(ar, pr, GROUP_BASE ++ "\n", GROUP_BASE ++ "\n          PR_BASE: ${{ github.event.pull_request.base.sha }}\n"), doc, "reads pull_request.base.sha");
    // the job's bound against the queue's
    try expectRefused(ar, try replaced(ar, pr, "    timeout-minutes: 330\n", "    timeout-minutes: 360\n"), doc, "not below the queue's");
    try expectRefused(ar, try replaced(ar, pr, "    timeout-minutes: 330\n", ""), doc, "has no timeout-minutes");
    try expectRefused(ar, pr, try replaced(ar, doc, QUEUE_TIMEOUT_KEY ++ "360", QUEUE_TIMEOUT_KEY ++ "300"), "not below the queue's");
    try expectRefused(ar, pr, try replaced(ar, doc, QUEUE_TIMEOUT_KEY, "\"check_timeout\": "), "sets no check_response_timeout_minutes");
}

test "a job check in a workflow other than pr.yml is refused, and pr.yml's own is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const other = "name: x\non: pull_request\njobs:\n  lint:\n    runs-on: ubuntu-24.04\n  check:\n    runs-on: ubuntu-24.04\n";
    try t.expect(try checkOneSource(ar, "coverage.yml", other) != null);
    try t.expect(try checkOneSource(ar, "pr.yml", other) == null);
    // a step or a key named check inside a job is not a job
    try t.expect(try checkOneSource(ar, "coverage.yml", "name: x\njobs:\n  lint:\n    steps:\n      - name: check\n    check:\n") == null);
    try t.expect(try checkOneSource(ar, "coverage.yml", "name: x\non: push\n") == null);
}

test "the readers see each spelling they are given" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // a top-level key is read up to the next one, comments and blank lines left out
    const lines = (try topLines(ar, "on:\n  # a note\n\n  push:\njobs:\n  a:\n", "on")).?;
    try t.expectEqual(@as(usize, 1), lines.len);
    try t.expectEqualStrings("  push:", lines[0]);
    try t.expect(try topLines(ar, "name: x\n", "on") == null);
    // `on:` is not `once:`
    try t.expect(try topLines(ar, "once:\n  push:\n", "on") == null);
    // the queue timeout is the number after the key, and a key with no number is no timeout
    try t.expectEqual(@as(?u32, 45), try queueTimeout("x \"check_response_timeout_minutes\": 45,\n"));
    try t.expectEqual(@as(?u32, null), try queueTimeout("x \"check_response_timeout_minutes\": none\n"));
    // the last step of a job is read to the job's end
    const job = [_][]const u8{ "      - name: a", "        run: x", "      - name: b", "        run: y" };
    try t.expectEqual(@as(usize, 2), stepLines(&job, "name: b").?.len);
    try t.expect(stepLines(&job, "name: c") == null);
}
