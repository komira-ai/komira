"""Runs the compile wrapper (tools/build/mojo/tools/mojo_compile.zig) against
a stand-in toolchain (standin.zig) through the cases runner (cases.zig), in a
remote action: every verdict of the compile watchdog, the wrapper signalled,
the compiler's exact environment, its stdin and signal dispositions, the link
line zig receives from the cc shim, and the output checks and refusals, each
with the scratch directory gone afterwards.
"""

load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

def _impl(ctx):
    def exe(dep):
        return dep[DefaultInfo].default_outputs[0]

    report = ctx.actions.declare_output("watchdog_cases.txt")
    ctx.actions.run(
        cmd_args(exe(ctx.attrs.runner), exe(ctx.attrs.wrapper), exe(ctx.attrs.standin), report.as_output()),
        env = rerun_env(ctx),
        category = "mojo_watchdog_cases",
    )
    return [DefaultInfo(default_output = report), rerun_info(ctx)]

mojo_watchdog_cases = rule(
    impl = _impl,
    attrs = RERUN_ATTRS | {
        # The cases runner (cases.zig).
        "runner": attrs.exec_dep(),
        # The stand-in compiler and link driver (standin.zig).
        "standin": attrs.exec_dep(),
        # The wrapper under test.
        "wrapper": attrs.exec_dep(default = "komira//tools/build/mojo:mojo_compile"),
    },
)
