"""The Buck2 code graph: every target in the configured universe, its rule kind, its deps, its
sources and its welded test files, committed as one sorted JSON file (docs/kg.toml [graph] out).

TWO HALVES, AND ONLY ONE NEEDS BUCK2.

* `export` runs ONE `buck2 uquery` (loading only: no configuration, no actions, no remote
  execution) and renders the file. `[graph] config` passes `-c` overrides so a checkout
  without `.buckconfig.local` loads every package; the overridden values appear nowhere in
  the output.
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


def input_paths(tree, cfg):
    """The paths whose working-tree state must equal the index before an export."""
    return sorted(set(p for p in tree.paths() if posixpath.basename(p) in cfg.build_files
                      or p.endswith(".bzl") or p in (".buckconfig", PIN)))


def find_buck2(root):
    """$BUCK2, then `buck2` on PATH. None when neither exists (tools/buck2 needs dotslash)."""
    b = os.environ.get("BUCK2")
    if b:
        return b
    return shutil.which("buck2")


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


def export(root, tree, cfg, buck2):
    """Run the query in `root` (a checkout of `tree`) and return the rendered bytes."""
    # Its own isolation dir: its own daemon, so the `-c` overrides never invalidate the state
    # of the daemon that builds.
    argv = [buck2, "--isolation-dir", "kg", "uquery"]
    for c in cfg.graph_config:
        argv += ["-c", c]
    argv += [query_expr(cfg), "--json", "--output-attribute", "buck.type|buck.deps|srcs|test_srcs"]
    try:
        r = subprocess.run(argv, cwd=root, capture_output=True, timeout=600)
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
    return render(normalize(raw, cells(tree)), fingerprint(tree, cfg), cfg)


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
