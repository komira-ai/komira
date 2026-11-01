"""The cases of the heavy checks (rules.bzl HEAVY): which labels a change builds
when a row's target is one it owns nothing of, over a graph written out here, and
the shipped row held to the paths that own it. cases.bxl runs them.

The graph (labels `k//package:name`):

    src/a/a.mojo  -> k//src/a:a         k//src/a:a_test tests it
    src/h/h.mojo  -> k//src/h:heavy     depends on a:a; k//src/h:h_root depends on heavy
    src/g/g.mojo  -> k//src/g:heavy2    depends on a:a; k//src/g:g_root depends on heavy2
    src/r/r.mojo  -> k//src/r:r         depends on heavy (a check of its own that needs it)

Two rows: heavy owned by `src/h/**` and `ci/**` with root h_root, heavy2 owned by
`src/g/**` with root g_root.
"""

load(":affected.bzl", "AFFECTED", "WIDENED", "heavy_split", "plan", "select")
load(":ci_graph.bzl", "default_findings")
load(":rules.bzl", "HEAVY", "INERT", "WIDEN")

_FILES = {
    "src/a/a.mojo": True,
    "src/h/h.mojo": True,
    "src/g/g.mojo": True,
    "src/r/r.mojo": True,
    "tools/build/x.zig": True,
    "ci/BUCK": True,
    "ci/targets.bzl": True,
}
_OWNERS = {
    "src/a/a.mojo": ["k//src/a:a"],
    "src/h/h.mojo": ["k//src/h:heavy"],
    "src/g/g.mojo": ["k//src/g:heavy2"],
    "src/r/r.mojo": ["k//src/r:r"],
    "ci/targets.bzl": ["k//ci:pr"],
}
_DEPENDENTS = {
    "k//src/a:a": ["k//src/a:a_test", "k//src/h:heavy", "k//src/g:heavy2"],
    "k//src/h:heavy": ["k//src/h:h_root", "k//src/r:r"],
    "k//src/g:heavy2": ["k//src/g:g_root"],
}

def _reverse_closure(seeds):
    seen = {}
    todo = list(seeds)
    for _ in range(1000):
        if not todo:
            break
        t = todo.pop()
        if t in seen:
            continue
        seen[t] = True
        todo += _DEPENDENTS.get(t, [])
    return seen.keys()

_GRAPH = struct(
    exists = lambda p: p in _FILES,
    owners = lambda p: _OWNERS.get(p, []),
    package_targets = lambda d: [],
    including = lambda p: [],
    rdeps = _reverse_closure,
)

_H = ("k//src/h:heavy", ["src/h/**", "ci/**"], ["k//src/h:h_root", "k//src/r:r"], "one compile")
_G = ("k//src/g:heavy2", ["src/g/**"], ["k//src/g:g_root"], "another compile")

_WIDEN = [("tools/build/**", "the build system")]

_AGG = "k//ci:pr"
_DEFAULT = "k//ci:pr_default"

def _labels(heavy, changed):
    rules = struct(widen = _WIDEN, inert = [], heavy = heavy)
    v = select(rules, changed, _GRAPH, "ci")
    if v.kind not in [AFFECTED, WIDENED]:
        return "the verdict is " + v.kind
    return sorted(plan(rules, changed, _GRAPH, v, _AGG, _DEFAULT)[0])

def _case(out, name, heavy, changed, wanted):
    got = _labels(heavy, changed)
    if got != sorted(wanted):
        out.append("heavy: {}: {}, wanted {}".format(name, got, sorted(wanted)))

