//! readme_coverage: the checker of the graph check of that name (checks.bxl).
//!
//! The ledger, release/README_COVERAGE.md, lists every `src/<name>/README.md`
//! of the repository and who runs its examples. This checker writes the
//! ledger's text from the facts and refuses a committed ledger that is not
//! that text byte for byte: each line that differs is a finding, with the
//! line it must be. So the list cannot go stale.
//!
//! The facts (checks.bxl) are tab-separated lines:
//!
//!   file <path>                        a file of the root doc_tree: a
//!                                      `src/.../README.md` or `src/.../mopm.toml`
//!   gate <label> <rule kind> <readme>  a mojo_adopted_library (`_adopted`)
//!                                      or mojo_library (`mojo_library_rule`)
//!                                      target, and `README.md` when its
//!                                      `readme` is its own package's
//!                                      README.md (buck2 matches the
//!                                      attribute, checks.bxl), "" otherwise
//!   e2e <label> <package>              a `readme_e2e` target and its `package`
//!   ledger <path>                      the ledger the graph_check names
//!   scan <path>                        a file whose text is in --scan
//!
//! A row is a README one directory under src/ (`src/<name>/README.md`):
//!
//!   mopm.toml  `src/<name>/mopm.toml` is a file
//!   e2e        `//release/readme_e2e/verify:<name>` is a `readme_e2e` target
//!   gate       a target of the package `src/<name>` whose `readme` is this
//!              README: `mojo_adopted_library` when one is that rule's,
//!              otherwise `mojo_library` when one is that rule's, otherwise
//!              `none`
//!   example    `yes` when the README examples reader (examples.zig, the one
//!              the gates and the e2e run) takes at least one example from
//!              it, `no` when none, `refused` when it refuses the README
//!   run by     `release e2e` when e2e is yes and example yes, `build gate`
//!              when gate is not none and example yes, both, or `nobody`
//!
//! Refused besides a ledger that is not the text: a readme_e2e target of
//! //release/readme_e2e/verify whose `package` is not `<namespace>/<its
//! name>` (it runs another package's README), one for a name with no
//! README, a ledger fact that names another file than LEDGER, a README or
//! ledger whose text is not in --scan, and a malformed fact.
const std = @import("std");
const examples = @import("examples");
const Allocator = std.mem.Allocator;

/// The ledger: the file the graph check `//release:readme_coverage` holds.
pub const LEDGER = "release/README_COVERAGE.md";
/// The package of the release's README e2e targets.
pub const VERIFY_PACKAGE = "release/readme_e2e/verify";

const ADOPTED_KIND = "_adopted";
const LIBRARY_KIND = "mojo_library_rule";

pub const Gate = enum { adopted, library, none };
pub const Example = enum { yes, no, refused };

pub const Row = struct {
    name: []const u8,
    mopm: bool = false,
    e2e: bool = false,
    gate: Gate = .none,
    example: Example = .no,

    pub fn byE2e(r: Row) bool {
        return r.e2e and r.example == .yes;
    }
    pub fn byGate(r: Row) bool {
        return r.gate != .none and r.example == .yes;
    }
};

pub const Outcome = struct {
    /// Fact lines read.
    facts: usize,
    /// READMEs found: rows of the ledger.
    readmes: usize,
    /// `gate` facts that name a README and `e2e` facts read: none of either
    /// means a query of checks.bxl matched nothing, so every row would read
    /// `none` or `no`.
    gates: usize,
    e2es: usize,
    /// Every refusal, one message each.
    findings: []const []const u8,
};

/// A rule kind's own name: `cell//path.bzl:_adopted` -> `_adopted`.
fn kindName(kind: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, kind, ':')) |i| kind[i + 1 ..] else kind;
}

/// `cell//a/b:c` -> `a/b`.
fn packageOf(label: []const u8) []const u8 {
    const s = if (std.mem.indexOf(u8, label, "//")) |i| label[i + 2 ..] else label;
    return if (std.mem.indexOfScalar(u8, s, ':')) |i| s[0..i] else s;
}

/// `cell//a/b:c` -> `c`, or "" for a label with no name.
fn nameOf(label: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, label, ':')) |i| label[i + 1 ..] else "";
}

/// The `<name>` of `src/<name>/<file>`, or null for any other path.
pub fn srcFile(path: []const u8, file: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "src/")) return null;
    const rest = path["src/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or !std.mem.eql(u8, rest[slash + 1 ..], file)) return null;
    return rest[0..slash];
}

