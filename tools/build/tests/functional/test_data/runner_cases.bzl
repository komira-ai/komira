"""mojo_test_command_case: the command a mojo_test gives `buck2 test`, run as a
build action (tests_act test-command), so a build of this package runs it.
"""

load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

def _test_command_impl(ctx):
    test = ctx.attrs.test[ExternalRunnerTestInfo]
    report = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "test-command",
            str(ctx.attrs.test.label.raw_target()),
            report.as_output(),
            "--",
            test.command,
        ),
        env = rerun_env(ctx),
        category = "mojo_test_command_case",
    )
    return [DefaultInfo(default_output = report), rerun_info(ctx)]

mojo_test_command_case = rule(
    impl = _test_command_impl,
    attrs = RERUN_ATTRS | {
        "test": attrs.dep(providers = [ExternalRunnerTestInfo]),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    },
)
