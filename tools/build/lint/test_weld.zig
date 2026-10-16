// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// test_weld.sh (awk, sort and grep run by a busybox shell), so that the
// test_weld lint runs no shell.
//! test_weld: the action behind test_weld.bzl / test_weld.bxl.
//!
//! usage: test_weld <result.json> <mojo> <prefix> <root> <known_untested.tsv>
//!            <its name> <welded>
//!
//! <mojo> lists the .mojo files of the tree, one path in the cell per line;
//! <welded> the welded test files, likewise (test_weld.bxl writes both). Reads
//! the packages under <root> and requires two things. Each directory directly
//! under <root> is one package, except <root>/tests, which is not a package but
//! holds them by kind: each directory <root>/tests/<kind>/<name> is one (the
//! test-only packages, docs/architecture.md#end-to-end-tests). A .mojo file
//! directly in <root>/tests or in <root>/tests/<kind> is in no package.
//!
//!   1. Every test file is welded. A test file is a `test_*.mojo` under a
//!      `tests/` directory of the package, at any depth. It is welded when its
//!      path is a line of <welded>: the test files the targets of the build
//!      graph run (a mojo_library's `test_srcs`, a mojo_test's `main`). A test
//!      no target runs never runs.
//!   2. Every package with a `.mojo` source (a `.mojo` file outside `tests/`)
//!      welds at least one test.
//!
//! A test file or a package that may break rule 1 or 2 has a row in
//! <known_untested.tsv>, with the reason. The ledger only shrinks: a row whose
//! test file is welded, or whose package welds a test, is a finding, so the
//! change that welds it deletes the row. A row naming nothing that exists is a
//! finding.
//!
//! Ledger lines are `<path><TAB><reason>`, the path being `<root>/<package>`
//! (`<root>/tests/<kind>/<name>` for a test-only one) or a test file's path;
//! blank lines and lines starting with `#` are comments.
//!
//! Writes <result.json> (status "success") when it finds nothing. A finding
//! fails the program instead, printing the findings on stderr (which is how
//! test_weld.bxl reports them): <result.json> is not written. Checks nothing,
//! so fails, when <root> holds no package. Findings name a file as
//! <prefix><path>.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Class = struct {
    /// The package.
    pkg: []const u8,
    /// A source (`.mojo` outside tests/), else a test file.
    is_src: bool,
    welded: bool,
    path: []const u8,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortedUnique(a: Alloc, lines: []const []const u8) ![][]const u8 {
    const copy = try a.dupe([]const u8, lines);
    std.mem.sort([]const u8, copy, {}, lessThan);
    var out = std.ArrayList([]const u8).empty;
    for (copy) |l| {
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1], l)) try out.append(a, l);
    }
    return out.toOwnedSlice(a);
}

/// The non-empty lines of `text`.
pub fn lineList(a: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) try out.append(a, l);
    }
    return out.toOwnedSlice(a);
}

/// Each `.mojo` file under `root` classified: a source of its package, or a
/// test file (`test_*.mojo` under a `tests/` directory of it) welded or not.
pub fn classify(a: Alloc, root: []const u8, mojo: []const []const u8, welded: []const []const u8) ![]Class {
    var w = std.StringHashMap(void).init(a);
    for (welded) |n| try w.put(n, {});
    var out = std.ArrayList(Class).empty;
    for (mojo) |p| {
        // rest = substr($0, length(root) + 2)
        if (p.len < root.len + 1) continue;
        const rest = p[root.len + 1 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        var pkg = rest[0..slash];
        if (std.mem.eql(u8, pkg, "tests")) {
            // <root>/tests holds packages by kind: the package is tests/<kind>/<name>.
            var parts: usize = 1;
            var third_end: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfScalarPos(u8, rest, pos, '/')) |i| {
                parts += 1;
                if (parts == 4) third_end = i;
                pos = i + 1;
            }
            if (parts < 4) continue;
            pkg = rest[0..third_end];
        }
        const inpkg = rest[pkg.len + 1 ..];
        const in_tests = std.mem.startsWith(u8, inpkg, "tests/") or std.mem.indexOf(u8, inpkg, "/tests/") != null;
        const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
        if (!in_tests) {
            try out.append(a, .{ .pkg = pkg, .is_src = true, .welded = false, .path = p });
        } else if (std.mem.startsWith(u8, base, "test_") and std.mem.endsWith(u8, base, ".mojo")) {
            try out.append(a, .{ .pkg = pkg, .is_src = false, .welded = w.contains(p), .path = p });
        }
    }
    return out.toOwnedSlice(a);
}

pub const Package = struct { name: []const u8, src: usize, welded: usize };

