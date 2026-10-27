// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// readme_api_coverage.sh (awk, find, sort, grep, diff run by a busybox shell),
// so that the lint runs no shell.
//! readme_api_coverage: the action behind readme_api_coverage.bzl.
//!
//! usage: readme_api_coverage census <readme tool> <findings.txt> <packages.tsv>
//!            <symbols.tsv> <report.txt> <tree> <prefix> <root> <exceptions.tsv>
//!            <its name> <enforce 0|1> <expected packages.tsv|-> <its name|->
//!            <expected symbols.tsv|-> <its name|-> <expected report.txt|-> <its name|->
//!        readme_api_coverage verdict <result.json> <findings.txt> <report.txt>
//!
//! Two actions, because a validation's action writes exactly one file: the
//! census writes the outputs above and the findings, one per line; the verdict
//! turns them into <result.json>. The rules of the census (what a package's
//! public API is, what a README use is, the ledger) are
//! docs/readme_api_coverage.md; the scanners are readme_api_scan.zig.
//!
//! Each directory directly under <tree>/<root> holding a file is one package,
//! except <root>/tests (test-only packages publish no API). With an expected
//! file given, the output must equal it byte for byte (a fixture's assertion).
//! Fails, checking nothing, when <root> holds no package.
//!
//! Exit status: 0; 2 for a usage error or a failure of the tool's own. The
//! findings, not the status, make the lint red.

const std = @import("std");
const scan = @import("readme_api_scan.zig");
const diff = @import("unified_diff");
const A = std.mem.Allocator;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("readme_api_coverage: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `x/y` as a percentage with one decimal, rounded as printf rounds an exact
/// tie (half to even), or "-" when y is 0.
pub fn percent(a: A, x: u64, y: u64, suffix: []const u8) ![]u8 {
    if (y == 0) return a.dupe(u8, "-");
    const t = 1000 * x;
    var q = t / y;
    const r2 = 2 * (t % y);
    if (r2 > y or (r2 == y and q % 2 == 1)) q += 1;
    return std.fmt.allocPrint(a, "{d}.{d}{s}", .{ q / 10, q % 10, suffix });
}

pub const Row = struct { pkg: []const u8, sym: []const u8, line: usize };

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

/// The ledger: `<package><TAB><symbol><TAB><reason>`; a malformed or repeated
/// row is a finding appended to `report`.
pub fn parseLedger(a: A, name: []const u8, text: []const u8, report: *std.ArrayList(u8)) ![]Row {
    var rows = std.ArrayList(Row).empty;
    var first = std.StringHashMap(usize).init(a);
    const ls = try scan.records(a, text);
    for (ls, 1..) |line, nr| {
        const t = std.mem.trimLeft(u8, line, " \t\n\r\x0b\x0c");
        if (t.len == 0 or t[0] == '#') continue;
        var f = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |x| try f.append(a, x);
        var bad = f.items.len != 3 or !scan.isIdent(f.items[0]);
        if (!bad) {
            const sym = f.items[1];
            const dot = std.mem.indexOfScalar(u8, sym, '.');
            bad = if (dot) |d|
                !(scan.isIdent(sym[0..d]) and scan.isIdent(sym[d + 1 ..]))
            else
                !scan.isIdent(sym);
            var spaces = true;
            for (f.items[2]) |c| {
                if (!isSpace(c)) spaces = false;
            }
            if (spaces) bad = true;
        }
        if (bad) {
            try report.writer(a).print("{s}:{d}: a row is <package><TAB><symbol><TAB><reason>, with a reason\n", .{ name, nr });
            continue;
        }
        const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ f.items[0], f.items[1] });
        if (first.get(key)) |prev| {
            try report.writer(a).print("{s}:{d}: {s} {s} has a row already, on line {d}\n", .{ name, nr, f.items[0], f.items[1], prev });
            continue;
        }
        try first.put(key, nr);
        try rows.append(a, .{ .pkg = f.items[0], .sym = f.items[1], .line = nr });
    }
    return rows.toOwnedSlice(a);
}

