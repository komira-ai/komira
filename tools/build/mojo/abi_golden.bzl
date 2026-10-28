"""komira_abi_golden: the golden of a C ABI, checked against its source, and the C header made from it.

    komira_abi_golden(name, src, golden, header_name = "<name>.h")

`src` is a Mojo file of `@export ... abi("C")` functions (the `main` of a
`mojo_shared_lib`). `golden` is a tab-separated file: a first line
`version<TAB><major>.<minor>`, then one row per symbol,
`symbol<TAB>return<TAB>arguments<TAB>since` (arguments are types joined by `,`,
or `-`; a function returning nothing returns `None`; `since` is the
`<major>.<minor>` that added the symbol).

The action (tools/build/mojo/tools/abi_golden.zig) fails, naming every
finding, on:

- a symbol the golden lists and the source does not export (a removal),
- a symbol the source exports and the golden does not list (an addition),
- a changed return type or argument types,
- a row whose `since` is above the golden version,
- a symbol listed twice, and
- a type outside the type map (Int8..Int64, UInt8..UInt64, Int, UInt, Float32,
  Float64, OpaquePointer, Handle, and `UnsafePointer[...]` of those).

With none, the target's one output, `<header_name>`, is the C header of the
golden: include guards, `<stddef.h>` and `<stdint.h>`,
`KOMIRA_ABI_VERSION_MAJOR` and `KOMIRA_ABI_VERSION_MINOR`, the opaque handle
typedef `komira_handle`, and one prototype per row in the golden's order.

What this does not check: that the golden's version was raised when a row
changed. That compares with the previous release, and a build holds only the
current tree.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    name = ctx.attrs.header_name or (ctx.label.name + ".h")
    if "/" in name or name in (".", ".."):
        fail("{}: header_name `{}` is not a plain file name".format(ctx.label.raw_target(), name))
    header = ctx.actions.declare_output(name)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            ctx.attrs.src,
            ctx.attrs.golden,
            header.as_output(),
            str(ctx.label.raw_target()),
            name,
        ),
        category = "abi_golden",
    )
    return [DefaultInfo(default_output = header)]

komira_abi_golden_rule = rule(
    impl = _impl,
    doc = "The C header of the golden `golden` (a tab-separated list of symbols with return and argument types and the version that added each), failing unless the `@export abi(\"C\")` functions of the Mojo file `src` are exactly its rows with the same types. See abi_golden.bzl.",
    attrs = {
        "golden": attrs.source(),
        "header_name": attrs.option(attrs.string(), default = None),
        "src": attrs.source(),
        "_tool": attrs.exec_dep(default = "komira//tools/build/mojo:abi_golden"),
    },
)

komira_abi_golden = declares_docs(komira_abi_golden_rule)
