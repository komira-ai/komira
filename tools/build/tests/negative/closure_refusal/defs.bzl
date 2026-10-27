"""A copy of the compiler closure with one member deleted."""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    out = ctx.actions.declare_output("compiler", dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs._act[RunInfo], "delete-member", tc.compiler, out.as_output(), ctx.attrs.delete),
        category = "closure_delete_member",
    )
    return [DefaultInfo(default_output = out)]

compiler_without_member = rule(impl = _impl, attrs = {
    "delete": attrs.string(),
    "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
})
