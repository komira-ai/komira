"""`botocore_model`: one service model out of the pinned botocore archive.

Its output is the model file, unchanged, once its sha256 equals the one
models.bzl states; otherwise the action fails naming both digests.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")

_SCRIPT = """
BB="$1"; SRC="$2"; WANT="$3"; OUT="$4"
GOT=$("$BB" sha256sum "$SRC" | "$BB" cut -d' ' -f1)
if [ "$GOT" != "$WANT" ]; then
    echo "botocore_model: $SRC has sha256 $GOT; models.bzl says $WANT" >&2
    exit 1
fi
"$BB" cp "$SRC" "$OUT"
"""

def _botocore_model_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.attrs.path)
    ctx.actions.run(
        busybox_sh(bb, _SCRIPT, ctx.attrs.src, ctx.attrs.sha256, out.as_output()),
        category = "botocore_model",
    )
    return [DefaultInfo(default_output = out)]

botocore_model_rule = rule(
    impl = _botocore_model_impl,
    attrs = {
        "busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        # The output's path: the model's path in botocore's data directory.
        "path": attrs.string(),
        "sha256": attrs.string(),
        "src": attrs.source(),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
botocore_model = declares_docs(botocore_model_rule)
