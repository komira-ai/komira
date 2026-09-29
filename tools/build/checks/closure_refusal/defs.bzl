"""A copy of the compiler closure with one member deleted."""

load("@mojo//:providers.bzl", "MojoToolchainInfo")
load("@mojo//:toolchain.bzl", "busybox_sh")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("compiler", dir = True)
    script = """
BB="$1"; case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
"$BB" cp -r "$2" "$3"
"$BB" rm "$3/$4"
"""
    ctx.actions.run(
        busybox_sh(tc.busybox, script, tc.compiler, out.as_output(), ctx.attrs.delete),
        category = "closure_delete_member",
    )
    return [DefaultInfo(default_output = out)]

compiler_without_member = rule(impl = _impl, attrs = {
    "delete": attrs.string(),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
})