pub const Symbol = struct {
    pkg: []const u8,
    kind: []const u8,
    sym: []const u8,
    id: []const u8,
    where: []const u8,
};

/// `f` (a path under the package directory) lies in the module `path` names:
/// `path`.mojo, or a file under `path`/.
fn inModule(f: []const u8, dir_len: usize, path: []const u8) bool {
    const rel = f[dir_len..];
    if (rel.len == path.len + 5 and std.mem.startsWith(u8, rel, path) and std.mem.endsWith(u8, rel, ".mojo")) return true;
    return rel.len > path.len and std.mem.startsWith(u8, rel, path) and rel[path.len] == '/';
}

/// The symbols of one package: its exported names, then for each exported
/// struct its public methods, in the module the import names when a struct of
/// that name is there.
pub fn symbolsOf(a: A, pkg: []const u8, dir: []const u8, exps: []const scan.Export, ms: []const scan.Method, out: *std.ArrayList(Symbol)) !void {
    var seen = std.StringHashMap(void).init(a);
    const dir_slash = try std.fmt.allocPrint(a, "{s}/", .{dir});
    for (exps) |e| {
        if (std.mem.eql(u8, e.name, "*") or seen.contains(e.name)) continue;
        try seen.put(e.name, {});
        try out.append(a, .{ .pkg = pkg, .kind = "name", .sym = e.name, .id = e.name, .where = try std.fmt.allocPrint(a, "{s}__init__.mojo:{d}", .{ dir_slash, e.line }) });
        if (std.mem.eql(u8, e.path, "-")) continue;
        var local = false;
        for (ms) |m| {
            if (std.mem.eql(u8, m.strukt, e.orig) and inModule(m.file, dir_slash.len, e.path)) local = true;
        }
        var got = std.StringHashMap(void).init(a);
        for (ms) |m| {
            if (!std.mem.eql(u8, m.strukt, e.orig)) continue;
            if (local and !inModule(m.file, dir_slash.len, e.path)) continue;
            if (got.contains(m.name)) continue;
            try got.put(m.name, {});
            try out.append(a, .{
                .pkg = pkg,
                .kind = "method",
                .sym = try std.fmt.allocPrint(a, "{s}.{s}", .{ e.name, m.name }),
                .id = m.name,
                .where = try std.fmt.allocPrint(a, "{s}:{d}", .{ m.file, m.line }),
            });
        }
    }
}

const PkgRow = struct { name: []const u8, init: bool, readme: []const u8 };

fn absolute(a: A, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return a.dupe(u8, p);
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ cwd, p });
}

fn readAll(a: A, dir: std.fs.Dir, path: []const u8) []u8 {
    return dir.readFileAlloc(a, path, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
}

pub fn packagesUnder(a: A, tree: std.fs.Dir, root: []const u8) ![][]const u8 {
    var names = std.StringHashMap(void).init(a);
    var d = tree.openDir(root, .{ .iterate = true }) catch return &.{};
    defer d.close();
    var w = try d.walk(a);
    while (try w.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const slash = std.mem.indexOfScalar(u8, e.path, '/') orelse continue;
        const top = e.path[0..slash];
        if (std.mem.eql(u8, top, "tests")) continue;
        try names.put(try a.dupe(u8, top), {});
    }
    var out = std.ArrayList([]const u8).empty;
    var it = names.keyIterator();
    while (it.next()) |k| try out.append(a, k.*);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(a);
}

pub fn sourcesOf(a: A, tree: std.fs.Dir, root: []const u8, p: []const u8) ![][]const u8 {
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, p });
    var d = try tree.openDir(dir, .{ .iterate = true });
    defer d.close();
    var out = std.ArrayList([]const u8).empty;
    var w = try d.walk(a);
    while (try w.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, e.basename, ".mojo")) continue;
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, e.path });
        if (std.mem.indexOf(u8, full, "/tests/") != null) continue;
        try out.append(a, full);
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(a);
}

