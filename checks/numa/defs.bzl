"""Exercises mojo/numa_guard.sh against made-up NUMA topologies, in a remote
action. Nothing here needs a multi-NUMA worker: the guard reads its topology
from `--root`, so every verdict (run or refuse) is checked on any worker.
"""

load("@mojo//:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("guard_cases.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, tc.numa_guard, report.as_output()),
        category = "numa_guard_cases",
    )
    return [DefaultInfo(default_output = report)]

numa_guard_cases = rule(
    impl = _impl,
    attrs = {
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
