load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")

def _parity_impl(ctx):
    r = ctx.attrs.binary[MojoRunnableInfo]
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script[DefaultInfo].default_outputs[0], bb, r.run_dir, r.binary, ctx.attrs.bundle[DefaultInfo].default_outputs[0], out.as_output()),
        category = "bundle_parity",
    )
    return [DefaultInfo(default_output = out)]

# Runs a mojo_binary's executable and its bundle through the same cases and
# fails unless stdout, stderr and exit status agree (see parity.sh).
bundle_parity = rule(
    impl = _parity_impl,
    attrs = {
        "binary": attrs.dep(providers = [MojoRunnableInfo]),
        "bundle": attrs.dep(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.dep(default = "checks//bundle_parity:parity.sh"),
    },
)
