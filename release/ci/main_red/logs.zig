//! What a failed job's log says: the failing targets and the key lines, read
//! from buck2's own output (`Action failed:`, `GATED TEST FAILED:`,
//! `Validation for ... failed`, `BUILD FAILED`) and the runner's `##[error]`.
//! Nothing here knows which workflow wrote the log.
const std = @import("std");

pub const MAX_TARGETS = 5;
pub const MAX_LOG_LINES = 2;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// The length of a runner timestamp at the start of `s`
/// (`2026-10-05T12:05:53.4100353Z `, fraction optional, one space), else 0.
fn runnerTsLen(s: []const u8) usize {
    // dddd-dd-ddTdd:dd:dd
    const shape = "dddd-dd-ddTdd:dd:dd";
    if (s.len < shape.len) return 0;
    for (shape, 0..) |p, i| {
        const c = s[i];
        if (p == 'd') {
            if (!isDigit(c)) return 0;
        } else if (c != p) return 0;
    }
    var i: usize = shape.len;
    if (i < s.len and s[i] == '.') {
        const start = i + 1;
        var j = start;
        while (j < s.len and isDigit(s[j])) j += 1;
        if (j == start) return 0;
        i = j;
    }
    if (i + 1 < s.len and s[i] == 'Z' and s[i + 1] == ' ') return i + 2;
    return 0;
}

/// The length of buck2's bracketed timestamp at the start of `s`
/// (`[2026-10-05T12:05:53.408+00:00] `, one optional space), else 0.
fn buckTsLen(s: []const u8) usize {
    if (s.len < 7 or s[0] != '[') return 0;
    const head = "dddd-dd-ddT";
    if (s.len < 1 + head.len) return 0;
    for (head, 0..) |p, i| {
        const c = s[1 + i];
        if (p == 'd') {
            if (!isDigit(c)) return 0;
        } else if (c != p) return 0;
    }
    const close = std.mem.indexOfScalarPos(u8, s, 1 + head.len, ']') orelse return 0;
    var n = close + 1;
    if (n < s.len and s[n] == ' ') n += 1;
    return n;
}

/// `line` without colour codes (`ESC [ digits/semicolons letter`), in a new
/// string.
fn withoutAnsi(a: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(a, line.len);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and (isDigit(line[j]) or line[j] == ';')) j += 1;
            if (j < line.len and std.ascii.isAlphabetic(line[j])) {
                i = j + 1;
                continue;
            }
        }
        try out.append(a, line[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

/// `line` without the runner's timestamp, colour codes, buck2's bracketed
/// timestamp and surrounding blanks.
pub fn stripLogLine(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    const no_eol = std.mem.trimRight(u8, line, "\r\n");
    const after_runner = no_eol[runnerTsLen(no_eol)..];
    const plain = try withoutAnsi(a, after_runner);
    return std.mem.trim(u8, plain[buckTsLen(plain)..], " \t\r\n\x0b\x0c");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0b or c == 0x0c;
}

/// The first run of non-blank characters of `s` ("" when it starts blank).
fn token(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and !isSpace(s[n])) n += 1;
    return s[0..n];
}

/// The target of a `Validation for `<target> (cfg)` failed` line: the
/// target may be in backticks or not, and ends at a blank or a backtick.
fn validationTarget(line: []const u8) ?[]const u8 {
    const prefix = "Validation for ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var rest = line[prefix.len..];
    if (rest.len > 0 and rest[0] == '`') rest = rest[1..];
    var n: usize = 0;
    while (n < rest.len and !isSpace(rest[n]) and rest[n] != '`') n += 1;
    if (n == 0) return null;
    const after = rest[n..];
    // `[^`]*`? failed`: " failed" follows with no backtick between, or
    // after exactly one.
    const stop = std.mem.indexOfScalar(u8, after, '`') orelse after.len;
    const f = " failed";
    var q: usize = 0;
    while (q <= stop) : (q += 1) {
        if (std.mem.startsWith(u8, after[q..], f)) return rest[0..n];
    }
    if (stop < after.len and std.mem.startsWith(u8, after[stop + 1 ..], f)) return rest[0..n];
    return null;
}

/// The target a stripped line names as failed, else null.
pub fn targetOf(line: []const u8) ?[]const u8 {
    inline for (.{ "Action failed: ", "GATED TEST FAILED: " }) |p| {
        if (std.mem.startsWith(u8, line, p)) {
            const t = token(line[p.len..]);
            if (t.len > 0) return t;
            return null;
        }
    }
    return validationTarget(line);
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The failing targets a job log names, in order of first appearance, each
/// once, at most `limit`.
pub fn failingTargets(a: std.mem.Allocator, log: []const u8, limit: usize) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |raw| {
        if (out.items.len == limit) break;
        const t = targetOf(try stripLogLine(a, raw)) orelse continue;
        if (!contains(out.items, t)) try out.append(a, t);
    }
    return out.toOwnedSlice(a);
}

fn isKey(pattern: usize, line: []const u8) bool {
    return switch (pattern) {
        0 => std.mem.startsWith(u8, line, "BUILD FAILED"),
        else => std.mem.startsWith(u8, line, "##[error]"),
    };
}

/// The lines that say why: the target lines when the log has any, else
/// `BUILD FAILED` and the runner's `##[error]` lines, in that preference;
/// each once, at most `limit`.
pub fn keyLogLines(a: std.mem.Allocator, log: []const u8, limit: usize) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |raw| try lines.append(a, try stripLogLine(a, raw));
    var out = std.ArrayList([]const u8).empty;
    for (lines.items) |line| {
        if (targetOf(line) != null and !contains(out.items, line)) {
            try out.append(a, line);
            if (out.items.len == limit) return out.toOwnedSlice(a);
        }
    }
    if (out.items.len > 0) return out.toOwnedSlice(a);
    var p: usize = 0;
    while (p < 2) : (p += 1) {
        for (lines.items) |line| {
            if (isKey(p, line) and !contains(out.items, line)) {
                try out.append(a, line);
                if (out.items.len == limit) return out.toOwnedSlice(a);
            }
        }
    }
    return out.toOwnedSlice(a);
}

fn str(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        else => "",
    };
}

fn field(obj: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (obj) {
        .object => |o| o.get(name),
        else => null,
    };
}

/// The jobs that failed, then those cancelled (a job past its
/// `timeout-minutes` is cancelled while the run fails).
pub fn failedJobs(a: std.mem.Allocator, jobs: []const std.json.Value) ![]const std.json.Value {
    var out = std.ArrayList(std.json.Value).empty;
    for (jobs) |j| {
        const c = str(field(j, "conclusion"));
        if (std.mem.eql(u8, c, "failure") or std.mem.eql(u8, c, "timed_out")) try out.append(a, j);
    }
    for (jobs) |j| {
        if (std.mem.eql(u8, str(field(j, "conclusion")), "cancelled")) try out.append(a, j);
    }
    return out.toOwnedSlice(a);
}

/// `job <name>, step <failed step>`, or `job <name> (<conclusion>)`.
pub fn jobLabel(a: std.mem.Allocator, job: std.json.Value) ![]const u8 {
    const name = str(field(job, "name"));
    if (field(job, "steps")) |steps| switch (steps) {
        .array => |arr| for (arr.items) |s| {
            if (std.mem.eql(u8, str(field(s, "conclusion")), "failure")) {
                return std.fmt.allocPrint(a, "job {s}, step {s}", .{ name, str(field(s, "name")) });
            }
        },
        else => {},
    };
    return std.fmt.allocPrint(a, "job {s} ({s})", .{ name, str(field(job, "conclusion")) });
}
