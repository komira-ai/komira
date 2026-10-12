"""mojo_test_command_case: the command a mojo_test gives `buck2 test`, run as a
build action (test_command_case.sh), so a build of this package runs it.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _test_command_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    test = ctx.attrs.test[ExternalRunnerTestInfo]
    report = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            ctx.attrs.script,
            tc.busybox,
            str(ctx.attrs.test.label.raw_target()),
            report.as_output(),
            "--",
            test.command,
        ),
        category = "mojo_test_command_case",
    )
    return [DefaultInfo(default_output = report)]

mojo_test_command_case = rule(
    impl = _test_command_impl,
    attrs = {
        "script": attrs.source(),
        "test": attrs.dep(providers = [ExternalRunnerTestInfo]),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
