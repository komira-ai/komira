"""The check of the common-task pages (python/docs/tasks/BUCK, `:pages`).

`task_pages_check(name, catalogue, tree, catalogue_display, display)` runs
`tasks-check` of the README examples tool (//tools/build/readme_examples:tool,
tools/build/readme_examples/tasks.zig) over the catalogue `catalogue`
(docs/tasks/catalogue.json) and the task directories of `tree`, a directory
whose subdirectories are the task directories: every directory is named after
a catalogue entry that is not a gap and holds example.py, expected_output.txt,
page.md and nothing but probe pairs, its page shows its files through include
markers that equal them byte for byte (tools/build/readme_examples/task_page.zig),
and every gap names its issues. A refusal names the catalogue
`catalogue_display` and the task files under `display`, and fails the build.
The output, `<name>.txt`, is the tool's report: `<directory> <status>` per task
directory. What each example prints, or each probe fails with, is held by its wheel
test, not here.

`task_examples(name, files, tree, python, wheels, script)` declares those
wheel tests: one `wheel_install_test` per task directory of `files` (the
package's `glob(["*/**"])`), named as the directory, and one per probe,
`<task>__probe_<name>`, each running `script` with `--task <task>` or
`--probe <task>/<name>` over `tree`. It also declares `name`, a
`ci_aggregate` (tools/build/ci/aggregate.bzl) of every one of them. Each wheel
test is a dependency of `name`, so none is a root of the check set: the
check set's root files (ci/roots/, tools/build/ci/roots.bzl) hold `name` alone, and
adding or removing a task directory adds or deletes none. Building `name` builds every
wheel test, and a failing one fails the build under its own label, the
directory's name. `task_dirs(files)` and `task_probes(files)` are the two
lists it reads off `files`.
"""

load("@komira//python:install_test.bzl", "wheel_install_test")
load("@komira//tools/build/ci:aggregate.bzl", "ci_aggregate")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _task_pages_check_impl(ctx):
    tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "tasks-check",
            "--catalogue",
            ctx.attrs.catalogue,
            "--catalogue-display",
            ctx.attrs.catalogue_display,
            "--root",
            tree,
            "--display",
            ctx.attrs.display,
            "--out",
            out.as_output(),
        ),
        category = "task_pages_check",
    )
    return [DefaultInfo(default_output = out)]

_task_pages_check = rule(
    impl = _task_pages_check_impl,
    doc = "The catalogue of common tasks against one language's task directories (python/task_examples.bzl); the output is the report, and a refusal fails the build.",
    attrs = {
        "catalogue": attrs.source(),
        "catalogue_display": attrs.string(),
        "display": attrs.string(),
        "tree": attrs.dep(),
        "_tool": attrs.exec_dep(default = "komira//tools/build/readme_examples:tool", providers = [RunInfo]),
    },
)

def _task_pages_check_macro(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _task_pages_check(**kwargs)

task_pages_check = declares_docs(_task_pages_check_macro)

def task_dirs(files):
    """The sorted task directories of `files` (paths below the package): the
    first component of every path that has one."""
    return sorted({f.split("/")[0]: True for f in files if "/" in f}.keys())

def task_probes(files):
    """The sorted probes of `files`, `<task>/<name>` for each
    `<task>/probe_<name>.py`."""
    return sorted([
        f.split("/")[0] + "/" + f.split("/")[1][len("probe_"):-len(".py")]
        for f in files
        if f.count("/") == 1 and f.split("/")[1].startswith("probe_") and f.endswith(".py")
    ])

def probe_target(probe):
    """The wheel test's name of the probe `<task>/<name>`: `<task>__probe_<name>`."""
    return probe.replace("/", "__probe_")

def task_examples(name, files, tree, python, wheels, script):
    """One wheel test per task directory and per probe of `files`, and `name`,
    the aggregate of them all (see the module's doc)."""
    tests = []
    for t in task_dirs(files):
        wheel_install_test(
            name = t,
            python = python,
            wheels = wheels,
            script = script,
            args = ["--task", t],
            files = {"--tasks-dir": tree},
        )
        tests.append(":" + t)
    for p in task_probes(files):
        wheel_install_test(
            name = probe_target(p),
            python = python,
            wheels = wheels,
            script = script,
            args = ["--probe", p],
            files = {"--tasks-dir": tree},
        )
        tests.append(":" + probe_target(p))
    ci_aggregate(name = name, deps = tests)
