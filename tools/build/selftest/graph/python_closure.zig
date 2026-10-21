//! python_closure: the checker of the graph check of that name (checks.bxl).
//!
//! Python serves only komira's Python surface (its SDK or bindings and their
//! own tests). Outside the allowlist, the check refuses:
//!
//!   target <label>  a target of the closure whose own closure holds a
//!                   Python marker: a target under third_party/python/ or
//!                   tools/build/python/, a Python rule kind (one whose name
//!                   holds `python` or starts with `py_`), or a `.py`
//!                   source. Every kind of dependency counts (target, exec,
//!                   toolchain), as checks.bxl collects them. A doc_tree
//!                   (tools/build/lint/doc_tree.bzl) is not walked: its
//!                   files are data the lints read, every file of a
//!                   package, and the `file` findings below see its `.py`.
//!   file <path>     a `.py` file of the repository's trees.
//!   exec <path>     a kci textproto whose `executable:` is a Python
//!                   interpreter, or a GitHub workflow or action with a
//!                   `run:` line that runs one or a `setup-python` step.
//!
//! The allowlist is the graph_check's two lists. `surface` holds package
//! paths (`src/<pkg>`): a finding of a target or path inside one is
//! allowed. `ceiling` holds findings exactly as this checker spells them;
//! each must still be found, so the list only shrinks: removing a violator
//! without its entry fails the check, as adding one without an entry does.
//!
//! The facts (checks.bxl) are tab-separated lines:
//!
//!   node <configured label> <label> <rule kind>
//!   dep <configured label> <configured label of a direct dependency>
//!   src <configured label> <path of a source file>
//!   file <path>        scan <path>        surface <path>        ceiling <finding>
const std = @import("std");

pub const Outcome = struct {
    /// Fact lines read.
    facts: usize,
    nodes: usize,
    files: usize,
    scanned: usize,
    /// Findings the allowlist allows, in the surface and in the ceiling.
    allowed: usize,
    /// Every refusal, one message each: a finding outside the allowlist, a
    /// ceiling entry no longer found or given twice, a malformed fact.
    refused: []const []const u8,
};

const Node = struct {
    label: []const u8,
    kind: []const u8,
    deps: std.ArrayList(usize),
    /// Why the node itself is a marker, or null.
    own: ?[]const u8 = null,
    data_tree: bool = false,
    state: enum { unvisited, visiting, done } = .unvisited,
    /// The marker node its closure reaches, when it reaches one.
    reach: ?usize = null,
};

/// A rule kind's name: `cell//path.bzl:_name_rule` -> `name`.
pub fn kindName(kind: []const u8) []const u8 {
    var k = kind;
    if (std.mem.lastIndexOfScalar(u8, k, ':')) |i| k = k[i + 1 ..];
    while (k.len > 0 and k[0] == '_') k = k[1..];
    if (std.mem.endsWith(u8, k, "_rule")) k = k[0 .. k.len - "_rule".len];
    return k;
}

/// The prelude's C/C++ rules name Python helper programs
/// (`python_bootstrap_binary`) as attributes, run by the `python_bootstrap`
/// toolchain's interpreter. komira's python_bootstrap toolchain
/// (tools/build/mojo/cxx.bzl) provides none: running a helper fails. So that
/// toolchain is not Python, and a helper is Python only when its closure
/// reaches a python_bootstrap toolchain that does provide an interpreter (any
/// other Python rule kind), never by its own kind or `.py` sources.
const NO_INTERPRETER = "no_python_bootstrap_toolchain";
const NO_INTERPRETER_FILE = "//tools/build/mojo/cxx.bzl";
const BOOTSTRAP_HELPER = "python_bootstrap_binary";

pub fn isPythonKind(kind: []const u8) bool {
    const k = kindName(kind);
    // The kind is `<cell>//tools/build/mojo/cxx.bzl[@<loading cell>]:<rule>`.
    const in_file = std.mem.indexOf(u8, kind, NO_INTERPRETER_FILE ++ ":") != null or std.mem.indexOf(u8, kind, NO_INTERPRETER_FILE ++ "@") != null;
    if (std.mem.eql(u8, k, NO_INTERPRETER) and in_file) return false;
    if (std.mem.eql(u8, k, BOOTSTRAP_HELPER)) return false;
    return std.mem.indexOf(u8, k, "python") != null or std.mem.startsWith(u8, k, "py_");
}

