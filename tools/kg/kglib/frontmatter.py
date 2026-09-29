"""Front matter: a strict YAML subset at the very top of a Markdown file.

    ---
    status: current
    governs: [komira_parquet, "komira_io"]
    summary: "One sentence."   # a comment
    ---

One `key: value` per line. A value is a scalar (bare, "double" or 'single' quoted) or a
one-line `[a, b]` list of scalars. Block lists, nested maps and multi-line values are
refused with the line number: a parser that guesses is how a `governs:` silently drops a
library from its pages.
"""
from __future__ import annotations

import re

from . import KgError

_KEY = re.compile(r"([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$")


def _scalar(tok, where):
    tok = tok.strip()
    if tok[:1] in ('"', "'"):
        q = tok[0]
        if len(tok) < 2 or not tok.endswith(q):
            raise KgError("%s: unterminated quoted value" % where)
        body = tok[1:-1]
        return body.replace('\\"', '"').replace("\\\\", "\\") if q == '"' else body.replace("''", "'")
    return tok


def _split_list(body, where):
    items, buf, q = [], [], None
    for c in body:
        if q:
            buf.append(c)
            if c == q:
                q = None
        elif c in "\"'":
            q = c
            buf.append(c)
        elif c == ",":
            items.append("".join(buf))
            buf = []
        elif c in "[]{":
            raise KgError("%s: nested lists or maps are not in kg's front-matter subset" % where)
        else:
            buf.append(c)
    if q:
        raise KgError("%s: unterminated quoted value in the list" % where)
    items.append("".join(buf))
    vals = [_scalar(x, where) for x in items]
    if vals and vals[-1] == "":
        vals.pop()
    if any(v == "" for v in vals):
        raise KgError("%s: empty item in the list" % where)
    return vals


def _strip_comment(v):
    q = None
    for i, c in enumerate(v):
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#" and (i == 0 or v[i - 1] in " \t"):
            return v[:i].rstrip()
    return v.rstrip()


def parse(data, name):
    """-> dict, or None when the file has no front matter. Raises KgError on a malformed block."""
    if isinstance(data, bytes):
        if not data.startswith(b"---\n") and not data.startswith(b"---\r\n"):
            return None
        data = data[:65536].decode("utf-8", "replace")
    elif not data.startswith("---\n"):
        return None
    lines = data.splitlines()
    fm = {}
    for n, raw in enumerate(lines[1:], start=2):
        where = "%s:%d" % (name, n)
        if raw.rstrip() == "---":
            return fm
        line = _strip_comment(raw)
        if not line.strip():
            continue
        if raw[:1] in " \t-":
            raise KgError("%s: indented or block values are not in kg's front-matter subset" % where)
        m = _KEY.match(line)
        if not m or not (m.group(2) or "").strip():
            raise KgError("%s: expected `key: value`" % where)
        k, v = m.group(1), m.group(2).strip()
        if k in fm:
            raise KgError("%s: key %r is repeated" % (where, k))
        if v.startswith("["):
            if not v.endswith("]"):
                raise KgError("%s: a list must open and close on one line" % where)
            fm[k] = _split_list(v[1:-1], where)
        else:
            fm[k] = _scalar(v, where)
    raise KgError("%s: the front matter is not closed by a `---` line" % name)
