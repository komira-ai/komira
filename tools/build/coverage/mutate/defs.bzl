"""The directory every mojo_library's mutation score build runs from
(tools/build/mojo/mutation.bzl; ../README.md, "Mutation score")."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")

def _mut_dir_impl(ctx):
    exe = ctx.attrs.mutate[MojoRunnableInfo]
    # The binary and the runtime libraries its run path ($ORIGIN/lib) names,
    # under fixed names.
    out = ctx.actions.copied_dir("mut_dir", {
        "mutate/mutate": exe.run_dir.project(exe.binary),
        "mutate/lib": exe.run_dir.project("lib"),
    })

    # The step script apart from the binary: it is an input of every
    # mutant's compile and test actions, which must keep their keys when
    # only the mutate tool changes.
    return [DefaultInfo(default_outputs = [ctx.attrs.script, out])]

_mut_dir = rule(
    impl = _mut_dir_impl,
    doc = "The directory a mojo_library's `[mutation]` sub-target runs from (tools/build/mojo/mutation.bzl): its two default outputs, in this order: `mut_step.sh` (`script`), and a directory holding `mutate/` (`mutate`, a mojo_binary, with its runtime libraries).",
    attrs = {
        "mutate": attrs.exec_dep(providers = [MojoRunnableInfo], default = "komira//tools/build/coverage/mutate:mutate_bin"),
        "script": attrs.source(default = "komira//tools/build/coverage/mutate:mut_step.sh"),
    },
)

mut_dir = declares_docs(_mut_dir)

def _cases_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]

    # Copied under buck-out, keyed by their path in the package, so the
    # action's digest is the same in a standalone checkout and in a
    # repository mounting komira as a cell.
    staged = ctx.actions.copied_dir("cases_srcs", {f.short_path: f for f in [ctx.attrs.script, ctx.attrs.step]})
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(bb, "sh", staged.project(ctx.attrs.script.short_path), bb, result.as_output(), staged.project(ctx.attrs.step.short_path)),
        category = "mut_step_cases",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_mut_step_cases = rule(
    impl = _cases_impl,
    doc = "Runs `script` under busybox sh as `sh <script> <busybox> <result.json> <step>`: the cases of mut_step.sh. The script exits non-zero on a wrong result and writes a successful validation result otherwise.",
    attrs = {
        "script": attrs.source(),
        "step": attrs.source(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

mut_step_cases = declares_docs(_mut_step_cases)
