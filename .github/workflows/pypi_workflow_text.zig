//! The reading of the publish workflow's text that its case files share: pypi.yml, with the jobs of the
//! Linux wheel (pypi_workflow_contract.zig and pypi_workflow_test.zig, the contract of each line;
//! pypi_workflow_run.zig, runs played from the text) and the jobs of the macOS arm64 wheel
//! (pypi_macos_jobs_contract.zig, pypi_macos_jobs_test.zig and pypi_macos_jobs_run.zig);
//! pypi_workflow_play.zig plays it. The jobs and the top-level keys as lines, the searches over those
//! lines, the workflow's own bytes (and release.yml's) under KOMIRA_TEST_WORK, and the edits a case writes
//! into them. Comment lines and blank lines are never returned.

const std = @import("std");

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

/// The names of the jobs of the `jobs:` map, in file order.
pub fn jobNames(ar: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
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
        if (indent == 2 and std.mem.endsWith(u8, trimmed, ":")) try out.append(ar, trimmed[0 .. trimmed.len - 1]);
    }
    return try out.toOwnedSlice(ar);
}

/// The lines of the top-level key `key` (a line at column 0, e.g. `on:`), up to the next
/// top-level line, without comment and blank lines.
pub fn topLines(ar: std.mem.Allocator, text: []const u8, key: []const u8, count: *usize) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var inside = false;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
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

pub fn has(lines: []const []const u8, exact: []const u8) bool {
    for (lines) |l| if (std.mem.eql(u8, l, exact)) return true;
    return false;
}

pub fn lineAt(lines: []const []const u8, exact: []const u8) ?usize {
    for (lines, 0..) |l, i| if (std.mem.eql(u8, l, exact)) return i;
    return null;
}

pub fn mentions(lines: []const []const u8, needle: []const u8) bool {
    return countMentions(lines, needle) > 0;
}

pub fn countMentions(lines: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

pub fn countPrefix(lines: []const []const u8, prefix: []const u8) usize {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.startsWith(u8, l, prefix)) n += 1;
    }
    return n;
}

/// The bytes of pypi.yml, the zig_test's data under KOMIRA_TEST_WORK/workflows/.
pub fn readWorkflow(ar: std.mem.Allocator) ![]const u8 {
    return readData(ar, "pypi.yml");
}

/// The bytes of release.yml, whose push filter pypi.yml's repeats.
pub fn readRelease(ar: std.mem.Allocator) ![]const u8 {
    return readData(ar, "release.yml");
}

fn readData(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(ar, &.{ work, "workflows", name });
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

/// `text` with every `from` replaced by `to`; the anchor must be there.
pub fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the case's anchor is not in the workflow: {s}\n", .{from});
        return error.NoAnchor;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

/// `text` with the first `from` at or after the header of the job `job` replaced by `to`.
pub fn inJob(ar: std.mem.Allocator, text: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const header = try std.fmt.allocPrint(ar, "\n  {s}:\n", .{job});
    const start = std.mem.indexOf(u8, text, header) orelse {
        std.debug.print("the case's job is not in the workflow: {s}\n", .{job});
        return error.NoAnchor;
    };
    const at = std.mem.indexOfPos(u8, text, start, from) orelse {
        std.debug.print("the case's anchor is not in job {s} of the workflow: {s}\n", .{ job, from });
        return error.NoAnchor;
    };
    return try std.mem.concat(ar, u8, &.{ text[0..at], to, text[at + from.len ..] });
}
