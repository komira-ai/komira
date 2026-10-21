//! The issue a red main opens, and the decisions around it: its title and
//! body (the contract an outside reader parses), which runs count, which
//! issue to comment on, which to close.
const std = @import("std");

pub const LABEL = "main-red";
pub const LABEL_COLOR = "b60205";
pub const LABEL_DESCRIPTION = "main's build failed (docs/ci.md, main_red.yml)";
/// The login the workflow's GITHUB_TOKEN writes as: only its comments record
/// heads (anyone can comment on a public issue).
pub const WORKFLOW_LOGIN = "github-actions[bot]";
pub const MAX_VALUE = 300;
pub const MAIN = "main";

pub const Kind = enum { red, green, ignore };

/// One line, at most MAX_VALUE bytes (never cutting a UTF-8 sequence): no
/// value can add a line.
pub fn value(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    while (it.next()) |word| {
        const before = out.items.len;
        if (before > 0) try out.append(a, ' ');
        // No control byte (an ESC above all) enters an issue.
        for (word) |c| {
            if (c >= 0x20 and c != 0x7f) try out.append(a, c);
        }
        if (out.items.len == before + @intFromBool(before > 0)) out.shrinkRetainingCapacity(before);
    }
    var n = @min(out.items.len, MAX_VALUE);
    // A continuation byte (10xxxxxx) at the cut: back up to the sequence's start.
    while (n > 0 and n < out.items.len and (out.items[n] & 0xC0) == 0x80) n -= 1;
    return out.items[0..n];
}

pub fn issueTitle(a: std.mem.Allocator, failing: []const []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "main red: {s}", .{try value(a, failing[0])});
}

/// The contract: Run, Head, Last green, Culprits, a Failing line per target,
/// a Log line per key line. `green` is null for none, `prs` empty for unknown.
pub fn issueBody(
    a: std.mem.Allocator,
    run_url: []const u8,
    head: []const u8,
    green: ?[]const u8,
    prs: []const u64,
    failing: []const []const u8,
    log_lines: []const []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(a, "Run: {s}\nHead: {s}\n", .{ try value(a, run_url), try value(a, head) });
    try out.print(a, "Last green: {s}\n", .{if (green) |g| try value(a, g) else "none"});
    try out.appendSlice(a, "Culprits: ");
    if (prs.len == 0) {
        try out.appendSlice(a, "unknown");
    } else for (prs, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "#{d}", .{n});
    }
    try out.append(a, '\n');
    for (failing) |f| try out.print(a, "Failing: {s}\n", .{try value(a, f)});
    for (log_lines) |l| try out.print(a, "Log: {s}\n", .{try value(a, l)});
    return out.items;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Every full commit id on a `Head:` line of `texts`, each once.
pub fn headsIn(a: std.mem.Allocator, texts: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (texts) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
            if (!std.mem.startsWith(u8, line, "Head: ")) continue;
            const sha = line["Head: ".len..];
            if (!isHex40(sha)) continue;
            var seen = false;
            for (out.items) |x| {
                if (std.mem.eql(u8, x, sha)) seen = true;
            }
            if (!seen) try out.append(a, sha);
        }
    }
    return out.toOwnedSlice(a);
}

pub fn fixedComment(a: std.mem.Allocator, sha: []const u8, run_url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Fixed: main is green at {s} (run {s})", .{ sha, run_url });
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

/// The workflow names the run may carry: a run of any other workflow is not
/// one this alert watches.
pub fn watches(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// `red`, `green` or `ignore` for a completed run of a watched workflow:
/// only a run started by a push to main counts.
pub fn classify(run: std.json.Value, names: []const []const u8) Kind {
    if (!std.mem.eql(u8, str(field(run, "event")), "push")) return .ignore;
    if (!std.mem.eql(u8, str(field(run, "head_branch")), MAIN)) return .ignore;
    if (!watches(names, str(field(run, "name")))) return .ignore;
    const c = str(field(run, "conclusion"));
    if (std.mem.eql(u8, c, "failure") or std.mem.eql(u8, c, "timed_out") or std.mem.eql(u8, c, "startup_failure")) return .red;
    if (std.mem.eql(u8, c, "success")) return .green;
    return .ignore;
}

pub const RedAction = union(enum) {
    open,
    /// Comment on this (the oldest open) issue.
    comment: u64,
};

pub fn decideRed(open_numbers: []const u64) RedAction {
    if (open_numbers.len == 0) return .open;
    return .{ .comment = std.mem.min(u64, open_numbers) };
}

/// What a green commit does to an open issue that recorded these heads:
/// close unless the green commit is known NOT to contain one of them.
/// `contains.of(head)` is true, false, or null for a head it cannot place
/// (unknown to the API, or off main's line), which neither blocks nor counts.
pub fn keepsOpen(heads: []const []const u8, contains: anytype) !bool {
    for (heads) |h| {
        if (try contains.of(h)) |yes| {
            if (!yes) return true;
        }
    }
    return false;
}

pub const Duplicates = struct { oldest: ?u64, others: []const u64 };

/// The oldest open issue and the others in order, after a race.
pub fn duplicates(a: std.mem.Allocator, open_numbers: []const u64) !Duplicates {
    if (open_numbers.len == 0) return .{ .oldest = null, .others = &.{} };
    const sorted = try a.dupe(u64, open_numbers);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{ .oldest = sorted[0], .others = sorted[1..] };
}
