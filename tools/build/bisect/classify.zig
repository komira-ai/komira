//! A probe's outcome from buck2's exit status and its build report.
//!
//! buck2's exit codes (app/buck2_error/src/exit_code.rs of the pinned
//! release): 0 success, 1 unknown failure, 2 infrastructure error, 3 user
//! error, 4 daemon busy, 5 daemon preempted, 6 timeout, 11 connect error,
//! 12 out of memory, 130 and 141 signals; `buck2 test` exits 32 when a test
//! failed.
//!
//! | outcome | rule |
//! |---|---|
//! | pass | exit 0 |
//! | fail | exit 3 and the report names a given target as failed; or, with the verb `test`, exit 32 |
//! | infra | anything else: another exit code, a signal or timeout, a missing or unreadable report, an exit 3 whose report names none of the given targets as failed |
const std = @import("std");
pub const Outcome = @import("search.zig").Outcome;

pub const Verb = enum { build, @"test" };

pub const MAX_EXCERPT_LINES = 20;
pub const MAX_EXCERPT_BYTES = 2048;

pub const Failure = struct {
    target: []const u8,
    excerpt: []const u8,
};

pub const Classified = struct {
    outcome: Outcome,
    /// The given targets the report names as failed, with an excerpt of
    /// each one's first error.
    failures: []const Failure = &.{},
    /// Why the outcome is `infra`, for the verdict; empty otherwise.
    reason: []const u8 = "",
};

/// The label without its cell: `komira//a:b` and `//a:b` are both `//a:b`.
pub fn stripCell(label: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, label, "//") orelse return label;
    return label[i..];
}

/// Whether the report's `label` is one of the given targets: the same label
/// (cells aside), or under a given pattern `//p/...` or `//p:`.
pub fn matches(given: []const u8, label: []const u8) bool {
    const g = stripCell(given);
    const l = stripCell(label);
    if (std.mem.eql(u8, g, l)) return true;
    if (std.mem.endsWith(u8, g, ":")) return std.mem.startsWith(u8, l, g);
    if (std.mem.endsWith(u8, g, "/...")) {
        const pkg = g[0 .. g.len - 4];
        if (!std.mem.startsWith(u8, l, pkg)) return false;
        const rest = l[pkg.len..];
        // `//p/...` holds `//p:x`, `//p/q:x`; `//:x` under `//...`.
        return rest.len > 0 and (rest[0] == ':' or rest[0] == '/' or std.mem.endsWith(u8, pkg, "/"));
    }
    return false;
}

/// At most MAX_EXCERPT_LINES lines and MAX_EXCERPT_BYTES bytes of `s`, cut
/// at a UTF-8 boundary.
pub fn excerpt(s: []const u8) []const u8 {
    var end: usize = 0;
    var lines: usize = 0;
    while (end < s.len and end < MAX_EXCERPT_BYTES) : (end += 1) {
        if (s[end] == '\n') {
            lines += 1;
            if (lines == MAX_EXCERPT_LINES) {
                end += 1;
                break;
            }
        }
    }
    if (end > s.len) end = s.len;
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// A string of the report: its value in the report's `strings` table when
/// it is a key there (buck2 interns message text), else itself.
fn resolve(strings: ?std.json.Value, s: []const u8) []const u8 {
    if (str(field(strings orelse return s, s))) |v| return v;
    return s;
}

/// The text of one error: the action's stderr when it has one, else the
/// error's message.
fn errorText(strings: ?std.json.Value, e: std.json.Value) ?[]const u8 {
    if (field(e, "action_error")) |ae| {
        if (str(field(ae, "stderr_content"))) |id| {
            const s = resolve(strings, id);
            if (std.mem.trim(u8, s, " \r\n\t").len > 0) return s;
        }
    }
    if (str(field(e, "message_content"))) |id| return resolve(strings, id);
    return null;
}

fn errorsText(strings: ?std.json.Value, errors: ?std.json.Value) ?[]const u8 {
    const es = errors orelse return null;
    if (es != .array) return null;
    for (es.array.items) |e| {
        if (errorText(strings, e)) |s| return s;
    }
    return null;
}

/// The first error text of a result entry: its own `errors`, then those of
/// each configuration.
fn firstError(strings: ?std.json.Value, entry: std.json.Value) ?[]const u8 {
    if (errorsText(strings, field(entry, "errors"))) |s| return s;
    if (field(entry, "configured")) |cs| {
        if (cs == .object) {
            for (cs.object.values()) |c| {
                if (errorsText(strings, field(c, "errors"))) |s| return s;
            }
        }
    }
    return null;
}

/// The given targets the report names as failed (`results.<label>.success`
/// is "FAIL"), in the report's order.
pub fn failedTargets(a: std.mem.Allocator, report: []const u8, targets: []const []const u8) !?[]const Failure {
    const parsed = std.json.parseFromSlice(std.json.Value, a, report, .{}) catch return null;
    const root = parsed.value;
    const results = field(root, "results") orelse return null;
    if (results != .object) return null;
    const strings = field(root, "strings");
    var out = std.ArrayList(Failure).init(a);
    var it = results.object.iterator();
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, str(field(kv.value_ptr.*, "success")) orelse "", "FAIL")) continue;
        var given = false;
        for (targets) |g| {
            if (matches(g, kv.key_ptr.*)) {
                given = true;
                break;
            }
        }
        if (!given) continue;
        const text = firstError(strings, kv.value_ptr.*) orelse "(the build report has no error text for this target)";
        try out.append(.{ .target = stripCell(kv.key_ptr.*), .excerpt = excerpt(text) });
    }
    return try out.toOwnedSlice();
}

/// `exit` is null when buck2 was killed (its timeout) or died of a signal;
/// `report` is the build report's bytes, null when buck2 wrote none.
pub fn classify(a: std.mem.Allocator, exit: ?u8, verb: Verb, report: ?[]const u8, targets: []const []const u8) !Classified {
    const code = exit orelse return .{ .outcome = .infra, .reason = "buck2 was killed or died of a signal" };
    if (code == 0) return .{ .outcome = .pass };
    if (code == 32 and verb == .@"test") {
        const none: []const Failure = &.{};
        const failures: []const Failure = if (report) |r| (try failedTargets(a, r, targets)) orelse none else none;
        return .{ .outcome = .fail, .failures = failures };
    }
    if (code != 3) return .{ .outcome = .infra, .reason = try std.fmt.allocPrint(a, "buck2 exited {d}, not a build failure", .{code}) };
    const r = report orelse return .{ .outcome = .infra, .reason = "buck2 exited 3 and wrote no build report" };
    const failures = (try failedTargets(a, r, targets)) orelse
        return .{ .outcome = .infra, .reason = "buck2 exited 3 and its build report cannot be read" };
    if (failures.len == 0) return .{ .outcome = .infra, .reason = "buck2 exited 3 and its build report names none of the given targets as failed" };
    return .{ .outcome = .fail, .failures = failures };
}
