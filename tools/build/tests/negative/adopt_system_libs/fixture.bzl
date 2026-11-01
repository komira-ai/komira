"""A stand-in for the `:lib` of a package built by buildrules' `mojo_package` that pins system libraries.

`pinned_lib` hands on the `.mojoc` of a real library and the directories of the `mojo_system_lib` targets it is given as `MojoSystemLibsInfo`, which is what the gated
`:lib` of a package with a format 3 unit graph carries. `mojo_adopted_library` (tools/build/mojo/adopt.bzl) takes it as `lib`.
"""

load("@buildrules//rules/mojo:providers.bzl", "MojoSystemLibsInfo")
load("@buildrules//rules/mojo:system_libs.bzl", "MojoSystemLibInfo")

def _impl(ctx):
    return [
        DefaultInfo(default_output = ctx.attrs.lib[DefaultInfo].default_outputs[0]),
        MojoSystemLibsInfo(dirs = [l[MojoSystemLibInfo].dir for l in ctx.attrs.system_libs]),
    ]

pinned_lib = rule(
    impl = _impl,
    attrs = {
        "lib": attrs.dep(),
        "system_libs": attrs.list(attrs.dep(providers = [MojoSystemLibInfo]), default = []),
    },
)
