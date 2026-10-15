//! census_files: the per-package coverage files, put together and taken
//! apart (census.md).
//!
//! usage: census_files assemble <target bp> <dir> <census out> <held out>
//!        census_files split <target bp> <census.tsv> <out dir>
//!
//! Each package keeps its own coverage data, so a change to one package's
//! coverage touches that package's directory and nothing else:
//!
//!   <package>/coverage_census.tsv  what the census measured of its
//!                                  libraries: `#` comment lines, the line
//!                                  `census <date> <commit> <note>`, then
//!                                  one row per library (census.sh says the
//!                                  12 fields), each naming the file's own
//!                                  directory as its package (field 2)
//!   <package>/coverage_held        the metrics the package holds at the
//!                                  target: `#` comment lines, then `line`
//!                                  and/or `branch`, one per line, each
//!                                  once, the grammar covcheck reads
//!                                  (README.md, "The 99% threshold and
//!                                  holds")
//!
//! A package reaches the target <target bp> on a metric when the census
//! measured it at least that on every library row of the package (kind
//! `library`) with an executable line, and on at least one: a row that is
//! not OK, or with no number for the metric (a branch `-`, or `0 0`), keeps
//! the package from reaching it; a row with no line (`0 0`, its sources all
//! generated) neither reaches nor keeps it from reaching. Basis points are
//! hit * 10000 / found, rounded down.
//!
//! assemble reads every such file under <dir> (the files staged at their
//! paths in the repository: //:coverage_census, census.bzl) and writes the
//! two files census.sh render and check read: <census out>, one comment
//! line, one census line and every row sorted by label in byte order, and
//! <held out>, one comment line and one row per marker sorted by package,
//! `<package> <metrics>` (tab-separated; `line`, `branch`, `line,branch`,
//! or `-` for a marker that holds nothing). The census line's date is the
//! latest of the packages', its commit theirs when they all name one (else
//! `-`), and its note theirs when every package has the same date and
//! note, `packages measured from <first> to <last>` when the dates differ,
//! else `-`. Refused, naming `<path>:<line>`: a file of another name, a
//! file at the top of <dir>, a carriage return, an empty line, a census
//! file without its census line first or without a library row, a
//! malformed census line, a row naming another package, a held line that is
//! not exactly `line` or `branch`, a metric held twice, a tree with no
//! census file; and, naming every one, a package that reached the target
//! on a metric its coverage_held does not hold (so a package that reaches
//! 99% stays held there). A label twice is left to render, which refuses
//! rows out of order (census.sh).
//!
//! split is the other way: from a census.tsv (census.sh collect writes it)
//! it writes each package's census file under <out dir>, the census line
//! repeated in each, and adds each metric a package reached to its
//! coverage_held there, writing the marker when it has none. It never
//! takes a metric out of a marker: a hold is removed by hand only. A
//! package's file it does not write is not touched (census.md says how to
//! refresh).
//!
//! Exit status: 0 done; 1 refused (nothing is written by assemble; split
//! checks everything before it writes); 2 bad usage.
//!
//! A static executable. `main` only builds the command line and calls
//! `entry`, which returns the exit status; census_files_test.zig calls
//! `entry` as main does.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const held_name = "coverage_held";
pub const census_name = "coverage_census.tsv";

pub const held_comment = "# The metrics this package holds at the coverage target, one per line: line, branch (tools/build/coverage/README.md, \"The 99% threshold and holds\").\n";
pub const census_comment = "# What the coverage census measured of this package's libraries (tools/build/coverage/census.md).\n";
pub const assembled_held_comment = "# The holds of every package: each package's coverage_held, assembled by census_files (census.bzl).\n";
pub const assembled_census_comment = "# The coverage census: each package's coverage_census.tsv, assembled by census_files (census.bzl).\n";

const usage =
    \\usage: census_files assemble <target bp> <dir> <census out> <held out>
    \\       census_files split <target bp> <census.tsv> <out dir>
    \\
;

const max_file = 1 << 26;

pub const Error = error{ Refused, Usage };

