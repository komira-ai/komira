//! The common-tasks check (`tool tasks-check`, cli.zig): the catalogue of
//! common data-analysis tasks (docs/tasks/catalogue.json) and one
//! language's task directories (python/docs/tasks); docs/tasks/README.md
//! says what each file is.
//!
//! The catalogue is a JSON array of entries, the entry at index i of rank
//! i + 1. Each entry is an object with exactly the keys `rank`, `slug`,
//! `category`, `question`, `status` and, optionally, `issues`:
//!
//!   - `slug`: lowercase ASCII letters, digits and single hyphens, neither
//!     first nor last; no two entries share one;
//!   - `category`: a non-empty string;
//!   - `question`: starts "How do I " and ends "?";
//!   - `status`: "works", "partial" or "gap";
//!   - `issues`: a non-empty array of issue names `komira-ai/<repo>#<n>`;
//!     a "gap" entry must have it.
//!
//! A task directory is named `<rank>-<slug>` after an entry that is not a
//! gap: the slug finds the entry, and the rank must be the entry's. It
//! holds `example.py`, `expected_output.txt` and `page.md`, and nothing
//! else but probes. A probe is the pair `probe_<name>.py` and
//! `probe_<name>.error.txt` (`<name>` lowercase letters, digits and `_`):
//! a program that must fail, and the one line it fails with. Only a gap or
//! a partial task has probes. The page follows task_page.zig. What a
//! program prints, or fails with, is held by the wheel test of the
//! directory (python/docs/tasks/BUCK), not here.
//!
//! Every refusal is one line naming the file, and the line of the file
//! where there is one. The fences are the shared Markdown reader's
//! (`@import("markdown")`, tools/build/markdown).

const std = @import("std");
const page_rules = @import("task_page.zig");
const Allocator = std.mem.Allocator;

pub const Status = enum { works, partial, gap };

pub const File = page_rules.File;

/// One task directory as the check reads it.
pub const Task = struct {
    /// The directory's name, `<rank>-<slug>`.
    name: []const u8,
    /// Everything the directory holds, in any order.
    files: []const File,
};

const Entry = struct {
    slug: []const u8,
    question: []const u8,
    status: Status,
};

/// What the check found: the refusals, one line each in the order found,
/// and, when there are none, the report `<name> <status>` per task, one
/// line each, in the order given.
pub const Result = struct {
    refusals: []const []const u8,
    report: []const u8,
};

const FILES = [_][]const u8{ "example.py", "expected_output.txt", "page.md" };

const PROBE = "probe_";
const PROBE_PY = ".py";
const PROBE_ERROR = ".error.txt";

fn probeNameOk(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

/// The `<name>` of `probe_<name><suffix>`, or null.
fn probeOf(file: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, file, PROBE) or !std.mem.endsWith(u8, file, suffix)) return null;
    if (file.len < PROBE.len + suffix.len) return null;
    const n = file[PROBE.len .. file.len - suffix.len];
    return if (probeNameOk(n)) n else null;
}

fn findFile(files: []const File, name: []const u8) ?File {
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

const KEYS = [_][]const u8{ "rank", "slug", "category", "question", "status", "issues" };

const Check = struct {
    alloc: Allocator,
    /// The directory the task files are named under, and the catalogue's name.
    display: []const u8,
    catalogue: []const u8,
    refusals: std.ArrayList([]const u8) = .empty,

    fn refuse(self: *Check, comptime f: []const u8, args: anytype) Allocator.Error!void {
        try self.refusals.append(self.alloc, try std.fmt.allocPrint(self.alloc, f, args));
    }
};

fn slugOk(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
        if (c == '-' and s[i - 1] == '-') return false;
    }
    return true;
}

