//! cov_branch_records: the output side of cov_branch_classify (README.md,
//! "cov_branch_classify"): one decision's record, and the lcov text of all
//! of them, copies summed arm by arm, files sorted. Imported by
//! cov_branch_classify.zig; no `main` of its own.

const std = @import("std");
const Alloc = std.mem.Allocator;
const source = @import("cov_branch_source.zig");
const fail = source.fail;
const oom = source.oom;
const Kind = source.Kind;

/// A record: one decision summed over the copies of its function.
pub const Record = struct {
    repo: []const u8,
    line: u64,
    col: u64,
    kind: Kind,
    ordinal: usize,
    total: usize, // how many of this kind at this location one copy holds
    arms: usize,
    weights: ?[]const u64, // null: never ran
};

fn recordLess(_: void, a: Record, b: Record) bool {
    const o = std.mem.order(u8, a.repo, b.repo);
    if (o != .eq) return o == .lt;
    if (a.line != b.line) return a.line < b.line;
    if (a.col != b.col) return a.col < b.col;
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return a.ordinal < b.ordinal;
}

// ---- output ----------------------------------------------------------------

fn pathLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Writes `SF:` and `end_of_record` for each path of `coded` (sorted) from
/// `p.*` on that sorts before `upto` (every one left when null), and steps
/// past `upto` itself: a measured file the IR holds code of, with no record.
fn writeNoRecord(w: anytype, coded: []const []const u8, p: *usize, upto: ?[]const u8) void {
    while (p.* < coded.len) {
        if (upto) |u| {
            switch (std.mem.order(u8, coded[p.*], u)) {
                .gt => return,
                .eq => {
                    p.* += 1;
                    return;
                },
                .lt => {},
            }
        }
        w.print("SF:{s}\nend_of_record\n", .{coded[p.*]}) catch oom();
        p.* += 1;
    }
}

/// The output: the records of `recs`, per file, and each measured file of
/// `coded` (the repository paths of the measured files the IR holds code
/// of) with no record named all the same, files sorted bytewise.
pub fn render(alloc: Alloc, recs: []Record, coded: [][]const u8) []const u8 {
    std.mem.sort(Record, recs, {}, recordLess);
    std.mem.sort([]const u8, coded, {}, pathLess);
    var p: usize = 0;
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();
    var i: usize = 0;
    var cur: ?[]const u8 = null;
    while (i < recs.len) {
        // Sum the copies of one (file, line, column, kind, ordinal).
        var j = i + 1;
        while (j < recs.len and !recordLess({}, recs[i], recs[j]) and !recordLess({}, recs[j], recs[i])) j += 1;
        const n = recs[i].arms;
        var ran = false;
        for (recs[i..j]) |r| {
            if (r.arms != n) fail("{s}:{d}:{d}: two instances of one {s} have {d} and {d} arms; nothing written", .{ r.repo, r.line, r.col, @tagName(r.kind), n, r.arms });
            if (r.weights != null) ran = true;
        }
        if (cur == null or !std.mem.eql(u8, cur.?, recs[i].repo)) {
            if (cur != null) w.writeAll("end_of_record\n") catch oom();
            writeNoRecord(w, coded, &p, recs[i].repo);
            cur = recs[i].repo;
            w.print("SF:{s}\n", .{recs[i].repo}) catch oom();
        }
        for (0..n) |arm| {
            w.print("BRDA:{d},{d}:{s}:{d}/{d},{d},", .{ recs[i].line, recs[i].col, @tagName(recs[i].kind), recs[i].ordinal, recs[i].total, arm }) catch oom();
            if (!ran) {
                w.writeAll("-\n") catch oom();
            } else {
                var sum: u64 = 0;
                for (recs[i..j]) |r| {
                    if (r.weights) |x| sum += if (arm < x.len) x[arm] else 0;
                }
                w.print("{d}\n", .{sum}) catch oom();
            }
        }
        i = j;
    }
    if (cur != null) w.writeAll("end_of_record\n") catch oom();
    writeNoRecord(w, coded, &p, null);
    return buf.items;
}

pub fn writeOut(path: []const u8, bytes: []const u8) !void {
    var af = try std.fs.cwd().atomicFile(path, .{});
    defer af.deinit();
    try af.file.writeAll(bytes);
    try af.finish();
}

pub fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}