def _plan_cases():
    out = []
    a_all = ["k//src/a:a", "k//src/a:a_test"]

    # a change that owns nothing of a row loses the row's target and everything above it
    _case(out, "a change outside both rows loses both and what depends on them", [_H, _G], ["src/a/a.mojo"], a_all)
    _case(out, "a change that owns one row keeps that row only", [_H, _G], ["src/g/g.mojo"], ["k//src/g:heavy2", "k//src/g:g_root"])
    _case(out, "a change of both rows' own keeps what each reaches", [_H, _G], ["src/g/g.mojo", "src/h/h.mojo"], ["k//src/g:heavy2", "k//src/g:g_root", "k//src/h:heavy", "k//src/h:h_root", "k//src/r:r"])
    _case(out, "a leaf and an own file keep every target of the leaf's reach that the owned row reaches", [_H], ["src/a/a.mojo", "src/h/h.mojo"], a_all + ["k//src/h:heavy", "k//src/h:h_root", "k//src/r:r", "k//src/g:heavy2", "k//src/g:g_root"])
    _case(out, "a check that depends on the heavy target is left out with it", [_H], ["src/r/r.mojo"], [_DEFAULT])

    # no row, or every row owned: the verdict as it was
    _case(out, "with no rows the verdict is unchanged", [], ["src/a/a.mojo"], a_all + ["k//src/h:heavy", "k//src/h:h_root", "k//src/r:r", "k//src/g:heavy2", "k//src/g:g_root"])
    _case(out, "with no rows a widening is the full aggregate", [], ["tools/build/x.zig"], [_AGG])

    # a widening, whichever file made it
    _case(out, "a widening that owns nothing is the default aggregate", [_H, _G], ["tools/build/x.zig"], [_DEFAULT])
    _case(out, "a widening with one row's own file is the default and that row's roots", [_H, _G], ["tools/build/x.zig", "src/g/g.mojo"], [_DEFAULT, "k//src/g:g_root"])
    _case(out, "a widening with the roots of a row with two of them", [_H, _G], ["tools/build/x.zig", "src/h/h.mojo"], [_DEFAULT, "k//src/h:h_root", "k//src/r:r"])
    _case(out, "a widening that owns every row is the full aggregate", [_H, _G], ["tools/build/x.zig", "src/h/h.mojo", "src/g/g.mojo"], [_AGG])
    _case(out, "a change to the aggregate's own files owns the row that names ci/**, not the other", [_H, _G], ["ci/targets.bzl"], [_DEFAULT, "k//src/h:h_root", "k//src/r:r"])
    return out

def _split_cases():
    out = []
    wanted, left = heavy_split(struct(heavy = [_H, _G]), ["src/h/h.mojo", "docs/a.md", ""])
    if [r[0] for r in wanted] != ["k//src/h:heavy"] or [r[0] for r in left] != ["k//src/g:heavy2"]:
        out.append("heavy split: wanted [heavy] and left [heavy2], got {} and {}".format([r[0] for r in wanted], [r[0] for r in left]))
    wanted, left = heavy_split(struct(heavy = [_H]), [])
    if wanted or len(left) != 1:
        out.append("heavy split: no changed file owns nothing, got wanted {}".format(wanted))
    for path in ["src/h", "src/hx/h.mojo", "src/g/g.mojo"]:
        wanted, _ = heavy_split(struct(heavy = [_H]), [path])
        if wanted:
            out.append("heavy split: '{}' is not under src/h/**".format(path))
    return out

# ---- the shipped rows ------------------------------------------------------------
#
# Every row's own paths hold the selector's and the aggregate's own files (a change to how
# the check set is chosen runs the whole of it), and kci's row owns its own directories and
# nothing a shared library or the build system reaches it through.

_OWNED = [
    "bin/kci/main.mojo",
    "bin/kci/BUCK",
    "src/kci_api/BUCK",
    "src/kci_resource_proto/src/x.mojo",
    "packaging/images/base/BUCK",
    "ci/targets.bzl",
    "tools/build/ci/affected.bzl",
]

_NOT_OWNED = [
    "src/komira_json/BUCK",
    "src/komira_core/src/komira_core/x.mojo",
    "tools/build/mojo/defs.bzl",
    "tools/build/proto-codegen/BUCK",
    "src/kcix/BUCK",
    "bin/kcix/main.mojo",
    "docs/ci.md",
]

def _shipped_cases():
    out = []
    shipped = struct(heavy = HEAVY)
    kci = [r for r in HEAVY if r[0] == "komira//bin/kci:kci"]
    if len(kci) != 1:
        return ["heavy shipped: the row of komira//bin/kci:kci is missing from HEAVY"]
    for p in _OWNED:
        wanted, _ = heavy_split(struct(heavy = kci), [p])
        if not wanted:
            out.append("heavy shipped: '{}' must own the kci row".format(p))
    for p in _NOT_OWNED:
        wanted, _ = heavy_split(struct(heavy = kci), [p])
        if wanted:
            out.append("heavy shipped: '{}' must not own the kci row".format(p))
    for r in shipped.heavy:
        if "ci/**" not in r[1] or "tools/build/ci/**" not in r[1]:
            out.append("heavy shipped: the row of {} must own ci/** and tools/build/ci/**".format(r[0]))
        if not r[2]:
            out.append("heavy shipped: the row of {} names no root".format(r[0]))
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
    return _plan_cases() + _split_cases() + _shipped_cases() + _guard_cases()
