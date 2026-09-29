"""The verbs that read a tree and act: build, fix, check, graph, the generator guard and the
pinned generator. Everything a hook does is one of these."""
from __future__ import annotations

import hashlib
import io
import os
import posixpath
import subprocess
import sys
import tarfile
import time

from . import KgError
from . import docsgraph, graph, layer1
from .gitio import git, out, index_tree, commit_tree, MemTree

CONFIG = "docs/kg.toml"
KG_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ONE_FIX = 'python3 tools/kg/kg.py build --all && git commit -m "kg: refresh pages" -- docs/libraries docs/kg'
GRAPH_FIX = 'python3 tools/kg/kg.py graph && git commit -m "kg: refresh the Buck2 graph" -- docs/kg'
LIST_CAP = 12


def toplevel():
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True)
    if r.returncode != 0:
        raise KgError("not inside a git work tree")
    return r.stdout.decode().strip()


def cache_root():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "komira-kg")


def short(paths):
    s = ", ".join(paths[:LIST_CAP])
    return s + (" (+%d more)" % (len(paths) - LIST_CAP) if len(paths) > LIST_CAP else "")


def config_of(tree, override=None):
    """The tree's docs/kg.toml, or `override` (a file path) when given; None when absent."""
    if override:
        with open(override, "rb") as f:
            return layer1.load_config(f.read(), override)
    got = tree.read([CONFIG])
    return layer1.load_config(got[CONFIG], CONFIG) if CONFIG in got else None


def generator_dirty(root, paths):
    """Paths under the generator whose working-tree state is not what the commit will hold."""
    raw = git(["status", "--porcelain", "-z", "--untracked-files=all", "--", *paths], root, read_only=True).stdout
    toks, bad, i = raw.split(b"\0"), [], 0
    while i < len(toks):
        t = toks[i].decode("utf-8", "replace")
        i += 1
        if len(t) < 4:
            continue
        xy, p = t[:2], t[3:]
        if xy[0] in "RC":
            i += 1
        if xy == "??" or xy[1] != " ":
            bad.append(p)
    return bad


def render_tree(tree, cfg):
    """Every generated file kg renders without buck2: the library pages, the map and the docs
    graph. (The Buck2 graph is `graph.export`, and only its fingerprint is checked here.)"""
    model = layer1.derive(tree, cfg)
    pages = layer1.render(model, cfg)
    if cfg.docs_graph:
        dm, model.refused = docsgraph.derive(tree, cfg, set(model.libs),
                                             set(pages) | {cfg.docs_graph, cfg.graph_out})
        pages[cfg.docs_graph] = docsgraph.render(dm)
    return model, pages


def inputs_dirty(root, tree, cfg):
    """Why the working tree cannot stand in for `tree` in a buck2 query: build inputs whose
    working-tree state differs, and untracked files inside a package (a glob would see them)."""
    paths = graph.input_paths(tree, cfg)
    bad = generator_dirty(root, paths) if paths else []
    pkgs = sorted({posixpath.dirname(p) for p in paths if posixpath.basename(p) in cfg.build_files})
    if pkgs:
        extra = out(["ls-files", "--others", "--exclude-standard", "--", *[p or "." for p in pkgs]], root,
                    read_only=True).splitlines()
        bad += extra
    return sorted(set(bad))


def graph_export(root, tree, cfg, buck2=None):
    if not cfg.graph_out:
        raise KgError("%s has no [graph] out, so the Buck2 graph is not configured" % CONFIG)
    buck2 = buck2 or graph.find_buck2(root)
    if not buck2:
        raise KgError("no buck2: put one on PATH or set BUCK2=/path/to/buck2 (tools/buck2 is a dotslash pin)")
    dirty = inputs_dirty(root, tree, cfg)
    if dirty:
        raise KgError("buck2 reads the working tree, and it differs from the tree being graphed: %s. "
                      "Stage or stash them (and add or ignore untracked files in a package), then rerun"
                      % short(dirty))
    return graph.export(root, tree, cfg, buck2)


