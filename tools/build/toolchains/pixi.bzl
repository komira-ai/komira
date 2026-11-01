"""`pixi_version_check`: the pinned pixi runs and reports the release the platform table pins.
`pixi_pin_record`: a pin's URL and sha256 as a two-line file, for checks that hold a copy elsewhere to it."""

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

def _pin_record_impl(ctx):
    out = ctx.actions.write(ctx.label.name + ".txt", "url {}\nsha256 {}\n".format(ctx.attrs.url, ctx.attrs.sha256))
    return [DefaultInfo(default_output = out)]

# Writes no action that runs a program: the two values are the rule's attributes.
pixi_pin_record = rule(
    impl = _pin_record_impl,
    doc = "A file of two lines, `url <url>` and `sha256 <hex>`: one pixi pin of the platform table.",
    attrs = {
        "sha256": attrs.string(),
        "url": attrs.string(),
    },
)
