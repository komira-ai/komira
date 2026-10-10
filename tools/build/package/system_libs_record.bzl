"""`system_libs_record`: system_libs.bzl's table as a file, one
`<soname> <requirement>` line per row in soname order, written at analysis
from `SYSTEM_LIBS` itself (no copy). kci compiles its own copy of the table
(src/kci_release_set/system_libs.mojo, the conda-forge requirements both
closure checks accept); its welded test reads this file and holds the two
equal, both ways.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/package:system_libs.bzl", "SYSTEM_LIBS")

def _impl(ctx):
    for soname, requirement in SYSTEM_LIBS.items():
        if " " in soname or "\n" in soname or "\n" in requirement:
            fail("{}: system_libs.bzl row {} = {} cannot be one `<soname> <requirement>` line".format(ctx.label, repr(soname), repr(requirement)))
    text = "".join(["{} {}\n".format(s, SYSTEM_LIBS[s]) for s in sorted(SYSTEM_LIBS.keys())])
    return [DefaultInfo(default_output = ctx.actions.write(ctx.label.name + ".txt", text))]

_system_libs_record = rule(
    impl = _impl,
    doc = "tools/build/package/system_libs.bzl's SYSTEM_LIBS as `<soname> <requirement>` lines, soname order.",
    attrs = {},
)

system_libs_record = declares_docs(_system_libs_record)
