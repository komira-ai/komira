"""The aggregate's side of the check set, asked of Buck2 from a BXL script.

`check_nodes`, `roots`, `closure` and `missing` (configured, cquery): which
targets are checks, which of them nothing else depends on (the list `//ci:pr`
holds), and which of them a given aggregate does not reach. The selector's
graph facade (`make_graph`, `without_left_out`) is buildrules'
`rules/affected/graph.bzl`.
"""

load(":rules.bzl", "SOURCE_KINDS")

def check_nodes(ctx, scope, excluded, left_out = []):
    """label -> configured node of every check in `scope` (cquery: a target
    incompatible with the host platform is not there, as a build pattern
    skips it), without the aggregate's package and without the patterns of
    `left_out` (rules.bzl EXCLUDED: the checks the aggregate leaves out on
    purpose)."""
    # uquery first: a cquery of the patterns would configure the aggregate too, and
    # an aggregate whose list is stale fails there, before the guard can say why.
    gone = " - ".join([excluded] + ["(" + p + ")" for p in left_out])
    labels = [str(t.label) for t in ctx.uquery().eval("({}) - {}".format(" + ".join(["(" + s + ")" for s in scope]), gone))]
    nodes = ctx.cquery().eval("set({})".format(" ".join(labels))) if labels else []
    return {str(n.label.raw_target()): n for n in nodes if n.rule_type not in SOURCE_KINDS}

# The rules that register execution platforms (tools/build/platforms/defs.bzl).
# They depend on a platform target only when `[komira_re]` or the host names a
# worker for it, so the edge is configuration of the checkout, not of the
# check set: `roots` does not follow it (a platform is a root whichever
# checkout generates the list).
REGISTRATION_KINDS = ["local_execution_platforms", "remote_execution_platforms"]

def is_registration(node):
    """Whether `node` is an execution-platform registration."""
    return node.rule_type.split(":")[-1] in REGISTRATION_KINDS

# The lints that depend on tests only to analyse them: the surface capability
# matrix (tools/build/lint/surface_capability_matrix.bzl) names a test target
# for each filled cell, and its analysis reads the target's providers, but it
# never builds or runs the test. `roots` does not follow those edges either,
# or filling a cell would drop its test from the check set and from TESTS,
# the list `buck2 test //ci:pr` runs.
NAMING_KINDS = ["_surface_capability_matrix_rule"]

def names_only(node):
    """Whether `node` is a lint that names its dependencies without building them."""
    return node.rule_type.split(":")[-1] in NAMING_KINDS

def roots(nodes):
    """The sorted labels of the checks no other check depends on, not counting
    the edges of an execution-platform registration (REGISTRATION_KINDS): which
    platforms it names depends on the checkout's `[komira_re]`, and a list that
    depended on it would lose the platform row of a checkout that names a macOS
    worker, which the check of a checkout that names none still builds. Nor
    the edges of a lint that names tests without building them (NAMING_KINDS),
    so that each test stays a root, built and run by the check set."""
    depended = {}
    for node in nodes.values():
        if is_registration(node) or names_only(node):
            continue
        for d in node.deps():
            depended[str(d.label.raw_target())] = True
    return sorted([l for l in nodes.keys() if l not in depended])

def closure(ctx, aggregate):
    """label -> True of every target `aggregate` reaches (every kind of dependency)."""
    return {str(n.label.raw_target()): True for n in ctx.cquery().eval("deps({})".format(aggregate))}

def missing(required, reached):
    """The sorted labels of `required` (a list) the aggregate's `reached` closure lacks."""
    return sorted([l for l in required if l not in reached])

# The command that writes every file of ci/roots/ and ci/test_roots/ (roots.bzl) from the
# graph. It runs the generator into a directory of buck-out first and copies only from a
# directory that is not `/` (an empty output would make a bare `cp ... "$(...)"/. ci/` copy the
# whole filesystem). Only once the generator has succeeded does it delete every file of the two
# trees, committed (`git rm`) or not (`git clean`, so a stale file nobody committed goes too),
# copy the new ones in and stage them. The files are empty, so forcing the deletion loses
# nothing the copy does not write again.
REGENERATE = 'out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d "$out" ] && [ "$out" != / ] && git rm -rqf --ignore-unmatch ci/roots ci/test_roots && git clean -fdq -- ci/roots ci/test_roots && cp -rL --no-preserve=mode "$out"/. ci/ && git add ci/roots ci/test_roots'

def is_test(ctx, node):
    """Whether Buck2 can run `node` as a test: a rule kind holding `test` whose analysis
    provides ExternalRunnerTestInfo."""
    if "test" not in node.rule_type.split(":")[-1]:
        return False
    return ExternalRunnerTestInfo in ctx.analysis(node).providers()

def findings(required, reached, aggregate):
    """The guard's failure text for the targets of `required` outside `reached`, or ""."""
    out = missing(required, reached)
    if not out:
        return ""
    shown = out[:25]
    return "{} check target(s) are outside {} (first {}): {}. Regenerate its list: {}".format(
        len(out),
        aggregate,
        len(shown),
        ", ".join(shown),
        REGENERATE,
    )

