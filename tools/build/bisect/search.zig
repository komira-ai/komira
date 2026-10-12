//! The binary search over the candidates, a pure function of the outcome of
//! each probe.
//!
//! The candidates c[0..n-1] are the first-parent commits after the good one,
//! oldest first; c[n-1] is the bad commit, which the caller has already seen
//! fail. The good commit is assumed to pass and is never probed. The search
//! keeps lo (the newest commit known to pass, -1 for good) and hi (the oldest
//! known to fail) and probes between them until they are adjacent: then
//! c[hi] is the first bad commit. A probe whose outcome is `infra` marks its
//! commit untestable, and the next probe is the untested commit closest to
//! the midpoint, as `git bisect skip` does; when every commit between lo and
//! hi is untestable, the search ends inconclusive.
const std = @import("std");

pub const Outcome = enum { pass, fail, infra };

pub const Result = union(enum) {
    /// The index of the first bad commit.
    culprit: usize,
    /// Every candidate between the last passing commit and the first
    /// failing one is untestable: the first bad commit is one of
    /// c[first..last] (inclusive; c[last] failed).
    inconclusive: struct { first: usize, last: usize },
};

/// The midpoint of the open interval (lo, hi); lo may be -1.
pub fn midpoint(lo: isize, hi: isize) isize {
    return lo + @divTrunc(hi - lo, 2);
}

/// The untested index in (lo, hi) closest to `mid`, the lower one first on a
/// tie; null when every index there is untestable.
pub fn nextProbe(lo: isize, hi: isize, mid: isize, untestable: []const bool) ?isize {
    var d: isize = 0;
    while (true) : (d += 1) {
        const below = mid - d;
        const above = mid + d;
        const below_in = below > lo and below < hi;
        const above_in = above > lo and above < hi;
        if (!below_in and !above_in) return null;
        if (below_in and !untestable[@intCast(below)]) return below;
        if (above_in and !untestable[@intCast(above)]) return above;
    }
}

/// Searches c[0..n-1] for the first bad commit. `ctx.probe(i)` builds c[i]
/// and returns its outcome (after any retry); it is never called for n-1.
/// `untestable` is scratch of at least n entries.
pub fn search(n: usize, ctx: anytype, untestable: []bool) !Result {
    std.debug.assert(n > 0 and untestable.len >= n);
    @memset(untestable[0..n], false);
    var lo: isize = -1;
    var hi: isize = @intCast(n - 1);
    while (hi - lo > 1) {
        const mid = nextProbe(lo, hi, midpoint(lo, hi), untestable) orelse
            return .{ .inconclusive = .{ .first = @intCast(lo + 1), .last = @intCast(hi) } };
        switch (try ctx.probe(@intCast(mid))) {
            .pass => lo = mid,
            .fail => hi = mid,
            .infra => untestable[@intCast(mid)] = true,
        }
    }
    return .{ .culprit = @intCast(hi) };
}
