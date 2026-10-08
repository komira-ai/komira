"""codec_owner: every codec library has one owner.

A validation, like the lints in defs.bzl: a build of the target fails when
any .mojo file under `root` of `tree` (a doc_tree target: the root one holds
every file of the cell) or, for a fixture, of `files` ({path in the tree:
source}), outside the `owners` directories (paths in the tree), names a snappy
C symbol as a whole string literal in either quote (`"snappy_compress"`, or
`"komira_snappy_compress"` once the vendored snappy's symbols carry the
prefix: the name `external_call` declares), starts a string literal with a
codec library soname (libz, libzstd, liblz4, libbz2, liblzma, libsnappy;
`.so` and `.dylib`), or imports komira_zlib or komira_lz4, the owners'
implementation layers. A name built from pieces (adjacent literals, `+`) is
not seen. The owners must hold a snappy declaration (`"snappy_uncompress"`,
either spelling) and the five sonames, so the snappy and soname patterns
cannot stop matching unnoticed; the import pattern and libsnappy have no such
check and are pinned by tests//negative/codec_owner (test 48).
codec_owner.sh says each pattern; a target with no `owners`, or with both or
neither of `tree` and `files`, fails at analysis.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _codec_owner_impl(ctx):
    if (ctx.attrs.tree == None) == (not ctx.attrs.files):
        fail("codec_owner {}: name the files in exactly one of `tree` and `files`".format(ctx.label))
    if not ctx.attrs.owners:
        fail("codec_owner {}: owners is empty, so every codec declaration would be a finding".format(ctx.label))
    if ctx.attrs.tree != None:
        tree = ctx.attrs.tree[DefaultInfo].default_outputs[0]
        prefix = "{}//".format(ctx.label.cell)
    else:
        tree = ctx.actions.copied_dir("tree", ctx.attrs.files)
        prefix = "{}//{}:".format(ctx.label.cell, ctx.label.package)
    result = ctx.actions.declare_output("validation.json")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, bb, result.as_output(), tree, prefix, ctx.attrs.root, ctx.attrs.owners),
        category = "lint_codec_owner",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "codec_owner", validation_result = result)]),
    ]

_codec_owner_rule = rule(
    impl = _codec_owner_impl,
    doc = "No .mojo file under `root` of `tree` or `files`, outside the `owners` directories, names a snappy symbol (with or without the komira_ prefix) or a codec library soname in a string literal of either quote, or imports komira_zlib / komira_lz4; and the owners hold a snappy declaration and the five sonames.",
    attrs = {
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "owners": attrs.list(attrs.string()),
        "root": attrs.string(default = "src"),
        "tree": attrs.option(attrs.dep(providers = [DocTreeInfo]), default = None),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_script": attrs.source(default = "komira//tools/build/lint:codec_owner.sh"),
    },
)

def _codec_owner(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _codec_owner_rule(**kwargs)

codec_owner = declares_docs(_codec_owner)
