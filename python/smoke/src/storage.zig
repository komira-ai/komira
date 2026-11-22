//! pypi_smoke: how much of an index's per-project limit a project's files take (`storage`). One GET of the
//! project's JSON; the total is the sum of `size` over every file of every release. A project the index does
//! not know holds nothing. Arithmetic is integer: the limit is `limit-gib` GiB, the percent is shown with one
//! decimal from per-mille, and `over` is `total * 100 > limit * over-percent`.
const std = @import("std");
const common = @import("common.zig");
const project = @import("project.zig");
const rbf = @import("release_beta_fetch");

const Allocator = common.Allocator;
const Error = common.Error;

pub const gib: u128 = 1 << 30;

pub const Totals = struct { bytes: u64 = 0, files: u64 = 0, versions: u64 = 0 };

pub const Options = struct {
    idx: common.Index,
    project: []const u8,
    limit_gib: u64,
    over_percent: u64,
};

pub const Report = struct {
    totals: Totals,
    over: bool,
    /// The Markdown bullet for the job summary, with its line feed.
    bullet: []const u8,
    /// The line of the GitHub log: the bullet's text when not over, the error annotation when over.
    log: []const u8,
};

pub fn title(idx: common.Index) []const u8 {
    return if (std.mem.eql(u8, idx.name, "testpypi")) "TestPyPI" else "PyPI";
}

/// `num / den` rounded to the nearest `1 / scale`, as a whole number of `1 / scale`s.
fn scaled(num: u128, den: u128, scale: u128) u128 {
    return (num * scale * 2 + den) / (den * 2);
}

fn hundredths(a: Allocator, n: u128) Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d:0>2}", .{ n / 100, n % 100 });
}

fn tenths(a: Allocator, n: u128) Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}", .{ n / 10, n % 10 });
}

/// What the maintainer does when an index is over the threshold: TestPyPI's old versions can be deleted;
/// PyPI's releases are never deleted, so only a higher limit helps there.
fn advice(idx: common.Index) []const u8 {
    if (std.mem.eql(u8, idx.name, "pypi")) return "ask for a higher limit on PyPI (its releases are never deleted)";
    return "prune old versions on TestPyPI or ask for a higher limit";
}

pub fn over(totals: Totals, limit_gib: u64, over_percent: u64) bool {
    return @as(u128, totals.bytes) * 100 > @as(u128, limit_gib) * gib * over_percent;
}

pub fn measure(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, opts: Options) Error!Report {
    var totals = Totals{};
    if (try project.fetch(project.Sized, a, why, fetcher, opts.idx, opts.project)) |releases| {
        for (releases.map.values()) |files| {
            if (files.len != 0) totals.versions += 1;
            for (files) |f| {
                totals.bytes += f.size;
                totals.files += 1;
            }
        }
    }
    const limit = @as(u128, opts.limit_gib) * gib;
    const is_over = over(totals, opts.limit_gib, opts.over_percent);
    const size = try hundredths(a, scaled(totals.bytes, gib, 100));
    const percent = try tenths(a, scaled(totals.bytes, limit, 1000));
    const text = try std.fmt.allocPrint(a, "{s} on {s}: {s} GiB ({d} bytes) in {d} files of {d} versions, {s}% of the {d} GiB limit", .{ opts.project, title(opts.idx), size, totals.bytes, totals.files, totals.versions, percent, opts.limit_gib });
    const bullet = if (is_over)
        try std.fmt.allocPrint(a, "- {s}: **over {d}%**\n", .{ text, opts.over_percent })
    else
        try std.fmt.allocPrint(a, "- {s}\n", .{text});
    const log = if (is_over)
        try std.fmt.allocPrint(a, "::error title=pypi::{s} on {s} holds {s} GiB, {s}% of its {d} GiB limit, over {d}%: {s} (docs/ci.md, Storage on the indexes)\n", .{ opts.project, title(opts.idx), size, percent, opts.limit_gib, opts.over_percent, advice(opts.idx) })
    else
        try std.fmt.allocPrint(a, "pypi_smoke: {s}\n", .{text});
    return .{ .totals = totals, .over = is_over, .bullet = bullet, .log = log };
}
