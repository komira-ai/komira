//! census_files: the per-package coverage files, put together and taken
//! apart (census.md).
//!
//! usage: census_files assemble <dir> <census out> <ratchet out>
//!        census_files split <census.tsv> <ratchet.tsv> <out dir>
//!
//! Each package keeps its own coverage data, so a change to one package's
//! coverage touches that package's directory and nothing else:
//!
//!   <package>/coverage_floor.tsv   its floor: `#` comment lines and exactly
//!                                  one ratchet row (`<package> <line floor>
//!                                  <branch floor>`, tab-separated, or with a
//!                                  fourth field, a pinned row's reason), in
//!                                  the grammar covcheck reads (README.md,
//!                                  "The ratchet"); the row names the
//!                                  file's own directory
//!   <package>/coverage_census.tsv  what the census measured of its
//!                                  libraries: `#` comment lines, the line
//!                                  `census <date> <commit> <note>`, then
//!                                  one row per library (census.sh says the
//!                                  12 fields), each naming the file's own
//!                                  directory as its package (field 2)
//!
//! assemble reads every such file under <dir> (the files staged at their
//! paths in the repository: //:coverage_census, census.bzl) and writes the
//! two files census.sh render and check read: <census out>, one comment
//! line, one census line and every row sorted by label in byte order, and
//! <ratchet out>, one comment line and every floor row sorted by package
//! in byte order. The census line's date is the latest of the packages',
//! its commit theirs when they all name one (else `-`), and its note theirs
//! when every package has the same date and note, `packages measured from
//! <first> to <last>` when the dates differ, else `-`. Refused, naming
//! `<path>:<line>`: a file of another name, a file at the top of <dir>, a
//! carriage return, an empty line, a floor file without exactly one row, a
//! floor row that is not 3 or 4 fields, a floor that is not 0 to 10000
//! (the branch floor may be `-`), a pinned row with an empty reason, a row
//! naming another package, a census file without its census line first or
//! without a library row, a malformed census line, and a tree with no
//! census file. A label twice is left to render, which refuses rows out of
//! order (census.sh).
//!
//! split is the other way: from a census.tsv and a ratchet.tsv (census.sh
//! collect and render write them) it writes each package's two files under
//! <out dir>, the census line repeated in each census file. A package's
//! file it does not write is not touched (census.md says how to refresh).
//!
//! Exit status: 0 done; 1 refused (nothing is written by assemble; split
//! checks everything before it writes); 2 bad usage.
//!
//! A static executable. `main` only builds the command line and calls
//! `entry`, which returns the exit status; census_files_test.zig calls
//! `entry` as main does.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const floor_name = "coverage_floor.tsv";
pub const census_name = "coverage_census.tsv";

pub const floor_comment = "# This package's coverage floor (tools/build/coverage/README.md, \"The ratchet\"): its directory, the line and branch floors in basis points, and a pinned row's reason.\n";
pub const census_comment = "# What the coverage census measured of this package's libraries (tools/build/coverage/census.md).\n";
pub const assembled_ratchet_comment = "# The floors of every package: each package's coverage_floor.tsv, assembled by census_files (census.bzl).\n";
pub const assembled_census_comment = "# The coverage census: each package's coverage_census.tsv, assembled by census_files (census.bzl).\n";

const usage =
    \\usage: census_files assemble <dir> <census out> <ratchet out>
    \\       census_files split <census.tsv> <ratchet.tsv> <out dir>
    \\
;

const max_file = 1 << 26;

pub const Error = error{ Refused, Usage };

/// What the tool writes to stderr, collected, so the tests read the very
/// messages a run prints.
pub const Diag = struct {
    text: std.ArrayList(u8),

    pub fn init(alloc: Alloc) Diag {
        return .{ .text = std.ArrayList(u8).init(alloc) };
    }

    fn refuse(self: *Diag, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.text.writer().print("census_files: " ++ fmt ++ "\n", args) catch oom();
        return error.Refused;
    }

    fn usageFail(self: *Diag, comptime fmt: []const u8, args: anytype) error{Usage} {
        self.text.writer().print("census_files: " ++ fmt ++ "\n" ++ usage, args) catch oom();
        return error.Usage;
    }
};