/// Whether a `readme` attribute of a target of `src/<name>` names that
/// package's README.md: as the package's own path (`README.md`), as the
/// path in the cell, or as a source with its cell (`komira//src/<name>/README.md`,
/// or with `:` before the file).
pub fn readsReadme(a: Allocator, value: []const u8, name: []const u8) Allocator.Error!bool {
    if (std.mem.eql(u8, value, "README.md")) return true;
    const v = try a.dupe(u8, value);
    std.mem.replaceScalar(u8, v, ':', '/');
    const want = try std.fmt.allocPrint(a, "src/{s}/README.md", .{name});
    if (std.mem.eql(u8, v, want)) return true;
    return std.mem.endsWith(u8, v, want) and v[v.len - want.len - 1] == '/';
}

fn fields(line: []const u8, buf: *[4][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (n == buf.len) return n + 1;
        buf[n] = f;
        n += 1;
    }
    return n;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn rowLess(_: void, x: Row, y: Row) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

pub const Collected = struct {
    facts: usize,
    gates: usize = 0,
    e2es: usize = 0,
    rows: []const Row,
    /// The committed ledger's text, or null when no ledger was read.
    ledger: ?[]const u8,
    findings: std.ArrayList([]const u8),
};

/// The rows of the facts, sorted by name, and every finding but the
/// ledger's own differences. `texts` holds the text of each `scan` path.
pub fn collect(a: Allocator, facts: []const u8, texts: *const std.StringHashMap([]const u8)) !Collected {
    var findings = std.ArrayList([]const u8).empty;
    var readmes = std.ArrayList([]const u8).empty;
    var mopm = std.StringHashMap(void).init(a);
    var gates = std.StringHashMap(Gate).init(a);
    var e2e = std.StringHashMap(void).init(a);
    var e2e_labels = std.ArrayList([]const u8).empty;
    var ledger: ?[]const u8 = null;
    var n: usize = 0;
    var e2es: usize = 0;
    var gate_facts = std.ArrayList([3][]const u8).empty;
    var it = std.mem.splitScalar(u8, facts, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        var f: [4][]const u8 = undefined;
        const k = fields(line, &f);
        const tag = f[0];
        if (std.mem.eql(u8, tag, "file") and k == 2) {
            if (srcFile(f[1], "README.md")) |name| try readmes.append(a, name);
            if (srcFile(f[1], "mopm.toml")) |name| try mopm.put(name, {});
        } else if (std.mem.eql(u8, tag, "gate") and k == 4) {
            const kind = kindName(f[2]);
            if (!std.mem.eql(u8, kind, ADOPTED_KIND) and !std.mem.eql(u8, kind, LIBRARY_KIND)) {
                try findings.append(a, try std.fmt.allocPrint(a, "the fact `{s}` names the rule kind {s}, which is neither {s} nor {s}", .{ line, f[2], ADOPTED_KIND, LIBRARY_KIND }));
                continue;
            }
            try gate_facts.append(a, .{ f[1], kind, f[3] });
        } else if (std.mem.eql(u8, tag, "e2e") and k == 3) {
            e2es += 1;
            if (!std.mem.eql(u8, packageOf(f[1]), VERIFY_PACKAGE)) continue;
            const name = nameOf(f[1]);
            const slash = std.mem.indexOfScalar(u8, f[2], '/');
            const own = if (std.mem.lastIndexOfScalar(u8, f[2], '/')) |i| f[2][i + 1 ..] else "";
            if (name.len == 0 or slash == null or slash.? == 0 or !std.mem.eql(u8, own, name)) {
                try findings.append(a, try std.fmt.allocPrint(a, "{s} installs `{s}`, not `<namespace>/{s}`: the e2e of a name runs that package's README", .{ f[1], f[2], name }));
                continue;
            }
            try e2e.put(name, {});
            try e2e_labels.append(a, f[1]);
        } else if (std.mem.eql(u8, tag, "ledger") and k == 2) {
            if (!std.mem.eql(u8, f[1], LEDGER)) {
                try findings.append(a, try std.fmt.allocPrint(a, "the ledger is {s}, and this checker writes {s}: its links are relative to release/", .{ f[1], LEDGER }));
                continue;
            }
            ledger = texts.get(f[1]) orelse {
                try findings.append(a, try std.fmt.allocPrint(a, "the text of the ledger {s} is not in --scan", .{f[1]}));
                continue;
            };
        } else if (std.mem.eql(u8, tag, "scan") and k == 2) {
            // The text is in `texts`; a fact that names a file reads it there.
        } else {
            try findings.append(a, try std.fmt.allocPrint(a, "malformed fact `{s}`", .{line}));
        }
    }
    // The gate of each package: an adopted one before a mojo_library one.
    var gates_read: usize = 0;
    for (gate_facts.items) |g| {
        if (g[2].len > 0) gates_read += 1;
        const pkg = packageOf(g[0]);
        const name = srcFile(try std.fmt.allocPrint(a, "{s}/README.md", .{pkg}), "README.md") orelse continue;
        if (g[2].len == 0) continue;
        if (!(try readsReadme(a, g[2], name))) continue;
        const this: Gate = if (std.mem.eql(u8, g[1], ADOPTED_KIND)) .adopted else .library;
        const had = gates.get(name) orelse .none;
        if (had == .none or (had == .library and this == .adopted)) try gates.put(name, this);
    }
    std.mem.sort([]const u8, readmes.items, {}, lessThan);
    var rows = std.ArrayList(Row).empty;
    var seen = std.StringHashMap(void).init(a);
    for (readmes.items) |name| {
        if (seen.contains(name)) continue;
        try seen.put(name, {});
        const path = try std.fmt.allocPrint(a, "src/{s}/README.md", .{name});
        var example: Example = .no;
        if (texts.get(path)) |text| {
            switch (try examples.extract(a, text, path, false)) {
                .examples => |xs| example = if (xs.len > 0) .yes else .no,
                .refused => example = .refused,
            }
        } else {
            try findings.append(a, try std.fmt.allocPrint(a, "the text of {s} is not in --scan", .{path}));
        }
        try rows.append(a, .{
            .name = name,
            .mopm = mopm.contains(name),
            .e2e = e2e.contains(name),
            .gate = gates.get(name) orelse .none,
            .example = example,
        });
    }
    std.mem.sort([]const u8, e2e_labels.items, {}, lessThan);
    for (e2e_labels.items) |l| {
        if (!seen.contains(nameOf(l))) try findings.append(a, try std.fmt.allocPrint(a, "{s} is the README e2e of `{s}`, and there is no src/{s}/README.md", .{ l, nameOf(l), nameOf(l) }));
    }
    std.mem.sort(Row, rows.items, {}, rowLess);
    return .{ .facts = n, .gates = gates_read, .e2es = e2es, .rows = try rows.toOwnedSlice(a), .ledger = ledger, .findings = findings };
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn gateWord(g: Gate) []const u8 {
    return switch (g) {
        .adopted => "mojo_adopted_library",
        .library => "mojo_library",
        .none => "none",
    };
}

fn runBy(r: Row) []const u8 {
    if (r.byE2e() and r.byGate()) return "release e2e, build gate";
    if (r.byE2e()) return "release e2e";
    if (r.byGate()) return "build gate";
    return "nobody";
}

const HEAD =
    \\# Which READMEs the release runs
    \\
    \\Every `src/<name>/README.md` of the repository, and who runs its `mojo` examples. The graph check
    \\`//release:readme_coverage` ([readme_coverage.zig](../tools/build/selftest/graph/readme_coverage.zig))
    \\writes this text from the build graph and the READMEs, and the pull request check fails when this
    \\file is not that text byte for byte, printing each line that differs with the line it must be. So a
    \\package that gains or loses a `mopm.toml`, a README e2e target, a README gate or its last example
    \\changes its row in the same change. Do not edit it by hand: copy the lines the check prints.
    \\
    \\| Column | What it says | Read from |
    \\|---|---|---|
    \\| `mopm.toml` | the package has a `src/<name>/mopm.toml`: the release publishes it on mopm | the files of the checkout (the root `doc_tree`) |
    \\| e2e | `//release/readme_e2e/verify:<name>` exists: the release installs the staged package into a fresh project and runs the README's examples against the installed copy ([readme_e2e](../tools/build/readme_e2e/README.md)) | the `readme_e2e` targets of that package, each installing `<namespace>/<its name>` |
    \\| gate | the README gate that runs the examples inside the build, against the library as the build holds it: `mojo_adopted_library` or `mojo_library` (a target of `//src/<name>` of that rule whose `readme` is this README), or `none` | the rule and the `readme` of every target under `//src/` |
    \\| example | `yes` when the README holds at least one example (a `mojo` or `mojo module` fenced block, as the README examples tool reads it), `no` when it holds none, `refused` when that tool refuses the README | the README |
    \\| run by | who runs the examples: `release e2e` (e2e and example are yes), `build gate` (a gate, and example is yes), both, or `nobody` | the columns before it |
    \\
    \\## Counts
    \\
    \\| READMEs | Count |
    \\|---|---|
    \\
;

const TABLE_HEAD =
    \\
    \\## The READMEs
    \\
    \\| Package | `mopm.toml` | e2e | gate | example | run by |
    \\|---|---|---|---|---|---|
    \\
;

fn print(out: *std.ArrayList(u8), a: Allocator, comptime f: []const u8, args: anytype) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, f, args));
}

