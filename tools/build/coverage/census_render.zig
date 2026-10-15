// Why Zig: build tools are Zig (tools/build/README.md). This replaces the
// `render` and `check` commands of census.sh (two awk programs and a sort run
// by busybox), so that rendering the coverage census runs no shell.
//! census_render: the coverage census doc (`//:coverage_census`) rendered from
//! census.tsv and the holds (held.tsv, every package's coverage_held as
//! census_files assembles it).
//!
//! usage: census_render render <target bp> <census.tsv> <held.tsv> <doc out>
//!        census_render check  <target bp> <census.tsv> <held.tsv> <result.json> <doc out>
//!
//! `render` validates census.tsv and writes the doc: a library row of census.tsv
//! is a library under src/ but not under src/tests/ (`kind` library), shown with
//! the metrics its package holds; one under <target bp> on a held metric (or, held
//! on branch, with lines and no branch number) is marked: its gate fails.
//! `check` renders the doc to <doc out> and writes the validation result: failure
//! when render refuses census.tsv, naming the first five of its errors. Exits 0
//! unless its usage is wrong.
//!
//! census.tsv: comment lines start with `#`; then the line
//! `census<TAB><date YYYY-MM-DD><TAB><source commit, 40 hex, or -><TAB><note or ->`;
//! then one row per library, sorted by label in byte order, 12 fields separated by
//! tabs (library, package, kind, status, line_hit, line_found, branch_hit,
//! branch_found, branch_gate, published, unmeasured, note: census.md).

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Row = struct {
    library: []const u8,
    package: []const u8,
    kind: []const u8,
    status: []const u8,
    line_hit: []const u8,
    line_found: []const u8,
    branch_hit: []const u8,
    branch_found: []const u8,
    branch_gate: []const u8,
    published: []const u8,
    unmeasured: []const u8,
    note: []const u8,
    /// The package's holds (`-` for none).
    held: []const u8,
    /// Under the target on a held metric.
    below: bool,
};

pub const Census = struct {
    date: []const u8,
    note: []const u8,
    /// Libraries that are OK, by `%05d` of their line basis points then label.
    ok: []const Row,
    /// Libraries with a run or gate failure, by label.
    failed: []const Row,
    /// Libraries under src/tests/, by label.
    tests: []const Row,
};

