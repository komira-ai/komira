//! The parallelism table: one line per variant, function and thread count,
//! from checked reports.
//!
//! For each variant and function, the lines are N = 1, 4 and 16 and every
//! other N a report holds, ascending. A line's numbers come from its row:
//! rows/s = rows / wall time, per thread = rows/s / N, efficiency =
//! rows/s(N) / (N x rows/s(1)), from the same variant and function at N = 1.
//! A row with more threads than the CPUs of its own report's host reads
//! `not measured: <cpus> cpus`. A missing line reads the same when its N is
//! above the most CPUs of any report holding that variant and function, with
//! that report's CPUs and run id (the first such report, in the order given);
//! any other missing line reads `missing`, since a host with enough CPUs ran
//! the function and the line could have been measured.
//! Flags: `noisy` when user + system CPU time is below 0.8 x wall x N, and
//! `throttled` when the cgroup throttled the run (nr_throttled went up).
//! The same variant, function and N in two rows is an error.

const std = @import("std");
const C = @import("common.zig");
const R = @import("report.zig");
const Fail = C.Fail;

pub const standard_threads = [_]u64{ 1, 4, 16 };

pub fn rowsPerS(r: R.Row) f64 {
    return @as(f64, @floatFromInt(r.rows)) * 1e9 / @as(f64, @floatFromInt(r.wall_ns));
}

pub fn noisy(r: R.Row) bool {
    const cpu: f64 = @floatFromInt(r.cpu_user_ns + r.cpu_sys_ns);
    return cpu < 0.8 * @as(f64, @floatFromInt(r.wall_ns)) * @as(f64, @floatFromInt(r.threads));
}

fn mib(bytes: u64) []const u8 {
    return C.fmt("{d:.1} MiB", .{@as(f64, @floatFromInt(bytes)) / 1048576.0});
}

const Entry = struct { row: R.Row, rep: *const R.Report };

const Group = struct {
    variant: []const u8,
    function: []const u8,
    rows: std.ArrayList(Entry),

    fn at(self: *const Group, n: u64) ?Entry {
        for (self.rows.items) |e| {
            if (e.row.threads == n) return e;
        }
        return null;
    }
};

fn groups(reports: []const R.Report) Fail![]Group {
    var out = C.list(Group);
    for (reports) |*rep| {
        for (rep.rows) |row| {
            const g = for (out.items) |*x| {
                if (C.eql(x.variant, row.variant) and C.eql(x.function, row.function)) break x;
            } else blk: {
                C.push(Group, &out, .{ .variant = row.variant, .function = row.function, .rows = C.list(Entry) });
                break :blk &out.items[out.items.len - 1];
            };
            if (g.at(row.threads)) |other| {
                return C.fail("{s} {s} N={d} is in {s} and in {s}", .{ row.variant, row.function, row.threads, other.rep.target, rep.target });
            }
            C.push(Entry, &g.rows, .{ .row = row, .rep = rep });
        }
    }
    return out.items;
}

