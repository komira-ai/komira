//! The range a red head belongs to: the last green commit before it and the
//! pull requests merged into main since.
const std = @import("std");

pub const MAIN = "main";

pub const Green = union(enum) {
    /// The last green commit of the head.
    found: []const u8,
    /// A green commit already contains the head: main is green past it.
    stale: []const u8,
    none,
};

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

/// The last green commit of `head`. `success_runs` are the head shas of the
/// successful push runs, newest first; `rel.relation(sha)` is the status of
/// `head` against `sha` as the compare API says it (`ahead`: sha is an
/// ancestor; `identical`; `behind`: sha descends from head; `diverged`).
pub fn lastGreen(head: []const u8, success_runs: []const []const u8, rel: anytype) !Green {
    for (success_runs) |sha| {
        if (std.mem.eql(u8, sha, head)) return .{ .found = sha };
        const status = try rel.relation(sha);
        if (std.mem.eql(u8, status, "ahead") or std.mem.eql(u8, status, "identical")) return .{ .found = sha };
        if (std.mem.eql(u8, status, "behind")) return .{ .stale = sha };
    }
    return .none;
}

fn commitByName(a: std.mem.Allocator, commits: []const std.json.Value) !std.StringHashMap(std.json.Value) {
    var by_sha = std.StringHashMap(std.json.Value).init(a);
    for (commits) |c| try by_sha.put(str(field(c, "sha")), c);
    return by_sha;
}

/// The commits of main from `head` back to (not including) `base`, following
/// first parents: the commits that landed on main, newest first. `commits`
/// is the compare API's list.
pub fn firstParentChain(a: std.mem.Allocator, commits: []const std.json.Value, head: []const u8, base: []const u8) ![]const []const u8 {
    const by_sha = try commitByName(a, commits);
    var chain = std.ArrayList([]const u8).empty;
    var sha = head;
    while (by_sha.get(sha)) |c| {
        if (std.mem.eql(u8, sha, base)) break;
        try chain.append(a, sha);
        const parents = field(c, "parents") orelse break;
        const list = switch (parents) {
            .array => |arr| arr.items,
            else => break,
        };
        if (list.len == 0) break;
        sha = str(field(list[0], "sha"));
    }
    return chain.toOwnedSlice(a);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The pull request a commit subject names: `Merge pull request #N ...` or a
/// squash's trailing `(#N)`; else null.
pub fn subjectPr(subject: []const u8) ?u64 {
    const merge = "Merge pull request #";
    if (std.mem.startsWith(u8, subject, merge)) {
        const rest = subject[merge.len..];
        var n: usize = 0;
        while (n < rest.len and rest[n] >= '0' and rest[n] <= '9') n += 1;
        if (n > 0 and n < rest.len and rest[n] == ' ') return std.fmt.parseInt(u64, rest[0..n], 10) catch null;
    }
    if (subject.len >= 4 and subject[subject.len - 1] == ')') {
        if (std.mem.lastIndexOf(u8, subject, "(#")) |open| {
            const digits = subject[open + 2 .. subject.len - 1];
            if (allDigits(digits)) return std.fmt.parseInt(u64, digits, 10) catch null;
        }
    }
    return null;
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn contains(list: []const u64, n: u64) bool {
    for (list) |x| if (x == n) return true;
    return false;
}

/// The pull requests merged into main in base..head, newest first, each once.
/// `pulls.of(sha)` is the API's pull requests of a commit (a JSON array); one
/// merged into main counts, else the commit's subject is read.
pub fn culprits(a: std.mem.Allocator, commits: []const std.json.Value, head: []const u8, base: []const u8, pulls: anytype) ![]const u64 {
    const by_sha = try commitByName(a, commits);
    var out = std.ArrayList(u64).empty;
    for (try firstParentChain(a, commits, head, base)) |sha| {
        var numbers = std.ArrayList(u64).empty;
        const listed = try pulls.of(sha);
        switch (listed) {
            .array => |arr| for (arr.items) |p| {
                const merged = field(p, "merged_at") orelse continue;
                const truthy = switch (merged) {
                    .string => |s| s.len > 0,
                    else => false,
                };
                if (!truthy) continue;
                const base_obj = field(p, "base") orelse continue;
                if (!std.mem.eql(u8, str(field(base_obj, "ref")), MAIN)) continue;
                const num = field(p, "number") orelse continue;
                switch (num) {
                    .integer => |i| try numbers.append(a, @intCast(i)),
                    else => {},
                }
            },
            else => {},
        }
        if (numbers.items.len == 0) {
            const commit = field(by_sha.get(sha).?, "commit") orelse continue;
            if (subjectPr(firstLine(str(field(commit, "message"))))) |n| try numbers.append(a, n);
        }
        for (numbers.items) |n| if (!contains(out.items, n)) try out.append(a, n);
    }
    return out.toOwnedSlice(a);
}