def default_findings(rows, full, default, reaches, aggregate, default_aggregate):
    """The failure texts of the default aggregate against the rows of HEAVY (rules.bzl), or [].

    `full` and `default` are the closures (label -> True) of the full and the default
    aggregate, `reaches(root, target)` says whether a root reaches a target. A row is
    (target, own, roots, reason). A finding for a row whose target the full aggregate does
    not reach (the row is stale: delete it), for a target the default aggregate reaches (a
    root that reaches it is not in the row's roots), and for a root that reaches nothing
    heavy (it is left out for nothing: delete it from the row)."""
    out = []
    for row in rows:
        target, roots_of_row = row[0], row[2]
        if target not in full:
            out.append("{} is not reached from {}: its row of HEAVY (tools/build/ci/rules.bzl) is stale".format(target, aggregate))
            continue
        if target in default:
            out.append("{} still reaches {}: a root that reaches it is missing from the roots of its row of HEAVY (tools/build/ci/rules.bzl)".format(default_aggregate, target))
        for r in roots_of_row:
            if not reaches(r, target):
                out.append("{} is left out of {} for {}, which it does not reach: delete it from the roots of the row".format(r, default_aggregate, target))
    return out

def root_findings(want, have):
    """The guard's failure text for committed root files (roots.bzl) that are out of date, or "".

    `want` is the paths (relative to the cell) the graph's roots need (`root_files`), `have`
    the paths committed under ci/roots/ and ci/test_roots/. A root with no file is missing (a
    target nothing depends on, or a test filed as a plain root: its `ci/test_roots/` file is
    the one wanted); a file no root needs is stale (its target is gone, now has a dependent,
    is filed in the wrong tree, or the path names no label). Each is named by its path, the
    file to add or to delete."""
    want_set = {p: True for p in want}
    have_set = {p: True for p in have}
    missing = sorted([p for p in want if p not in have_set])
    stale = sorted([p for p in have if p not in want_set])
    out = []
    if missing:
        out.append("{} root(s) of the check set have no file (first {}, add each as an empty file): {}".format(len(missing), min(len(missing), 10), " ".join(missing[:10])))
    if stale:
        out.append("{} file(s) name no root of the check set (first {}, delete each): {}".format(len(stale), min(len(stale), 10), " ".join(stale[:10])))
    if not out:
        return ""
    return "the committed roots of //ci:pr (ci/roots/, ci/test_roots/) are out of date: {}. Add and delete those files, or write every one from the graph: {}".format("; ".join(out), REGENERATE)

# ---- Python in the aggregate ------------------------------------------------

# Packages whose every target is Python (the hermetic Python of the tests and its rules).
PYTHON_PACKAGES = ["third_party/python", "tools/build/python"]

# The prelude's C/C++ rules name Python helper programs as attributes, run by the
# `python_bootstrap` toolchain's interpreter. komira's toolchain provides none, so
# these two kinds are not Python (the graph check python_closure says the same).
NO_INTERPRETER_KINDS = ["python_bootstrap_binary", "no_python_bootstrap_toolchain"]

# A doc_tree holds every file of its package as data for the lints, a `.py`
# file among them; nothing runs it (python_closure does not walk it either).
DATA_KINDS = ["doc_tree"]

def kind_name(rule_type):
    """`cell//path.bzl:_name_rule` -> `name`."""
    k = rule_type.split(":")[-1].lstrip("_")
    return k[:-len("_rule")] if k.endswith("_rule") else k

def package_of(label):
    """`cell//a/b:c` (configured or not) -> `a/b`."""
    return label.split(" ")[0].split("//", 1)[-1].split(":")[0]

def _in_package(package, root):
    return package == root or package.startswith(root + "/")

def python_reason(label, kind, srcs):
    """Why a target is Python, or "": a rule kind whose name holds `python` or
    starts with `py_`, a target of the hermetic-Python packages, or a `.py`
    source. The two bootstrap kinds and the doc_tree are none of these."""
    k = kind_name(kind)
    if k in NO_INTERPRETER_KINDS or k in DATA_KINDS:
        return ""
    if "python" in k or k.startswith("py_"):
        return "rule kind " + k
    for p in PYTHON_PACKAGES:
        if _in_package(package_of(label), p):
            return "a target of " + p
    for s in srcs:
        if s.endswith(".py"):
            return "source " + s
    return ""

def python_findings(nodes, surface, own_deps, aggregate):
    """The failure text for the Python targets `aggregate` reaches outside the
    Python SDK, or "". `nodes` is a list of structs (label, kind, srcs) of the
    aggregate's closure, `surface` the package paths of the Python SDK
    (PYTHON_SURFACE) and `own_deps` the labels the SDK's own targets reach:
    Python inside either is allowed, anything else is a finding."""
    found = []
    for n in nodes:
        why = python_reason(n.label, n.kind, n.srcs)
        if not why:
            continue
        if any([_in_package(package_of(n.label), s) for s in surface]) or n.label in own_deps:
            continue
        found.append("{} ({})".format(n.label, why))
    if not found:
        return ""
    found = sorted(found)
    return "{} Python target(s) are reached from {} outside the Python SDK's tests (first {}): {}. Python serves only the SDK (PYTHON_SURFACE in tests/python_closure_allowlist.bzl): leave them out of the aggregate with a row of EXCLUDED in tools/build/ci/rules.bzl, then write its roots again: {}.".format(
        len(found),
        aggregate,
        min(len(found), 25),
        ", ".join(found[:25]),
        REGENERATE,
    )

def python_nodes(ctx, aggregate):
    """The structs (label, kind, srcs) of every target `aggregate` reaches."""
    out = []
    for n in ctx.cquery().eval("deps({})".format(aggregate)):
        out.append(struct(
            label = str(n.label.raw_target()),
            kind = n.rule_type,
            srcs = [s.short_path for s in n.sources()],
        ))
    return out

def sdk_own_deps(ctx, nodes, surface):
    """label -> True of every target the Python SDK's own targets (those in a
    package of `surface`) reach: their wheels and interpreter."""
    own = [n.label for n in nodes if any([_in_package(package_of(n.label), s) for s in surface])]
    if not own:
        return {}
    return {str(n.label.raw_target()): True for n in ctx.cquery().eval("deps(set({}))".format(" ".join(own)))}