/// `cell//a/b:c` -> `a/b`.
fn packageOf(label: []const u8) []const u8 {
    const s = if (std.mem.indexOf(u8, label, "//")) |i| label[i + 2 ..] else label;
    return if (std.mem.indexOfScalar(u8, s, ':')) |i| s[0..i] else s;
}

fn cellOf(label: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, label, "//")) |i| label[0..i] else "";
}

fn under(path: []const u8, dir: []const u8) bool {
    return std.mem.eql(u8, path, dir) or (std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/');
}

const PYTHON_DIRS = [_][]const u8{ "third_party/python", "tools/build/python" };

/// Whether `word` names a Python interpreter: `python`, `python3`,
/// `python3.12`, with any directory and quotes around it.
pub fn isPythonExe(word: []const u8) bool {
    var w = std.mem.trim(u8, word, "\"'");
    if (std.mem.lastIndexOfScalar(u8, w, '/')) |i| w = w[i + 1 ..];
    if (!std.mem.startsWith(u8, w, "python")) return false;
    for (w["python".len..]) |c| if (!std.ascii.isDigit(c) and c != '.') return false;
    return true;
}

/// The Python a textproto line runs: `executable: "<python>"`.
pub fn textprotoRunsPython(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, s, "executable:")) return false;
    return isPythonExe(std.mem.trim(u8, s["executable:".len..], " \t"));
}

/// The Python a workflow line runs: a `run:` line or a line of a `run: |`
/// block whose first word is a Python interpreter, or a `setup-python` step.
pub fn workflowRunsPython(line: []const u8) bool {
    var s = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, s, "- ")) s = std.mem.trimLeft(u8, s[2..], " \t");
    if (std.mem.startsWith(u8, s, "uses:") and std.mem.indexOf(u8, s, "setup-python") != null) return true;
    if (std.mem.startsWith(u8, s, "run:")) s = std.mem.trimLeft(u8, s["run:".len..], " \t");
    var words = std.mem.tokenizeAny(u8, s, " \t");
    const first = words.next() orelse return false;
    return isPythonExe(first);
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

fn reach(nodes: []Node, i: usize) ?usize {
    const n = &nodes[i];
    switch (n.state) {
        .done => return n.reach,
        // A cycle cannot be configured; were one here, it adds nothing new.
        .visiting => return null,
        .unvisited => {},
    }
    n.state = .visiting;
    var r: ?usize = null;
    if (!n.data_tree) {
        if (n.own != null) r = i else for (n.deps.items) |d| {
            if (reach(nodes, d)) |m| {
                r = m;
                break;
            }
        }
    }
    nodes[i].state = .done;
    nodes[i].reach = r;
    return r;
}

const Finding = struct { key: []const u8, why: []const u8, subject: []const u8, in_cell: bool };

