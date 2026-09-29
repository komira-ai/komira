"""Runs tools/build/mojo/gate_runner.sh against a stand-in test (a shell
script) in one remote action (runner_cases.sh): the parts of the test runtime
contract that two separate test actions cannot show deterministically.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("runner_cases.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, tc.gate_runner, report.as_output()),
        category = "mojo_gate_runner_cases",
    )
    return [DefaultInfo(default_output = report)]

mojo_gate_runner_cases = rule(
    impl = _impl,
    attrs = {
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
