// Why Zig: build tools are Zig (tools/build/README.md): the freshness check of a
// generated library runs as a build action, so it is a program, not a script.
//! fresh: the freshness check of a generated library (the `<name>_fresh` target of
//! tools/build/gen/defs.bzl).
//!
//!   fresh --gen <dir> --committed <dir> --label <label> --dir <path> --regen <command> --out <file>
//!
//! <dir> after `--gen` is what the generator writes now (the `<name>_gen` target);
//! after `--committed` it is the directory the library is built from, as committed
//! to the repository (<path> names it in the repository, for the message). The two
//! must be the same set of files with the same bytes. When they are, <file> is
//! written (the marker the library's gate takes as an input). When they are not,
//! nothing is written and the exit status is 1: the message on stderr lists the
//! files that are missing from the committed directory, the committed files that
//! are no longer generated, and the files whose bytes differ (the first line that
//! differs), then prints <command>, the command that regenerates the directory.
//!
//! Exit status: 0 in sync; 1 out of date; 2 for a usage error or a failure of the
//! tool's own.

const std = @import("std");
const U = @import("act_util");

const prog = "gen_fresh";

/// How one file of the two directories differs.
pub const Diff = struct {
    name: []const u8,
    /// 1-based line of the first difference.
    line: usize,
    committed: []const u8,
    generated: []const u8,
};

pub const Report = struct {
    /// Generated now, not committed.
    missing: []const []const u8,
    /// Committed, not generated now.
    stale: []const []const u8,
    /// In both, with other bytes.
    differ: []const Diff,

    pub fn inSync(self: Report) bool {
        return self.missing.len == 0 and self.stale.len == 0 and self.differ.len == 0;
    }
};

/// The longest part of a line the message quotes.
const quote_max = 120;

fn clip(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const t = std.mem.trimRight(u8, s, "\r");
    if (t.len <= quote_max) return t;
    return std.fmt.allocPrint(a, "{s}...", .{t[0..quote_max]});
}

/// The first line where `x` and `y` differ: its 1-based number and the line in
/// each (empty past the end of the shorter file).
fn firstDifference(a: std.mem.Allocator, x: []const u8, y: []const u8) !struct { line: usize, x: []const u8, y: []const u8 } {
    var xi = std.mem.splitScalar(u8, x, '\n');
    var yi = std.mem.splitScalar(u8, y, '\n');
    var n: usize = 1;
    while (true) : (n += 1) {
        const lx = xi.next();
        const ly = yi.next();
        if (lx == null and ly == null) break;
        const sx = lx orelse "";
        const sy = ly orelse "";
        if (lx == null or ly == null or !std.mem.eql(u8, sx, sy)) {
            return .{ .line = n, .x = try clip(a, sx), .y = try clip(a, sy) };
        }
    }
    // Equal line by line, so they differ in the bytes only after the last
    // line (a missing final newline).
    return .{ .line = n, .x = "", .y = "" };
}

/// Compares the regular files under `gen` and under `committed` (relative paths,
/// subdirectories included). Symbolic links are followed: a staged directory of
/// source files may be made of them.
pub fn judge(a: std.mem.Allocator, gen: std.fs.Dir, committed: std.fs.Dir) !Report {
    const g = try U.listFiles(a, gen, true);
    const c = try U.listFiles(a, committed, true);
    var missing = std.ArrayList([]const u8).empty;
    var stale = std.ArrayList([]const u8).empty;
    var differ = std.ArrayList(Diff).empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < g.len or j < c.len) {
        const order: std.math.Order = if (i >= g.len) .gt else if (j >= c.len) .lt else std.mem.order(u8, g[i], c[j]);
        switch (order) {
            .lt => {
                try missing.append(a, g[i]);
                i += 1;
            },
            .gt => {
                try stale.append(a, c[j]);
                j += 1;
            },
            .eq => {
                const gb = try U.readAll(a, gen, g[i]);
                const cb = try U.readAll(a, committed, c[j]);
                if (!std.mem.eql(u8, gb, cb)) {
                    const d = try firstDifference(a, cb, gb);
                    try differ.append(a, .{ .name = g[i], .line = d.line, .committed = d.x, .generated = d.y });
                }
                i += 1;
                j += 1;
            },
        }
    }
    return .{ .missing = missing.items, .stale = stale.items, .differ = differ.items };
}

fn put(a: std.mem.Allocator, b: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    try b.appendSlice(a, text);
}

/// The message of a Report that is not in sync.
pub fn render(a: std.mem.Allocator, r: Report, label: []const u8, dir: []const u8, regen: []const u8) ![]u8 {
    var b = std.ArrayList(u8).empty;
    try put(a, &b, "{s}: the committed generated sources of {s} are out of date ({s}/).\n", .{ prog, label, dir });
    for (r.missing) |n| try put(a, &b, "  missing, generated now but not committed: {s}\n", .{n});
    for (r.stale) |n| try put(a, &b, "  stale, committed but no longer generated: {s}\n", .{n});
    for (r.differ) |d| {
        try put(a, &b, "  differs: {s}, first at line {d}:\n    committed: {s}\n    generated: {s}\n", .{ d.name, d.line, d.committed, d.generated });
    }
    try put(a, &b, "Generated files are never edited by hand, and the library is built from them only while they are what the generator writes now. Regenerate with:\n    {s}\nand commit {s}/.\n", .{ regen, dir });
    return b.items;
}

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    const spec = [_]U.Spec{ .{ .name = "gen" }, .{ .name = "committed" }, .{ .name = "label" }, .{ .name = "dir" }, .{ .name = "regen" }, .{ .name = "out" } };
    var bad: []const u8 = "";
    const plain = a.alloc([]const u8, argv.len - 1) catch std.process.exit(2);
    for (argv[1..], 0..) |s, i| plain[i] = s;
    const f = U.parseFlags(a, plain, &spec, &bad) catch |e| std.process.exit(usage("{s}: {s}", .{ @errorName(e), bad }));
    const gen = f.need("gen") catch std.process.exit(usage("needs --gen", .{}));
    const committed = f.need("committed") catch std.process.exit(usage("needs --committed", .{}));
    const label = f.need("label") catch std.process.exit(usage("needs --label", .{}));
    const dir = f.need("dir") catch std.process.exit(usage("needs --dir", .{}));
    const regen = f.need("regen") catch std.process.exit(usage("needs --regen", .{}));
    const out = f.need("out") catch std.process.exit(usage("needs --out", .{}));

    var gd = std.fs.cwd().openDir(gen, .{ .iterate = true }) catch |e| std.process.exit(usage("cannot open {s}: {s}", .{ gen, @errorName(e) }));
    defer gd.close();
    var cd = std.fs.cwd().openDir(committed, .{ .iterate = true }) catch |e| std.process.exit(usage("cannot open {s}: {s}", .{ committed, @errorName(e) }));
    defer cd.close();
    const report = judge(a, gd, cd) catch |e| std.process.exit(usage("cannot compare the directories: {s}", .{@errorName(e)}));
    if (!report.inSync()) {
        const text = render(a, report, label, dir, regen) catch std.process.exit(2);
        std.debug.print("{s}", .{text});
        std.process.exit(1);
    }
    U.writeAll(std.fs.cwd(), out, "in sync\n") catch |e| std.process.exit(usage("cannot write {s}: {s}", .{ out, @errorName(e) }));
}