/// Checks `facts`. `texts` holds the contents of each `scan` path.
pub fn pythonClosure(a: std.mem.Allocator, cell: []const u8, facts: []const u8, texts: *const std.StringHashMap([]const u8)) !Outcome {
    var refused = std.ArrayList([]const u8).empty;
    var nodes = std.ArrayList(Node).empty;
    var index = std.StringHashMap(usize).init(a);
    var files = std.ArrayList([]const u8).empty;
    var scans = std.ArrayList([]const u8).empty;
    var surface = std.ArrayList([]const u8).empty;
    var ceiling = std.ArrayList([]const u8).empty;
    const Edge = struct { from: []const u8, to: []const u8 };
    var edges = std.ArrayList(Edge).empty;
    const Src = struct { node: []const u8, path: []const u8 };
    var srcs = std.ArrayList(Src).empty;
    var n_facts: usize = 0;

    var it = std.mem.splitScalar(u8, facts, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n_facts += 1;
        var f: [4][]const u8 = undefined;
        const n = fields(line, &f);
        const kind = f[0];
        const want: usize = if (std.mem.eql(u8, kind, "node")) 4 else if (std.mem.eql(u8, kind, "dep") or std.mem.eql(u8, kind, "src")) 3 else 2;
        if (n != want) {
            try refused.append(a, try std.fmt.allocPrint(a, "a malformed fact: {s}", .{line}));
            continue;
        }
        if (std.mem.eql(u8, kind, "node")) {
            const g = try index.getOrPut(f[1]);
            if (g.found_existing) continue;
            g.value_ptr.* = nodes.items.len;
            try nodes.append(a, .{ .label = f[2], .kind = f[3], .deps = std.ArrayList(usize).empty });
        } else if (std.mem.eql(u8, kind, "dep")) {
            try edges.append(a, .{ .from = f[1], .to = f[2] });
        } else if (std.mem.eql(u8, kind, "src")) {
            try srcs.append(a, .{ .node = f[1], .path = f[2] });
        } else if (std.mem.eql(u8, kind, "file")) {
            try files.append(a, f[1]);
        } else if (std.mem.eql(u8, kind, "scan")) {
            try scans.append(a, f[1]);
        } else if (std.mem.eql(u8, kind, "surface")) {
            try surface.append(a, f[1]);
        } else if (std.mem.eql(u8, kind, "ceiling")) {
            try ceiling.append(a, f[1]);
        } else {
            try refused.append(a, try std.fmt.allocPrint(a, "a malformed fact: {s}", .{line}));
        }
    }

    // The graph: every dependency and source names a node of the facts, so
    // the closure the checker walks is the one checks.bxl collected.
    for (edges.items) |e| {
        const from = index.get(e.from);
        const to = index.get(e.to);
        if (from == null or to == null) {
            try refused.append(a, try std.fmt.allocPrint(a, "the facts are not a closure: the dependency {s} -> {s} names a node they do not hold", .{ e.from, e.to }));
            continue;
        }
        try nodes.items[from.?].deps.append(a, to.?);
    }
    for (nodes.items) |*nd| {
        nd.data_tree = std.mem.eql(u8, kindName(nd.kind), "doc_tree");
        for (PYTHON_DIRS) |d| {
            if (nd.own == null and under(packageOf(nd.label), d)) nd.own = try std.fmt.allocPrint(a, "it is under {s}/", .{d});
        }
        if (nd.own == null and isPythonKind(nd.kind)) nd.own = try std.fmt.allocPrint(a, "it is a Python rule ({s})", .{kindName(nd.kind)});
    }
    for (srcs.items) |s| {
        const i = index.get(s.node) orelse {
            try refused.append(a, try std.fmt.allocPrint(a, "the facts are not a closure: the source {s} is of a node they do not hold ({s})", .{ s.path, s.node }));
            continue;
        };
        if (std.mem.eql(u8, kindName(nodes.items[i].kind), BOOTSTRAP_HELPER)) continue;
        if (nodes.items[i].own == null and std.mem.endsWith(u8, s.path, ".py")) nodes.items[i].own = try std.fmt.allocPrint(a, "it has the Python source {s}", .{s.path});
    }

    var found = std.ArrayList(Finding).empty;
    var seen = std.StringHashMap(void).init(a);
    for (nodes.items, 0..) |nd, i| {
        const m = reach(nodes.items, i) orelse continue;
        const key = try std.fmt.allocPrint(a, "target {s}", .{nd.label});
        if ((try seen.getOrPut(key)).found_existing) continue;
        const marker = nodes.items[m];
        const why = if (m == i) marker.own.? else try std.fmt.allocPrint(a, "its closure holds {s}: {s}", .{ marker.label, marker.own.? });
        try found.append(a, .{ .key = key, .why = why, .subject = packageOf(nd.label), .in_cell = std.mem.eql(u8, cellOf(nd.label), cell) });
    }
    for (files.items) |p| {
        if (!std.mem.endsWith(u8, p, ".py")) continue;
        const key = try std.fmt.allocPrint(a, "file {s}", .{p});
        if ((try seen.getOrPut(key)).found_existing) continue;
        try found.append(a, .{ .key = key, .why = "a Python file", .subject = p, .in_cell = true });
    }
    for (scans.items) |p| {
        const text = texts.get(p) orelse {
            try refused.append(a, try std.fmt.allocPrint(a, "cannot read the scanned file {s}", .{p}));
            continue;
        };
        const textproto = std.mem.endsWith(u8, p, ".textproto");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var no: usize = 0;
        var hits = std.ArrayList(u8).empty;
        while (lines.next()) |l| {
            no += 1;
            const hit = if (textproto) textprotoRunsPython(l) else workflowRunsPython(l);
            if (!hit) continue;
            try hits.writer(a).print("{s}line {d}: {s}", .{ @as([]const u8, if (hits.items.len > 0) "; " else ""), no, std.mem.trim(u8, l, " \t\r") });
        }
        if (hits.items.len == 0) continue;
        const key = try std.fmt.allocPrint(a, "exec {s}", .{p});
        if ((try seen.getOrPut(key)).found_existing) continue;
        try found.append(a, .{ .key = key, .why = try std.fmt.allocPrint(a, "it runs Python ({s})", .{hits.items}), .subject = p, .in_cell = true });
    }

    // The allowlist.
    const used = try a.alloc(bool, ceiling.items.len);
    @memset(used, false);
    var allowed: usize = 0;
    for (ceiling.items, 0..) |c, i| {
        for (ceiling.items[0..i]) |d| if (std.mem.eql(u8, c, d)) {
            try refused.append(a, try std.fmt.allocPrint(a, "the ceiling names `{s}` twice", .{c}));
            break;
        };
    }
    for (found.items) |fd| {
        var ok = false;
        if (fd.in_cell) for (surface.items) |s| {
            if (under(fd.subject, s)) ok = true;
        };
        if (!ok) for (ceiling.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, fd.key)) {
                used[i] = true;
                ok = true;
            }
        };
        if (ok) {
            allowed += 1;
            continue;
        }
        try refused.append(a, try std.fmt.allocPrint(a, "{s}: {s}; Python serves only the Python surface", .{ fd.key, fd.why }));
    }
    for (ceiling.items, 0..) |c, i| {
        if (used[i]) continue;
        try refused.append(a, try std.fmt.allocPrint(a, "the ceiling entry `{s}` is no longer found: delete it (the ceiling only shrinks)", .{c}));
    }
    return .{ .facts = n_facts, .nodes = nodes.items.len, .files = files.items.len, .scanned = scans.items.len, .allowed = allowed, .refused = try refused.toOwnedSlice(a) };
}

