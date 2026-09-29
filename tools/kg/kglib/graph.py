"""The Buck2 code graph: every target in the configured universe, its rule kind, its deps, its
sources and its welded test files, committed as one sorted JSON file (docs/kg.toml [graph] out).

TWO HALVES, AND ONLY ONE NEEDS BUCK2.

* `export` runs ONE `buck2 uquery` (loading only: no configuration, no actions, no remote
  execution) and renders the file. The query runs in a scratch checkout of the tree being
  graphed (the index, or a commit), never in the working tree: a `.buckconfig.local`, an
  untracked file or an ignored file there would change what buck2 loads, and a contributor's
  machine would render bytes a clean CI checkout cannot. `[graph] config` passes `-c`
  overrides so that clean tree loads every package; the overridden values appear nowhere in
  the output.
* Every cell in `.buckconfig` [cells] is either queried (`<cell>//...` in `[graph] universe`)
  or named in `[graph] exclude`. A cell in neither is refused, so a new cell cannot go
  unindexed while the graph still reads as fresh.
* `fingerprint` is pure: a digest of every input the query reads that git can see -- the
  build files, every `.bzl`, `.buckconfig`, the buck2 pin, and the PATHS (not contents) of
  the files inside a package, since a glob depends on paths. The file records it, so the
  hooks can tell "the graph was rendered from other inputs" without buck2, in milliseconds.
  Only the CI job, with buck2, proves the bytes.

Queries (`deps`, `rdeps`, `tests`, `owner`) read the committed file; they run no buck2.
"""
from __future__ import annotations

import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import tempfile

from . import KgError
from .layer1 import cells

GRAPH_FORMAT = 1
PIN = "tools/buck2"


def _owned(tree, cfg):
    """Tracked paths inside some package (a directory, or an ancestor, holding a build file)."""
    pkgs = {posixpath.dirname(p) for p in tree.paths() if posixpath.basename(p) in cfg.build_files}
    res = []
    for p in tree.paths():
        d = posixpath.dirname(p)
        while True:
            if d in pkgs:
                res.append(p)
                break
            if not d:
                break
            d = posixpath.dirname(d)
    return sorted(res)


def fingerprint(tree, cfg):
    h = hashlib.sha256()
    h.update(b"kg-graph %d\n" % GRAPH_FORMAT)
    for x in cfg.graph_universe + ["-c"] + cfg.graph_config:
        h.update(x.encode() + b"\n")
    inputs = sorted(p for p in tree.paths()
                    if posixpath.basename(p) in cfg.build_files or p.endswith(".bzl")
                    or p in (".buckconfig", PIN))
    for p in inputs:
        h.update(("C %s %s\n" % (p, tree.oid(p))).encode())
    for p in _owned(tree, cfg):
        h.update(("P %s\n" % p).encode())
    return h.hexdigest()


def find_buck2(root):
    """$BUCK2, then `buck2` on PATH. None when neither exists (tools/buck2 needs dotslash)."""
    b = os.environ.get("BUCK2")
    if b:
        return b
    return shutil.which("buck2")


def _universe_cell(pattern, root_cell):
    """The cell a universe entry covers whole (`cell//...`, or `//...` for the root cell); None
    for any narrower pattern."""
    if not pattern.endswith("//..."):
        return None
    return pattern[:-len("//...")] or root_cell


def uncovered_cells(tree, cfg):
    """Problems with the universe against `.buckconfig` [cells]: a cell neither queried whole nor
    excluded, and an excluded or queried cell that [cells] does not declare. [] when none."""
    cellmap = cells(tree)
    declared = [c for _, c in cellmap]
    root_cell = next((c for d, c in cellmap if d == ""), None)
    queried = {_universe_cell(u, root_cell) for u in cfg.graph_universe} - {None}
    res = ["cell `%s` is in .buckconfig [cells] but neither in [graph] universe (as `%s//...`) nor in "
           "[graph] exclude" % (c, "" if c == root_cell else c)
           for c in sorted(set(declared) - queried - set(cfg.graph_exclude))]
    res += ["[graph] %s names cell `%s`, which .buckconfig [cells] does not declare" % (k, c)
            for k, names in (("universe", queried), ("exclude", set(cfg.graph_exclude)))
            for c in sorted(names - set(declared))]
    res += ["cell `%s` is both queried and excluded" % c for c in sorted(queried & set(cfg.graph_exclude))]
    return res


