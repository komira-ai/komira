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
"""

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