def write_pages(root, pages, changed, removed, stage):
    for p in changed:
        full = os.path.join(root, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(pages[p])
    for p in removed:
        try:
            os.unlink(os.path.join(root, p))
        except FileNotFoundError:
            pass
    if not stage:
        return
    for i in range(0, len(changed), 200):
        git(["add", "--", *changed[i:i + 200]], root)
    for i in range(0, len(removed), 200):
        git(["rm", "-q", "--cached", "--ignore-unmatch", "--", *removed[i:i + 200]], root)


def build(root, out_dir=None, config=None):
    """Rebuild every page and the map from the INDEX. Stages the changed ones, or writes
    every page under `out_dir` (a scratch directory; nothing in the repository changes)."""
    t0 = time.perf_counter()
    tree = index_tree(root)
    cfg = config_of(tree, config)
    if cfg is None:
        raise KgError("this tree has no %s, so kg is not configured here" % CONFIG)
    model, pages = render_tree(tree, cfg)
    if out_dir:
        for p, b in pages.items():
            full = os.path.join(out_dir, p)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(b)
        changed, removed = sorted(pages), []
    else:
        changed, removed = layer1.diff(tree, pages, cfg)
        write_pages(root, pages, changed, removed, stage=True)
    return {"libraries": len(model.libs), "changed": changed, "removed": removed, "problems": model.problems,
            "refused": model.refused,
            "notes": model.notes, "pages": pages, "seconds": time.perf_counter() - t0}


def fix(root):
    tree = index_tree(root)
    cfg = config_of(tree)
    if cfg is None and CONFIG not in tree.unmerged:
        raise KgError("this tree has no %s, so kg is not configured here" % CONFIG)
    pages_prefix = (cfg.pages if cfg else "docs/libraries") + "/"
    generated = {cfg.docs_graph} if cfg else set()
    src = sorted(p for p in tree.unmerged if not p.startswith(pages_prefix) and p not in generated)
    if src:
        raise KgError("resolve these first, then run kg fix again: " + short(src))
    model, pages = render_tree(tree, cfg)
    changed, removed = layer1.diff(tree, pages, cfg)
    write_pages(root, pages, changed, removed, stage=True)
    return changed, removed


def _rev(root, spec):
    r = git(["rev-parse", "--verify", "-q", spec], root, check=False, read_only=True)
    return r.stdout.decode().strip() if r.returncode == 0 else None


def pinned_generator(root, sha, cfg):
    """None when the working tree's generator IS the commit's and this process runs it;
    else the path of the commit's generator entry, extracted once into the cache."""
    paths = cfg.generator
    same = git(["diff", "--quiet", sha, "--", *paths], root, check=False, read_only=True).returncode == 0
    extra = out(["ls-files", "--others", "--exclude-standard", "--", *paths], root, read_only=True)
    mine = os.path.realpath(os.path.join(root, posixpath.dirname(cfg.entry))) == os.path.realpath(KG_DIR)
    if same and not extra and mine:
        return None
    present = [(p, _rev(root, "%s:%s" % (sha, p))) for p in paths]
    key = hashlib.sha1("\n".join("%s %s" % (p, o or "-") for p, o in present).encode()).hexdigest()
    dest = os.path.join(cache_root(), "generators", key)
    entry = os.path.join(dest, cfg.entry)
    if not os.path.isfile(entry):
        have = [p for p, o in present if o]
        if cfg.entry.split("/")[0] not in {h.split("/")[0] for h in have}:
            raise KgError("the generator of %s has no %s" % (sha[:12], cfg.entry))
        data = git(["archive", "--format=tar", sha, "--", *have], root).stdout
        tmp = "%s.tmp%d" % (dest, os.getpid())
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            for m in tf.getmembers():
                n = posixpath.normpath(m.name)
                if n.startswith(("/", "..")) or not (m.isfile() or m.isdir()):
                    raise KgError("refusing to extract %r from the generator archive" % m.name)
            if hasattr(tarfile, "data_filter"):
                tf.extractall(tmp, filter="data")
            else:
                tf.extractall(tmp)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            os.rename(tmp, dest)
        except OSError:
            pass      # another process extracted the same key first
    return entry


def check(root, commit="HEAD", base=None, pinned=False, stream=sys.stdout, with_graph=False):
    """0 fresh; 1 refused (stale pages or docs graph, dead doc references, a Buck2 graph
    rendered from other inputs, shims, caps in this change). `with_graph` also re-runs the
    buck2 query and compares bytes; it needs buck2 and a clean checkout of `commit`. Raises
    KgError on a tree kg cannot judge."""
    sha = _rev(root, commit + "^{commit}")
    if not sha:
        raise KgError("%s is not a commit in this clone" % commit)
    tree = commit_tree(root, sha)
    cfg = config_of(tree)
    if cfg is None:
        raise KgError("%s has no %s, so kg is not configured in that tree" % (sha[:12], CONFIG))
    if not pinned:
        gen = pinned_generator(root, sha, cfg)
        if gen:
            argv = [sys.executable, "-B", gen, "check", "--commit", sha, "--pinned"] + (["--base", base] if base else []) \
                + (["--graph"] if with_graph else [])
            stream.flush()
            return subprocess.run(argv, cwd=root).returncode
    model, pages = render_tree(tree, cfg)
    changed, removed = layer1.diff(tree, pages, cfg)
    shims = layer1.check_shims(tree, cfg)
    touched = set()
    if base:
        if not _rev(root, base + "^{commit}"):
            raise KgError("the base %s is not in this clone; fetch it" % base)
        touched = set(out(["diff", "--name-only", base, sha], root, read_only=True).splitlines())
    here = [c for c in model.problems if c[1] in touched]
    rc = 0
    s12 = sha[:12]
    if changed or removed:
        rc = 1
        stream.write("kg check %s: STALE pages: %s\n" % (s12, short(changed + removed)))
        stream.write("  fix, on a checkout of %s (git pull first): %s\n" % (s12, ONE_FIX))
    for p in model.refused[:LIST_CAP]:
        rc = 1
        stream.write("kg check %s: DEAD REFERENCE: %s\n" % (s12, p))
    why = graph.stale_reason(tree, cfg)
    if why:
        rc = 1
        stream.write("kg check %s: STALE Buck2 graph: %s\n  fix (needs buck2): %s\n" % (s12, why, GRAPH_FIX))
    gnote = "graph inputs match"
    if with_graph and cfg.graph_out and not why:
        if _rev(root, "HEAD") != sha:
            raise KgError("--graph runs buck2 in this checkout, which is not %s; check it out first" % s12)
        fresh = graph_export(root, tree, cfg)
        if fresh != tree.read([cfg.graph_out]).get(cfg.graph_out):
            rc = 1
            stream.write("kg check %s: STALE Buck2 graph: buck2 renders different bytes than %s\n"
                         "  fix: %s\n" % (s12, cfg.graph_out, GRAPH_FIX))
        else:
            gnote = "graph bytes re-derived by buck2"
    elif cfg.graph_out and not with_graph:
        gnote = "graph inputs match (bytes not re-derived: no --graph)"
    for p in shims:
        rc = 1
        stream.write("kg check %s: SHIM: %s\n" % (s12, p))
    for lib, path, msg in here[:LIST_CAP]:
        rc = 1
        stream.write("kg check %s: PROBLEM in this change: %s%s\n" % (s12, msg if msg.startswith(path) else path + ": " + msg,
                                                                      " (library %s)" % lib if lib else ""))
    if rc == 0:
        stream.write("kg check %s: FRESH, %d libraries; docs graph ok; %s; shims %s; problems: %d, none in "
                     "this change%s\n" % (s12, len(model.libs), gnote if cfg.graph_out else "no Buck2 graph configured",
                                          "ok" if cfg.shims else "not configured", len(model.problems),
                                          "" if base else " (no --base)"))
    return rc