// ---- Unit tests: facts the check must refuse, and ones it must pass. ----

const t = std.testing;

fn run(a: std.mem.Allocator, facts: []const u8, scanned: []const [2][]const u8) !Outcome {
    var texts = std.StringHashMap([]const u8).init(a);
    for (scanned) |s| try texts.put(s[0], s[1]);
    return pythonClosure(a, "komira", facts, &texts);
}

fn holds(o: Outcome, want: []const u8) bool {
    for (o.refused) |r| if (std.mem.indexOf(u8, r, want) != null) return true;
    return false;
}

// A Mojo library with a test that depends, through an exec dependency, on
// a CPython: the shape komira_tls_interop_e2e has today.
const LIB_REACHES_CPYTHON =
    "node\tkomira//src/a:a (cfg)\tkomira//src/a:a\tkomira//tools/build/mojo/library.bzl:_mojo_library\n" ++
    "node\tkomira//src/a:peer (cfg)\tkomira//src/a:peer\tprelude//rules.bzl:genrule\n" ++
    "node\tkomira//third_party/python:cpython (exec)\tkomira//third_party/python:cpython\tkomira//tools/build/mojo/download.bzl:pinned_file\n" ++
    "dep\tkomira//src/a:a (cfg)\tkomira//src/a:peer (cfg)\n" ++
    "dep\tkomira//src/a:peer (cfg)\tkomira//third_party/python:cpython (exec)\n" ++
    "src\tkomira//src/a:a (cfg)\tsrc/a/a.mojo\n";

test "a library whose closure holds third_party/python is refused, with the path to it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), LIB_REACHES_CPYTHON, &.{});
    try t.expectEqual(@as(usize, 3), o.nodes);
    try t.expectEqual(@as(usize, 3), o.refused.len);
    try t.expect(holds(o, "target komira//src/a:a: its closure holds komira//third_party/python:cpython: it is under third_party/python/"));
    try t.expect(holds(o, "target komira//src/a:peer: its closure holds komira//third_party/python:cpython"));
    try t.expect(holds(o, "target komira//third_party/python:cpython: it is under third_party/python/"));
}

