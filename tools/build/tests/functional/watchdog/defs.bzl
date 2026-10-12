"""Runs the compile wrapper (tools/build/mojo/tools/mojo_compile.zig, or
mojo_compile_macos.zig for `cases_darwin` on a macOS worker) against
a stand-in toolchain (standin.zig) through the cases runner (cases.zig), in a
remote action: every verdict of the compile watchdog, the wrapper signalled,
the compiler's exact environment, its stdin and signal dispositions, the link
line zig receives from the cc shim, and the output checks and refusals, each
with the scratch directory gone afterwards.
"""

def _impl(ctx):
    def exe(dep):
        return dep[DefaultInfo].default_outputs[0]

    report = ctx.actions.declare_output("watchdog_cases.txt")
    ctx.actions.run(
        cmd_args(exe(ctx.attrs.runner), exe(ctx.attrs.wrapper), exe(ctx.attrs.standin), report.as_output()),
        category = "mojo_watchdog_cases",
    )
    return [DefaultInfo(default_output = report)]

mojo_watchdog_cases = rule(
    impl = _impl,
    attrs = {
        # The cases runner (cases.zig).
        "runner": attrs.exec_dep(),
        # The stand-in compiler and link driver (standin.zig).
        "standin": attrs.exec_dep(),
        # The wrapper under test: the Linux one unless a target names another.
        "wrapper": attrs.exec_dep(default = "komira//tools/build/mojo:mojo_compile"),
    },
)
