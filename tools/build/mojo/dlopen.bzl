"""`mojo_library(dlopen = [...])`: the shared libraries a library opens at run
time, by soname, and what its conda package then requires.

    mojo_library(name = "komira_zlib", ..., dlopen = ["libz.so.1"])

Each soname must be a row of tools/build/package/system_libs.bzl, which names
the conda-forge package that ships it. A declaration that table lacks is a
refusal of the library's conda package, known at analysis (the package target
builds as REFUSED, its release fails, and so does every dependent's: see
tools/build/package/conda.bzl). The packer holds the declaration to the
sources: they must open exactly the declared sonames
(tools/build/package/pack/conda_dlopen.zig), and the package requires each
row's requirement, byte for byte.

Only the package reads it. The library, its welded tests and its dependents
build the same with or without a declaration.
"""

load("@komira//tools/build/package:system_libs.bzl", "SYSTEM_LIBS")

DLOPEN_ATTRS = {
    # Sonames the library opens at run time (`OwnedDLHandle`); see above.
    "dlopen": attrs.list(attrs.string(), default = []),
}

def dlopen_refusal(ctx):
    """Why the library's package cannot be made because of its `dlopen`
    (a soname given twice, or one system_libs.bzl does not name), else None."""
    seen = {}
    for s in ctx.attrs.dlopen:
        if s in seen:
            return "{} declares `dlopen` {} twice".format(ctx.label.raw_target(), s)
        seen[s] = True
    unknown = [s for s in ctx.attrs.dlopen if s not in SYSTEM_LIBS]
    if unknown:
        return "{} declares `dlopen` of {}, for which tools/build/package/system_libs.bzl names no conda package; add the soname's row there (and to kci's copy) or remove the declaration".format(ctx.label.raw_target(), ", ".join(unknown))
    return None

def dlopen_rows(ctx):
    """MojoInfo.dlopen: (soname, requirement) per declared soname that
    system_libs.bzl names, in soname order."""
    return [(s, SYSTEM_LIBS[s]) for s in sorted(ctx.attrs.dlopen) if s in SYSTEM_LIBS]