test "the same library is held by an exact ceiling, and passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), LIB_REACHES_CPYTHON ++
        "ceiling\ttarget komira//src/a:a\nceiling\ttarget komira//src/a:peer\nceiling\ttarget komira//third_party/python:cpython\n", &.{});
    try t.expectEqual(@as(usize, 0), o.refused.len);
    try t.expectEqual(@as(usize, 3), o.allowed);
}

test "a ceiling entry no longer found is stale and refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), LIB_REACHES_CPYTHON ++
        "ceiling\ttarget komira//src/a:a\nceiling\ttarget komira//src/a:peer\nceiling\ttarget komira//third_party/python:cpython\n" ++
        "ceiling\ttarget komira//src/tests/helpers/gone:gone\nceiling\ttarget komira//src/a:a\n", &.{});
    try t.expectEqual(@as(usize, 2), o.refused.len);
    try t.expect(holds(o, "the ceiling entry `target komira//src/tests/helpers/gone:gone` is no longer found"));
    try t.expect(holds(o, "the ceiling names `target komira//src/a:a` twice"));
}

test "a ceiling entry spelt for one finding allows no other" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), LIB_REACHES_CPYTHON ++ "ceiling\ttarget komira//src/a:a\n", &.{});
    try t.expectEqual(@as(usize, 2), o.refused.len);
    try t.expectEqual(@as(usize, 1), o.allowed);
}

test "a surface package allows its own targets, not a library outside it that depends on one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const facts =
        "node\tkomira//src/komira_py:komira_py (cfg)\tkomira//src/komira_py:komira_py\tkomira//tools/build/python/defs.bzl:_py_test\n" ++
        "node\tkomira//src/komira_py/tests:t (cfg)\tkomira//src/komira_py/tests:t\tprelude//rules.bzl:genrule\n" ++
        "node\tkomira//src/b:b (cfg)\tkomira//src/b:b\tkomira//tools/build/mojo/library.bzl:_mojo_library\n" ++
        "node\ttests//src/komira_py:x (cfg)\ttests//src/komira_py:x\tprelude//rules.bzl:genrule\n" ++
        "dep\tkomira//src/komira_py/tests:t (cfg)\tkomira//src/komira_py:komira_py (cfg)\n" ++
        "dep\tkomira//src/b:b (cfg)\tkomira//src/komira_py:komira_py (cfg)\n" ++
        "dep\ttests//src/komira_py:x (cfg)\tkomira//src/komira_py:komira_py (cfg)\n" ++
        "file\tsrc/komira_py/sdk.py\nsurface\tsrc/komira_py\n";
    const o = try run(arena.allocator(), facts, &.{});
    try t.expectEqual(@as(usize, 3), o.allowed);
    try t.expectEqual(@as(usize, 2), o.refused.len);
    try t.expect(holds(o, "target komira//src/b:b: its closure holds komira//src/komira_py:komira_py: it is a Python rule (py_test)"));
    // The surface is a path of the check's cell: another cell's package of the same path is not in it.
    try t.expect(holds(o, "target tests//src/komira_py:x:"));
}

test "a stray .py file is refused; .pyx, .py.txt and a directory named .py are not Python files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), "file\tsrc/a/foo.py\nfile\tsrc/a/foo.pyx\nfile\tsrc/a/foo.py.txt\nfile\tsrc/a.py/BUCK\nfile\tsrc/a/a.mojo\n", &.{});
    try t.expectEqual(@as(usize, 5), o.files);
    try t.expectEqual(@as(usize, 1), o.refused.len);
    try t.expect(holds(o, "file src/a/foo.py: a Python file"));
}

