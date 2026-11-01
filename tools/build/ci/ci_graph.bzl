"""The graph of the check set, asked of Buck2 from a BXL script.

`make_graph` is the facade `affected.bzl` selects over (owners, packages,
reverse dependencies, all uquery); `check_nodes`, `roots`, `closure` and
`missing` are the aggregate's side (configured, cquery): which targets are
checks, which of them nothing else depends on (the list `//ci:pr` holds),
and which of them a given aggregate does not reach.
"""

load(":rules.bzl", "SOURCE_KINDS")

def _label(node):
    return str(node.label)

def _is_buck_file(f):
    return str(f).split("/")[-1] == "BUCK"

def make_graph(ctx, scope, excluded):
    """The facade over the real graph. `scope` is a list of target patterns,
    `excluded` a pattern removed from the universe the reverse-dependency
    query answers over (the aggregate's package)."""
    uq = ctx.uquery()
    cell = ctx.cell_root()
    scope_expr = " + ".join(["(" + s + ")" for s in scope])
    state = {}

    def exists(path):
        return ctx.fs.exists(cell + "/" + path)

    def owners(path):
        return [_label(t) for t in uq.owner(path)]

    def package_targets(d):
        return [_label(t) for t in uq.targets_in_buildfile(d + "/BUCK" if d else "BUCK")]

    def including(bzl):
        if "buildfiles" not in state:
            state["buildfiles"] = uq.buildfile(uq.eval(scope_expr))
        loaders = [str(f) for f in uq.rbuildfiles(state["buildfiles"], bzl) if _is_buck_file(f)]
        if not loaders:
            return []
        return [_label(t) for t in uq.targets_in_buildfile(loaders)]

    def rdeps(seeds):
        if "universe" not in state:
            state["universe"] = uq.eval("({}) - {}".format(scope_expr, excluded))
        return [_label(t) for t in uq.rdeps(state["universe"], seeds)]

    return struct(exists = exists, owners = owners, package_targets = package_targets, including = including, rdeps = rdeps)

def without_left_out(ctx, targets, left_out):
    """`targets` (labels) without those the patterns of `left_out` match: the
    selector leaves out what the aggregate leaves out (rules.bzl EXCLUDED), so a
    change to a file an excluded target owns never selects it."""
    if not left_out or not targets:
        return list(targets)
    gone = {str(t.label): True for t in ctx.uquery().eval(" + ".join(["(" + p + ")" for p in left_out]))}
    return [t for t in targets if t not in gone]

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

def roots(nodes):
    """The sorted labels of the checks no other check depends on, not counting
    the edges of an execution-platform registration (REGISTRATION_KINDS): which
    platforms it names depends on the checkout's `[komira_re]`, and a list that
    depended on it would lose the platform row of a checkout that names a macOS
    worker, which the check of a checkout that names none still builds."""
    depended = {}
    for node in nodes.values():
        if is_registration(node):
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

# ci/targets.bzl is a small loader of SHARDS files, ci/targets/shard_<n>.bzl, each
# holding the rows of the packages that hash to it (shard_of). A package's rows
# stay together and adding a package moves no other package's rows; the hash,
# not the package's name, spreads them, so no prefix (`komira_`, `kci_`) or
# top-level directory (`src/` holds most) can fill one shard. Raising SHARDS
# re-spreads every row (the generator rewrites them all).
SHARDS = 8

# A generated file stays under this many lines (CLAUDE.md: "files under 1000
# lines"); `shard_findings` fails the guard before a shard reaches it.
LINE_LIMIT = 1000

REGENERATE = 'out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d "$out" ] && [ "$out" != / ] && cp -rL --no-preserve=mode "$out"/. ci/'

def shard_of(label):
    """The shard (0 .. SHARDS - 1) of the package of `label`: a polynomial hash
    of the package path (`cell//a/b:c` -> `a/b`)."""
    h = 0
    for c in package_of(label).elems():
        h = (h * 31 + ord(c)) % 65521
    return h % SHARDS

def shard_path(n):
    return "ci/targets/shard_{}.bzl".format(n)

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