fn line(out: *std.ArrayList(u8), cells: []const []const u8) void {
    C.add(out, "| ");
    C.add(out, C.join(cells, " | "));
    C.add(out, " |\n");
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn lessU64(_: void, x: u64, y: u64) bool {
    return x < y;
}

/// Sorted, without repeats.
fn uniq(comptime T: type, items: []T, comptime less: fn (void, T, T) bool, comptime same: fn (T, T) bool) []T {
    std.mem.sort(T, items, {}, less);
    var n: usize = 0;
    for (items) |x| {
        if (n > 0 and same(items[n - 1], x)) continue;
        items[n] = x;
        n += 1;
    }
    return items[0..n];
}

fn sameStr(x: []const u8, y: []const u8) bool {
    return C.eql(x, y);
}

fn sameU64(x: u64, y: u64) bool {
    return x == y;
}

const dashes5 = [_][]const u8{"-"} ** 5;

/// Renders the table and the facts of each report, in Markdown.
pub fn render(reports: []const R.Report) Fail![]const u8 {
    var out = C.list(u8);
    C.add(&out, "# Parallelism table\n\n");
    var ids = C.list([]const u8);
    for (reports) |r| C.push([]const u8, &ids, r.run_id);
    const runs = uniq([]const u8, ids.items, lessStr, sameStr);
    if (runs.len > 1) C.add(&out, C.fmt("The reports are of {d} runs: {s}.\n\n", .{ runs.len, C.join(runs, ", ") }));
    line(&out, &.{ "variant", "function", "N", "rows/s", "rows/s per thread", "efficiency", "memory", "latency ns (median / p90)", "flags", "run_id" });
    line(&out, &([_][]const u8{"---"} ** 10));
    for (try groups(reports)) |g| {
        const base: ?f64 = if (g.at(1)) |e| rowsPerS(e.row) else null;
        // The report of the group with the most CPUs; the first, on a tie.
        var most = g.rows.items[0].rep;
        for (g.rows.items) |e| {
            if (e.rep.host.cpus > most.host.cpus) most = e.rep;
        }
        var ns = C.list(u64);
        for (g.rows.items) |e| C.push(u64, &ns, e.row.threads);
        for (standard_threads) |n| C.push(u64, &ns, n);
        for (uniq(u64, ns.items, lessU64, sameU64)) |n| {
            var cells = C.list([]const u8);
            for ([_][]const u8{ g.variant, g.function, C.fmt("{d}", .{n}) }) |c| C.push([]const u8, &cells, c);
            const e = g.at(n) orelse {
                const why = if (n > most.host.cpus) C.fmt("not measured: {d} cpus", .{most.host.cpus}) else "missing";
                C.push([]const u8, &cells, why);
                for (dashes5) |d| C.push([]const u8, &cells, d);
                C.push([]const u8, &cells, most.run_id);
                line(&out, cells.items);
                continue;
            };
            const row = e.row;
            const rep = e.rep;
            if (n > rep.host.cpus) {
                C.push([]const u8, &cells, C.fmt("not measured: {d} cpus", .{rep.host.cpus}));
                for (dashes5) |d| C.push([]const u8, &cells, d);
            } else {
                const rps = rowsPerS(row);
                const nf: f64 = @floatFromInt(n);
                C.push([]const u8, &cells, C.fmt("{d:.0}", .{rps}));
                C.push([]const u8, &cells, C.fmt("{d:.0}", .{rps / nf}));
                C.push([]const u8, &cells, if (base) |b| C.fmt("{d:.2}", .{rps / (nf * b)}) else "-");
                var mem = C.list([]const u8);
                for (row.memory) |m| C.push([]const u8, &mem, C.fmt("{s} {s}", .{ m.k, mib(m.bytes) }));
                C.push([]const u8, &cells, C.join(mem.items, ", "));
                C.push([]const u8, &cells, C.fmt("{d} / {d}", .{ row.latency.median, row.latency.p90 }));
                var flags = C.list([]const u8);
                if (noisy(row)) C.push([]const u8, &flags, "noisy");
                if (rep.host.nr_throttled_delta > 0) C.push([]const u8, &flags, "throttled");
                C.push([]const u8, &cells, if (flags.items.len == 0) "-" else C.join(flags.items, ", "));
            }
            C.push([]const u8, &cells, rep.run_id);
            line(&out, cells.items);
        }
    }
    C.add(&out, "\n## Reports\n\n");
    for (reports) |r| {
        const h = r.host;
        const b = r.build;
        var opt = C.list([]const u8);
        for (b.opt_levels) |kv| C.push([]const u8, &opt, C.fmt("{s}=O{s}", .{ kv.k, kv.v }));
        var ver = C.list([]const u8);
        for (b.versions) |kv| C.push([]const u8, &ver, C.fmt("{s} {s}", .{ kv.k, kv.v }));
        var warm = C.list([]const u8);
        for (r.rows) |x| C.push([]const u8, &warm, C.fmt("{d}", .{x.latency.warmup_discarded}));
        C.add(&out, C.fmt(
            "- `{s}[report]` run_id={s}: {d} cpus ({s}), cpu.max {s}, nr_throttled +{d}, throttled_usec +{d}, loadavg {d} {d} {d}; opt levels {s}; coverage {s}; versions {s}; warmup discarded {s}\n",
            .{
                r.target,                 r.run_id,                   h.cpus,
                h.cpu_model,              h.cpu_max,                  h.nr_throttled_delta,
                h.throttled_usec_delta,   h.loadavg[0],               h.loadavg[1],
                h.loadavg[2],             C.join(opt.items, " "),     if (b.coverage) "yes" else "no",
                if (ver.items.len == 0) "-" else C.join(ver.items, ", "), C.join(warm.items, "/"),
            },
        ));
    }
    return out.items;
}
