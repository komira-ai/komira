"""Runs tools/build/mojo/mem_cap.sh against a stand-in for gate_runner.sh
(cases.sh), in a remote action: where /proc stops being readable, and where
the cap itself is signalled, nothing of the run is left alive.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("mem_cap_cases.txt")
    mem_cap = ctx.attrs._mem_cap[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, mem_cap, report.as_output()),
        env = rerun_env(ctx),
        category = "mojo_mem_cap_cases",
    )
    return [DefaultInfo(default_output = report), rerun_info(ctx)]

mojo_mem_cap_cases = rule(
    impl = _impl,
    attrs = RERUN_ATTRS | {
        "script": attrs.source(),
        "_mem_cap": attrs.dep(default = "komira//tools/build/mojo:mem_cap.sh"),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