test "a .py source of a target is a marker, for it and for what depends on it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const facts =
        "node\tkomira//src/a:gen (cfg)\tkomira//src/a:gen\tprelude//rules.bzl:genrule\n" ++
        "node\tkomira//src/a:script (cfg)\tkomira//src/a:script\tprelude//rules.bzl:export_file\n" ++
        "dep\tkomira//src/a:gen (cfg)\tkomira//src/a:script (cfg)\n" ++
        "src\tkomira//src/a:script (cfg)\tsrc/a/make_fixture.py\n";
    const o = try run(arena.allocator(), facts, &.{});
    try t.expectEqual(@as(usize, 2), o.refused.len);
    try t.expect(holds(o, "target komira//src/a:script: it has the Python source src/a/make_fixture.py"));
    try t.expect(holds(o, "target komira//src/a:gen: its closure holds komira//src/a:script"));
}

test "a doc_tree's .py files are data: neither it nor a lint reading it is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const facts =
        "node\tkomira//:docs (cfg)\tkomira//:docs\tkomira//tools/build/lint/defs.bzl:_markdown_docs\n" ++
        "node\tkomira//:doc_tree (cfg)\tkomira//:doc_tree\tkomira//tools/build/lint/doc_tree.bzl:doc_tree\n" ++
        "node\tkomira//tools/build/python:doc_tree (cfg)\tkomira//tools/build/python:doc_tree\tkomira//tools/build/lint/doc_tree.bzl:doc_tree\n" ++
        "dep\tkomira//:docs (cfg)\tkomira//:doc_tree (cfg)\n" ++
        "dep\tkomira//:doc_tree (cfg)\tkomira//tools/build/python:doc_tree (cfg)\n" ++
        "src\tkomira//tools/build/python:doc_tree (cfg)\ttools/build/python/pyrun.py\n";
    const o = try run(arena.allocator(), facts, &.{});
    try t.expectEqual(@as(usize, 0), o.refused.len);
}

test "the Python rule kinds, and the kinds that are not" {
    try t.expect(isPythonKind("komira//tools/build/python/defs.bzl:_py_test"));
    try t.expect(isPythonKind("komira//tools/build/python/defs.bzl:_python_oracle"));
    try t.expect(isPythonKind("komira//tools/build/python/defs.bzl:_python_wheel"));
    try t.expect(isPythonKind("prelude//rules.bzl:python_binary"));
    try t.expect(isPythonKind("prelude//rules.bzl:prebuilt_python_library"));
    try t.expect(!isPythonKind("komira//tools/build/mojo/library.bzl:_mojo_library"));
    try t.expect(!isPythonKind("prelude//rules.bzl:genrule"));
    try t.expect(!isPythonKind("komira//tools/build/selftest/defs.bzl:graph_check_rule"));
    try t.expectEqualStrings("doc_tree", kindName("komira//tools/build/lint/doc_tree.bzl:doc_tree"));
    try t.expectEqualStrings("zig_exe", kindName("komira//tools/build/mojo/toolchain.bzl:zig_exe_rule"));
}

test "a textproto whose executable is python3 is refused; one that only mentions it is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const proto =
        "# `python3 release/ci/check.py --from x` prints it\n" ++
        "  validation {\n    executable: \"python3\"\n    args: \"release/ci/check.py\"\n  }\n" ++
        "  build_system {\n    executable: \"buck2\"\n  }\n";
    const o = try run(arena.allocator(), "scan\trelease/artifacts.textproto\nscan\trelease/machine.textproto\n", &.{
        .{ "release/artifacts.textproto", proto },
        .{ "release/machine.textproto", "executable: \"buck2\"\n# conda pulls python for mojo-python\n" },
    });
    try t.expectEqual(@as(usize, 1), o.refused.len);
    try t.expect(holds(o, "exec release/artifacts.textproto: it runs Python (line 3: executable: \"python3\")"));
}

