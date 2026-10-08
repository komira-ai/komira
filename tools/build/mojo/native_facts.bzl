"""What a mojo_library's C and run-time shared libraries are to its conda
package: the facts mojo_library (defs.bzl) records in MojoInfo (`native`,
`dlopen`; providers.bzl) and the refusals they give, by
tools/build/native/members.bzl and tools/build/package/system_libs.bzl; and
conda_facts, the package's name and refusal, which folds those refusals in
with the ones that need no C.
"""

load("@prelude//linking:link_info.bzl", "MergedLinkInfo")
load(":providers.bzl", "MojoInfo")
load("@komira//tools/build/native:defs.bzl", "NativeArchiveInfo")
load(
    "@komira//tools/build/native:members.bzl",
    NATIVE_ARCHIVES = "ARCHIVES",
    NATIVE_CALLERS = "CALLERS",
    NATIVE_PER_LIBRARY = "PER_LIBRARY",
    "native_label",
)
load("@komira//tools/build/package:system_libs.bzl", "SYSTEM_LIBS")

def native_facts(ctx, c_link):
    """(MojoInfo.native, direct) for this library: what its C closure is to
    libkomira_native.so.1 (providers.bzl), and the same three lists for the
    C targets this library itself names in `deps`. None, None without C."""
    if c_link == None:
        return None, None
    closure = {"per_library": {}, "shared": {}, "undeclared": {}}
    direct = {"per_library": {}, "shared": {}, "undeclared": {}}
    ships = []
    for d in ctx.attrs.deps:
        if MojoInfo in d:
            n = d[MojoInfo].native
            if n != None:
                for kind in closure:
                    for label in getattr(n, kind):
                        closure[kind][label] = True
        elif MergedLinkInfo in d:
            label = native_label(d.label) or str(d.label.raw_target())
            kind = "undeclared"
            if NativeArchiveInfo in d:
                info = d[NativeArchiveInfo]
                kind = info.kind
                if kind == "per_library":
                    ships.append(("lib/lib{}.a".format(info.name), info.archive))
            closure[kind][label] = True
            direct[kind][label] = True
    native = struct(
        per_library = sorted(closure["per_library"]),
        shared = sorted(closure["shared"]),
        ships = ships,
        undeclared = sorted(closure["undeclared"]),
    )
    return native, struct(**{k: sorted(v) for k, v in direct.items()})

def native_refusal(ctx, direct):
    """Why the C this library names in `deps` keeps it from a conda package,
    or None. Its dependencies' C is their own packages' business: a dependency
    refused for it refuses this package too (conda_facts below)."""
    if direct == None:
        return None
    me = ctx.label.raw_target()
    if direct.undeclared:
        return "{} links C that libkomira_native.so.1 does not hold and no package ships: {}. A `.mojoc` holds no machine code, so a consumer could not link it; declare the archive (native_archive, tools/build/native/README.md) and list it in tools/build/native/members.bzl".format(me, ", ".join(direct.undeclared))
    missing = [l for l in direct.shared if l not in NATIVE_ARCHIVES]
    if missing:
        return "{} links {}, declared `shared`, which libkomira_native.so.1 does not hold (tools/build/native/members.bzl ARCHIVES)".format(me, ", ".join(missing))
    missing = [l for l in direct.per_library if l not in NATIVE_PER_LIBRARY]
    if missing:
        return "{} links {}, declared `per_library`, which tools/build/native/members.bzl PER_LIBRARY does not list".format(me, ", ".join(missing))
    if direct.shared and native_label(ctx.label) not in NATIVE_CALLERS:
        return "{} links {} of libkomira_native.so.1 but is not one of its callers (tools/build/native/members.bzl CALLERS), so the library need not export what it calls".format(me, ", ".join(direct.shared))
    return None

def dlopen_refusal(ctx):
    """Why the sonames the library declares in `dlopen` keep it from a conda
    package (one system_libs.bzl names no package for), or None."""
    unknown = [s for s in ctx.attrs.dlopen if s not in SYSTEM_LIBS]
    if unknown:
        return "{} opens {} at run time (`dlopen`), for which tools/build/package/system_libs.bzl names no conda package".format(ctx.label.raw_target(), ", ".join(unknown))
    return None

def dlopen_rows(ctx):
    """MojoInfo.dlopen: (soname, requirement) per declared soname that
    system_libs.bzl names, sorted."""
    return [(s, SYSTEM_LIBS[s]) for s in sorted(ctx.attrs.dlopen) if s in SYSTEM_LIBS]

def conda_facts(ctx, import_name, native_direct, has_tests):
    """(conda name, refusal) of this library's conda package.

    The name is None when the library opted out. The refusal is None when the
    package can be built, else the reason it cannot: a reason known without
    reading a source (C that libkomira_native.so.1 does not hold, no tests, a
    dependency with no package, a name that is not a conda name). The package
    target still builds, as a directory holding the reason
    (tools/build/package/conda.bzl).
    """
    if not ctx.attrs.conda:
        return None, None
    name = ctx.attrs.conda_name or import_name
    if not regex_match("^[a-z][a-z0-9_]*$", name):
        return name, "`{}` is not a conda name (a lowercase letter, then lowercase letters, digits and _); set `conda_name`".format(name)
    refusal = native_refusal(ctx, native_direct) or dlopen_refusal(ctx)
    if refusal != None:
        return name, refusal
    if not has_tests:
        return name, "{} has no tests, so its package would not be gated by any; declare test_srcs on the library".format(ctx.label.raw_target())
    for d in ctx.attrs.deps:
        if MojoInfo in d:
            di = d[MojoInfo]
            if di.conda_name == None:
                return name, "it depends on {}, which has no conda package (`conda = False`, or it is not a mojo_library)".format(d.label.raw_target())
            if di.conda_refusal != None:
                return name, "it depends on {}, which has no conda package: {}".format(d.label.raw_target(), di.conda_refusal)
    return name, None