/// Whether `s` is `komira-ai/<repo>#<n>`: a repo of lowercase letters,
/// digits and hyphens, and a decimal number with no leading zero.
fn issueOk(s: []const u8) bool {
    const owner = "komira-ai/";
    if (!std.mem.startsWith(u8, s, owner)) return false;
    const rest = s[owner.len..];
    const hash = std.mem.indexOfScalar(u8, rest, '#') orelse return false;
    const repo = rest[0..hash];
    const num = rest[hash + 1 ..];
    if (repo.len == 0 or num.len == 0 or num[0] == '0') return false;
    for (repo) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    for (num) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn stringField(c: *Check, obj: std.json.ObjectMap, rank: usize, key: []const u8) Allocator.Error!?[]const u8 {
    const v = obj.get(key) orelse {
        try c.refuse("{s}: rank {d}: no \"{s}\"", .{ c.catalogue, rank, key });
        return null;
    };
    if (v != .string or v.string.len == 0) {
        try c.refuse("{s}: rank {d}: \"{s}\" is not a non-empty string", .{ c.catalogue, rank, key });
        return null;
    }
    return v.string;
}

const Catalogue = struct {
    /// The entry of each rank (index rank - 1), null when it is refused.
    entries: []const ?Entry,
    /// The rank of each slug an entry gives, refused entry or not.
    ranks: std.StringHashMap(usize),
};

/// The entries of the catalogue, null at an index whose entry is refused.
fn readCatalogue(c: *Check, text: []const u8) Allocator.Error!Catalogue {
    var slugs = std.StringHashMap(usize).init(c.alloc);
    const value = std.json.parseFromSliceLeaky(std.json.Value, c.alloc, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try c.refuse("{s}: not JSON: {s}", .{ c.catalogue, @errorName(e) });
            return .{ .entries = &.{}, .ranks = slugs };
        },
    };
    if (value != .array or value.array.items.len == 0) {
        try c.refuse("{s}: not a non-empty JSON array", .{c.catalogue});
        return .{ .entries = &.{}, .ranks = slugs };
    }
    const items = value.array.items;
    const out = try c.alloc.alloc(?Entry, items.len);
    for (items, 0..) |item, i| {
        out[i] = null;
        const rank = i + 1;
        if (item != .object) {
            try c.refuse("{s}: entry {d} is not an object", .{ c.catalogue, rank });
            continue;
        }
        const obj = item.object;
        var bad = false;
        for (obj.keys()) |k| {
            const known = for (KEYS) |want| {
                if (std.mem.eql(u8, k, want)) break true;
            } else false;
            if (!known) {
                try c.refuse("{s}: rank {d}: unknown key \"{s}\"", .{ c.catalogue, rank, k });
                bad = true;
            }
        }
        const r = obj.get("rank");
        if (r == null or r.? != .integer or r.?.integer != @as(i64, @intCast(rank))) {
            try c.refuse("{s}: entry {d} does not have \"rank\": {d} (the entries are in rank order from 1)", .{ c.catalogue, rank, rank });
            bad = true;
        }
        const slug = try stringField(c, obj, rank, "slug");
        if (slug) |s| {
            if (!slugOk(s)) {
                try c.refuse("{s}: rank {d}: slug \"{s}\" is not lowercase letters, digits and single hyphens", .{ c.catalogue, rank, s });
                bad = true;
            } else if (slugs.get(s)) |other| {
                try c.refuse("{s}: rank {d}: slug \"{s}\" is also rank {d}'s", .{ c.catalogue, rank, s, other });
                bad = true;
            } else {
                try slugs.put(s, rank);
            }
        } else bad = true;
        if ((try stringField(c, obj, rank, "category")) == null) bad = true;
        const question = try stringField(c, obj, rank, "question");
        if (question) |q| {
            if (!std.mem.startsWith(u8, q, "How do I ") or !std.mem.endsWith(u8, q, "?")) {
                try c.refuse("{s}: rank {d}: the question does not start \"How do I \" and end \"?\"", .{ c.catalogue, rank });
                bad = true;
            }
        } else bad = true;
        var status: ?Status = null;
        if (try stringField(c, obj, rank, "status")) |s| {
            status = std.meta.stringToEnum(Status, s);
            if (status == null) {
                try c.refuse("{s}: rank {d}: status \"{s}\" is not works, partial or gap", .{ c.catalogue, rank, s });
                bad = true;
            }
        } else bad = true;
        if (obj.get("issues")) |v| {
            if (v != .array or v.array.items.len == 0) {
                try c.refuse("{s}: rank {d}: \"issues\" is not a non-empty array", .{ c.catalogue, rank });
                bad = true;
            } else for (v.array.items) |x| {
                if (x != .string or !issueOk(x.string)) {
                    try c.refuse("{s}: rank {d}: an issue is not komira-ai/<repo>#<n>", .{ c.catalogue, rank });
                    bad = true;
                }
            }
        } else if (status != null and status.? == .gap) {
            try c.refuse("{s}: rank {d}: a gap names the issues that block it in \"issues\"", .{ c.catalogue, rank });
            bad = true;
        }
        if (!bad) out[i] = .{ .slug = slug.?, .question = question.?, .status = status.? };
    }
    return .{ .entries = out, .ranks = slugs };
}