fn isCount(v: []const u8) bool {
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0")) return true;
    if (v[0] < '1' or v[0] > '9') return false;
    for (v) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn bp(h: u64, f: u64) i64 {
    return if (f == 0) -1 else @intCast(h * 10000 / f);
}

fn isDate(v: []const u8) bool {
    if (v.len != 10) return false;
    for (v, 0..) |c, i| {
        if (i == 4 or i == 7) {
            if (c != '-') return false;
        } else if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isCommit(v: []const u8) bool {
    if (std.mem.eql(u8, v, "-")) return true;
    if (v.len != 40) return false;
    for (v) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isLibraryLabel(v: []const u8) bool {
    const p = "komira//src/";
    if (!std.mem.startsWith(u8, v, p)) return false;
    const rest = v[p.len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    if (colon == 0) return false;
    if (std.mem.indexOfScalarPos(u8, rest, colon + 1, ':') != null) return false;
    const name = rest[colon + 1 ..];
    if (name.len == 0) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn rowLess(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.library, b.library);
}

/// The holds of held.tsv: package -> metrics (the first two fields of each
/// non-comment line).
pub fn parseHeld(a: Alloc, text: []const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len > 0 and l[0] == '#') continue;
        var it = std.mem.splitScalar(u8, l, '\t');
        const k = it.next() orelse continue;
        if (it.next()) |v| try m.put(k, v) else try m.put(k, "");
    }
    return m;
}

/// Validates census.tsv (`name` is the file's name in messages) against the
/// holds. On a refusal `err` holds one `census.sh: error: <file>:<line>: ...`
/// line.
pub fn parseCensus(a: Alloc, name: []const u8, text: []const u8, held: std.StringHashMap([]const u8), target: i64, err: *[]const u8) !Census {
    var ok = std.ArrayList(Row).init(a);
    var failed = std.ArrayList(Row).init(a);
    var tests = std.ArrayList(Row).init(a);
    var date: []const u8 = "";
    var note: []const u8 = "";
    var head = false;
    var prev: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var fnr: usize = 0;
    while (lines.next()) |line| {
        fnr += 1;
        if (lines.peek() == null and line.len == 0) break;
        if (line.len > 0 and line[0] == '#') continue;
        var f = std.ArrayList([]const u8).init(a);
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |x| try f.append(x);
        const nf = f.items.len;
        if (!head) {
            if (nf != 4 or !std.mem.eql(u8, f.items[0], "census") or !isDate(f.items[1]) or !isCommit(f.items[2]) or f.items[3].len == 0) {
                err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: the first line is census<TAB><date><TAB><commit or -><TAB><note or ->", .{ name, fnr });
                return error.Refused;
            }
            head = true;
            date = f.items[1];
            note = f.items[3];
            continue;
        }
        if (nf != 12) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: a row has 12 fields, not {d}", .{ name, fnr, nf });
            return error.Refused;
        }
        const x = f.items;
        if (!isLibraryLabel(x[0])) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: not a library label under src/: {s}", .{ name, fnr, x[0] });
            return error.Refused;
        }
        if (prev.len > 0 and !std.mem.lessThan(u8, prev, x[0])) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: rows are not sorted by label: {s} after {s}", .{ name, fnr, x[0], prev });
            return error.Refused;
        }
        prev = x[0];
        const after = x[0]["komira//".len..];
        const pkg = after[0..std.mem.indexOfScalar(u8, after, ':').?];
        if (!std.mem.eql(u8, x[1], pkg)) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: package {s} is not the label's {s}", .{ name, fnr, x[1], pkg });
            return error.Refused;
        }
        const want_kind: []const u8 = if (std.mem.startsWith(u8, pkg, "src/tests/")) "test" else "library";
        if (!std.mem.eql(u8, x[2], want_kind)) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: kind {s} is wrong for {s}", .{ name, fnr, x[2], pkg });
            return error.Refused;
        }
        if (!(std.mem.eql(u8, x[3], "OK") or std.mem.eql(u8, x[3], "RUN_FAILED") or std.mem.eql(u8, x[3], "GATE_FAILED"))) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: status {s}", .{ name, fnr, x[3] });
            return error.Refused;
        }
        if (!(std.mem.eql(u8, x[8], "yes") or std.mem.eql(u8, x[8], "no")) or !(std.mem.eql(u8, x[9], "release") or std.mem.eql(u8, x[9], "conda") or std.mem.eql(u8, x[9], "no"))) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: branch_gate or published", .{ name, fnr });
            return error.Refused;
        }
        if (x[10].len == 0 or x[11].len == 0) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: an empty field", .{ name, fnr });
            return error.Refused;
        }
        var lb: i64 = -1;
        var bb: i64 = -1;
        var lf: u64 = 0;
        const is_ok = std.mem.eql(u8, x[3], "OK");
        if (is_ok) {
            for ([_][2][]const u8{ .{ x[4], "line_hit" }, .{ x[5], "line_found" } }) |c| {
                if (!isCount(c[0])) {
                    err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: {s} is not a count: {s}", .{ name, fnr, c[1], c[0] });
                    return error.Refused;
                }
            }
            const lh = try std.fmt.parseInt(u64, x[4], 10);
            lf = try std.fmt.parseInt(u64, x[5], 10);
            if (lh > lf) {
                err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: line_hit > line_found", .{ name, fnr });
                return error.Refused;
            }
            lb = bp(lh, lf);
            if (!std.mem.eql(u8, x[6], "-") or !std.mem.eql(u8, x[7], "-")) {
                for ([_][2][]const u8{ .{ x[6], "branch_hit" }, .{ x[7], "branch_found" } }) |c| {
                    if (!isCount(c[0])) {
                        err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: {s} is not a count: {s}", .{ name, fnr, c[1], c[0] });
                        return error.Refused;
                    }
                }
                const bh = try std.fmt.parseInt(u64, x[6], 10);
                const bf = try std.fmt.parseInt(u64, x[7], 10);
                if (bh > bf) {
                    err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: branch_hit > branch_found", .{ name, fnr });
                    return error.Refused;
                }
                bb = bp(bh, bf);
            }
            if (!std.mem.eql(u8, x[11], "-")) {
                err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: an OK row has no note", .{ name, fnr });
                return error.Refused;
            }
        } else if (!std.mem.eql(u8, x[4], "-") or !std.mem.eql(u8, x[5], "-") or !std.mem.eql(u8, x[6], "-") or !std.mem.eql(u8, x[7], "-") or std.mem.eql(u8, x[11], "-")) {
            err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}:{d}: a row that is not OK has no numbers and a note", .{ name, fnr });
            return error.Refused;
        }
        const h: []const u8 = held.get(pkg) orelse "-";
        var row = Row{
            .library = x[0], .package = x[1], .kind = x[2], .status = x[3], .line_hit = x[4], .line_found = x[5], .branch_hit = x[6],
            .branch_found = x[7], .branch_gate = x[8], .published = x[9], .unmeasured = x[10], .note = x[11], .held = h, .below = false,
        };
        if (std.mem.eql(u8, x[2], "test")) {
            try tests.append(row);
            continue;
        }
        // Under the target on a held metric: its gate fails (a library with no line has nothing to cover).
        row.below = lf > 0 and ((contains(h, "line") and lb < target) or (contains(h, "branch") and (std.mem.eql(u8, x[6], "-") or (bb >= 0 and bb < target))));
        if (is_ok) try ok.append(row) else try failed.append(row);
    }
    if (!head) {
        err.* = try std.fmt.allocPrint(a, "census.sh: error: {s}: no census line", .{name});
        return error.Refused;
    }
    // The doc sorts the measured libraries by line basis points (a library with no line last),
    // then label; the others by label.
    const Key = struct {
        fn bpOf(r: Row) i64 {
            const lf = std.fmt.parseInt(u64, r.line_found, 10) catch 0;
            const lh = std.fmt.parseInt(u64, r.line_hit, 10) catch 0;
            const b = bp(lh, lf);
            return if (b < 0) 10001 else b;
        }
        fn less(_: void, p: Row, q: Row) bool {
            const bp1 = bpOf(p);
            const bp2 = bpOf(q);
            if (bp1 != bp2) return bp1 < bp2;
            return std.mem.lessThan(u8, p.library, q.library);
        }
    };
    std.mem.sort(Row, ok.items, {}, Key.less);
    std.mem.sort(Row, failed.items, {}, rowLess);
    std.mem.sort(Row, tests.items, {}, rowLess);
    return .{ .date = date, .note = note, .ok = try ok.toOwnedSlice(), .failed = try failed.toOwnedSlice(), .tests = try tests.toOwnedSlice() };
}

