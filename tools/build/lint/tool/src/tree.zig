//! The lint kinds over the repository's tree and package list: retired_names
//! and src_layout.

const std = @import("std");
const lint = @import("lint.zig");
const Ctx = lint.Ctx;

/// Whether `s` holds a YYYY-MM-DD date (`[0-9]{4}-[0-9]{2}-[0-9]{2}`).
fn holdsDate(s: []const u8) bool {
    const shape = "dddd-dd-dd";
    if (s.len < shape.len) return false;
    var i: usize = 0;
    while (i + shape.len <= s.len) : (i += 1) {
        const ok = for (shape, 0..) |k, j| {
            const b = s[i + j];
            if (k == 'd' and !std.ascii.isDigit(b)) break false;
            if (k == '-' and b != '-') break false;
        } else true;
        if (ok) return true;
    }
    return false;
}

fn holdsName(line: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.indexOf(u8, line, n) != null) return true;
    return false;
}

/// The lines of `text` that hold a name and no date, as findings `<at>:<n>:<line>`.
fn retiredIn(c: *Ctx, at: []const u8, text: []const u8, names: []const []const u8) !void {
    var lines = lint.Lines.init(text);
    while (lines.next()) |line| {
        if (!holdsName(line, names)) continue;
        // The date is read from the whole finding, its path included.
        const f = try std.fmt.allocPrint(c.alloc, "{s}:{d}:{s}", .{ at, lines.n, line });
        if (holdsDate(f)) continue;
        try c.finding("{s} -- a retired name; only a dated history note may keep it", .{f});
    }
}

/// kind retired_names, args <tree> <prefix of tree> <name>... -- <file>...:
/// no file under <tree> (the cell's doc_tree, findings named <prefix of
/// tree><path>) and no <file> holds a <name> (a fixed string) on a line that
/// carries no YYYY-MM-DD date: a retired name survives only in a dated
/// history note. Checks nothing, so fails, when the tree holds no file.
pub fn retiredNames(c: *Ctx, args: []const []const u8) !void {
    if (args.len < 2) return error.Usage;
    const tree = args[0];
    const tprefix = args[1];
    var i: usize = 2;
    while (i < args.len and !std.mem.eql(u8, args[i], "--")) i += 1;
    const names = args[2..i];
    const files = if (i < args.len) args[i + 1 ..] else args[args.len..];

    const paths = try lint.listFiles(c.alloc, tree);
    c.checked = paths.len + files.len;
    for (paths) |p| {
        const full = try std.fs.path.join(c.alloc, &.{ tree, p });
        const text = try lint.readFile(c.alloc, full);
        try retiredIn(c, try std.mem.concat(c.alloc, u8, &.{ tprefix, p }), text, names);
    }
    for (files) |f| try retiredIn(c, f, try lint.readFile(c.alloc, f), names);
}

/// Where a package of this name belongs under <root>/tests.
fn kindOf(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, "_e2e") or std.mem.endsWith(u8, name, "_loopback")) return "e2e";
    if (std.mem.endsWith(u8, name, "_conformance")) return "conformance";
    return "helpers";
}

fn describe(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "e2e")) return "named *_e2e or *_loopback";
    if (std.mem.eql(u8, kind, "conformance")) return "named *_conformance";
    return "a harness, not named *_e2e, *_loopback or *_conformance";
}

/// The `/`-separated parts of `s` (none for an empty string, as awk splits).
fn parts(c: *Ctx, s: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (s.len == 0) return out.toOwnedSlice(c.alloc);
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |p| try out.append(c.alloc, p);
    return out.toOwnedSlice(c.alloc);
}

/// A module map row, `| [`<name>`](<link>) |`: its name and its link.
const Row = struct { name: []const u8, link: []const u8 };

fn mapRow(line: []const u8) ?Row {
    const head = "| [`";
    if (!std.mem.startsWith(u8, line, head)) return null;
    const ne = std.mem.indexOfScalarPos(u8, line, head.len, '`') orelse return null;
    if (ne == head.len or !std.mem.startsWith(u8, line[ne..], "`](")) return null;
    const le = std.mem.indexOfScalarPos(u8, line, ne + 3, ')') orelse return null;
    if (!std.mem.startsWith(u8, line[le..], ") |")) return null;
    // The link is what follows the line's first `(`, up to the next `)`.
    const open = std.mem.indexOfScalar(u8, line, '(').?;
    const close = std.mem.indexOfScalarPos(u8, line, open + 1, ')').?;
    return .{ .name = line[head.len..ne], .link = line[open + 1 .. close] };
}