def render_shard(root_labels, test_labels):
    """The lines of one shard, ci/targets/shard_<n>.bzl."""
    lines = [
        "# GENERATED by `{}`; do not edit.".format(REGENERATE),
        "# The rows of the packages of one shard of the check set: see tools/build/ci/targets.bxl.",
        "# `guard.bxl:check` fails the pull request check when this file is out of date.",
        "",
        "TARGETS = [",
    ]
    lines += ['    "{}",'.format(l) for l in root_labels]
    lines += ["]", "", "TESTS = ["]
    lines += ['    "{}",'.format(l) for l in test_labels]
    lines += ["]", ""]
    return lines

def render_loader():
    """The lines of ci/targets.bzl: it loads every shard and exposes TARGETS and
    TESTS, each the sorted union of the shards' lists."""
    lines = [
        "# GENERATED by `{}`; do not edit.".format(REGENERATE),
        "# The roots of the check set and the tests among them, loaded from the shards",
        "# of ci/targets/: see tools/build/ci/targets.bxl.",
        "",
    ]
    for n in range(SHARDS):
        lines.append('load("//ci/targets:shard_{n}.bzl", _TARGETS_{n} = "TARGETS", _TESTS_{n} = "TESTS")'.format(n = n))
    lines += ["", "TARGETS = sorted(" + " + ".join(["_TARGETS_{}".format(n) for n in range(SHARDS)]) + ")", ""]
    lines += ["TESTS = sorted(" + " + ".join(["_TESTS_{}".format(n) for n in range(SHARDS)]) + ")", ""]
    return lines

def render_all(root_labels, test_labels):
    """path (relative to the cell) -> lines of every generated file: the loader
    and each shard (an empty shard is a file all the same)."""
    out = {"ci/targets.bzl": render_loader()}
    for n in range(SHARDS):
        out[shard_path(n)] = render_shard(
            [l for l in root_labels if shard_of(l) == n],
            [l for l in test_labels if shard_of(l) == n],
        )
    return out

def shard_findings(want_targets, have_targets, have_tests):
    """The guard's failure text for a stale or oversized shard set, or "".
    `want_targets` is what the graph says (roots), `have_targets` and
    `have_tests` what the checked-in loader exposes. The line counts are those
    of the files `render_all` makes from the lists the loader exposes (a BXL
    script reads no file's text), which are the files' lines when generated."""
    out = []
    want = {l: True for l in want_targets}
    have = {l: True for l in have_targets}
    gone = sorted([l for l in have_targets if l not in want])
    new = sorted([l for l in want_targets if l not in have])
    if gone:
        out.append("{} row(s) of the shards are no longer roots of the check set (first {}): {}".format(len(gone), min(len(gone), 10), ", ".join(gone[:10])))
    if new:
        out.append("{} root(s) of the check set are in no shard (first {}): {}".format(len(new), min(len(new), 10), ", ".join(new[:10])))
    for l in have_tests:
        if l not in have:
            out.append("TESTS row {} is not a row of TARGETS".format(l))
    if out:
        return "ci/targets.bzl is out of date: {}. Regenerate it and its shards: {}".format("; ".join(out), REGENERATE)
    big = []
    for path, lines in render_all(have_targets, have_tests).items():
        if len(lines) >= LINE_LIMIT:
            big.append("{} would be {} lines".format(path, len(lines)))
    if big:
        return "a generated target list reaches the {}-line limit of a file ({}): raise SHARDS in tools/build/ci/ci_graph.bzl, then regenerate: {}".format(LINE_LIMIT, "; ".join(sorted(big)), REGENERATE)
    return ""

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
    return "{} Python target(s) are reached from {} outside the Python SDK's tests (first {}): {}. Python serves only the SDK (PYTHON_SURFACE in tests/python_closure_allowlist.bzl): leave them out of the aggregate with a row of EXCLUDED in tools/build/ci/rules.bzl, then regenerate ci/targets.bzl.".format(
        len(found),
        aggregate,
        min(len(found), 25),
        ", ".join(found[:25]),
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
