//! The search's cases: a table of outcomes stands in for the builds.
const std = @import("std");
const search = @import("search.zig");
const t = std.testing;

/// Commits before `culprit` pass, the rest fail; `infra` lists commits whose
/// probe is untestable. Records every index probed.
const Table = struct {
    culprit: usize,
    infra: []const usize = &.{},
    probed: [64]usize = undefined,
    n_probed: usize = 0,

    pub fn probe(self: *Table, i: usize) !search.Outcome {
        self.probed[self.n_probed] = i;
        self.n_probed += 1;
        for (self.infra) |x| if (x == i) return .infra;
        return if (i < self.culprit) .pass else .fail;
    }

    fn sawProbe(self: *const Table, i: usize) bool {
        for (self.probed[0..self.n_probed]) |p| if (p == i) return true;
        return false;
    }
};

fn ceilLog2(n: usize) usize {
    var k: usize = 0;
    while ((@as(usize, 1) << @intCast(k)) < n) k += 1;
    return k;
}

test "every culprit position of every length up to 40 is found within ceil(log2 n) probes, never probing the bad commit" {
    var scratch: [64]bool = undefined;
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var c: usize = 0;
        while (c < n) : (c += 1) {
            var tab = Table{ .culprit = c };
            const r = try search.search(n, &tab, &scratch);
            try t.expectEqual(search.Result{ .culprit = c }, r);
            try t.expect(tab.n_probed <= ceilLog2(n));
            try t.expect(!tab.sawProbe(n - 1));
        }
    }
}

test "the first probe of 9 candidates is index 3, the midpoint of (-1, 8)" {
    var scratch: [9]bool = undefined;
    var tab = Table{ .culprit = 5 };
    _ = try search.search(9, &tab, &scratch);
    try t.expectEqual(@as(usize, 3), tab.probed[0]);
    try t.expectEqualSlices(usize, &.{ 3, 5, 4 }, tab.probed[0..tab.n_probed]);
}

test "a single candidate is the bad commit: no probe" {
    var scratch: [1]bool = undefined;
    var tab = Table{ .culprit = 0 };
    try t.expectEqual(search.Result{ .culprit = 0 }, try search.search(1, &tab, &scratch));
    try t.expectEqual(@as(usize, 0), tab.n_probed);
}

test "an untestable midpoint is skipped for its closest neighbour and the culprit is still found" {
    var scratch: [9]bool = undefined;
    var tab = Table{ .culprit = 5, .infra = &.{3} };
    try t.expectEqual(search.Result{ .culprit = 5 }, try search.search(9, &tab, &scratch));
    // 3 is untestable; 2 (below, first on a tie) passes; then the search goes on above it.
    try t.expectEqual(@as(usize, 3), tab.probed[0]);
    try t.expectEqual(@as(usize, 2), tab.probed[1]);
}

test "an untestable culprit leaves the culprit and the next commit as the candidates" {
    var scratch: [9]bool = undefined;
    var tab = Table{ .culprit = 5, .infra = &.{5} };
    const r = try search.search(9, &tab, &scratch);
    try t.expectEqual(search.Result{ .inconclusive = .{ .first = 5, .last = 6 } }, r);
}

test "an untestable commit is never counted as failing: an untestable c0 before a culprit c1" {
    var scratch: [4]bool = undefined;
    var tab = Table{ .culprit = 1, .infra = &.{0} };
    const r = try search.search(4, &tab, &scratch);
    try t.expectEqual(search.Result{ .inconclusive = .{ .first = 0, .last = 1 } }, r);
}

test "every commit untestable: inconclusive over all of them" {
    var scratch: [5]bool = undefined;
    var tab = Table{ .culprit = 2, .infra = &.{ 0, 1, 2, 3 } };
    const r = try search.search(5, &tab, &scratch);
    try t.expectEqual(search.Result{ .inconclusive = .{ .first = 0, .last = 4 } }, r);
    try t.expectEqual(@as(usize, 4), tab.n_probed);
}

test "nextProbe: the closest untested index inside the open interval, lower first" {
    const u = [_]bool{ false, true, true, false, false };
    try t.expectEqual(@as(?isize, 3), search.nextProbe(-1, 4, 2, &u));
    try t.expectEqual(@as(?isize, 0), search.nextProbe(-1, 3, 1, &u));
    try t.expectEqual(@as(?isize, null), search.nextProbe(0, 3, 1, &u));
    try t.expectEqual(@as(isize, 3), search.midpoint(-1, 8));
    try t.expectEqual(@as(isize, -1 + 0), search.midpoint(-1, 0));
}