/// The ledger's text for `rows` (sorted by name).
pub fn render(a: Allocator, rows: []const Row) ![]const u8 {
    var c = struct { mopm: usize = 0, e2e: usize = 0, adopted: usize = 0, library: usize = 0, none: usize = 0, yes: usize = 0, refused: usize = 0, by_e2e: usize = 0, by_gate: usize = 0, nobody: usize = 0, gate_only: usize = 0 }{};
    var nobody = std.ArrayList(u8).empty;
    for (rows) |r| {
        if (r.mopm) c.mopm += 1;
        if (r.e2e) c.e2e += 1;
        switch (r.gate) {
            .adopted => c.adopted += 1,
            .library => c.library += 1,
            .none => c.none += 1,
        }
        if (r.example == .yes) c.yes += 1;
        if (r.example == .refused) c.refused += 1;
        if (r.byE2e()) c.by_e2e += 1;
        if (r.byGate()) c.by_gate += 1;
        if (r.byGate() and !r.byE2e()) c.gate_only += 1;
        if (!r.byE2e() and !r.byGate()) {
            c.nobody += 1;
            const sep: []const u8 = if (nobody.items.len == 0) "" else ", ";
            try print(&nobody, a, "{s}[`{s}`](../src/{s}/README.md)", .{ sep, r.name, r.name });
        }
    }
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, HEAD);
    try print(&out, a, "| every `src/<name>/README.md` | {d} |\n", .{rows.len});
    try print(&out, a, "| with a `mopm.toml` | {d} |\n", .{c.mopm});
    try print(&out, a, "| with a README e2e target | {d} |\n", .{c.e2e});
    try print(&out, a, "| with a `mojo_adopted_library` gate | {d} |\n", .{c.adopted});
    try print(&out, a, "| with a `mojo_library` gate | {d} |\n", .{c.library});
    try print(&out, a, "| with no gate | {d} |\n", .{c.none});
    try print(&out, a, "| with at least one example | {d} |\n", .{c.yes});
    try print(&out, a, "| refused by the README examples tool | {d} |\n", .{c.refused});
    try print(&out, a, "| run by the release e2e | {d} |\n", .{c.by_e2e});
    try print(&out, a, "| run by a build gate | {d} |\n", .{c.by_gate});
    try print(&out, a, "| run by nobody | {d} |\n", .{c.nobody});
    try out.appendSlice(a, "\n## Left out\n\n");
    try print(&out, a, "Run by a build gate and not by the release e2e: {d} READMEs. Their packages have no `mopm.toml`, so the release does not publish them; [UNPUBLISHED.md](UNPUBLISHED.md) says why for each library.\n\n", .{c.gate_only});
    if (nobody.items.len == 0) {
        try out.appendSlice(a, "Run by nobody: none.\n");
    } else {
        try print(&out, a, "Run by nobody ({d}): {s}.\n", .{ c.nobody, nobody.items });
    }
    try out.appendSlice(a, TABLE_HEAD);
    for (rows) |r| {
        try print(&out, a, "| [`{s}`](../src/{s}/README.md) | {s} | {s} | {s} | {s} | {s} |\n", .{ r.name, r.name, yesNo(r.mopm), yesNo(r.e2e), gateWord(r.gate), @tagName(r.example), runBy(r) });
    }
    return out.toOwnedSlice(a);
}

