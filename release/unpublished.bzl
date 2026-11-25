"""The paths //release:unpublished_cases reads to find the Mojo libraries under src/.

`src_library_paths` writes, one per line and sorted, every path of `tree` (the cell's root doc_tree,
which holds every file) that is under `src/` and is a `BUCK` file or a `.mojo` file. It reads only the
paths, at analysis: no file of the tree is an input of anything. Which of those paths make a library is
unpublished_test.zig's to say, so the rule holds no logic a case would have to cover.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "DocTreeInfo", "declares_docs")

def _src_library_paths_impl(ctx):
    paths = sorted([
        p
        for p in ctx.attrs.tree[DocTreeInfo].files.keys()
        if p.startswith("src/") and (p.endswith("/BUCK") or p.endswith(".mojo"))
    ])
    out = ctx.actions.write(ctx.label.name + ".txt", "".join([p + "\n" for p in paths]))
    return [DefaultInfo(default_output = out)]

_src_library_paths = rule(
    impl = _src_library_paths_impl,
    doc = "Every `src/**/BUCK` and `src/**.mojo` path of `tree` (a doc_tree), one per line, sorted.",
    attrs = {"tree": attrs.dep(providers = [DocTreeInfo])},
)

src_library_paths = declares_docs(_src_library_paths)