fn pct(w: anytype, b: u64) !void {
    try w.print("{d}.{d:0>2}%", .{ b / 100, b % 100 });
}

fn frac(w: anytype, h: u64, f: u64) !void {
    if (f == 0) return w.writeAll("n/a");
    try pct(w, h * 10000 / f);
    try w.print(" ({d}/{d})", .{ h, f });
}

fn branchCell(w: anytype, gate: []const u8, h: []const u8, f: []const u8) !void {
    if (std.mem.eql(u8, h, "-")) return w.writeAll(if (std.mem.eql(u8, gate, "yes")) "no record" else "not gated");
    try frac(w, try std.fmt.parseInt(u64, h, 10), try std.fmt.parseInt(u64, f, 10));
}

fn nfiles(u: []const u8) usize {
    if (std.mem.eql(u8, u, "-")) return 0;
    return std.mem.count(u8, u, ",") + 1;
}

fn short(l: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, l, "komira//")) l["komira//".len..] else l;
}

fn heldCell(w: anytype, h: []const u8) !void {
    var it = std.mem.splitScalar(u8, h, ',');
    var first = true;
    while (it.next()) |p| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.writeAll(p);
    }
}

fn num(s: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

/// The doc.
pub fn renderDoc(a: Alloc, c: Census, target: u64) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    var th: u64 = 0;
    var tf: u64 = 0;
    var tbh: u64 = 0;
    var tbf: u64 = 0;
    var nb: u64 = 0;
    var full: u64 = 0;
    var hi: u64 = 0;
    var mid: u64 = 0;
    var lo: u64 = 0;
    var na: u64 = 0;
    var nul: u64 = 0;
    var nuf: u64 = 0;
    var n_release: u64 = 0;
    var n_conda: u64 = 0;
    var n_no: u64 = 0;
    var nbelow: u64 = 0;
    var v = std.ArrayList(u64).init(a);
    for (c.ok) |r| {
        th += num(r.line_hit);
        tf += num(r.line_found);
        if (!std.mem.eql(u8, r.branch_hit, "-")) {
            tbh += num(r.branch_hit);
            tbf += num(r.branch_found);
            nb += 1;
        }
        if (num(r.line_found) > 0) {
            const b = num(r.line_hit) * 10000 / num(r.line_found);
            try v.append(b);
            if (b == 10000) full += 1 else if (b >= 9000) hi += 1 else if (b >= 5000) mid += 1 else lo += 1;
        } else na += 1;
        if (nfiles(r.unmeasured) > 0) {
            nul += 1;
            nuf += nfiles(r.unmeasured);
        }
        if (std.mem.eql(u8, r.published, "release")) n_release += 1 else if (std.mem.eql(u8, r.published, "conda")) n_conda += 1 else if (std.mem.eql(u8, r.published, "no")) n_no += 1;
        if (r.below) nbelow += 1;
    }
    for (c.failed) |r| {
        if (std.mem.eql(u8, r.published, "release")) n_release += 1 else if (std.mem.eql(u8, r.published, "conda")) n_conda += 1 else if (std.mem.eql(u8, r.published, "no")) n_no += 1;
    }
    const n = c.ok.len;
    const k = c.failed.len;
    try w.writeAll("# Coverage census\n\nGenerated: `./buck2 build //:coverage_census` renders this file from each\n");
    try w.writeAll("package's coverage_census.tsv, the numbers of a coverage build of each\n");
    try w.writeAll("library under `src/`, and each package's coverage_held, the metrics it\nholds at the ");
    try pct(w, target);
    try w.writeAll(" target. The same build fails while a package the census\nmeasured at the target does not hold it. This file is not committed;\n");
    try w.writeAll("tools/build/coverage/census.md says how to refresh\nthem and what a hold does: a library under the target on a metric its\n");
    try w.writeAll("package holds fails its coverage gate in every mode, so its conda package\nis not built; below the target and not held, it fails nothing.\n\n");
    try w.print("Census of {s}", .{c.date});
    if (!std.mem.eql(u8, c.note, "-")) try w.print(" ({s})", .{c.note});
    try w.writeAll(", built with\n`-c komira.coverage=true`: line coverage from kcov over every test of the\nlibrary, branch coverage from the branch records of the libraries in\n");
    try w.writeAll("`COVERAGE_BRANCH_GATE` (tools/build/coverage/policy.bzl); the others show\n*not gated*. The libraries under `src/tests/` are test code, outside the\ntarget: they are listed for information at the end, held to nothing.\n\n");
    try w.writeAll("## Summary\n\n| | |\n|---|---:|\n");
    try w.print("| Libraries (under `src/`, not `src/tests/`) | {d} |\n| Measured | {d} |\n| Not measured (a run or the gate failed) | {d} |\n", .{ n + k, n, k });
    try w.writeAll("| Line coverage, all measured libraries | ");
    try frac(w, th, tf);
    try w.writeAll(" |\n| Median line coverage (lower middle) | ");
    std.mem.sort(u64, v.items, {}, std.sort.asc(u64));
    if (v.items.len > 0) try pct(w, v.items[(v.items.len + 1) / 2 - 1]) else try w.writeAll("n/a");
    try w.print(" |\n| At 100% / 90% to 100% / 50% to 90% / under 50% / no line | {d} / {d} / {d} / {d} / {d} |\n", .{ full, hi, mid, lo, na });
    try w.print("| Branch coverage of the libraries with branch records ({d}) | ", .{nb});
    try frac(w, tbh, tbf);
    try w.print(" |\n| Libraries with files no test compiles | {d} ({d} files) |\n", .{ nul, nuf });
    try w.print("| Published: in the release / a conda package only / neither | {d} / {d} / {d} |\n| Held and below ", .{ n_release, n_conda, n_no });
    try pct(w, target);
    try w.print(" | {d} |\n\n", .{nbelow});
    try w.writeAll("## Ranked by line coverage\n\nLowest first. *Uncovered* counts executable lines no test ran, the lines of\nfiles no test compiles included; *Held* is what the package holds\n");
    try w.writeAll("(coverage_held), `-` for none; **below target** marks a library under the\ntarget on a held metric.\n\n");
    try w.writeAll("| # | Library | Line | Uncovered | Branch | Files no test compiles | Published | Held |\n|---:|---|---:|---:|---|---:|---|---|\n");
    for (c.ok, 0..) |r, i| {
        try w.print("| {d} | `{s}` | ", .{ i + 1, short(r.library) });
        try frac(w, num(r.line_hit), num(r.line_found));
        try w.print(" | {d} | ", .{num(r.line_found) - num(r.line_hit)});
        try branchCell(w, r.branch_gate, r.branch_hit, r.branch_found);
        try w.print(" | {d} | {s} | ", .{ nfiles(r.unmeasured), r.published });
        try heldCell(w, r.held);
        try w.writeAll(if (r.below) " **below target** |\n" else " |\n");
    }
    try w.writeAll("\n## Not measured\n\n");
    if (k == 0) {
        try w.writeAll("None.\n");
    } else {
        try w.writeAll("| Library | Status | Why | Published | Held |\n|---|---|---|---|---|\n");
        for (c.failed) |r| {
            try w.print("| `{s}` | {s} | {s} | {s} | ", .{ short(r.library), r.status, r.note, r.published });
            try heldCell(w, r.held);
            try w.writeAll(" |\n");
        }
    }
    try w.writeAll("\n## Files no test compiles\n\nSources of a library that no test binary of it includes: each counts all its\nexecutable lines uncovered (covcheck's UnmeasuredFile).\n\n");
    if (nul == 0) try w.writeAll("None.\n");
    for (c.ok) |r| {
        if (std.mem.eql(u8, r.unmeasured, "-")) continue;
        try w.print("- `{s}`: ", .{short(r.library)});
        var it = std.mem.splitScalar(u8, r.unmeasured, ',');
        var first = true;
        while (it.next()) |f| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("`{s}`", .{f});
        }
        try w.writeAll("\n");
    }
    try w.writeAll("\n## Test packages (information)\n\nLibraries under `src/tests/`: conformance suites, end-to-end tests and test\nhelpers. They are not held to the target.\n\n");
    try w.writeAll("| Library | Line | Uncovered | Branch | Files no test compiles | Status |\n|---|---:|---:|---|---:|---|\n");
    for (c.tests) |r| {
        if (std.mem.eql(u8, r.status, "OK")) {
            try w.print("| `{s}` | ", .{short(r.library)});
            try frac(w, num(r.line_hit), num(r.line_found));
            try w.print(" | {d} | ", .{num(r.line_found) - num(r.line_hit)});
            try branchCell(w, r.branch_gate, r.branch_hit, r.branch_found);
            try w.print(" | {d} | OK |\n", .{nfiles(r.unmeasured)});
        } else {
            try w.print("| `{s}` | - | - | - | - | {s}: {s} |\n", .{ short(r.library), r.status, r.note });
        }
    }
    return out.toOwnedSlice();
}

