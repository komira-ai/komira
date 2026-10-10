"""Runs tools/build/mojo/test_deadline.sh against a stand-in for
gate_runner.sh (cases.sh), in a remote action: the runner's status passes
through, the test is killed at the limit with the runner left to report it,
and nothing of the run is left alive.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("test_deadline_cases.txt")
    deadline = ctx.attrs._test_deadline[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, deadline, report.as_output()),
        category = "mojo_test_deadline_cases",
    )
    return [DefaultInfo(default_output = report)]

mojo_test_deadline_cases = rule(
    impl = _impl,
    attrs = {
        "script": attrs.source(),
        "_test_deadline": attrs.dep(default = "komira//tools/build/mojo:test_deadline.sh"),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
