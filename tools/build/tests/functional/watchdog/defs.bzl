"""Runs the compile watchdog of tools/build/mojo/mojo_wrapper.sh against
stand-in compilers (cases.sh), in a remote action: a tree that uses no CPU is
killed with exit 124, one that uses CPU (itself or through a child) is not.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("watchdog_cases.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, tc.wrapper, report.as_output()),
        category = "mojo_watchdog_cases",
    )
    return [DefaultInfo(default_output = report)]

mojo_watchdog_cases = rule(
    impl = _impl,
    attrs = {
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