fn firstLines(a: A, log: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        if (n == 3) break;
        try out.appendSlice(a, l);
        try out.append(a, ' ');
        n += 1;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(a);
}

fn census(a: A, argv: []const []const u8) !void {
    if (argv.len != 19) die("usage: readme_api_coverage census <19 arguments, see the header>", .{});
    const tool = try absolute(a, argv[2]);
    const findings_out = argv[3];
    const packages_out = argv[4];
    const symbols_out = argv[5];
    const report_out = argv[6];
    const tree_path = argv[7];
    const prefix = argv[8];
    const root = argv[9];
    const ledger_path = argv[10];
    const ledger_name = argv[11];
    const enforce = std.mem.eql(u8, argv[12], "1");
    const cwd = std.fs.cwd();

    // Scratch is per action: BUCK_SCRATCH_PATH, unset on a remote worker, whose root is the action's own.
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".komira_action");
    const scratch = try std.fs.path.join(a, &.{ try absolute(a, scratch_base), "komira_readme_api" });
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ scratch, "gen" }));
    defer std.fs.cwd().deleteTree(scratch) catch {};

    var tree = cwd.openDir(tree_path, .{ .iterate = true }) catch |e| die("cannot open {s}: {s}", .{ tree_path, @errorName(e) });
    defer tree.close();

    var findings = std.ArrayList(u8).empty;
    var notes = std.ArrayList(u8).empty;
    var syms = std.ArrayList(Symbol).empty;
    var ids = std.StringHashMap(void).init(a); // "pkg\tn|a\tid"
    var pkgs = std.ArrayList(PkgRow).empty;

    const names = try packagesUnder(a, tree, root);
    for (names) |p| {
        const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, p });
        var init = false;
        const init_path = try std.fmt.allocPrint(a, "{s}/__init__.mojo", .{dir});
        if (tree.statFile(init_path)) |st| {
            init = st.kind == .file;
        } else |_| {}
        if (init) {
            const exps = try scan.exports(a, p, readAll(a, tree, init_path));
            for (exps) |e| {
                if (std.mem.eql(u8, e.name, "*")) try notes.writer(a).print("{s}: `from {s} import *` at {s}:{d}: its names cannot be listed, so none is counted\n", .{ p, e.path, init_path, e.line });
            }
            var ms = std.ArrayList(scan.Method).empty;
            for (try sourcesOf(a, tree, root, p)) |f| try scan.methods(a, f, readAll(a, tree, f), &ms);
            try symbolsOf(a, p, dir, exps, ms.items, &syms);
        }
        var readme: []const u8 = "none";
        const readme_path = try std.fmt.allocPrint(a, "{s}/README.md", .{dir});
        const has_readme = if (tree.statFile(readme_path)) |st| st.kind == .file else |_| false;
        if (has_readme) {
            const out_dir = try std.fmt.allocPrint(a, "{s}/gen/{s}", .{ scratch, p });
            const examples = try std.fmt.allocPrint(a, "{s}/gen/{s}.examples", .{ scratch, p });
            const r = std.process.Child.run(.{
                .allocator = a,
                .argv = &.{ tool, "generate", "--readme", readme_path, "--display", readme_path, "--package", p, "--links", "allow", "--out-dir", out_dir, "--examples", examples },
                .cwd_dir = tree,
                .max_output_bytes = 1 << 24,
            }) catch |e| die("cannot run {s}: {s}", .{ tool, @errorName(e) });
            const rc: u32 = switch (r.term) {
                .Exited => |c| c,
                .Signal => |s| 128 + s,
                else => 255,
            };
            if (rc != 0) {
                readme = "refused";
                const log = try std.mem.concat(a, u8, &.{ r.stdout, r.stderr });
                try notes.writer(a).print("{s}: the readme tool refused {s}/README.md (exit {d}): {s}\n", .{ p, dir, rc, try firstLines(a, log) });
            } else {
                const ex = cwd.readFileAlloc(a, examples, 1 << 24) catch "";
                var count: usize = 0;
                var lines = std.mem.splitScalar(u8, ex, '\n');
                while (lines.next()) |l| {
                    if (l.len > 0) count += 1;
                }
                if (ex.len == 0) {
                    readme = "no-example";
                } else {
                    readme = try std.fmt.allocPrint(a, "examples:{d}", .{count});
                    var keys = std.StringHashMap(void).init(a);
                    var state = scan.Ids{};
                    lines = std.mem.splitScalar(u8, ex, '\n');
                    while (lines.next()) |l| {
                        if (l.len == 0) continue;
                        const prog = try std.fmt.allocPrint(a, "{s}/readme_{s}_{s}.mojo", .{ out_dir, p, l });
                        const text = cwd.readFileAlloc(a, prog, 1 << 26) catch |e| die("cannot read {s}: {s}", .{ prog, @errorName(e) });
                        for (try scan.records(a, text)) |line| try state.feed(a, line, &keys);
                    }
                    var kit = keys.keyIterator();
                    while (kit.next()) |k| try ids.put(try std.fmt.allocPrint(a, "{s}\t{s}", .{ p, k.* }), {});
                }
            }
        }
        try pkgs.append(a, .{ .name = p, .init = init, .readme = readme });
    }

    // The ledger, with its line numbers; a malformed or repeated row is a finding.
    try findings.appendSlice(a, "");
    const ledger_text = readAll(a, cwd, ledger_path);
    const rows = try parseLedger(a, ledger_name, ledger_text, &findings);
    var lrow = std.StringHashMap(usize).init(a);
    for (rows) |r| try lrow.put(try std.fmt.allocPrint(a, "{s}\t{s}", .{ r.pkg, r.sym }), r.line);

    // The census: symbols, packages, the report, and the ledger's findings.
    var sym_out = std.ArrayList(u8).empty;
    try sym_out.appendSlice(a, "package\tsymbol\tkind\tstatus\twhere\n");
    var pk_out = std.ArrayList(u8).empty;
    try pk_out.appendSlice(a, "package\tinit\treadme\texported\tused\tpercent\tnames\tnames_used\tmethods\tmethods_used\texcepted\tundocumented\n");
    const Count = struct { n: u64 = 0, u: u64 = 0, nn: u64 = 0, nu: u64 = 0, mn: u64 = 0, mu: u64 = 0, ex: u64 = 0, un: u64 = 0 };
    var counts = std.StringHashMap(Count).init(a);
    var exported = std.StringHashMap(void).init(a);
    var undoc = std.ArrayList(u8).empty;
    for (syms.items) |s| {
        const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ s.pkg, s.sym });
        try exported.put(key, {});
        const is_name = std.mem.eql(u8, s.kind, "name");
        const id_key = try std.fmt.allocPrint(a, "{s}\t{s}\t{s}", .{ s.pkg, if (is_name) "n" else "a", s.id });
        const used = ids.contains(id_key);
        const excepted = lrow.contains(key);
        const status: []const u8 = if (used) "used" else if (excepted) "excepted" else "undocumented";
        try sym_out.writer(a).print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ s.pkg, s.sym, s.kind, status, s.where });
        const gop = try counts.getOrPut(s.pkg);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const c = gop.value_ptr;
        c.n += 1;
        if (used) c.u += 1;
        if (is_name) {
            c.nn += 1;
            if (used) c.nu += 1;
        } else {
            c.mn += 1;
            if (used) c.mu += 1;
        }
        if (std.mem.eql(u8, status, "excepted")) c.ex += 1;
        if (std.mem.eql(u8, status, "undocumented")) {
            c.un += 1;
            try undoc.writer(a).print("{s}\t{s}\t{s}\n", .{ s.pkg, s.sym, s.where });
            if (enforce)
                try findings.writer(a).print("{s}{s}: {s} {s}: exported and used by no README example; use it in a ```mojo example of {s}/{s}/README.md, or give it a row in {s}\n", .{ prefix, s.where, s.pkg, s.sym, root, s.pkg, ledger_name });
        }
        if (used and excepted)
            try findings.writer(a).print("{s}:{d}: {s} {s}: {s}/{s}/README.md uses it now; delete the row (the ledger only shrinks)\n", .{ ledger_name, lrow.get(key).?, s.pkg, s.sym, root, s.pkg });
    }
    for (rows) |r| {
        const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ r.pkg, r.sym });
        if (!exported.contains(key))
            try findings.writer(a).print("{s}:{d}: {s} {s}: not exported by {s}/{s}/__init__.mojo; delete the row\n", .{ ledger_name, r.line, r.pkg, r.sym, root, r.pkg });
    }
    var tot = Count{};
    var np: usize = 0;
    var noinit = std.ArrayList(u8).empty;
    var noexp = std.ArrayList(u8).empty;
    var noreadme_list = std.ArrayList(u8).empty;
    var noreadme: u64 = 0;
    var table = std.ArrayList(u8).empty;
    for (pkgs.items) |p| {
        const c = counts.get(p.name) orelse Count{};
        const pc = try percent(a, c.u, c.n, "");
        try pk_out.writer(a).print("{s}\t{s}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ p.name, if (p.init) "yes" else "no", p.readme, c.n, c.u, pc, c.nn, c.nu, c.mn, c.mu, c.ex, c.un });
        np += 1;
        tot.n += c.n;
        tot.u += c.u;
        tot.nn += c.nn;
        tot.nu += c.nu;
        tot.mn += c.mn;
        tot.mu += c.mu;
        tot.ex += c.ex;
        tot.un += c.un;
        if (!p.init) {
            try noinit.writer(a).print(" {s}", .{p.name});
        } else if (c.n == 0) {
            try noexp.writer(a).print(" {s}", .{p.name});
        } else if (std.mem.eql(u8, p.readme, "none")) {
            noreadme += 1;
            try noreadme_list.writer(a).print(" {s}", .{p.name});
        }
        const pcs = try percent(a, c.u, c.n, "%");
        try table.writer(a).print("  {s:<40} {s:>6} {d:>5}/{d:<5} names {d}/{d} methods {d}/{d}  {s}\n", .{ p.name, pcs, c.u, c.n, c.nu, c.nn, c.mu, c.mn, p.readme });
    }
    var rep = std.ArrayList(u8).empty;
    const w = rep.writer(a);
    try w.print("README API coverage ({s})\n\n", .{if (enforce) "enforcing" else "report-only"});
    try w.print("packages: {d}; exported: {d}; used: {d} ({s}); names {d}/{d} ({s}); methods {d}/{d} ({s}); excepted: {d}; undocumented: {d}\n", .{
        np,     tot.n,                                    tot.u,  try percent(a, tot.u, tot.n, "%"),
        tot.nu, tot.nn,                                   try percent(a, tot.nu, tot.nn, "%"),
        tot.mu, tot.mn,                                   try percent(a, tot.mu, tot.mn, "%"),
        tot.ex, tot.un,
    });
    try w.print("packages with no __init__.mojo (nothing exported):{s}\n", .{if (noinit.items.len == 0) " none" else noinit.items});
    try w.print("packages whose __init__.mojo exports nothing (their API is their submodules, not counted):{s}\n", .{if (noexp.items.len == 0) " none" else noexp.items});
    try w.print("packages with an __init__.mojo and no README (0%): {d}{s}{s}\n", .{ noreadme, if (noreadme_list.items.len == 0) "" else ":", noreadme_list.items });
    try w.writeAll("\nby package: percent used/exported, names, methods, readme\n");
    try w.writeAll(table.items);
    try w.writeAll("\nnotes:\n");
    var nl = std.mem.splitScalar(u8, notes.items, '\n');
    while (nl.next()) |l| {
        if (nl.peek() == null and l.len == 0) break;
        try w.print("  {s}\n", .{l});
    }
    try w.writeAll("\nundocumented (package, symbol, where):\n");
    var ul = std.mem.splitScalar(u8, undoc.items, '\n');
    while (ul.next()) |l| {
        if (ul.peek() == null and l.len == 0) break;
        try w.print("  {s}\n", .{l});
    }

    // A fixture's assertion: the census equals the expected files.
    const outputs = [_][]const u8{ pk_out.items, sym_out.items, rep.items };
    for (outputs, 0..) |got, i| {
        const want_path = argv[13 + 2 * i];
        const want_name = argv[14 + 2 * i];
        if (std.mem.eql(u8, want_path, "-")) continue;
        const want = readAll(a, cwd, want_path);
        if (std.mem.eql(u8, want, got)) continue;
        try findings.writer(a).print("the census differs from {s} (- expected, + got):\n", .{want_name});
        if (try diff.unifiedDiff(a, "expected", "got", want, got)) |d| {
            var ls = std.mem.splitScalar(u8, d, '\n');
            var k: usize = 0;
            var emitted: usize = 0;
            while (ls.next()) |l| {
                if (ls.peek() == null and l.len == 0) break;
                k += 1;
                if (k <= 2) continue;
                if (emitted == 60) break;
                try findings.writer(a).print("{s}\n", .{l});
                emitted += 1;
            }
        }
    }
    if (names.len == 0) try findings.writer(a).print("readme_api_coverage: checked nothing (no package under {s})\n", .{root});

    writeFile(packages_out, pk_out.items);
    writeFile(symbols_out, sym_out.items);
    writeFile(report_out, rep.items);
    writeFile(findings_out, findings.items);
}

