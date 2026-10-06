"""test_weld: every test file runs, every package with code welds a test, and no package loses tests silently.

A validation, like the lints in defs.bzl: any build holding the target fails
when, among the packages under `root` (each directory directly under it):

- a `test_*.mojo` under a `tests/` directory is named by no BUCK file
  (`test_srcs` or a mojo_test), so it never runs;
- a package with a `.mojo` source welds no test;
- a package welds fewer test files, or fewer test functions, than its row
  in `coverage_floor` records.

`known_untested` is the ledger of the test files and packages allowed to
break the first two rules, each with its reason. It only shrinks: a row whose
test is welded, or whose package welds a test, is a finding, and so is a row
naming nothing. The action is test_weld.sh, which says how each count is
read.

The files come from `tree` (a doc_tree target: the root one holds every file
of the cell) or, for a fixture, from `files` ({path in the tree: source}),
never both. A target with neither fails at analysis.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _test_weld_impl(ctx):
    if (ctx.attrs.tree == None) == (not ctx.attrs.files):
        fail("test_weld {}: name the files in exactly one of `tree` and `files`".format(ctx.label))
    if ctx.attrs.tree != None:
        tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
        prefix = "{}//".format(ctx.label.cell)
    else:
        tree = ctx.actions.copied_dir("tree", ctx.attrs.files)
        prefix = "{}[files]/".format(ctx.label.raw_target())
    package = "{}//{}".format(ctx.label.cell, ctx.label.package + "/" if ctx.label.package else "")
    result = ctx.actions.declare_output("validation.json")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            ctx.attrs._script,
            bb,
            result.as_output(),
            tree,
            prefix,
            ctx.attrs.root,
            ctx.attrs.known_untested,
            package + ctx.attrs.known_untested.short_path,
            ctx.attrs.coverage_floor,
            package + ctx.attrs.coverage_floor.short_path,
        ),
        category = "lint_test_weld",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "test_weld", validation_result = result)]),
    ]

_test_weld_rule = rule(
    impl = _test_weld_impl,
    doc = "Every test file under `root` is welded, every package with a .mojo source welds a test, and every package keeps the test files and functions of its `coverage_floor` row; `known_untested` lists the exceptions and only shrinks. See test_weld.bzl.",
    attrs = {
        "coverage_floor": attrs.source(),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "known_untested": attrs.source(),
        "root": attrs.string(default = "src"),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:test_weld.sh"),
    },
)

def _test_weld(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _test_weld_rule(**kwargs)

test_weld = declares_docs(_test_weld)