/// What the tool writes to stderr, collected, so the tests read the very
/// messages a run prints.
pub const Diag = struct {
    text: std.ArrayList(u8),
    alloc: Alloc,

    pub fn init(alloc: Alloc) Diag {
        return .{ .text = std.ArrayList(u8).empty, .alloc = alloc };
    }

    fn refuse(self: *Diag, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.text.writer(self.alloc).print("census_files: " ++ fmt ++ "\n", args) catch oom();
        return error.Refused;
    }

    fn usageFail(self: *Diag, comptime fmt: []const u8, args: anytype) error{Usage} {
        self.text.writer(self.alloc).print("census_files: " ++ fmt ++ "\n" ++ usage, args) catch oom();
        return error.Usage;
    }
};

fn oom() noreturn {
    std.debug.print("census_files: out of memory\n", .{});
    std.process.exit(1);
}

/// A row and what it is sorted by.
pub const Row = struct {
    key: []const u8,
    line: []const u8,
};

fn rowLess(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The census line's fields.
pub const Head = struct {
    date: []const u8,
    commit: []const u8,
    note: []const u8,
};

/// The lines of `text` (refusing a carriage return, an empty line and a
/// last line with no newline is accepted).
fn lines(alloc: Alloc, diag: *Diag, path: []const u8, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (std.mem.indexOfScalar(u8, text, '\r')) |at| {
        const n = std.mem.count(u8, text[0..at], "\n") + 1;
        return diag.refuse("{s}:{d}: a carriage return (the file must use LF line ends)", .{ path, n });
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        n += 1;
        if (l.len == 0) {
            if (it.peek() == null) break;
            return diag.refuse("{s}:{d}: an empty line (a comment starts with '#')", .{ path, n });
        }
        out.append(alloc, l) catch oom();
    }
    return out.items;
}

fn fields(alloc: Alloc, line: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| out.append(alloc, f) catch oom();
    return out.items;
}

/// A count of the census (a line or branch number): digits, no sign.
fn number(v: []const u8) ?u64 {
    if (v.len == 0 or v.len > 12) return null;
    for (v) |ch| if (ch < '0' or ch > '9') return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

fn isDate(v: []const u8) bool {
    if (v.len != 10 or v[4] != '-' or v[7] != '-') return false;
    for (v, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The metrics a package holds.
pub const Hold = struct {
    line: bool = false,
    branch: bool = false,
};

/// A package's coverage_held, checked.
pub fn parseHold(alloc: Alloc, diag: *Diag, path: []const u8, text: []const u8) !Hold {
    const ls = try lines(alloc, diag, path, text);
    var h = Hold{};
    for (ls, 1..) |l, n| {
        if (l[0] == '#') continue;
        const slot: *bool = if (std.mem.eql(u8, l, "line")) &h.line else if (std.mem.eql(u8, l, "branch")) &h.branch else return diag.refuse("{s}:{d}: '{s}' is not a held metric: a line holds exactly `line` or `branch`, with no number", .{ path, n, l });
        if (slot.*) return diag.refuse("{s}:{d}: {s} is held twice", .{ path, n, l });
        slot.* = true;
    }
    return h;
}

/// Whether a package reached the target on a metric: 0 no library row of
/// it with an executable line yet, 1 every one so far at the target, -1 one
/// that is not.
pub const Reach = struct {
    line: i8 = 0,
    branch: i8 = 0,
};

fn reachOne(state: *i8, hit: ?u64, found: ?u64, target: u64) void {
    if (hit == null or found == null or found.? == 0 or hit.? * 10000 / found.? < target) {
        state.* = -1;
    } else if (state.* == 0) state.* = 1;
}

/// What each package of the census `rows` reached (see the header).
pub fn reached(alloc: Alloc, rows: []const Row, target: u64) std.StringArrayHashMap(Reach) {
    var out = std.StringArrayHashMap(Reach).init(alloc);
    for (rows) |r| {
        const f = fields(alloc, r.line);
        if (f.len < 4 or std.mem.eql(u8, f[2], "test")) continue;
        const g = out.getOrPut(f[1]) catch oom();
        if (!g.found_existing) g.value_ptr.* = .{};
        if (f.len != 12 or !std.mem.eql(u8, f[3], "OK")) {
            g.value_ptr.* = .{ .line = -1, .branch = -1 };
            continue;
        }
        // A library with no line (its sources all generated) sets nothing.
        if (number(f[5]) != null and number(f[5]).? == 0) continue;
        reachOne(&g.value_ptr.line, number(f[4]), number(f[5]), target);
        reachOne(&g.value_ptr.branch, number(f[6]), number(f[7]), target);
    }
    return out;
}

fn parseTarget(diag: *Diag, v: []const u8) !u64 {
    const t = number(v) orelse return diag.usageFail("<target bp> '{s}' is not a number of basis points from 0 to 10000", .{v});
    if (t > 10000) return diag.usageFail("<target bp> '{s}' is not a number of basis points from 0 to 10000", .{v});
    return t;
}

fn keyLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The census line and the library rows of a package's coverage_census.tsv,
/// checked.
fn censusRows(alloc: Alloc, diag: *Diag, path: []const u8, package: []const u8, text: []const u8, rows: *std.ArrayList(Row)) !Head {
    const ls = try lines(alloc, diag, path, text);
    var head: ?Head = null;
    var count: usize = 0;
    for (ls, 1..) |l, n| {
        if (l[0] == '#') continue;
        const f = fields(alloc, l);
        if (head == null) {
            if (f.len != 4 or !std.mem.eql(u8, f[0], "census") or !isDate(f[1]) or f[2].len == 0 or f[3].len == 0)
                return diag.refuse("{s}:{d}: the first line is census<TAB><date YYYY-MM-DD><TAB><commit or -><TAB><note or ->", .{ path, n });
            head = .{ .date = f[1], .commit = f[2], .note = f[3] };
            continue;
        }
        if (f.len < 2 or !std.mem.eql(u8, f[1], package))
            return diag.refuse("{s}:{d}: the row's package is {s}, not its directory {s}", .{ path, n, if (f.len < 2) "missing" else f[1], package });
        rows.append(alloc, .{ .key = f[0], .line = l }) catch oom();
        count += 1;
    }
    if (head == null or count == 0) return diag.refuse("{s}: no census line and library row", .{path});
    return head.?;
}

fn readAll(alloc: Alloc, diag: *Diag, dir: std.fs.Dir, path: []const u8) ![]const u8 {
    return dir.readFileAlloc(alloc, path, max_file) catch |e| diag.refuse("{s}: cannot read it: {s}", .{ path, @errorName(e) });
}

fn writeAll(diag: *Diag, dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| dir.makePath(d) catch |e| return diag.refuse("{s}: cannot make it: {s}", .{ d, @errorName(e) });
    dir.writeFile(.{ .sub_path = path, .data = bytes }) catch |e| return diag.refuse("{s}: cannot write it: {s}", .{ path, @errorName(e) });
}

/// The census line of the assembled census.
pub fn combine(alloc: Alloc, heads: []const Head) []const u8 {
    var first = heads[0].date;
    var last = heads[0].date;
    var commit = heads[0].commit;
    var note = heads[0].note;
    for (heads[1..]) |h| {
        if (std.mem.lessThan(u8, h.date, first)) first = h.date;
        if (std.mem.lessThan(u8, last, h.date)) last = h.date;
        if (!std.mem.eql(u8, h.commit, commit)) commit = "-";
        if (!std.mem.eql(u8, h.note, note)) note = "-";
    }
    if (!std.mem.eql(u8, first, last))
        note = std.fmt.allocPrint(alloc, "packages measured from {s} to {s}", .{ first, last }) catch oom();
    return std.fmt.allocPrint(alloc, "census\t{s}\t{s}\t{s}\n", .{ last, commit, note }) catch oom();
}

fn assemble(alloc: Alloc, diag: *Diag, cwd: std.fs.Dir, args: []const []const u8) !void {
    if (args.len != 4) return diag.usageFail("assemble takes 4 arguments, not {d}", .{args.len});
    const target = try parseTarget(diag, args[0]);
    var root = cwd.openDir(args[1], .{ .iterate = true }) catch |e| return diag.refuse("{s}: cannot open it: {s}", .{ args[1], @errorName(e) });
    defer root.close();
    var paths = std.ArrayList([]const u8).empty;
    var walk = root.walk(alloc) catch oom();
    while (walk.next() catch |e| return diag.refuse("{s}: cannot list it: {s}", .{ args[1], @errorName(e) })) |e| {
        if (e.kind == .directory) continue;
        paths.append(alloc, alloc.dupe(u8, e.path) catch oom()) catch oom();
    }
    std.mem.sort([]const u8, paths.items, {}, strLess);
    var held = std.StringArrayHashMap(Hold).init(alloc);
    var rows = std.ArrayList(Row).empty;
    var heads = std.ArrayList(Head).empty;
    for (paths.items) |p| {
        const base = std.fs.path.basename(p);
        const package = std.fs.path.dirname(p) orelse
            return diag.refuse("{s}: at the top of {s}; a package's coverage files are in its directory", .{ p, args[1] });
        const text = try readAll(alloc, diag, root, p);
        if (std.mem.eql(u8, base, held_name)) {
            held.put(package, try parseHold(alloc, diag, p, text)) catch oom();
        } else if (std.mem.eql(u8, base, census_name)) {
            heads.append(alloc, try censusRows(alloc, diag, p, package, text, &rows)) catch oom();
        } else return diag.refuse("{s}: not a {s} or a {s}", .{ p, held_name, census_name });
    }
    if (heads.items.len == 0) return diag.refuse("{s}: no {s} under it", .{ args[1], census_name });
    std.mem.sort(Row, rows.items, {}, rowLess);
    // Every package that reached the target holds what it reached.
    var reach = reached(alloc, rows.items, target);
    const pkgs = alloc.dupe([]const u8, reach.keys()) catch oom();
    std.mem.sort([]const u8, pkgs, {}, keyLess);
    var missing = std.ArrayList(u8).empty;
    for (pkgs) |pkg| {
        const r = reach.get(pkg).?;
        const h = held.get(pkg) orelse Hold{};
        for ([_]struct { []const u8, bool, bool }{ .{ "line", r.line == 1, h.line }, .{ "branch", r.branch == 1, h.branch } }) |m| {
            if (m[1] and !m[2]) missing.writer(alloc).print("\n  {s}: {s} reached {d} basis points in every library; add `{s}` to {s}/{s}", .{ pkg, m[0], target, m[0], pkg, held_name }) catch oom();
        }
    }
    if (missing.items.len > 0)
        return diag.refuse("a package the census measured at the target does not hold it (census_files split adds the hold):{s}", .{missing.items});
    var c = std.ArrayList(u8).empty;
    c.appendSlice(alloc, assembled_census_comment) catch oom();
    c.appendSlice(alloc, combine(alloc, heads.items)) catch oom();
    for (rows.items) |r| c.writer(alloc).print("{s}\n", .{r.line}) catch oom();
    const hk = alloc.dupe([]const u8, held.keys()) catch oom();
    std.mem.sort([]const u8, hk, {}, keyLess);
    var f = std.ArrayList(u8).empty;
    f.appendSlice(alloc, assembled_held_comment) catch oom();
    for (hk) |pkg| {
        const h = held.get(pkg).?;
        const m: []const u8 = if (h.line and h.branch) "line,branch" else if (h.line) "line" else if (h.branch) "branch" else "-";
        f.writer(alloc).print("{s}\t{s}\n", .{ pkg, m }) catch oom();
    }
    try writeAll(diag, cwd, args[2], c.items);
    try writeAll(diag, cwd, args[3], f.items);
}

fn split(alloc: Alloc, diag: *Diag, cwd: std.fs.Dir, args: []const []const u8) !void {
    if (args.len != 3) return diag.usageFail("split takes 3 arguments, not {d}", .{args.len});
    const target = try parseTarget(diag, args[0]);
    // Every package's file, by path, checked before anything is written.
    var out = std.StringArrayHashMap(std.ArrayList(u8)).init(alloc);
    const census = try lines(alloc, diag, args[1], try readAll(alloc, diag, cwd, args[1]));
    var head: ?[]const u8 = null;
    var rows = std.ArrayList(Row).empty;
    for (census, 1..) |l, n| {
        if (l[0] == '#') continue;
        const f = fields(alloc, l);
        if (head == null) {
            if (f.len != 4 or !std.mem.eql(u8, f[0], "census") or !isDate(f[1]))
                return diag.refuse("{s}:{d}: the first line is census<TAB><date YYYY-MM-DD><TAB><commit or -><TAB><note or ->", .{ args[1], n });
            head = l;
            continue;
        }
        if (f.len < 2 or f[1].len == 0) return diag.refuse("{s}:{d}: a row with no package", .{ args[1], n });
        rows.append(alloc, .{ .key = f[0], .line = l }) catch oom();
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ f[1], census_name }) catch oom();
        const g = out.getOrPut(path) catch oom();
        if (!g.found_existing) {
            g.value_ptr.* = std.ArrayList(u8).empty;
            g.value_ptr.writer(alloc).print("{s}{s}\n", .{ census_comment, head.? }) catch oom();
        }
        g.value_ptr.writer(alloc).print("{s}\n", .{l}) catch oom();
    }
    if (head == null) return diag.refuse("{s}: no census line", .{args[1]});
    var dir = cwd.openDir(args[2], .{}) catch |e| return diag.refuse("{s}: cannot open it: {s}", .{ args[2], @errorName(e) });
    defer dir.close();
    // Each metric reached is added to the package's marker; one already
    // there is kept, with its comments.
    var reach = reached(alloc, rows.items, target);
    var it = reach.iterator();
    while (it.next()) |e| {
        const want = Hold{ .line = e.value_ptr.line == 1, .branch = e.value_ptr.branch == 1 };
        if (!want.line and !want.branch) continue;
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ e.key_ptr.*, held_name }) catch oom();
        var comments: []const u8 = held_comment;
        var have = Hold{};
        if (dir.readFileAlloc(alloc, path, max_file)) |text| {
            have = try parseHold(alloc, diag, path, text);
            var cs = std.ArrayList(u8).empty;
            for (try lines(alloc, diag, path, text)) |l| if (l[0] == '#') cs.writer(alloc).print("{s}\n", .{l}) catch oom();
            comments = cs.items;
        } else |err| if (err != error.FileNotFound) return diag.refuse("{s}: cannot read it: {s}", .{ path, @errorName(err) });
        const line = have.line or want.line;
        const branch = have.branch or want.branch;
        if (line == have.line and branch == have.branch) continue;
        var b = std.ArrayList(u8).empty;
        b.appendSlice(alloc, comments) catch oom();
        if (line) b.appendSlice(alloc, "line\n") catch oom();
        if (branch) b.appendSlice(alloc, "branch\n") catch oom();
        out.put(path, b) catch oom();
    }
    var wit = out.iterator();
    while (wit.next()) |e| try writeAll(diag, dir, e.key_ptr.*, e.value_ptr.items);
}

fn run(alloc: Alloc, diag: *Diag, cwd: std.fs.Dir, args: []const []const u8) Error!void {
    if (args.len == 0) return diag.usageFail("no command", .{});
    if (std.mem.eql(u8, args[0], "assemble")) return assemble(alloc, diag, cwd, args[1..]);
    if (std.mem.eql(u8, args[0], "split")) return split(alloc, diag, cwd, args[1..]);
    return diag.usageFail("unknown command '{s}'", .{args[0]});
}

/// The program: `args` without the program name, files relative to `cwd`.
pub fn entry(alloc: Alloc, cwd: std.fs.Dir, args: []const []const u8, stderr: anytype) u8 {
    var diag = Diag.init(alloc);
    const status: u8 = if (run(alloc, &diag, cwd, args)) 0 else |err| switch (err) {
        error.Refused => 1,
        error.Usage => 2,
    };
    stderr.writeAll(diag.text.items) catch {};
    return status;
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch oom();
    const args = alloc.alloc([]const u8, argv.len -| 1) catch oom();
    for (args, 1..) |*a, i| a.* = argv[i];
    return entry(alloc, std.fs.cwd(), args, std.fs.File.stderr().deprecatedWriter());
}