fn writeFile(path: []const u8, data: []const u8) void {
    const f = std.fs.cwd().createFile(path, .{}) catch |e| die("cannot create {s}: {s}", .{ path, @errorName(e) });
    defer f.close();
    f.writeAll(data) catch |e| die("cannot write {s}: {s}", .{ path, @errorName(e) });
}

/// The JSON string body of `findings`: its first 200 lines, control characters
/// but tab and newline dropped, backslash, quote and tab escaped, each line
/// ended by a `\n` escape.
pub fn escapedFindings(a: A, findings: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const ls = try scan.records(a, findings);
    for (ls[0..@min(ls.len, 200)]) |line| {
        for (line) |c| {
            switch (c) {
                0...8, 11...31 => {},
                '\\' => try out.appendSlice(a, "\\\\"),
                '"' => try out.appendSlice(a, "\\\""),
                '\t' => try out.appendSlice(a, "\\t"),
                else => try out.append(a, c),
            }
        }
        try out.appendSlice(a, "\\n");
    }
    return out.toOwnedSlice(a);
}

fn verdict(a: A, argv: []const []const u8) !void {
    if (argv.len != 5) die("usage: readme_api_coverage verdict <result.json> <findings.txt> <report.txt>", .{});
    const cwd = std.fs.cwd();
    const findings = readAll(a, cwd, argv[3]);
    const report = readAll(a, cwd, argv[4]);
    var totals: []const u8 = "";
    var it = std.mem.splitScalar(u8, report, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        n += 1;
        if (n == 3) totals = l;
    }
    var out = std.ArrayList(u8).empty;
    if (findings.len > 0) {
        const lines = std.mem.count(u8, findings, "\n");
        try out.writer(a).print("{{\"version\": 1, \"data\": {{\"status\": \"failure\", \"message\": \"readme_api_coverage: {d} finding line(s)\\n{s}\"}}}}\n", .{ lines, try escapedFindings(a, findings) });
    } else {
        try out.writer(a).print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"readme_api_coverage: {s}\"}}}}\n", .{totals});
    }
    writeFile(argv[2], out.items);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) die("the first argument is census or verdict", .{});
    if (std.mem.eql(u8, argv[1], "census")) return census(a, argv);
    if (std.mem.eql(u8, argv[1], "verdict")) return verdict(a, argv);
    die("the first argument is census or verdict", .{});
}