/// The rank a directory name starts with (`<rank>-`, no leading zero) and
/// the rest, or null.
fn splitName(name: []const u8) ?struct { rank: usize, slug: []const u8 } {
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return null;
    const digits = name[0..dash];
    if (digits.len == 0 or digits[0] == '0') return null;
    const rank = std.fmt.parseInt(usize, digits, 10) catch return null;
    return .{ .rank = rank, .slug = name[dash + 1 ..] };
}

fn checkTask(c: *Check, task: Task, cat: Catalogue) Allocator.Error!?Status {
    const split = splitName(task.name) orelse {
        try c.refuse("{s}/{s}: a task directory is named <rank>-<slug>", .{ c.display, task.name });
        return null;
    };
    const rank = cat.ranks.get(split.slug) orelse {
        try c.refuse("{s}/{s}: the catalogue has no slug \"{s}\"", .{ c.display, task.name, split.slug });
        return null;
    };
    if (rank != split.rank) {
        try c.refuse("{s}/{s}: slug \"{s}\" is rank {d} in the catalogue", .{ c.display, task.name, split.slug, rank });
        return null;
    }
    // A refused entry is named by the catalogue's own refusal.
    const entry = cat.entries[rank - 1] orelse return null;
    if (entry.status == .gap) {
        try c.refuse("{s}/{s}: rank {d} is a gap, which has no example", .{ c.display, task.name, rank });
        return null;
    }
    var probes: usize = 0;
    for (task.files) |f| {
        const dir = try std.fmt.allocPrint(c.alloc, "{s}/{s}", .{ c.display, task.name });
        if (f.data == null) {
            try c.refuse("{s}/{s}/: a task directory holds no directory", .{ dir, f.name });
            continue;
        }
        const known = for (FILES) |want| {
            if (std.mem.eql(u8, f.name, want)) break true;
        } else false;
        if (known) continue;
        if (probeOf(f.name, PROBE_ERROR)) |n| {
            const py = try std.mem.concat(c.alloc, u8, &.{ PROBE, n, PROBE_PY });
            if (findFile(task.files, py) == null) try c.refuse("{s}/{s}: no {s}, the probe it is the failure of", .{ dir, f.name, py });
            const d = f.data.?;
            const one_line = d.len > 1 and d[d.len - 1] == '\n' and std.mem.indexOfScalar(u8, d[0 .. d.len - 1], '\n') == null and std.mem.indexOfScalar(u8, d, '\r') == null;
            if (!one_line) try c.refuse("{s}/{s}: not one line ended by a line feed", .{ dir, f.name });
            continue;
        }
        if (probeOf(f.name, PROBE_PY)) |n| {
            probes += 1;
            const err = try std.mem.concat(c.alloc, u8, &.{ PROBE, n, PROBE_ERROR });
            if (findFile(task.files, err) == null) try c.refuse("{s}/{s}: no {s}, the line the probe must fail with", .{ dir, f.name, err });
            continue;
        }
        try c.refuse("{s}/{s}: a task directory holds only example.py, expected_output.txt, page.md and probe_<name>.py with probe_<name>.error.txt", .{ dir, f.name });
    }
    if (probes > 0 and entry.status == .works) {
        try c.refuse("{s}/{s}: rank {d} works, and a probe is for a gap or partial task (what komira cannot do yet)", .{ c.display, task.name, rank });
    }
    for (FILES) |want| {
        if (findFile(task.files, want) == null) try c.refuse("{s}/{s}: no {s}", .{ c.display, task.name, want });
    }
    if (findFile(task.files, "page.md")) |p| {
        if (p.data) |text| {
            const name = try std.fmt.allocPrint(c.alloc, "{s}/{s}/page.md", .{ c.display, task.name });
            try page_rules.check(c.alloc, &c.refusals, name, entry.question, text, task.files);
        }
    }
    return entry.status;
}

/// Checks the catalogue text against the task directories. `display` is
/// the directory the refusals name the task files under, and
/// `catalogue_display` the name they give the catalogue.
pub fn check(alloc: Allocator, display: []const u8, catalogue_display: []const u8, catalogue: []const u8, tasks: []const Task) Allocator.Error!Result {
    var c = Check{ .alloc = alloc, .display = display, .catalogue = catalogue_display };
    const cat = try readCatalogue(&c, catalogue);
    var report = std.ArrayList(u8).empty;
    for (tasks) |task| {
        const status = try checkTask(&c, task, cat) orelse continue;
        try report.writer(alloc).print("{s} {s}\n", .{ task.name, @tagName(status) });
    }
    if (c.refusals.items.len > 0) return .{ .refusals = c.refusals.items, .report = "" };
    return .{ .refusals = &.{}, .report = try report.toOwnedSlice(alloc) };
}
