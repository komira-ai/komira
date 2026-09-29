"""The kg command line. Every refusal names its fix; every answer is short.

    python3 tools/kg/kg.py setup                 # once per clone: core.hooksPath .githooks + self-check
    python3 tools/kg/kg.py status                # the self-check again
    python3 tools/kg/kg.py build --all           # rebuild every page and the map from the index; stage them
    python3 tools/kg/kg.py build --all --out DIR # write every page under DIR instead; the repo is untouched
    python3 tools/kg/kg.py fix                   # a merge or rebase stopped on a page
    python3 tools/kg/kg.py check [--commit C] [--base B] [--graph]
    python3 tools/kg/kg.py graph [--out FILE]    # buck2 uquery -> docs/kg/buck_graph.json, staged
    python3 tools/kg/kg.py deps|rdeps <target> [--depth N]
    python3 tools/kg/kg.py tests <target|path>   # welded test_srcs, test targets, gated dependents
    python3 tools/kg/kg.py owner <path>          # the targets whose srcs/test_srcs hold a file
    python3 tools/kg/kg.py hook <pre-commit|pre-push>

`check --graph` and `graph` run buck2 (loading only: no build, no remote execution); every
other verb, and both hooks, need only git and python3. Query verbs read the committed graph.

Exit status: 0 ok, 1 refused (the message says why and how to fix it), 2 cannot run here,
3 a verb this version does not have.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

from . import KgError, graph, layer1, ops
from .gitio import git, out, index_tree

HOOKS = ("pre-commit", "pre-push")
HOOKS_PATH = ".githooks"
MIN_GIT = (2, 25)
MIN_PY = (3, 9)


def _say(msg):
    sys.stdout.write(msg + "\n")


def _git_version():
    m = re.search(r"(\d+)\.(\d+)", subprocess.run(["git", "--version"], capture_output=True, text=True).stdout)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def status(root):
    bad = []
    gv, pv = _git_version(), sys.version_info[:2]
    if gv < MIN_GIT:
        bad.append("git %d.%d is older than %d.%d; upgrade git" % (gv + MIN_GIT))
    if pv < MIN_PY:
        bad.append("python %d.%d is older than %d.%d" % (pv + MIN_PY))
    hp = out(["config", "--get", "core.hooksPath"], root, check=False, read_only=True)
    if hp != HOOKS_PATH:
        bad.append("core.hooksPath is %r, not %r; run `python3 tools/kg/kg.py setup`" % (hp or "unset", HOOKS_PATH))
    for h in HOOKS:
        p = os.path.join(root, HOOKS_PATH, h)
        if not (os.path.isfile(p) and os.access(p, os.X_OK)):
            bad.append("%s/%s is missing or not executable; `chmod +x %s/%s`" % (HOOKS_PATH, h, HOOKS_PATH, h))
    t0 = time.perf_counter()
    tree = index_tree(root)
    cfg = ops.config_of(tree)
    if cfg is None:
        bad.append("no %s in this checkout" % ops.CONFIG)
        stale = "n/a"
    else:
        model, pages = ops.render_tree(tree, cfg)
        changed, removed = layer1.diff(tree, pages, cfg)
        stale = "%d page(s) would change" % len(changed + removed)
    _say("kg status: git %d.%d, python %d.%d, core.hooksPath=%s; dry pre-commit %.2f s (%s)" % (
        gv + pv + (hp or "unset", time.perf_counter() - t0, stale)))
    for b in bad:
        _say("  FAIL: " + b)
    return 1 if bad else 0


def setup(root):
    tree = index_tree(root)
    if ops.CONFIG not in tree.entries:
        raise KgError("this checkout has no %s, so kg is not configured here; nothing was changed" % ops.CONFIG)
    r = git(["config", "--show-origin", "--get", "core.hooksPath"], root, check=False, read_only=True)
    cur = r.stdout.decode().strip()
    if cur:
        origin, _, val = cur.partition("\t")
        if val != HOOKS_PATH:
            raise KgError("core.hooksPath is already %r (%s). Two hook setups silently disable each other: "
                          "unset it (`git config --unset core.hooksPath`) and run setup again" % (val, origin))
    else:
        git(["config", "core.hooksPath", HOOKS_PATH], root)
    return status(root)


def hook(root, name, stdin):
    if name == "pre-commit":
        tree = index_tree(root)
        cfg = ops.config_of(tree)
        if cfg is None:
            return 0
        dirty = ops.generator_dirty(root, cfg.generator)
        if dirty:
            raise KgError("the generator has changes that are not in this commit (%s). `git add` them (with "
                          "`git commit <paths>`, name them in the paths too), or stash them, then commit"
                          % ops.short(dirty))
        t0 = time.perf_counter()
        model, pages = ops.render_tree(tree, cfg)
        if model.refused:
            raise KgError("this commit has %d dead doc reference(s): %s. Fix the reference (or restore "
                          "the file it names), then commit" % (len(model.refused), "; ".join(model.refused[:6])))
        changed, removed = layer1.diff(tree, pages, cfg)
        ops.write_pages(root, pages, changed, removed, stage=True)
        if changed or removed:
            _say("kg: refreshed %d generated file(s)" % len(changed + removed))
        why = graph.stale_reason(tree, cfg)
        if why:
            # Not refused here: re-deriving it needs buck2, which a hook never runs. pre-push
            # and the `kg` CI check refuse it.
            _say("kg: WARNING: the Buck2 graph is stale: %s.\n  before pushing: %s" % (why, ops.GRAPH_FIX))
        if os.environ.get("KG_TIMING"):
            _say("kg pre-commit: %.3f s" % (time.perf_counter() - t0))
        return 0
    if name == "pre-push":
        rc = 0
        for line in stdin:
            f = line.split()
            if len(f) != 4:
                continue
            lref, lsha, rref, rsha = f
            why = None
            if set(lsha) == {"0"}:
                why = "a delete"
            elif not rref.startswith("refs/heads/"):
                why = "not a branch"
            elif not out(["rev-list", "-n1", lsha, "--not", "--remotes"], root, read_only=True):
                why = "already on a remote-tracking ref"
            elif git(["cat-file", "-e", "%s:%s" % (lsha, ops.CONFIG)], root, check=False).returncode:
                why = "no %s at that tip" % ops.CONFIG
            if why:
                _say("kg pre-push: %s skipped (%s)" % (rref, why))
                continue
            base = rsha if set(rsha) != {"0"} and ops._rev(root, rsha + "^{commit}") else None
            sys.stdout.write("kg pre-push: %s: " % rref)
            if ops.check(root, lsha, base) != 0:
                rc = 1
        return rc
    raise KgError("unknown hook %r (known: %s)" % (name, ", ".join(HOOKS)))


def graph_verb(root, args):
    t0 = time.perf_counter()
    tree = index_tree(root)
    cfg = ops.config_of(tree)
    if cfg is None:
        raise KgError("this tree has no %s, so kg is not configured here" % ops.CONFIG)
    body = ops.graph_export(root, tree, cfg)
    n = len(json.loads(body)["targets"])
    if "--out" in args:
        dest = args[args.index("--out") + 1]
        with open(dest, "wb") as f:
            f.write(body)
        _say("kg graph: %d targets, %d bytes -> %s in %.2f s" % (n, len(body), dest, time.perf_counter() - t0))
        return 0
    same = tree.read([cfg.graph_out]).get(cfg.graph_out) == body
    if not same:
        ops.write_pages(root, {cfg.graph_out: body}, [cfg.graph_out], [], stage=True)
    _say("kg graph: %d targets, %d bytes; %s %s in %.2f s" % (
        n, len(body), "unchanged" if same else "staged", cfg.graph_out, time.perf_counter() - t0))
    return 0


def query_verb(root, verb, args):
    if not args or args[0].startswith("-"):
        raise KgError("`%s` needs a target%s" % (verb, " or a path" if verb in ("tests", "owner") else ""))
    tree = index_tree(root)
    cfg = ops.config_of(tree)
    doc = graph.load(tree, cfg) if cfg and cfg.graph_out else None
    if doc is None:
        raise KgError("no committed Buck2 graph; run `python3 tools/kg/kg.py graph`")
    why = graph.stale_reason(tree, cfg)
    if why:
        _say("kg: note: the graph is stale (%s); answers are from the committed file" % why)
    t = doc["targets"]
    if verb in ("deps", "rdeps"):
        depth = int(args[args.index("--depth") + 1]) if "--depth" in args else 0
        start, hits = graph.deps(t, args[0], reverse=verb == "rdeps", depth=depth)
        _say("%s %s: %d target(s)" % (verb, start, len(hits)))
        for lab, lvl in hits[:200]:
            _say("  %d %s (%s)" % (lvl, lab, t.get(lab, {}).get("kind", "outside the graph")))
        return 0
    if verb == "owner":
        hits = graph.owner(t, args[0])
        _say("owner %s: %s" % (args[0], ", ".join(hits) if hits else "no target in the graph lists it"))
        return 0 if hits else 1
    start, welded, tgts, gated = graph.tests(t, args[0])
    _say("tests %s:" % start)
    _say("  welded (run when it is built): " + (", ".join("%s %s" % x for x in welded) or "none"))
    _say("  test targets that reach it: " + (", ".join(tgts) or "none"))
    _say("  gated libraries that depend on it: " + (", ".join(gated) or "none"))
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        _say(__doc__.strip())
        return 0
    verb, args = argv[0], argv[1:]
    if verb in layer1.RESERVED_VERBS:
        _say("kg: `%s` is reserved and not in this version of kg" % verb)
        return 3
    try:
        root = ops.toplevel()
        os.chdir(root)
        if verb == "setup":
            return setup(root)
        if verb == "status":
            return status(root)
        if verb == "build":
            if "--all" not in args:
                raise KgError("say `build --all`: kg rebuilds every page, never a subset")
            outd = args[args.index("--out") + 1] if "--out" in args else None
            conf = args[args.index("--config") + 1] if "--config" in args else None
            if conf and not outd:
                raise KgError("--config is only for `--out` (a scratch render); a staged build uses %s" % ops.CONFIG)
            r = ops.build(root, outd, conf)
            sizes = sorted(len(b) for p, b in r["pages"].items() if p.endswith(".md") and not p.endswith("/README.md"))
            mp = [len(b) for p, b in r["pages"].items() if p.endswith("/README.md")]
            _say("kg build: %d libraries, %s %d file(s)%s in %.2f s; page bytes p50 %d max %d; map %d bytes; "
                 "problems %d%s" % (r["libraries"], "wrote" if outd else "staged", len(r["changed"] + r["removed"]),
                                     " to " + outd if outd else "", r["seconds"], sizes[len(sizes) // 2] if sizes else 0,
                                     sizes[-1] if sizes else 0, mp[0] if mp else 0, len(r["problems"]),
                                     "; " + "; ".join(r["notes"]) if r["notes"] else ""))
            for p in r["refused"]:
                _say("  DEAD REFERENCE: " + p)
            return 1 if r["refused"] else 0
        if verb == "fix":
            changed, removed = ops.fix(root)
            _say("kg fix: %d page(s) rebuilt and staged; now `git commit` or `git rebase --continue`"
                 % len(changed + removed))
            return 0
        if verb == "check":
            commit = args[args.index("--commit") + 1] if "--commit" in args else "HEAD"
            base = args[args.index("--base") + 1] if "--base" in args else None
            return ops.check(root, commit, base, pinned="--pinned" in args, with_graph="--graph" in args)
        if verb == "graph":
            return graph_verb(root, args)
        if verb in ("deps", "rdeps", "tests", "owner"):
            return query_verb(root, verb, args)
        if verb == "hook":
            if not args:
                raise KgError("hook needs a name (%s)" % ", ".join(HOOKS))
            return hook(root, args[0], sys.stdin)
        raise KgError("unknown verb %r; see `python3 tools/kg/kg.py --help`" % verb)
    except KgError as e:
        sys.stderr.write("kg %s: %s\n" % (verb, e))
        return 1 if verb in ("hook", "fix", "setup", "check") else 2
    except IndexError:
        sys.stderr.write("kg %s: a flag is missing its value\n" % verb)
        return 2
