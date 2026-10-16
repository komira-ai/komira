//! A unified diff of two texts, as `diff -u -L` prints it (proto_fixture.zig's leg 1).

const std = @import("std");

fn splitLines(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        try out.append(l);
    }
    return out.toOwnedSlice();
}

/// `diff -u -L <label1> -L <label2> <a> <b>`: null when the texts are equal.
/// Lines are compared as lines; three lines of context.
pub fn unifiedDiff(a: std.mem.Allocator, label1: []const u8, label2: []const u8, t1: []const u8, t2: []const u8) !?[]u8 {
    if (std.mem.eql(u8, t1, t2)) return null;
    const x = try splitLines(a, t1);
    const y = try splitLines(a, t2);
    const n = x.len;
    const m = y.len;
    // The longest common subsequence of lines, from the ends (so a diff of two
    // large files that share a prefix and a suffix stays cheap).
    var pre: usize = 0;
    while (pre < n and pre < m and std.mem.eql(u8, x[pre], y[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < n - pre and suf < m - pre and std.mem.eql(u8, x[n - 1 - suf], y[m - 1 - suf])) suf += 1;
    const xs = x[pre .. n - suf];
    const ys = y[pre .. m - suf];
    const w = ys.len + 1;
    const table = try a.alloc(u32, (xs.len + 1) * w);
    @memset(table, 0);
    var i: usize = xs.len;
    while (i > 0) {
        i -= 1;
        var j: usize = ys.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (std.mem.eql(u8, xs[i], ys[j])) table[(i + 1) * w + j + 1] + 1 else @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    // Ops over the whole files: ' ' common, '-' only in the first, '+' only in the second.
    const Op = struct { kind: u8, line: []const u8 };
    var ops = std.ArrayList(Op).init(a);
    for (x[0..pre]) |l| try ops.append(.{ .kind = ' ', .line = l });
    var p: usize = 0;
    var q: usize = 0;
    while (p < xs.len or q < ys.len) {
        if (p < xs.len and q < ys.len and std.mem.eql(u8, xs[p], ys[q])) {
            try ops.append(.{ .kind = ' ', .line = xs[p] });
            p += 1;
            q += 1;
        } else if (p < xs.len and (q == ys.len or table[(p + 1) * w + q] >= table[p * w + q + 1])) {
            try ops.append(.{ .kind = '-', .line = xs[p] });
            p += 1;
        } else {
            try ops.append(.{ .kind = '+', .line = ys[q] });
            q += 1;
        }
    }
    for (x[n - suf ..]) |l| try ops.append(.{ .kind = ' ', .line = l });

    var out = std.ArrayList(u8).init(a);
    try out.writer().print("--- {s}\n+++ {s}\n", .{ label1, label2 });
    const context = 3;
    // The line number of each op in the old and the new file.
    const old_at = try a.alloc(usize, ops.items.len + 1);
    const new_at = try a.alloc(usize, ops.items.len + 1);
    var l1: usize = 1;
    var l2: usize = 1;
    for (ops.items, 0..) |op, k| {
        old_at[k] = l1;
        new_at[k] = l2;
        if (op.kind != '+') l1 += 1;
        if (op.kind != '-') l2 += 1;
    }
    var k: usize = 0;
    while (k < ops.items.len) {
        while (k < ops.items.len and ops.items[k].kind == ' ') k += 1;
        if (k == ops.items.len) break;
        // A hunk: the changes from k, merged while the common run between two is no longer than twice the context.
        const first = k;
        var last = k;
        var j = k + 1;
        while (j < ops.items.len) : (j += 1) {
            if (ops.items[j].kind != ' ') {
                last = j;
            } else if (j - last > 2 * context) break;
        }
        const start = if (first >= context) first - context else 0;
        const stop = @min(ops.items.len, last + context + 1);
        var olds: usize = 0;
        var news: usize = 0;
        for (ops.items[start..stop]) |op| {
            if (op.kind != '+') olds += 1;
            if (op.kind != '-') news += 1;
        }
        const o1 = if (olds == 0) old_at[start] - 1 else old_at[start];
        const n1 = if (news == 0) new_at[start] - 1 else new_at[start];
        try out.writer().print("@@ -{d},{d} +{d},{d} @@\n", .{ o1, olds, n1, news });
        for (ops.items[start..stop]) |op| try out.writer().print("{c}{s}\n", .{ op.kind, op.line });
        k = stop;
    }
    return try out.toOwnedSlice();
}
