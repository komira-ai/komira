"""The mapping: the files of a change -> the targets it affects.

A pure function over a graph facade `g`, so the cases (cases.bxl) answer it
from tables as well as from the real graph. The rules, in this order, for
each changed file (paths are relative to the cell, as `git diff --name-only`
prints them from the repository root):

  1. a file matching a WIDEN row widens: the answer is the whole check set;
  2. a file the change no longer has seeds every target of the nearest
     package above it (a deleted BUCK file widens: its package is gone);
  3. a `BUCK` file seeds every target of its package;
  4. a `.bzl` file seeds every target of every package whose BUCK file loads
     it (and the targets that list it);
  5. any other file seeds the targets that own it; a file no target owns
     widens, unless an INERT row names it (it builds nothing).

The answer is the seeds and everything that depends on one of them within
the check set, minus the aggregate package (the aggregate depends on
everything, so it would be selected for every change). It never
under-approximates: a file the rules above cannot map widens, with the
reason; a change that seeds the aggregate package itself (its list)
widens; a change whose files reach no target is VACUOUS and a change of no
file is EMPTY, never a pass.

A failed query is not caught here: it fails the script (buck2's own error),
which is the BROKEN of the previous selector.

The facade `g` has: exists(path) -> bool (at the head); owners(path) ->
[label]; package_targets(dir) -> [label]; including(bzl) -> [label];
rdeps(seeds) -> [label]. Labels are strings `cell//package:name`.
"""

AFFECTED = "AFFECTED"
WIDENED = "WIDENED"
VACUOUS = "VACUOUS"
EMPTY = "EMPTY"

HELD_FILE = "coverage_held"

def pattern_matches(pattern, path):
    """`dir/**` and `text*` match by prefix, `*text` by suffix, anything else exactly."""
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-2])
    if pattern.endswith("*"):
        return path.startswith(pattern[:-1])
    if pattern.startswith("*"):
        return path.endswith(pattern[1:])
    return path == pattern

def widen_reason(rules, path):
    """`<pattern>: <reason>` of the first WIDEN row `path` matches, or ""."""
    for row in rules.widen:
        if pattern_matches(row[0], path):
            return row[0] + ": " + row[1]
    return ""

def is_inert(rules, path):
    for pattern in rules.inert:
        if pattern_matches(pattern, path):
            return True
    return False

def dirname(path):
    i = path.rfind("/")
    if i < 0:
        return ""
    return path[:i]

def basename(path):
    return path[path.rfind("/") + 1:]

def label_package(label):
    """`cell//package:name` -> `package`."""
    rest = label.split("//", 1)[1] if "//" in label else label
    return rest.split(":", 1)[0]

def nearest_package(g, path):
    """The directory of the nearest BUCK file above `path` at the head, or None."""
    d = dirname(path)
    for _ in range(64):
        buck = d + "/BUCK" if d else "BUCK"
        if g.exists(buck):
            return d
        if not d:
            return None
        d = dirname(d)
    return None

def _unique(xs):
    return sorted({x: True for x in xs}.keys())

def _widened(reason, files, warnings):
    return struct(kind = WIDENED, reason = reason, targets = [], files = files, warnings = warnings)

def select(rules, changed, g, aggregate_package):
    """The verdict for the changed files: struct(kind, reason, targets, files, warnings).

    `rules` is struct(widen, inert); `targets` is sorted and unique, only for
    AFFECTED; a WIDENED answer is the whole check set, which the caller names.
    """
    files = _unique([f for f in changed if f])
    warnings = []
    if not files:
        return struct(kind = EMPTY, reason = "the change names no file", targets = [], files = 0, warnings = warnings)
    seeds = []
    owned = []
    for f in files:
        why = widen_reason(rules, f)
        if why:
            return _widened("'{}' matches widen rule {}".format(f, why), len(files), warnings)
        if not g.exists(f):
            if basename(f) == "BUCK":
                return _widened("'{}' was deleted: its package is gone".format(f), len(files), warnings)
            d = nearest_package(g, f)
            if d == None:
                if is_inert(rules, f):
                    warnings.append("deleted file no package holds (inert): " + f)
                    continue
                return _widened("'{}' was deleted and no package holds it".format(f), len(files), warnings)
            seeds += g.package_targets(d)
            continue
        if basename(f) == "BUCK":
            seeds += g.package_targets(dirname(f))
            continue
        if f.endswith(".bzl"):
            including = g.including(f)
            if not including:
                return _widened("the .bzl file '{}' is loaded by no BUCK file".format(f), len(files), warnings)
            seeds += including
            seeds += g.owners(f)
            continue
        owners = g.owners(f)
        if owners:
            seeds += owners
        elif is_inert(rules, f):
            warnings.append("no target owns (inert): " + f)
        else:
            warnings.append("no target owns: " + f)
            return _widened("no target owns '{}' and no inert row names it".format(f), len(files), warnings)
    if not seeds:
        shown = files[:5]
        return struct(
            kind = VACUOUS,
            reason = "the {} changed file(s) reach no target: {}{}".format(len(files), ", ".join(shown), " ..." if len(files) > 5 else ""),
            targets = [],
            files = len(files),
            warnings = warnings,
        )
    seeds = _unique(seeds)
    for s in seeds:
        if label_package(s) == aggregate_package:
            return _widened("'{}' is in the aggregate's own package: its list changed".format(s), len(files), warnings)
    reached = g.rdeps(seeds)
    if not reached:
        return _widened("the reverse-dependency query of {} seed(s) answered nothing".format(len(seeds)), len(files), warnings)
    return struct(kind = AFFECTED, reason = "", targets = _unique(reached), files = len(files), warnings = warnings)

# ---- coverage holds ----------------------------------------------------

def is_held_file(path):
    return path == HELD_FILE or path.endswith("/" + HELD_FILE)

def _metrics(lines):
    return {l.strip(): True for l in lines if l.strip() and not l.strip().startswith("#")}

def parse_held_lines(lines, head_rev):
    """`git grep -n '' <base> <head_rev> -- '*coverage_held'` lines
    (`rev:path:line number:text`) -> (base, head): path -> [text]."""
    base = {}
    head = {}
    for l in lines:
        parts = l.split(":", 3)
        if len(parts) < 4:
            fail("the held input has a line that is not `rev:path:number:text`: '{}'".format(l))
        into = head if parts[0] == head_rev else base
        into.setdefault(parts[1], []).append(parts[3])
    return base, head

def held_refusals(changed, base, head, g):
    """One message per hold the change drops: a metric the base held that the
    head's marker no longer has, or a marker deleted while its package stays.
    A marker that is new, gains a metric, or is deleted together with its
    package's BUCK file passes. Each only for a marker the change names."""
    out = []
    for path in _unique([c for c in changed if is_held_file(c)]):
        if path not in base:
            continue
        was = _metrics(base[path])
        now = _metrics(head.get(path, []))
        if path not in head and not g.exists(dirname(path) + "/BUCK" if dirname(path) else "BUCK"):
            continue
        for m in sorted(was.keys()):
            if m not in now:
                out.append("{}: {} is no longer held".format(path, m))
    return out
