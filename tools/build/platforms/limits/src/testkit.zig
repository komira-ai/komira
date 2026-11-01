//! What the limits check's unit tests share: run a check, and require one
//! finding.

const std = @import("std");
const limits = @import("limits.zig");

pub const name = "limits.tsv";

pub const Run = struct {
    limits: usize,
    findings: usize,
    report: []const u8,
};

/// Rule 1 alone: the rows of `text`.
pub fn rows(a: std.mem.Allocator, text: []const u8) !Run {
    var out = std.ArrayList(u8).empty;
    const p = try limits.parseRows(a, name, text, out.writer(a));
    return .{ .limits = p.rows.len, .findings = p.findings, .report = out.items };
}

/// Rules 1 to 3 over `files`, as (path, contents) pairs.
pub fn tree(a: std.mem.Allocator, text: []const u8, files: []const [2][]const u8) !Run {
    const fs = try a.alloc(limits.File, files.len);
    for (files, 0..) |f, i| fs[i] = .{ .path = f[0], .data = f[1] };
    var out = std.ArrayList(u8).empty;
    const r = try limits.checkTree(a, name, text, fs, &out);
    return .{ .limits = r.limits, .findings = r.findings, .report = out.items };
}

/// Rule 4: the rows of `text` against `subjects`.
pub fn merged(a: std.mem.Allocator, text: []const u8, subjects: []const u8) !Run {
    var out = std.ArrayList(u8).empty;
    const r = try limits.checkMerged(a, name, text, subjects, &out);
    return .{ .limits = r.limits, .findings = r.findings, .report = out.items };
}

/// `r` holds exactly one finding, and it contains `needle`.
pub fn only(r: Run, needle: []const u8) !void {
    if (r.findings != 1 or std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("want one finding holding `{s}`, got {d}:\n{s}\n", .{ needle, r.findings, r.report });
        return error.TestExpectedFinding;
    }
}

/// `r` holds no finding.
pub fn clean(r: Run) !void {
    if (r.findings != 0) {
        std.debug.print("want no finding, got {d}:\n{s}\n", .{ r.findings, r.report });
        return error.TestUnexpectedFinding;
    }
}
