"""The directory every mojo_library's mutation score build runs from
(tools/build/mojo/mutation.bzl; ../README.md, "Mutation score")."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")

def _mut_dir_impl(ctx):
    exe = ctx.attrs.mutate[MojoRunnableInfo]
    # The binary and the runtime libraries its run path ($ORIGIN/lib) names,
    # under fixed names. Each step runs through the toolchain's `gate step`
    # (tools/build/run), not a tool of this directory: a mutant's compile and
    # test actions keep their keys when only the mutate tool changes.
    out = ctx.actions.copied_dir("mut_dir", {
        "mutate/mutate": exe.run_dir.project(exe.binary),
        "mutate/lib": exe.run_dir.project("lib"),
    })
    return [DefaultInfo(default_outputs = [out])]

_mut_dir = rule(
    impl = _mut_dir_impl,
    doc = "The directory a mojo_library's `[mutation]` sub-target runs from (tools/build/mojo/mutation.bzl): one default output, a directory holding `mutate/` (`mutate`, a mojo_binary, with its runtime libraries).",
    attrs = {
        "mutate": attrs.exec_dep(providers = [MojoRunnableInfo], default = "komira//tools/build/coverage/mutate:mutate_bin"),
    },
)

mut_dir = declares_docs(_mut_dir)