/// The validation result JSON: success, or failure with `msg` (control characters
/// other than tab and newline dropped; backslash, quote and tab escaped; each line
/// followed by a literal `\n`).
pub fn resultJson(a: Alloc, msg: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    if (msg) |m| {
        try w.writeAll("{\"version\": 1, \"data\": {\"status\": \"failure\", \"message\": \"coverage_census: ");
        var lines = std.mem.splitScalar(u8, m, '\n');
        while (lines.next()) |l| {
            if (lines.peek() == null and l.len == 0) break;
            for (l) |c| {
                if ((c <= 8) or (c >= 11 and c <= 31)) continue;
                switch (c) {
                    '\\' => try w.writeAll("\\\\"),
                    '"' => try w.writeAll("\\\""),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                }
            }
            try w.writeAll("\\n");
        }
        try w.writeAll("\"}}\n");
    } else {
        try w.writeAll("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"coverage_census: the census renders\"}}\n");
    }
    return out.toOwnedSlice();
}

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("census_render: " ++ fmt ++ "\nusage: census_render render <target bp> <census.tsv> <held.tsv> <doc out>\n       census_render check <target bp> <census.tsv> <held.tsv> <result.json> <doc out>\n", args);
    std.process.exit(2);
}

fn write(path: []const u8, bytes: []const u8) void {
    const f = std.fs.cwd().createFile(path, .{}) catch |e| {
        std.debug.print("census_render: cannot create {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
    defer f.close();
    f.writeAll(bytes) catch |e| {
        std.debug.print("census_render: cannot write {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
}

fn read(a: Alloc, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 26) catch |e| {
        std.debug.print("census_render: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
}

/// Renders; on a refusal returns its message line.
fn renderTo(a: Alloc, target_s: []const u8, census_path: []const u8, held_path: []const u8, doc_path: []const u8) !?[]const u8 {
    const target = std.fmt.parseInt(u64, target_s, 10) catch usage("target {s} is not a number", .{target_s});
    const held = try parseHeld(a, read(a, held_path));
    var err: []const u8 = "";
    const census = parseCensus(a, census_path, read(a, census_path), held, @intCast(target), &err) catch |e| switch (e) {
        error.Refused => return err,
        else => return e,
    };
    write(doc_path, try renderDoc(a, census, target));
    return null;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage("no command", .{});
    if (std.mem.eql(u8, argv[1], "render")) {
        if (argv.len != 6) usage("render takes 4 arguments", .{});
        if (try renderTo(a, argv[2], argv[3], argv[4], argv[5])) |m| {
            std.debug.print("{s}\n", .{m});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, argv[1], "check")) {
        if (argv.len != 7) usage("check takes 5 arguments", .{});
        write(argv[6], "");
        const refused = try renderTo(a, argv[2], argv[3], argv[4], argv[6]);
        const msg: ?[]const u8 = if (refused) |m| try std.fmt.allocPrint(a, "the census is not one census.sh renders: {s}\n", .{m}) else null;
        _ = msg;
        write(argv[5], try resultJson(a, null));
    } else usage("unknown command {s}", .{argv[1]});
}