/// kind src_layout, args <root> <shipped> <cell prefix> <map> <package>...:
/// <root> (src) holds what komira ships: each <package> (a package path in
/// the cell, as Buck2 lists the root package's subpackages) is <root>/<name>,
/// or a test-only package <root>/tests/<kind>/<name> with <kind> e2e (a
/// <name> ending _e2e or _loopback), conformance (ending _conformance) or
/// helpers (neither). So a *_e2e, *_loopback or *_conformance package
/// anywhere else under <root> is a finding, and so is a komira_test_* package
/// directly under <root> that <shipped> (`-` or a comma-separated list of
/// names) does not name: a test harness komira does not ship is under
/// <root>/tests/helpers. A <shipped> name that is no package directly under
/// <root> is a finding too. Findings name a package <cell prefix><package>.
/// Checks nothing, so fails, when no <package> is under <root>. <map> is `-`
/// or the module map, a Markdown file: a row is a line starting
/// "| [`<name>`](<link>) |", and a row whose <link>, less its leading `../`s
/// and trailing `/`, is a path under <root> names that path. Each <package>
/// under <root> has exactly one row; no row names a path that is not a
/// <package>; a row's <name> is its path's last component.
pub fn srcLayout(c: *Ctx, args: []const []const u8) !void {
    if (args.len < 4) return error.Usage;
    const root = args[0];
    const shipped = args[1];
    const pre = args[2];
    const map = args[3];
    const packages = args[4..];
    const under = try std.mem.concat(c.alloc, u8, &.{ root, "/" });

    var ship = std.StringArrayHashMap(void).init(c.alloc);
    var it = std.mem.splitScalar(u8, shipped, ',');
    while (it.next()) |s| if (!std.mem.eql(u8, s, "-")) try ship.put(s, {});
    var top = std.StringHashMap(void).init(c.alloc);
    var pkg = std.StringHashMap(void).init(c.alloc);

    for (packages) |p| {
        if (!std.mem.startsWith(u8, p, under)) continue;
        try pkg.put(p, {});
        c.checked += 1;
        const at = try std.mem.concat(c.alloc, u8, &.{ pre, p });
        const ps = try parts(c, p[under.len..]);
        if (ps.len > 0 and std.mem.eql(u8, ps[0], "tests")) {
            const k = if (ps.len > 1) ps[1] else "";
            if (ps.len != 3 or !(std.mem.eql(u8, k, "e2e") or std.mem.eql(u8, k, "conformance") or std.mem.eql(u8, k, "helpers"))) {
                try c.finding("{s}: {s}/tests holds packages only at {s}/tests/<kind>/<name>, <kind> e2e, conformance or helpers", .{ at, root, root });
            } else if (!std.mem.eql(u8, kindOf(ps[2]), k)) {
                try c.finding("{s}: a package under {s}/tests/{s} is {s}; this one belongs in {s}/tests/{s}/{s}", .{ at, root, k, describe(k), root, kindOf(ps[2]), ps[2] });
            }
            continue;
        }
        if (ps.len != 1) {
            try c.finding("{s}: a package is {s}/<name> (what komira ships) or {s}/tests/<kind>/<name> (test-only)", .{ at, root, root });
            continue;
        }
        try top.put(ps[0], {});
        if (!std.mem.eql(u8, kindOf(ps[0]), "helpers")) {
            try c.finding("{s}: a test-only package directly under {s}/, which holds what komira ships; move it to {s}/tests/{s}/{s}", .{ at, root, root, kindOf(ps[0]), ps[0] });
        } else if (std.mem.startsWith(u8, ps[0], "komira_test_") and !ship.contains(ps[0])) {
            try c.finding("{s}: a test library directly under {s}/ that `shipped` does not name; a harness komira does not ship is {s}/tests/helpers/{s}", .{ at, root, root, ps[0] });
        }
    }
    for (ship.keys()) |s| {
        if (!top.contains(s)) try c.finding("shipped names {s}, which is no package directly under {s}/; delete it", .{ s, root });
    }
    if (std.mem.eql(u8, map, "-")) return;

    // The module map: one row per package, and no row for a path that is none.
    var found = std.ArrayList(u8).empty;
    const w = found.writer(c.alloc);
    var row = std.StringHashMap(usize).init(c.alloc);
    var lines = lint.Lines.init(try lint.readFile(c.alloc, map));
    while (lines.next()) |line| {
        const r = mapRow(line) orelse continue;
        var path = r.link;
        while (std.mem.startsWith(u8, path, "../")) path = path[3..];
        if (std.mem.endsWith(u8, path, "/")) path = path[0 .. path.len - 1];
        if (!std.mem.startsWith(u8, path, under)) continue;
        if (row.get(path)) |first| {
            try w.print("{s}:{d}: a second row for {s} (the first is line {d}); a package has one row\n", .{ map, lines.n, path, first });
            continue;
        }
        try row.put(path, lines.n);
        const last = std.fs.path.basenamePosix(path);
        if (!std.mem.eql(u8, last, r.name))
            try w.print("{s}:{d}: the row names {s} but links {s}; name it {s}\n", .{ map, lines.n, r.name, path, last });
        if (!pkg.contains(path))
            try w.print("{s}:{d}: a row for {s}, which is no package; delete the row or fix its link\n", .{ map, lines.n, path });
    }
    var pi = pkg.keyIterator();
    while (pi.next()) |k| {
        if (!row.contains(k.*)) try w.print("{s}{s}: no row in {s}; add one to the section it belongs in\n", .{ pre, k.*, map });
    }
    try c.report.appendSlice(c.alloc, try lint.sortLines(c.alloc, found.items));
}