/// The package a ledger line is the row of (`| [`<name>`](...`), or null.
fn rowName(line: []const u8) ?[]const u8 {
    const open = "| [`";
    if (!std.mem.startsWith(u8, line, open)) return null;
    const end = std.mem.indexOfPos(u8, line, open.len, "`]") orelse return null;
    return line[open.len..end];
}

const Split = struct {
    rows: std.StringArrayHashMap([]const u8),
    twice: std.ArrayList([]const u8),
    /// The other lines, each with its 1-based line number.
    other: std.ArrayList(struct { n: usize, text: []const u8 }),
};

fn split(a: Allocator, text: []const u8) !Split {
    var s = Split{ .rows = std.StringArrayHashMap([]const u8).init(a), .twice = .empty, .other = .empty };
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (rowName(line)) |name| {
            if (s.rows.contains(name)) try s.twice.append(a, name) else try s.rows.put(name, line);
        } else try s.other.append(a, .{ .n = n, .text = line });
    }
    return s;
}

/// The findings of a committed ledger `have` that is not the text `want`:
/// each row missing, out of date, for a package with no README or given
/// twice, and the first other line that differs. A ledger that differs in
/// nothing of that (its rows are out of order) is one finding too.
pub fn compare(a: Allocator, want: []const u8, have: []const u8, findings: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, want, have)) return;
    const before = findings.items.len;
    const w = try split(a, want);
    const h = try split(a, have);
    for (w.rows.keys(), w.rows.values()) |name, line| {
        if (h.rows.get(name)) |got| {
            if (!std.mem.eql(u8, got, line)) try findings.append(a, try std.fmt.allocPrint(a, "{s}: the row of `{s}` is out of date; it must be:\n{s}", .{ LEDGER, name, line }));
        } else try findings.append(a, try std.fmt.allocPrint(a, "{s}: no row for `{s}`, which has a README; add:\n{s}", .{ LEDGER, name, line }));
    }
    for (h.rows.keys()) |name| {
        if (!w.rows.contains(name)) try findings.append(a, try std.fmt.allocPrint(a, "{s}: a row for `{s}`, which has no src/{s}/README.md: delete it", .{ LEDGER, name, name }));
    }
    for (h.twice.items) |name| try findings.append(a, try std.fmt.allocPrint(a, "{s}: the row of `{s}` is there twice: delete one", .{ LEDGER, name }));
    var i: usize = 0;
    while (i < w.other.items.len or i < h.other.items.len) : (i += 1) {
        const wl: ?[]const u8 = if (i < w.other.items.len) w.other.items[i].text else null;
        const hl: ?[]const u8 = if (i < h.other.items.len) h.other.items[i].text else null;
        if (wl != null and hl != null and std.mem.eql(u8, wl.?, hl.?)) continue;
        if (hl) |got| {
            try findings.append(a, try std.fmt.allocPrint(a, "{s}:{d}: the line `{s}` must be:\n{s}", .{ LEDGER, h.other.items[i].n, got, wl orelse "(no line: the file ends before it)" }));
        } else {
            try findings.append(a, try std.fmt.allocPrint(a, "{s}: the file ends early; the line after its last must be:\n{s}", .{ LEDGER, wl.? }));
        }
        break;
    }
    if (findings.items.len == before) try findings.append(a, try std.fmt.allocPrint(a, "{s}: its rows are the generated ones in another order: sort them by package", .{LEDGER}));
}