/// The packages the classified files name, sorted by name.
pub fn packages(a: Alloc, classes: []const Class) ![]Package {
    var map = std.StringHashMap(Package).init(a);
    for (classes) |c| {
        const e = try map.getOrPut(c.pkg);
        if (!e.found_existing) e.value_ptr.* = .{ .name = c.pkg, .src = 0, .welded = 0 };
        if (c.is_src) e.value_ptr.src += 1 else if (c.welded) e.value_ptr.welded += 1;
    }
    var out = std.ArrayList(Package).empty;
    var it = map.valueIterator();
    while (it.next()) |p| try out.append(a, p.*);
    std.mem.sort(Package, out.items, {}, struct {
        fn lt(_: void, x: Package, y: Package) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

pub const Row = struct { path: []const u8, line: usize };

/// The ledger's rows; a malformed row, or a path with a row already, is a
/// finding appended to `report`.
pub fn parseLedger(a: Alloc, name: []const u8, text: []const u8, report: *std.ArrayList(u8)) ![]Row {
    var rows = std.ArrayList(Row).empty;
    var first = std.StringHashMap(usize).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var nr: usize = 0;
    while (lines.next()) |line| {
        nr += 1;
        if (lines.peek() == null and line.len == 0) break;
        const t = std.mem.trimLeft(u8, line, " \t\r\x0b\x0c");
        if (t.len == 0 or t[0] == '#') continue;
        var f = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |x| try f.append(a, x);
        const blank_reason = f.items.len == 2 and std.mem.trim(u8, f.items[1], " \t\r\x0b\x0c\n").len == 0;
        if (f.items.len != 2 or f.items[0].len == 0 or blank_reason) {
            try report.writer(a).print("{s}:{d}: a row is <path><TAB><reason>, with a reason\n", .{ name, nr });
            continue;
        }
        if (first.get(f.items[0])) |prev| {
            try report.writer(a).print("{s}:{d}: {s} has a row already, on line {d}\n", .{ name, nr, f.items[0], prev });
            continue;
        }
        try first.put(f.items[0], nr);
        try rows.append(a, .{ .path = f.items[0], .line = nr });
    }
    return rows.toOwnedSlice(a);
}

/// The findings of the two rules against the ledger, sorted.
pub fn findings(a: Alloc, root: []const u8, prefix: []const u8, ledger_name: []const u8, classes: []const Class, pkgs: []const Package, rows: []const Row) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var state = std.StringHashMap(bool).init(a); // test path -> welded
    for (classes) |c| {
        if (!c.is_src) try state.put(c.path, c.welded);
    }
    var in_ledger = std.StringHashMap(void).init(a);
    for (rows) |r| try in_ledger.put(r.path, {});
    var by_name = std.StringHashMap(Package).init(a);
    for (pkgs) |p| try by_name.put(p.name, p);
    const root_slash = try std.fmt.allocPrint(a, "{s}/", .{root});
    for (rows) |r| {
        const at = try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ ledger_name, r.line, r.path });
        if (!std.mem.startsWith(u8, r.path, root_slash)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}: not under {s}/", .{ at, root }));
        } else if (state.get(r.path)) |welded| {
            if (welded) try out.append(a, try std.fmt.allocPrint(a, "{s}: the test is welded now; delete the row (the ledger only shrinks)", .{at}));
        } else {
            const p = r.path[root.len + 1 ..];
            const pk = by_name.get(p);
            if (pk == null or pk.?.src == 0) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: names neither a test file nor a package with a .mojo source; delete the row", .{at}));
            } else if (pk.?.welded > 0) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: the package welds {d} test(s) now; delete the row (the ledger only shrinks)", .{ at, pk.?.welded }));
            }
        }
    }
    var st = state.iterator();
    while (st.next()) |e| {
        if (!e.value_ptr.* and !in_ledger.contains(e.key_ptr.*))
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s}: a test file no target welds (test_srcs or a mojo_test), so it never runs; weld it, delete it, or give it a row in {s}", .{ prefix, e.key_ptr.*, ledger_name }));
    }
    for (pkgs) |p| {
        const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, p.name });
        if (p.src > 0 and p.welded == 0 and !in_ledger.contains(key))
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s}: {d} .mojo source(s) and no welded test; weld one in test_srcs, or give the package a row in {s}", .{ prefix, key, p.src, ledger_name }));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(a);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("test_weld: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn read(a: Alloc, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 26) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 8) die("usage: test_weld <result.json> <mojo> <prefix> <root> <known_untested.tsv> <its name> <welded>", .{});
    const result = argv[1];
    const prefix = argv[3];
    const root = argv[4];
    const ledger_name = argv[6];

    // The .mojo files under <root>, from the list.
    const root_slash = try std.fmt.allocPrint(a, "{s}/", .{root});
    var mojo_all = std.ArrayList([]const u8).empty;
    for (try lineList(a, read(a, argv[2]))) |l| {
        if (std.mem.startsWith(u8, l, root_slash) and std.mem.endsWith(u8, l, ".mojo")) try mojo_all.append(a, l);
    }
    const mojo = try sortedUnique(a, mojo_all.items);
    const welded = try sortedUnique(a, try lineList(a, read(a, argv[7])));
    const classes = try classify(a, root, mojo, welded);
    const pkgs = try packages(a, classes);

    var report = std.ArrayList(u8).empty;
    const rows = try parseLedger(a, ledger_name, read(a, argv[5]), &report);
    for (try findings(a, root, prefix, ledger_name, classes, pkgs, rows)) |f| {
        try report.appendSlice(a, f);
        try report.append(a, '\n');
    }
    if (pkgs.len == 0) try report.writer(a).print("test_weld: checked nothing (no package under {s})\n", .{root});
    if (report.items.len > 0) {
        const n = std.mem.count(u8, report.items, "\n");
        std.debug.print("test_weld: {d} finding line(s)\n", .{n});
        var lines = std.mem.splitScalar(u8, report.items, '\n');
        var shown: usize = 0;
        while (lines.next()) |l| {
            if (lines.peek() == null and l.len == 0) break;
            if (shown == 200) break;
            std.debug.print("{s}\n", .{l});
            shown += 1;
        }
        std.process.exit(1);
    }
    const f = std.fs.cwd().createFile(result, .{}) catch |e| die("cannot create {s}: {s}", .{ result, @errorName(e) });
    defer f.close();
    try f.deprecatedWriter().print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"test_weld: {d} packages checked\"}}}}\n", .{pkgs.len});
}