def query_expr(cfg):
    return 'kind(".*", %s)' % " + ".join(cfg.graph_universe)


def _path(cellmap, lab):
    """A source label `cell//dir/file` -> the repository path; a target label is kept."""
    if ":" in lab or "//" not in lab:
        return lab
    cell, rel = lab.split("//", 1)
    for d, c in cellmap:
        if c == cell:
            return posixpath.join(d, rel) if d else rel
    return lab


def normalize(raw, cellmap):
    """uquery JSON (label -> attributes) -> the committed model. Sorted, empty lists dropped."""
    targets = {}
    for lab in sorted(raw):
        a = raw[lab]
        t = {"kind": a.get("buck.type") or "?"}
        for key, src in (("deps", "buck.deps"), ("srcs", "srcs"), ("test_srcs", "test_srcs")):
            v = a.get(src) or []
            if isinstance(v, dict):
                v = list(v.values())
            if not isinstance(v, list):
                continue
            v = sorted({_path(cellmap, x) if key != "deps" else x for x in v if isinstance(x, str)})
            if v:
                t[key] = v
        targets[lab] = t
    return targets


def render(targets, fp, cfg):
    doc = {"format": GRAPH_FORMAT,
           "generated_by": "python3 tools/kg/kg.py graph",
           "query": query_expr(cfg),
           "inputs": fp,
           "targets": targets}
    return (json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _checkout(root, treeish, dest):
    """Write `treeish` (a commit, or None for the index) under `dest`. Only what git tracks lands
    there: no `.buckconfig.local`, no untracked or ignored file, no unstaged edit."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    if treeish is not None:
        env["GIT_INDEX_FILE"] = dest.rstrip("/") + ".index"
        steps = [["read-tree", treeish]]
    else:
        steps = []      # the index being graphed: $GIT_INDEX_FILE when a hook set it
    steps.append(["checkout-index", "-a", "-f", "--prefix=%s/" % dest.rstrip("/")])
    for args in steps:
        r = subprocess.run(["git", *args], cwd=root, capture_output=True, env=env)
        if r.returncode != 0:
            err = r.stderr.decode("utf-8", "replace").strip().splitlines()
            raise KgError("git %s failed: %s" % (args[0], err[0] if err else "exit %d" % r.returncode))


def export(root, tree, cfg, buck2, treeish=None):
    """Check `tree` (the index, or the commit `treeish`) out into a scratch directory, run the
    query there, and return the rendered bytes."""
    bad = uncovered_cells(tree, cfg)
    if bad:
        raise KgError("the Buck2 graph would not index every cell: %s" % "; ".join(bad))
    scratch = tempfile.mkdtemp(prefix="kg-graph-")
    work = os.path.join(scratch, "tree")
    try:
        _checkout(root, treeish, work)
        return render(normalize(_uquery(work, cfg, buck2), cells(tree)), fingerprint(tree, cfg), cfg)
    finally:
        try:
            subprocess.run([buck2, "--isolation-dir", "kg", "kill"], cwd=work, capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            pass
        shutil.rmtree(scratch, ignore_errors=True)


def _uquery(work, cfg, buck2):
    # Its own isolation dir, in its own scratch project: its own daemon, killed afterwards.
    argv = [buck2, "--isolation-dir", "kg", "uquery"]
    for c in cfg.graph_config:
        argv += ["-c", c]
    argv += [query_expr(cfg), "--json", "--output-attribute", "buck.type|buck.deps|srcs|test_srcs"]
    try:
        r = subprocess.run(argv, cwd=work, capture_output=True, timeout=600)
    except FileNotFoundError:
        raise KgError("buck2 not found at %r; set BUCK2=/path/to/buck2" % buck2)
    if r.returncode != 0:
        err = [l for l in r.stderr.decode("utf-8", "replace").splitlines() if l.strip()]
        raise KgError("buck2 uquery failed (exit %d): %s" % (r.returncode, " | ".join(err[-6:])))
    try:
        raw = json.loads(r.stdout)
    except ValueError as e:
        raise KgError("buck2 uquery printed something that is not JSON (%s)" % e)
    if not raw:
        raise KgError("buck2 uquery returned no targets for %s; an empty graph is refused, not "
                      "written" % query_expr(cfg))
    return raw


def load(tree, cfg):
    """The committed graph of `tree`, parsed; None when absent."""
    got = tree.read([cfg.graph_out]).get(cfg.graph_out)
    if got is None:
        return None
    try:
        doc = json.loads(got)
    except ValueError as e:
        raise KgError("%s is not JSON (%s); regenerate it: python3 tools/kg/kg.py graph" % (cfg.graph_out, e))
    if doc.get("format") != GRAPH_FORMAT:
        raise KgError("%s has format %r; this kg reads %d" % (cfg.graph_out, doc.get("format"), GRAPH_FORMAT))
    return doc


def stale_reason(tree, cfg):
    """None when the committed graph was rendered from this tree's inputs; else why not."""
    if not cfg.graph_out:
        return None
    bad = uncovered_cells(tree, cfg)
    if bad:
        return ("the graph does not index every cell: %s (name each cell in docs/kg.toml [graph] universe or "
                "exclude first)" % "; ".join(bad))
    doc = load(tree, cfg)
    if doc is None:
        return "%s is missing" % cfg.graph_out
    if doc.get("inputs") != fingerprint(tree, cfg):
        return ("%s was rendered from other inputs (a build file, a .bzl, .buckconfig, the buck2 pin, or "
                "the set of files in a package changed)" % cfg.graph_out)
    if doc.get("query") != query_expr(cfg):
        return "%s was rendered from another query" % cfg.graph_out
    return None


# ---- queries over the committed file (no buck2) -------------------------------------------

def _resolve(targets, name):
    if name in targets:
        return name
    hits = sorted(t for t in targets if t.endswith(":" + name) or t.endswith("//" + name)
                  or t.split("//", 1)[-1] == name.lstrip("/"))
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise KgError("no target %r in the graph; labels look like komira//examples:hellopkg" % name)
    raise KgError("%r is ambiguous: %s" % (name, ", ".join(hits[:8])))


def deps(targets, name, reverse=False, depth=0):
    """Transitive deps (or reverse deps) of a target, within the graph. depth 0 = unbounded."""
    start = _resolve(targets, name)
    edges = {}
    for t, a in targets.items():
        for d in a.get("deps", []):
            if reverse:
                edges.setdefault(d, []).append(t)
            else:
                edges.setdefault(t, []).append(d)
    seen, frontier, level = {}, [start], 0
    while frontier and (depth == 0 or level < depth):
        level += 1
        nxt = []
        for n in frontier:
            for m in edges.get(n, []):
                if m not in seen and m != start:
                    seen[m] = level
                    nxt.append(m)
        frontier = nxt
    return start, sorted(seen.items(), key=lambda x: (x[1], x[0]))


def tests(targets, name):
    """What tests `name` (a target, or a source path): its own welded `test_srcs`, and every
    test target (kind *_test) that reaches it through deps."""
    if name in targets or ":" in name or "/" not in name:
        start = _resolve(targets, name)
        roots = {start}
    else:
        roots = {t for t, a in targets.items() if name in a.get("srcs", []) + a.get("test_srcs", [])}
        if not roots:
            raise KgError("no target in the graph owns %r" % name)
        start = name
    welded = sorted({(t, f) for t in roots for f in targets[t].get("test_srcs", [])})
    covering = set()
    for r in roots:
        covering.update(t for t, _ in deps(targets, r, reverse=True)[1])
        covering.add(r)
    tgts = sorted(t for t in covering if targets[t]["kind"].endswith("_test"))
    gated = sorted(t for t in covering if targets[t].get("test_srcs") and t not in roots)
    return start, welded, tgts, gated


def owner(targets, path):
    return sorted(t for t, a in targets.items() if path in a.get("srcs", []) or path in a.get("test_srcs", []))