/// The whole check over `facts`.
pub fn check(a: Allocator, facts: []const u8, texts: *const std.StringHashMap([]const u8)) !Outcome {
    var c = try collect(a, facts, texts);
    if (c.ledger) |have| {
        try compare(a, try render(a, c.rows), have, &c.findings);
    } else {
        try c.findings.append(a, try std.fmt.allocPrint(a, "no ledger was read: the graph_check names {s} in its srcs", .{LEDGER}));
    }
    return .{ .facts = c.facts, .readmes = c.rows.len, .gates = c.gates, .e2es = c.e2es, .findings = try c.findings.toOwnedSlice(a) };
}

// ---- tests ------------------------------------------------------------------

const t = std.testing;

const README_EXAMPLE = "# json\n\n```mojo\nprint(1)\n```\n";
const README_NONE = "# kafka\n\nNo example.\n";
const README_REFUSED = "# x\n\n```mojo skip\nprint(1)\n```\n";

/// The facts of a small repository: `json` (on mopm, an e2e target, an
/// adopted gate, an example), `arrow` (a mojo_library gate, an example),
/// `kafka` (a mojo_library gate, no example) and `notes` (no gate, an example).
const FACTS =
    "file\tsrc/json/README.md\nscan\tsrc/json/README.md\nfile\tsrc/json/mopm.toml\n" ++
    "gate\tkomira//src/json:json\tkomira//tools/build/mojo/adopt.bzl:_adopted\tkomira//src/json/README.md\n" ++
    "e2e\tkomira//release/readme_e2e/verify:json\tkomira-ai/json\n" ++
    "file\tsrc/arrow/README.md\nscan\tsrc/arrow/README.md\n" ++
    "gate\tkomira//src/arrow:arrow\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tkomira//src/arrow/README.md\n" ++
    "file\tsrc/kafka/README.md\nscan\tsrc/kafka/README.md\n" ++
    "gate\tkomira//src/kafka:kafka\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tREADME.md\n" ++
    "file\tsrc/notes/README.md\nscan\tsrc/notes/README.md\n" ++
    "ledger\trelease/README_COVERAGE.md\nscan\trelease/README_COVERAGE.md\n";

/// The texts of FACTS' READMEs, and `ledger` as the committed ledger.
fn fixtureTexts(a: Allocator, ledger: []const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    try m.put("src/json/README.md", README_EXAMPLE);
    try m.put("src/arrow/README.md", README_EXAMPLE);
    try m.put("src/kafka/README.md", README_NONE);
    try m.put("src/notes/README.md", README_EXAMPLE);
    try m.put(LEDGER, ledger);
    return m;
}

fn rowsOf(a: Allocator, facts: []const u8, m: *const std.StringHashMap([]const u8)) ![]const Row {
    return (try collect(a, facts, m)).rows;
}

/// The rendered row of `name`.
fn renderedRow(a: Allocator, rows: []const Row, name: []const u8) ![]const u8 {
    const text = try render(a, rows);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| if (rowName(line)) |n| if (std.mem.eql(u8, n, name)) return line;
    return error.NoRow;
}

fn expectOne(findings: []const []const u8, want: []const u8) !void {
    try t.expectEqual(@as(usize, 1), findings.len);
    try t.expectEqualStrings(want, findings[0]);
}