test "a workflow that runs python or sets it up is refused; one that names it otherwise is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const red = "      - name: Alert\n        run: python3 -I tools/alert.py --repo x\n";
    const block = "    steps:\n      - run: |\n          set -e\n          /usr/bin/python3.12 x.py\n";
    const setup = "      - uses: actions/setup-python@0123456789abcdef0123456789abcdef01234567\n";
    const clean = "      - name: python tests are gone\n        run: ./buck2 build //...  # not python3\n";
    const o = try run(arena.allocator(), "scan\t.github/workflows/red.yml\nscan\t.github/workflows/block.yml\nscan\t.github/actions/s/action.yml\nscan\t.github/workflows/clean.yml\n", &.{
        .{ ".github/workflows/red.yml", red },
        .{ ".github/workflows/block.yml", block },
        .{ ".github/actions/s/action.yml", setup },
        .{ ".github/workflows/clean.yml", clean },
    });
    try t.expectEqual(@as(usize, 4), o.scanned);
    try t.expectEqual(@as(usize, 3), o.refused.len);
    try t.expect(holds(o, "exec .github/workflows/red.yml: it runs Python (line 2: run: python3 -I tools/alert.py --repo x)"));
    try t.expect(holds(o, "exec .github/workflows/block.yml: it runs Python (line 4:"));
    try t.expect(holds(o, "exec .github/actions/s/action.yml"));
}

test "the interpreter names" {
    try t.expect(isPythonExe("python"));
    try t.expect(isPythonExe("\"python3\""));
    try t.expect(isPythonExe("/usr/bin/python3.12"));
    try t.expect(!isPythonExe("pythonic"));
    try t.expect(!isPythonExe("buck2"));
    try t.expect(!isPythonExe("py"));
}

test "facts that are not a closure, or not facts, are refused rather than read as none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), "node\tkomira//src/a:a (cfg)\tkomira//src/a:a\tk\ndep\tkomira//src/a:a (cfg)\tkomira//third_party/python:cpython (exec)\nbogus\tx\nfile\n", &.{});
    try t.expectEqual(@as(usize, 3), o.refused.len);
    try t.expect(holds(o, "the facts are not a closure: the dependency komira//src/a:a (cfg) -> komira//third_party/python:cpython (exec)"));
    try t.expect(holds(o, "a malformed fact: bogus\tx"));
    try t.expect(holds(o, "a malformed fact: file"));
}

test "a scanned file the checker was not given is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), "scan\trelease/artifacts.textproto\n", &.{});
    try t.expect(holds(o, "cannot read the scanned file release/artifacts.textproto"));
}

// A C library of the prelude names the Python helper create_build, run by
// the python_bootstrap toolchain: the shape of every cxx_library today.
fn bootstrapFacts(comptime toolchain_kind: []const u8) []const u8 {
    return "node\tkomira//third_party/zstd:zstd (cfg)\tkomira//third_party/zstd:zstd\tprelude//rules.bzl:cxx_library\n" ++
        "node\tprelude//third-party/tools:create_build (cfg)\tprelude//third-party/tools:create_build\tprelude//rules.bzl:python_bootstrap_binary\n" ++
        "node\ttoolchains//:python_bootstrap (cfg)\ttoolchains//:python_bootstrap\t" ++ toolchain_kind ++ "\n" ++
        "dep\tkomira//third_party/zstd:zstd (cfg)\tprelude//third-party/tools:create_build (cfg)\n" ++
        "dep\tprelude//third-party/tools:create_build (cfg)\ttoolchains//:python_bootstrap (cfg)\n" ++
        "src\tprelude//third-party/tools:create_build (cfg)\tprelude/third-party/tools/create_build.py\n";
}

test "a prelude Python helper run by komira's interpreter-less bootstrap toolchain is not Python" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), bootstrapFacts("komira//tools/build/mojo/cxx.bzl@toolchains:no_python_bootstrap_toolchain"), &.{});
    try t.expectEqual(@as(usize, 0), o.refused.len);
}

test "the same helper under a bootstrap toolchain that provides an interpreter is refused, with every C library naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const o = try run(arena.allocator(), bootstrapFacts("prelude//rules.bzl:python_bootstrap_toolchain"), &.{});
    try t.expectEqual(@as(usize, 3), o.refused.len);
    try t.expect(holds(o, "target komira//third_party/zstd:zstd: its closure holds toolchains//:python_bootstrap: it is a Python rule (python_bootstrap_toolchain)"));
    // A rule of another file named like komira's is not komira's.
    const p = try run(arena.allocator(), bootstrapFacts("other//x.bzl:no_python_bootstrap_toolchain"), &.{});
    try t.expectEqual(@as(usize, 3), p.refused.len);
}