fn oom() noreturn {
    std.debug.print("census_files: out of memory\n", .{});
    std.process.exit(1);
}

/// A row and what it is sorted by.
const Row = struct {
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
    var out = std.ArrayList([]const u8).init(alloc);
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
        out.append(l) catch oom();
    }
    return out.items;
}

fn fields(alloc: Alloc, line: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| out.append(f) catch oom();
    return out.items;
}

fn isFloor(v: []const u8) bool {
    if (v.len == 0 or v.len > 5) return false;
    if (v.len > 1 and v[0] == '0') return false;
    for (v) |c| if (c < '0' or c > '9') return false;
    const n = std.fmt.parseInt(u32, v, 10) catch return false;
    return n <= 10000;
}

fn isDate(v: []const u8) bool {
    if (v.len != 10 or v[4] != '-' or v[7] != '-') return false;
    for (v, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The floor row of a package's coverage_floor.tsv, checked.
pub fn floorRow(alloc: Alloc, diag: *Diag, path: []const u8, package: []const u8, text: []const u8) ![]const u8 {
    const ls = try lines(alloc, diag, path, text);
    var row: ?[]const u8 = null;
    for (ls, 1..) |l, n| {
        if (l[0] == '#') continue;
        if (row != null) return diag.refuse("{s}:{d}: a second row (a package's floor file holds exactly one)", .{ path, n });
        const f = fields(alloc, l);
        if (f.len != 3 and f.len != 4)
            return diag.refuse("{s}:{d}: a row has 3 tab-separated fields (package, line floor, branch floor), or 4 (a pinned row's reason), not {d}", .{ path, n, f.len });
        if (!std.mem.eql(u8, f[0], package))
            return diag.refuse("{s}:{d}: the row names package {s}, not its directory {s}", .{ path, n, f[0], package });
        if (!isFloor(f[1])) return diag.refuse("{s}:{d}: line floor '{s}' is not a number of basis points from 0 to 10000", .{ path, n, f[1] });
        if (!std.mem.eql(u8, f[2], "-") and !isFloor(f[2]))
            return diag.refuse("{s}:{d}: branch floor '{s}' is not '-' or a number of basis points from 0 to 10000", .{ path, n, f[2] });
        if (f.len == 4 and f[3].len == 0) return diag.refuse("{s}:{d}: a pinned row has an empty reason", .{ path, n });
        row = l;
    }
    return row orelse diag.refuse("{s}: no row (a package's floor file holds exactly one)", .{path});
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
        rows.append(.{ .key = f[0], .line = l }) catch oom();
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
    dir.writeFile(path, bytes) catch |e| return diag.refuse("{s}: cannot write it: {s}", .{ path, @errorName(e) });
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
    if (args.len != 3) return diag.usageFail("assemble takes 3 arguments, not {d}", .{args.len});
    var root = cwd.openDir(args[0], .{ .iterate = true }) catch |e| return diag.refuse("{s}: cannot open it: {s}", .{ args[0], @errorName(e) });
    defer root.close();
    var paths = std.ArrayList([]const u8).init(alloc);
    var walk = root.walk(alloc) catch oom();
    while (walk.next() catch |e| return diag.refuse("{s}: cannot list it: {s}", .{ args[0], @errorName(e) })) |e| {
        if (e.kind == .directory) continue;
        paths.append(alloc.dupe(u8, e.path) catch oom()) catch oom();
    }
    std.mem.sort([]const u8, paths.items, {}, strLess);
    var floors = std.ArrayList(Row).init(alloc);
    var rows = std.ArrayList(Row).init(alloc);
    var heads = std.ArrayList(Head).init(alloc);
    for (paths.items) |p| {
        const base = std.fs.path.basename(p);
        const package = std.fs.path.dirname(p) orelse
            return diag.refuse("{s}: at the top of {s}; a package's coverage files are in its directory", .{ p, args[0] });
        const text = try readAll(alloc, diag, root, p);
        if (std.mem.eql(u8, base, floor_name)) {
            floors.append(.{ .key = package, .line = try floorRow(alloc, diag, p, package, text) }) catch oom();
        } else if (std.mem.eql(u8, base, census_name)) {
            heads.append(try censusRows(alloc, diag, p, package, text, &rows)) catch oom();
        } else return diag.refuse("{s}: not a {s} or a {s}", .{ p, floor_name, census_name });
    }
    if (heads.items.len == 0) return diag.refuse("{s}: no {s} under it", .{ args[0], census_name });
    std.mem.sort(Row, floors.items, {}, rowLess);
    std.mem.sort(Row, rows.items, {}, rowLess);
    var c = std.ArrayList(u8).init(alloc);
    c.appendSlice(assembled_census_comment) catch oom();
    c.appendSlice(combine(alloc, heads.items)) catch oom();
    for (rows.items) |r| c.writer().print("{s}\n", .{r.line}) catch oom();
    var f = std.ArrayList(u8).init(alloc);
    f.appendSlice(assembled_ratchet_comment) catch oom();
    for (floors.items) |r| f.writer().print("{s}\n", .{r.line}) catch oom();
    try writeAll(diag, cwd, args[1], c.items);
    try writeAll(diag, cwd, args[2], f.items);
}

fn split(alloc: Alloc, diag: *Diag, cwd: std.fs.Dir, args: []const []const u8) !void {
    if (args.len != 3) return diag.usageFail("split takes 3 arguments, not {d}", .{args.len});
    // Every package's file, by path, checked before anything is written.
    var out = std.StringArrayHashMap(std.ArrayList(u8)).init(alloc);
    const census = try lines(alloc, diag, args[0], try readAll(alloc, diag, cwd, args[0]));
    var head: ?[]const u8 = null;
    for (census, 1..) |l, n| {
        if (l[0] == '#') continue;
        const f = fields(alloc, l);
        if (head == null) {
            if (f.len != 4 or !std.mem.eql(u8, f[0], "census") or !isDate(f[1]))
                return diag.refuse("{s}:{d}: the first line is census<TAB><date YYYY-MM-DD><TAB><commit or -><TAB><note or ->", .{ args[0], n });
            head = l;
            continue;
        }
        if (f.len < 2 or f[1].len == 0) return diag.refuse("{s}:{d}: a row with no package", .{ args[0], n });
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ f[1], census_name }) catch oom();
        const g = out.getOrPut(path) catch oom();
        if (!g.found_existing) {
            g.value_ptr.* = std.ArrayList(u8).init(alloc);
            g.value_ptr.writer().print("{s}{s}\n", .{ census_comment, head.? }) catch oom();
        }
        g.value_ptr.writer().print("{s}\n", .{l}) catch oom();
    }
    if (head == null) return diag.refuse("{s}: no census line", .{args[0]});
    const ratchet = try lines(alloc, diag, args[1], try readAll(alloc, diag, cwd, args[1]));
    for (ratchet) |l| {
        if (l[0] == '#') continue;
        const f = fields(alloc, l);
        const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ f[0], floor_name }) catch oom();
        const text = std.fmt.allocPrint(alloc, "{s}{s}\n", .{ floor_comment, l }) catch oom();
        _ = try floorRow(alloc, diag, path, f[0], text);
        const g = out.getOrPut(path) catch oom();
        if (g.found_existing) return diag.refuse("{s}: package {s} has a second row", .{ args[1], f[0] });
        g.value_ptr.* = std.ArrayList(u8).init(alloc);
        g.value_ptr.appendSlice(text) catch oom();
    }
    var dir = cwd.openDir(args[2], .{}) catch |e| return diag.refuse("{s}: cannot open it: {s}", .{ args[2], @errorName(e) });
    defer dir.close();
    var it = out.iterator();
    while (it.next()) |e| try writeAll(diag, dir, e.key_ptr.*, e.value_ptr.items);
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
    return entry(alloc, std.fs.cwd(), args, std.io.getStdErr().writer());
}
