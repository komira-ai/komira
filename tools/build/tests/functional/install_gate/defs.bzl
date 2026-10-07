"""Runs install_gate.sh's cases (cases.sh) in one action under the Mojo
toolchain's busybox: the SKIP and FAIL lines of the pixi install case of
conda.sh and conda_set.sh, on PATHs this action makes, both scripts'
refusal of --require-install beside --no-install, and each script run up to
and through its own install_gate call.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("install_gate_cases.txt")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            ctx.attrs.script,
            tc.busybox,
            ctx.attrs.gate,
            ctx.attrs.conda,
            ctx.attrs.conda_set,
            report.as_output(),
        ),
        category = "install_gate_cases",
    )
    return [DefaultInfo(default_output = report)]

install_gate_cases = rule(
    impl = _impl,
    attrs = {
        "conda": attrs.source(),
        "conda_set": attrs.source(),
        "gate": attrs.source(),
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