test "a ledger that is the generated text holds, and each column reads its fact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const rows = try rowsOf(a, FACTS, &m);
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqualStrings("| [`arrow`](../src/arrow/README.md) | no | no | mojo_library | yes | build gate |", try renderedRow(a, rows, "arrow"));
    try t.expectEqualStrings("| [`json`](../src/json/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |", try renderedRow(a, rows, "json"));
    try t.expectEqualStrings("| [`kafka`](../src/kafka/README.md) | no | no | mojo_library | no | nobody |", try renderedRow(a, rows, "kafka"));
    try t.expectEqualStrings("| [`notes`](../src/notes/README.md) | no | no | none | yes | nobody |", try renderedRow(a, rows, "notes"));
    const text = try render(a, rows);
    try t.expect(std.mem.indexOf(u8, text, "| run by nobody | 2 |\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "Run by nobody (2): [`kafka`](../src/kafka/README.md), [`notes`](../src/notes/README.md).\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "Run by a build gate and not by the release e2e: 1 READMEs.") != null);
    m = try fixtureTexts(a, text);
    const o = try check(a, FACTS, &m);
    try t.expectEqual(@as(usize, 4), o.readmes);
    try t.expectEqual(@as(usize, 0), o.findings.len);
}

test "a README with no row is a finding that gives the row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const text = try render(a, try rowsOf(a, FACTS, &m));
    const row = "| [`notes`](../src/notes/README.md) | no | no | none | yes | nobody |\n";
    const at = std.mem.indexOf(u8, text, row).?;
    const without = try std.mem.concat(a, u8, &.{ text[0..at], text[at + row.len ..] });
    m = try fixtureTexts(a, without);
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md: no row for `notes`, which has a README; add:\n| [`notes`](../src/notes/README.md) | no | no | none | yes | nobody |");
}

test "a row for a package with no README is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const text = try render(a, try rowsOf(a, FACTS, &m));
    m = try fixtureTexts(a, try std.mem.concat(a, u8, &.{ text, "| [`gone`](../src/gone/README.md) | no | no | none | no | nobody |\n" }));
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md: a row for `gone`, which has no src/gone/README.md: delete it");
}

test "a row whose e2e column is stale is a finding that gives the row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const text = try render(a, try rowsOf(a, FACTS, &m));
    // The facts lose json's e2e target: the committed row still says yes.
    const no_e2e = try std.mem.replaceOwned(u8, a, FACTS, "e2e\tkomira//release/readme_e2e/verify:json\tkomira-ai/json\n", "");
    m = try fixtureTexts(a, text);
    const o = try check(a, no_e2e, &m);
    try t.expectEqual(@as(usize, 2), o.findings.len);
    try t.expectEqualStrings("release/README_COVERAGE.md: the row of `json` is out of date; it must be:\n| [`json`](../src/json/README.md) | yes | no | mojo_adopted_library | yes | build gate |", o.findings[0]);
    // The count above the table moved too: the first line that differs is named.
    try t.expect(std.mem.startsWith(u8, o.findings[1], "release/README_COVERAGE.md:24: the line `| with a README e2e target | 1 |` must be:\n| with a README e2e target | 0 |"));
}

test "a row given twice, and rows out of order, are findings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const text = try render(a, try rowsOf(a, FACTS, &m));
    const json = "| [`json`](../src/json/README.md) | yes | yes | mojo_adopted_library | yes | release e2e, build gate |\n";
    m = try fixtureTexts(a, try std.mem.concat(a, u8, &.{ text, json }));
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md: the row of `json` is there twice: delete one");
    const arrow = "| [`arrow`](../src/arrow/README.md) | no | no | mojo_library | yes | build gate |\n";
    const swapped = try std.mem.replaceOwned(u8, a, text, try std.mem.concat(a, u8, &.{ arrow, json }), try std.mem.concat(a, u8, &.{ json, arrow }));
    m = try fixtureTexts(a, swapped);
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md: its rows are the generated ones in another order: sort them by package");
}

test "a changed line of the prose is a finding naming its line, and so is a file that ends early" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const text = try render(a, try rowsOf(a, FACTS, &m));
    m = try fixtureTexts(a, try std.mem.replaceOwned(u8, a, text, "# Which READMEs the release runs\n", "# Which READMEs run\n"));
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md:1: the line `# Which READMEs run` must be:\n# Which READMEs the release runs");
    m = try fixtureTexts(a, text[0 .. text.len - 1]);
    try expectOne((try check(a, FACTS, &m)).findings, "release/README_COVERAGE.md: the file ends early; the line after its last must be:\n");
}

