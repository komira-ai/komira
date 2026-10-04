"""retired_names: a renamed package or type keeps its old name only in a dated history note.

A validation, like the lints in defs.bzl: `./buck2 build //...` fails when
any file of `tree` (a doc_tree target; the root one holds every file of the
cell) or of `srcs` (the dotfiles a glob skips) holds one of `names`, fixed
strings, on a line that carries no YYYY-MM-DD date. Spell each name in parts
(`"kci" + "_old"`) so the BUCK file naming it does not hold it. A target with
no `names` fails at analysis.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _retired_names_impl(ctx):
    if not ctx.attrs.names:
        fail("retired_names {}: names is empty, so it would check nothing".format(ctx.label))
    result = ctx.actions.declare_output("validation.json")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, bb, result.as_output(), tree, "{}//".format(ctx.label.cell), ctx.attrs.names, "--", ctx.attrs.srcs),
        category = "lint_retired_names",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "retired_names", validation_result = result)]),
    ]

_retired_names_rule = rule(
    impl = _retired_names_impl,
    doc = "No file of `tree` and no file in `srcs` holds one of `names` on a line without a YYYY-MM-DD date.",
    attrs = {
        "names": attrs.list(attrs.string()),
        "srcs": attrs.list(attrs.source(), default = []),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:retired_names.sh"),
    },
)

def _retired_names(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _retired_names_rule(**kwargs)

retired_names = declares_docs(_retired_names)
