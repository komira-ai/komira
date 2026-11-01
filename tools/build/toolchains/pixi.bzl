"""`pixi_version_check`: the pinned pixi runs and reports the release the platform table pins."""

# Runs `<pixi> --version` (version_check.zig) with no environment but PATH
# and HOME (pixi must not read a user's configuration to answer) and fails
# unless the one line it prints is `pixi <version>`. The download itself is
# checked by its sha256 (pinned_file), so this checks that the bytes are the
# release the table's URL names, and that they run on the platform they are
# pinned for.
def _impl(ctx):
    pixi = ctx.attrs.pixi[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(ctx.attrs._check[RunInfo], pixi, "pixi " + ctx.attrs.version, out.as_output()),
        category = "pixi_version_check",
    )
    return [DefaultInfo(default_output = out)]

pixi_version_check = rule(
    impl = _impl,
    doc = "Fails unless `pixi --version` of `pixi` prints `pixi <version>`.",
    attrs = {
        "pixi": attrs.exec_dep(),
        "version": attrs.string(),
        "_check": attrs.exec_dep(default = "komira//tools/build/toolchains:version_check", providers = [RunInfo]),
    },
)
