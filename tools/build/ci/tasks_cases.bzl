"""The cases of the common-task examples in the check set's generated list (run by cases.bxl).

`task_examples` (python/task_examples.bzl) declares one wheel test per task
directory and per probe, and an aggregate of them, `:examples`, so that the
generated list (ci/targets.bzl and its shards) names the aggregate and no task:
a pull request that adds a task directory then edits no generated file, and two
such pull requests do not conflict there.

The fixture is two trees declared as python/docs/tasks/BUCK declares the real
one (python/docs/task_tree_fixture/): `before` with two task directories (one
with a probe), `after` the same with one directory more. A fixture directory
holds an expected output and, in 2-b, a probe: the macro reads the directory
names and the probe file names, never their contents. The cases configure
them (nothing builds them) and hold:

  - the generated files: the roots of each tree, written as the real package's
    rows, render the same loader and shards byte for byte;
  - the one row: each tree's only root is its `:examples`;
  - what the row builds: every task directory and probe of each tree, the added
    one too, has its own target named after it, and `:examples` reaches it;
  - the real package: its roots are `:examples` and the targets that do not
    change with the tree (the pages check and the four refusals), and its
    aggregate reaches every task directory's target.
"""

load(":ci_graph.bzl", "check_nodes", "closure", "render_all", "roots")
load(":rules.bzl", "AGGREGATE", "EXCLUDED")

TASKS_PACKAGE = "komira//python/docs/tasks"

_FIXTURE = "komira//python/docs/task_tree_fixture"
_BEFORE = _FIXTURE + "/before"
_AFTER = _FIXTURE + "/after"

# The checks of each fixture tree: one target per task directory and per probe, and the aggregate.
_BEFORE_CHECKS = ["1-a", "2-b", "2-b__probe_x", "examples"]
_AFTER_CHECKS = ["1-a", "2-b", "2-b__probe_x", "3-c", "examples"]

# The roots of the real package that do not change with its tree (python/docs/tasks/BUCK).
_REAL_ROOTS = [
    "examples",
    "pages",
    "refuses_example_that_raises",
    "refuses_probe_that_runs",
    "refuses_probe_with_another_error",
    "refuses_wrong_expected_output",
]

def _labels(package, names):
    return ["{}:{}".format(package, n) for n in names]

def _as_real(labels, package):
    """`labels` of `package` written as rows of the real tasks package."""
    return [TASKS_PACKAGE + l[len(package):] for l in labels]

def generated_files_differ(before, after):
    """The paths of the generated files whose lines differ between two
    `render_all` outputs (path -> lines), sorted; [] when they are byte-identical."""
    paths = sorted({p: True for p in before.keys() + after.keys()}.keys())
    return [p for p in paths if before.get(p) != after.get(p)]

def _without_doc_tree(nodes):
    """`nodes` without the package's `doc_tree`, which every package declares
    (tools/build/lint/doc_tree.bzl) and which is a root only within one package:
    in the whole check set the parent package's doc_tree depends on it."""
    return {l: n for l, n in nodes.items() if l.split(":")[1] != "doc_tree"}

def _fixture_nodes(ctx, package):
    return _without_doc_tree(check_nodes(ctx, [package + ":"], AGGREGATE.split(":")[0] + ":"))

def task_tree_cases(ctx):
    """The cases above, over the configured fixture and the real package."""
    out = []
    before = _fixture_nodes(ctx, _BEFORE)
    after = _fixture_nodes(ctx, _AFTER)

    # adding a task directory leaves every generated file byte-identical
    files_before = render_all(_as_real(roots(before), _BEFORE), [])
    files_after = render_all(_as_real(roots(after), _AFTER), [])
    differ = generated_files_differ(files_before, files_after)
    if differ:
        out.append("tasks: adding the task directory 3-c changed the generated files {}: the roots were {}, then {}".format(
            ", ".join(differ),
            roots(before),
            roots(after),
        ))

    # the one row of each tree is its aggregate
    for package, nodes in [(_BEFORE, before), (_AFTER, after)]:
        if roots(nodes) != [package + ":examples"]:
            out.append("tasks: the roots of {} are {}, wanted only {}:examples".format(package, roots(nodes), package))

    # every task directory and probe, the added one too, is a target named after it that the row builds
    for package, nodes, names in [(_BEFORE, before, _BEFORE_CHECKS), (_AFTER, after, _AFTER_CHECKS)]:
        if sorted(nodes.keys()) != _labels(package, names):
            out.append("tasks: the checks of {} are {}, wanted {}".format(package, sorted(nodes.keys()), _labels(package, names)))
        reached = closure(ctx, package + ":examples")
        lost = [l for l in _labels(package, names) if l not in reached]
        if lost:
            out.append("tasks: {}:examples does not reach {}".format(package, ", ".join(lost)))

    # the real package: one row for its tasks, beside the targets that never change with the tree
    real = _without_doc_tree(check_nodes(ctx, [TASKS_PACKAGE + ":"], AGGREGATE.split(":")[0] + ":", [p for p, _ in EXCLUDED]))
    if roots(real) != _labels(TASKS_PACKAGE, _REAL_ROOTS):
        out.append("tasks: the roots of {} are {}, wanted {}: a task's target must be reached from :examples, not be a row of its own".format(
            TASKS_PACKAGE,
            roots(real),
            _labels(TASKS_PACKAGE, _REAL_ROOTS),
        ))
    reached = closure(ctx, TASKS_PACKAGE + ":examples")
    per_task = [l for l in real.keys() if l.split(":")[1][0].isdigit()]
    if not per_task:
        out.append("tasks: {} has no target of a task directory".format(TASKS_PACKAGE))
    lost = sorted([l for l in per_task if l not in reached])
    if lost:
        out.append("tasks: {}:examples does not reach {}".format(TASKS_PACKAGE, ", ".join(lost)))

    # the comparison itself: a differing shard is named, identical outputs name none
    if generated_files_differ({"a": ["x"], "b": ["y"]}, {"a": ["x"], "b": ["z"]}) != ["b"]:
        out.append("tasks: generated_files_differ must name the one file whose lines differ")
    if generated_files_differ({"a": ["x"]}, {"a": ["x"], "c": []}) != ["c"]:
        out.append("tasks: generated_files_differ must name a file only one side has")
    if generated_files_differ(files_before, files_before) != []:
        out.append("tasks: generated_files_differ must find nothing between identical outputs")
    return out
