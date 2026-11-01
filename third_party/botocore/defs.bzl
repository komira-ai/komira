"""`botocore_model`: one service model out of the pinned botocore archive.

Its output is the model file, unchanged, once its sha256 equals the one
models.bzl states (`third_party_act botocore-model`, no shell); otherwise the
action fails naming both digests.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _botocore_model_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.path)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "botocore-model",
            "--src",
            ctx.attrs.src,
            "--sha256",
            ctx.attrs.sha256,
            "--out",
            out.as_output(),
        ),
        category = "botocore_model",
    )
    return [DefaultInfo(default_output = out)]

botocore_model_rule = rule(
    impl = _botocore_model_impl,
    attrs = {
        # The output's path: the model's path in botocore's data directory.
        "path": attrs.string(),
        "sha256": attrs.string(),
        "src": attrs.source(),
        "_tool": attrs.exec_dep(default = "komira//tools/build/third_party_srcs:third_party_act", providers = [RunInfo]),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
botocore_model = declares_docs(botocore_model_rule)
