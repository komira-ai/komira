"""The cases of the heavy checks (rules.bzl HEAVY) that are this repository's:
the shipped rows held to the paths that own them, and the guard of the default
aggregate (ci_graph.bzl `default_findings`). How a row changes the labels of a
change (`plan`, `heavy_split`) is buildrules' `rules/affected`, which holds those
cases. cases.bxl runs them.

The rows of the guard's cases (labels `k//package:name`): heavy owned by
`src/h/**` and `ci/**` with roots h_root and r, in front of the aggregate
`k//ci:pr` and its default `k//ci:pr_default`.
"""

load("@buildrules//rules/affected:defs.bzl", "heavy_split")
load(":ci_graph.bzl", "default_findings")
load(":rules.bzl", "HEAVY")

_H = ("k//src/h:heavy", ["src/h/**", "ci/**"], ["k//src/h:h_root", "k//src/r:r"], "one compile")

_AGG = "k//ci:pr"
_DEFAULT = "k//ci:pr_default"

# ---- the shipped rows ------------------------------------------------------------
#
# Every row's own paths hold the selector's and the aggregate's own files (a change to how
# the check set is chosen runs the whole of it). The selector's mapping is buildrules', behind
# the pin in .buckconfig, so .buckconfig is one of them.

_SELECTOR_FILES = [
    ".buckconfig",
    "ci/BUCK",
    "ci/roots/komira/src/containers:ci",
    "tools/build/ci/affected.bxl",
]

def _shipped_cases():
    out = []
    for r in HEAVY:
        if "ci/**" not in r[1] or "tools/build/ci/**" not in r[1]:
            out.append("heavy shipped: the row of {} must own ci/** and tools/build/ci/**".format(r[0]))
        if not r[2]:
            out.append("heavy shipped: the row of {} names no root".format(r[0]))
        for p in _SELECTOR_FILES:
            wanted, _ = heavy_split(struct(heavy = [r]), [p])
            if not wanted:
                out.append("heavy shipped: '{}' must own the row of {}".format(p, r[0]))
    return out

# ---- the default aggregate's guard -------------------------------------------------

def _guard_cases():
    out = []
    rows = [_H]
    full = {"k//src/h:heavy": True, "k//src/h:h_root": True, "k//src/r:r": True, "k//src/a:a": True}
    default = {"k//src/a:a": True}
    reach = {"k//src/h:h_root": ["k//src/h:heavy"], "k//src/r:r": ["k//src/h:heavy"]}

    def reaches(root, target):
        return target in reach.get(root, [])

    def case(name, rows, full, default, reaches, wanted_substrings):
        got = default_findings(rows, full, default, reaches, _AGG, _DEFAULT)
        text = "; ".join(got)
        if not wanted_substrings and got:
            out.append("heavy guard: {}: findings {}".format(name, text))
        for w in wanted_substrings:
            if w not in text:
                out.append("heavy guard: {}: '{}' not in '{}'".format(name, w, text))
        if wanted_substrings and len(got) != len(wanted_substrings):
            out.append("heavy guard: {}: {} finding(s), wanted {}: {}".format(name, len(got), len(wanted_substrings), text))

    case("a default aggregate without the heavy target passes", rows, full, default, reaches, [])
    case("a default aggregate that reaches the heavy target fails", rows, full, dict(default, **{"k//src/h:heavy": True}), reaches, ["k//ci:pr_default still reaches k//src/h:heavy"])
    case("a root left out that reaches nothing heavy fails", rows, full, default, lambda r, t: r == "k//src/h:h_root", ["k//src/r:r is left out of k//ci:pr_default for k//src/h:heavy"])
    case("a row whose target the full aggregate does not reach is stale", rows, {"k//src/a:a": True}, default, reaches, ["is not reached from k//ci:pr"])
    return out

def heavy_cases():
    return _shipped_cases() + _guard_cases()
