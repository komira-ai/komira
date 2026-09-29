"""The docs graph: every tracked Markdown doc, its title, the repository paths it references,
the libraries it governs, and the canonical-doc table (docs/kg.toml `canonical`), committed as
one sorted JSON file (`docs_graph`). A pure function of the tree; no buck2, no network.

A REFERENCE is a Markdown link target (`[x](path)`, resolved against the doc's directory) or a
backticked token shaped like a repository path (`dir/file.ext`, first segment a tracked
top-level entry). A reference that names no tracked file or directory is DEAD. Dead
references are refused everywhere (pre-commit, pre-push, CI), not counted: the tree starts at
zero and a ratchet at zero is a refusal.

The canonical table is the Markdown table in the `canonical` doc whose header row starts
`| Authority for |`: each row names what a doc is the authority FOR, and links the doc. A
row whose link is dead is refused like any other dead reference.
"""
from __future__ import annotations

import json
import posixpath
import re

from . import KgError
from . import frontmatter

DOCS_FORMAT = 1
_LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
_TICK = re.compile(r"`([^`\s]+)`")
_TITLE = re.compile(r"^#\s+(.+?)\s*#*\s*$", re.M)
_FENCE = re.compile(r"^(```|~~~).*?^\1\s*$", re.M | re.S)


def doc_paths(tree, cfg):
    prefix = cfg.docs + "/"
    return sorted(p for p in tree.paths() if p.endswith(".md") and tree.is_file(p)
                  and (p.startswith(prefix) or "/" not in p)
                  and not p.startswith(cfg.pages + "/"))


def _exists(tree, dirs, p):
    p = posixpath.normpath(p)
    return p in tree.entries or p in dirs


def _dirs(tree):
    ds = set()
    for p in tree.paths():
        d = posixpath.dirname(p)
        while d and d not in ds:
            ds.add(d)
            d = posixpath.dirname(d)
    return ds


def _refs(path, text, tree, dirs, tops):
    """-> (live, dead): sorted repository paths this doc references."""
    body = _FENCE.sub("", text)
    live, dead = set(), set()
    base = posixpath.dirname(path)
    for m in _LINK.finditer(body):
        t = m.group(1).split("#", 1)[0]
        if not t or re.match(r"[a-z][a-z0-9+.-]*:", t) or t.startswith("/"):
            continue        # a URL, a mail link, an in-page anchor, or a site-absolute path
        p = posixpath.normpath(posixpath.join(base, t))
        if p.startswith("../") or p == "..":
            dead.add(t)     # leaves the repository
        else:
            (live if _exists(tree, dirs, p) else dead).add(p)
    for m in _TICK.finditer(body):
        t = m.group(1).rstrip(".,;")
        if "/" not in t or any(c in t for c in ":<>*$%{}[]()|=~@'\"?") or t.startswith(("/", ".", "-")):
            continue
        t = t.rstrip("/")
        if t.split("/", 1)[0] not in tops or " " in t:
            continue
        (live if _exists(tree, dirs, t) else dead).add(t)
    return sorted(live), sorted(dead)


def _canonical(path, text):
    """[(authority for, linked doc path)] from the `| Authority for |` table."""
    rows, on = [], False
    base = posixpath.dirname(path)
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("| Authority for |"):
            on = True
            continue
        if on and s.startswith("|---"):
            continue
        if on and s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            links = _LINK.findall(s)
            if links:
                rows.append((cells[0], posixpath.normpath(posixpath.join(base, links[0].split("#", 1)[0]))))
            continue
        if on:
            break
    return rows


def derive(tree, cfg, libs=(), generated=()):
    """-> (model dict, [problem strings]). `libs` is the set of library ids (for `governs:`);
    `generated` the paths kg renders into this commit, which count as present."""
    docs = doc_paths(tree, cfg)
    gen = {p for p in generated if p}
    dirs = _dirs(tree) | {posixpath.dirname(p) for p in gen}
    tops = {p.split("/", 1)[0] for p in list(tree.paths()) + list(gen)}
    tree = _WithGenerated(tree, gen)
    blobs = tree.read(docs)
    out, probs = {}, []
    for p in docs:
        text = blobs[p].decode("utf-8", "replace")
        live, dead = _refs(p, text, tree, dirs, tops)
        for d in dead:
            probs.append("%s: dead reference `%s` (no tracked file or directory by that name)" % (p, d))
        entry = {}
        m = _TITLE.search(_FENCE.sub("", text))
        if m:
            entry["title"] = m.group(1)
        if live:
            entry["refs"] = live
        try:
            fm = frontmatter.parse(blobs[p], p) or {}
        except KgError:
            fm = {}      # layer1 reports unreadable front matter
        gov = fm.get("governs")
        if gov:
            entry["governs"] = sorted(g for g in (gov if isinstance(gov, list) else [gov]) if g in libs or ":" in g)
            if not entry["governs"]:
                del entry["governs"]
        if fm.get("status"):
            entry["status"] = fm["status"]
        out[p] = entry
    canon = {}
    if cfg.canonical:
        got = tree.read([cfg.canonical]).get(cfg.canonical)
        if got is None:
            probs.append("%s: the canonical-doc table (docs/kg.toml `canonical`) is missing" % cfg.canonical)
        else:
            rows = _canonical(cfg.canonical, got.decode("utf-8", "replace"))
            if not rows:
                probs.append("%s: no `| Authority for |` table" % cfg.canonical)
            for what, doc in rows:
                if doc not in tree.entries:
                    probs.append("%s: canonical row %r links %s, which is not a tracked file" % (cfg.canonical, what, doc))
                canon.setdefault(doc, []).append(what)
    for doc, whats in canon.items():
        if doc in out:
            out[doc]["canonical_for"] = sorted(whats)
    return {"format": DOCS_FORMAT, "generated_by": "python3 tools/kg/kg.py build --all",
            "canonical": cfg.canonical, "docs": out}, sorted(set(probs))


class _WithGenerated:
    """A tree view in which the generated paths exist (only `entries` membership is read)."""

    def __init__(self, tree, gen):
        self._t, self.entries = tree, set(tree.entries) | set(gen)

    def read(self, paths):
        return self._t.read(paths)


def render(model):
    return (json.dumps(model, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