test "an e2e target that installs another package, and one with no README, are findings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const other = try std.mem.replaceOwned(u8, a, FACTS, "verify:json\tkomira-ai/json", "verify:json\tkomira-ai/arrow");
    const c = try collect(a, other, &m);
    try t.expectEqualStrings("komira//release/readme_e2e/verify:json installs `komira-ai/arrow`, not `<namespace>/json`: the e2e of a name runs that package's README", c.findings.items[0]);
    try t.expectEqual(false, c.rows[1].e2e);
    const bare = try std.mem.replaceOwned(u8, a, FACTS, "verify:json\tkomira-ai/json", "verify:json\tjson");
    try t.expectEqual(@as(usize, 1), (try collect(a, bare, &m)).findings.items.len);
    const orphan = try std.mem.concat(a, u8, &.{ FACTS, "e2e\tkomira//release/readme_e2e/verify:gone\tkomira-ai/gone\n" });
    const d = try collect(a, orphan, &m);
    try t.expectEqual(@as(usize, 1), d.findings.items.len);
    try t.expectEqualStrings("komira//release/readme_e2e/verify:gone is the README e2e of `gone`, and there is no src/gone/README.md", d.findings.items[0]);
    // A readme_e2e target outside the release's package is not the release's e2e.
    const elsewhere = try std.mem.concat(a, u8, &.{ FACTS, "e2e\ttests//functional/readme_e2e:notes\tkomira-ai/notes\n" });
    const e = try collect(a, elsewhere, &m);
    try t.expectEqual(@as(usize, 0), e.findings.items.len);
    try t.expectEqual(false, e.rows[3].e2e);
}

test "the gate is the package's own and reads this README; adopted comes before mojo_library" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const extra =
        // A second, adopted target of arrow: arrow's gate is the adopted one.
        "gate\tkomira//src/arrow:arrow_adopted\tkomira//tools/build/mojo/adopt.bzl:_adopted\tkomira//src/arrow:README.md\n" ++
        // A target of a subpackage, and one whose readme is another file: neither is notes' gate.
        "gate\tkomira//src/notes/sub:sub\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tREADME.md\n" ++
        "gate\tkomira//src/notes:notes\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tkomira//src/notes/docs/README.md\n" ++
        "gate\tkomira//src/notes:other\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tkomira//src/xnotes/README.md\n" ++
        // A library with no README attribute.
        "gate\tkomira//src/notes:bare\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\t\n";
    const rows = try rowsOf(a, try std.mem.concat(a, u8, &.{ FACTS, extra }), &m);
    try t.expectEqual(Gate.adopted, rows[0].gate);
    try t.expectEqual(Gate.none, rows[3].gate);
    // An adopted target first and a mojo_library one after keeps the adopted one.
    const after = "gate\tkomira//src/json:json_lib\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\tREADME.md\n";
    try t.expectEqual(Gate.adopted, (try rowsOf(a, try std.mem.concat(a, u8, &.{ FACTS, after }), &m))[1].gate);
}

test "only a README one directory under src/ is a row, and only its own mopm.toml counts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const extra = "file\tsrc/tests/e2e/x/README.md\nfile\tsrc/README.md\nfile\tsrc//README.md\nfile\tdocs/README.md\nfile\tsrc/notes/sub/mopm.toml\nfile\tsrc/notes/mopm.toml.bak\n";
    const rows = try rowsOf(a, try std.mem.concat(a, u8, &.{ FACTS, extra }), &m);
    try t.expectEqual(@as(usize, 4), rows.len);
    try t.expectEqual(false, rows[3].mopm);
}

test "a README the examples reader refuses is `refused`, and one whose text is missing is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    try m.put("src/notes/README.md", README_REFUSED);
    const rows = try rowsOf(a, FACTS, &m);
    try t.expectEqual(Example.refused, rows[3].example);
    try t.expectEqualStrings("| [`notes`](../src/notes/README.md) | no | no | none | refused | nobody |", try renderedRow(a, rows, "notes"));
    _ = m.remove("src/notes/README.md");
    const c = try collect(a, FACTS, &m);
    try t.expectEqual(@as(usize, 1), c.findings.items.len);
    try t.expectEqualStrings("the text of src/notes/README.md is not in --scan", c.findings.items[0]);
}

test "an e2e target with no example is run by nobody, and a module example counts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    try m.put("src/json/README.md", README_NONE);
    try t.expectEqualStrings("| [`json`](../src/json/README.md) | yes | yes | mojo_adopted_library | no | nobody |", try renderedRow(a, try rowsOf(a, FACTS, &m), "json"));
    try m.put("src/json/README.md", "# json\n\n```mojo module\ndef main():\n    pass\n```\n");
    try t.expectEqual(Example.yes, (try rowsOf(a, FACTS, &m))[1].example);
    // An e2e target without a gate (its README is the gate's, so the build refuses it) is still run by the e2e.
    const no_gate = try std.mem.replaceOwned(u8, a, FACTS, "gate\tkomira//src/json:json\tkomira//tools/build/mojo/adopt.bzl:_adopted\tkomira//src/json/README.md\n", "");
    try m.put("src/json/README.md", README_EXAMPLE);
    try t.expectEqualStrings("| [`json`](../src/json/README.md) | yes | yes | none | yes | release e2e |", try renderedRow(a, try rowsOf(a, no_gate, &m), "json"));
}

