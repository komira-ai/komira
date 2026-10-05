"""`pixi_version_check`: the pinned pixi runs and reports the release the platform table pins."""

# Runs `<pixi> --version` with no environment but PATH (empty HOME: pixi
# must not read a user's configuration to answer) and fails unless the one
# line it prints is `pixi <version>`. The download itself is checked by its
# sha256 (pinned_file), so this checks that the bytes are the release the
# table's URL names, and that they run on the platform they are pinned for.
_SCRIPT = """
bb=$1 pixi=$2 want=$3 out=$4
got=$("$bb" env -i PATH=/nonexistent HOME=/nonexistent "$pixi" --version 2>&1) || {
    echo "pixi --version failed: $got" >&2
    exit 1
}
if [ "$got" != "$want" ]; then
    echo "pixi --version printed '$got', expected '$want' (tools/build/platforms/table.bzl)" >&2
    exit 1
fi
printf '%s\\n' "$got" > "$out"
"""

def _impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    pixi = ctx.attrs.pixi[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _SCRIPT, "sh", bb, pixi, "pixi " + ctx.attrs.version, out.as_output()),
        category = "pixi_version_check",
    )
    return [DefaultInfo(default_output = out)]

pixi_version_check = rule(
    impl = _impl,
    doc = "Fails unless `pixi --version` of `pixi` prints `pixi <version>`.",
    attrs = {
        "pixi": attrs.exec_dep(),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)