test "no ledger, a ledger elsewhere, a ledger not scanned and malformed facts are findings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const no_ledger = try std.mem.replaceOwned(u8, a, FACTS, "ledger\trelease/README_COVERAGE.md\n", "");
    try expectOne((try check(a, no_ledger, &m)).findings, "no ledger was read: the graph_check names release/README_COVERAGE.md in its srcs");
    _ = m.remove(LEDGER);
    try expectOne((try check(a, FACTS, &m)).findings[0..1], "the text of the ledger release/README_COVERAGE.md is not in --scan");
    const elsewhere = try std.mem.replaceOwned(u8, a, FACTS, "ledger\trelease/README_COVERAGE.md\n", "ledger\tdocs/README_COVERAGE.md\n");
    try t.expectEqualStrings("the ledger is docs/README_COVERAGE.md, and this checker writes release/README_COVERAGE.md: its links are relative to release/", (try check(a, elsewhere, &m)).findings[0]);
    const bad = "file\nfile\ta\tb\nwhat\tx\ngate\tkomira//src/x:x\tkomira//r.bzl:genrule\tREADME.md\n";
    const c = try collect(a, bad, &m);
    try t.expectEqual(@as(usize, 4), c.facts);
    try t.expectEqual(@as(usize, 4), c.findings.items.len);
    try t.expectEqualStrings("malformed fact `file`", c.findings.items[0]);
    try t.expectEqualStrings("malformed fact `what\tx`", c.findings.items[2]);
    try t.expectEqualStrings("the fact `gate\tkomira//src/x:x\tkomira//r.bzl:genrule\tREADME.md` names the rule kind komira//r.bzl:genrule, which is neither _adopted nor mojo_library_rule", c.findings.items[3]);
}

test "no fact reads no README" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const o = try check(a, "\n\n", &m);
    try t.expectEqual(@as(usize, 0), o.facts);
    try t.expectEqual(@as(usize, 0), o.readmes);
}

test "readsReadme takes the package's README in each spelling and nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "README.md", "src/json/README.md", "komira//src/json/README.md", "komira//src/json:README.md", "root//src/json/README.md" }) |v| try t.expect(try readsReadme(a, v, "json"));
    for ([_][]const u8{ "docs/README.md", "komira//src/xjson/README.md", "komira//src/json/README.md.bak", "komira//src/json/sub/README.md", "README" }) |v| try t.expect(!(try readsReadme(a, v, "json")));
}

test "the gate and e2e facts are counted, so a query that matched no kind is told apart" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const o = try check(a, FACTS, &m);
    try t.expectEqual(@as(usize, 3), o.gates);
    try t.expectEqual(@as(usize, 1), o.e2es);
    // Gate facts whose readme names no README (the attribute query matched none) count as none read.
    const unnamed = "gate\tkomira//src/notes:notes\tkomira//tools/build/mojo/defs.bzl:mojo_library_rule\t\n";
    try t.expectEqual(@as(usize, 0), (try check(a, unnamed, &m)).gates);
    const files_only = "file\tsrc/notes/README.md\nscan\tsrc/notes/README.md\n";
    const p = try check(a, files_only, &m);
    try t.expectEqual(@as(usize, 1), p.readmes);
    try t.expectEqual(@as(usize, 0), p.gates);
    try t.expectEqual(@as(usize, 0), p.e2es);
}

test "a fact with too many fields is malformed, and a line that only opens a row is prose" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try fixtureTexts(a, "");
    const c = try collect(a, "gate\tkomira//src/x:x\tkomira//a.bzl:_adopted\tREADME.md\textra\n", &m);
    try t.expectEqualStrings("malformed fact `gate\tkomira//src/x:x\tkomira//a.bzl:_adopted\tREADME.md\textra`", c.findings.items[0]);
    try t.expect(rowName("| [`open") == null);
    try t.expectEqualStrings("json", rowName("| [`json`](../src/json/README.md) | yes |").?);
}

test "every README run renders `none` left out, and a ledger longer than the text is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_]Row{.{ .name = "json", .mopm = true, .e2e = true, .gate = .adopted, .example = .yes }};
    const text = try render(a, &rows);
    try t.expect(std.mem.indexOf(u8, text, "Run by nobody: none.\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "| run by nobody | 0 |\n") != null);
    var findings = std.ArrayList([]const u8).empty;
    // The text ends in a newline, so "\ntrailing" adds an empty line (as the text's last) and then one more.
    try compare(a, text, try std.mem.concat(a, u8, &.{ text, "\ntrailing" }), &findings);
    try expectOne(findings.items, try std.fmt.allocPrint(a, "release/README_COVERAGE.md:{d}: the line `trailing` must be:\n(no line: the file ends before it)", .{std.mem.count(u8, text, "\n") + 2}));
}
