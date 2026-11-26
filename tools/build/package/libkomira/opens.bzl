"""What libkomira's native directory needs from the host: the libraries its
Mojo closure opens at run time, held to what each platform's hosts provide.

A package carrying the native directory (`//src/so:libkomira[dist]`: the
Python wheel, the npm platform packages) installs no conda requirement, so a
library the closure opens with `dlopen` (`mojo_library(dlopen = [...])`,
tools/build/mojo/dlopen.bzl) must be on the host. `dist_opens_check` refuses,
at analysis, a closure that opens a soname a platform's row of `HOST_LIBS`
(tools/build/package/system_libs.bzl) lacks, naming the platform, the soname
and the libraries that declare it. It runs on Linux for every platform row,
the macOS one among them, since the declarations are the same for each, so a
pull request that adds such a library is refused by its own check, before any
macOS wheel is built.

    opens_refusals(opens, platforms, host_libs)
        the refusal lines, platform then soname order; [] when the hosts of
        each platform provide every soname of `opens` (MojoInfo.opens)
    dist_opens_cases()
        fails loading the package when `opens_refusals` or `merge_opens` gets
        a case wrong
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:dlopen.bzl", "merge_opens")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo")
load("@komira//tools/build/package:system_libs.bzl", "HOST_LIBS")

def opens_refusals(opens, platforms, host_libs):
    """The lines refusing `opens` ({soname: [import name]}) on `platforms`,
    given `host_libs` ({platform: [soname]}): one per platform with no row,
    and one per soname a platform's hosts do not provide."""
    lines = []
    for p in sorted(platforms):
        if p not in host_libs:
            lines.append("{}: tools/build/package/system_libs.bzl HOST_LIBS has no row for the platform, so what its hosts provide is not known".format(p))
            continue
        for s in sorted(opens.keys()):
            if s not in host_libs[p]:
                lines.append("{}: libkomira's closure opens {} at run time (`dlopen` of {}), which a {} host does not provide and the native directory does not carry".format(p, s, ", ".join(opens[s]), p))
    return lines

def _dist_opens_check_impl(ctx):
    opens = ctx.attrs.lib[MojoInfo].opens
    refusals = opens_refusals(opens, ctx.attrs.platforms, HOST_LIBS)
    if refusals:
        fail("{}: {}".format(ctx.label.raw_target(), "\n".join(refusals)))
    lines = []
    for p in sorted(ctx.attrs.platforms):
        lines.append("{}: {}".format(p, ", ".join(["{} ({})".format(s, ", ".join(opens[s])) for s in sorted(opens.keys())]) or "none"))
    out = ctx.actions.write(ctx.label.name + ".txt", "\n".join(lines) + "\n")
    return [DefaultInfo(default_output = out)]

# Fails at analysis unless the hosts of every platform of `platforms` provide
# each library `lib`'s closure opens at run time. Its output lists, per
# platform, the sonames the directory takes from the host and who opens them.
_dist_opens_check = rule(
    impl = _dist_opens_check_impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoInfo]),
        "platforms": attrs.list(attrs.string()),
    },
)

dist_opens_check = declares_docs(_dist_opens_check)

_HOSTS = {
    "darwin-arm64": ["libz.so.1"],
    "linux-x86_64": ["libz.so.1", "libzstd.so.1"],
}

# (opens, platforms, the refusal lines).
_REFUSAL_CASES = [
    # Nothing opened: nothing to provide.
    ({}, ["darwin-arm64", "linux-x86_64"], []),
    # Provided on both.
    ({"libz.so.1": ["zlib"]}, ["darwin-arm64", "linux-x86_64"], []),
    # libzstd, which Linux hosts provide and macOS hosts do not.
    (
        {"libz.so.1": ["zlib"], "libzstd.so.1": ["compression"]},
        ["darwin-arm64", "linux-x86_64"],
        ["darwin-arm64: libkomira's closure opens libzstd.so.1 at run time (`dlopen` of compression), which a darwin-arm64 host does not provide and the native directory does not carry"],
    ),
    # A platform outside `platforms` is not judged.
    ({"libzstd.so.1": ["compression"]}, ["linux-x86_64"], []),
    # Two sonames refused, in soname order, each naming every library that declares it.
    (
        {"liblz4.so.1": ["compression", "lz4"], "libzstd.so.1": ["compression"]},
        ["darwin-arm64"],
        [
            "darwin-arm64: libkomira's closure opens liblz4.so.1 at run time (`dlopen` of compression, lz4), which a darwin-arm64 host does not provide and the native directory does not carry",
            "darwin-arm64: libkomira's closure opens libzstd.so.1 at run time (`dlopen` of compression), which a darwin-arm64 host does not provide and the native directory does not carry",
        ],
    ),
    # A platform with no row is refused even when nothing is opened, and the other platforms are still judged.
    (
        {"libzstd.so.1": ["compression"]},
        ["linux-arm64", "darwin-arm64"],
        [
            "darwin-arm64: libkomira's closure opens libzstd.so.1 at run time (`dlopen` of compression), which a darwin-arm64 host does not provide and the native directory does not carry",
            "linux-arm64: tools/build/package/system_libs.bzl HOST_LIBS has no row for the platform, so what its hosts provide is not known",
        ],
    ),
    (
        {},
        ["linux-arm64"],
        ["linux-arm64: tools/build/package/system_libs.bzl HOST_LIBS has no row for the platform, so what its hosts provide is not known"],
    ),
]

# (import name, own sonames, the dependencies' opens, the library's opens).
_MERGE_CASES = [
    ("leaf", [], [], {}),
    ("zlib", ["libz.so.1"], [], {"libz.so.1": ["zlib"]}),
    # A dependency's declaration is the closure's.
    ("so", [], [{"libz.so.1": ["zlib"]}], {"libz.so.1": ["zlib"]}),
    # The same soname declared by the library and a dependency names both, sorted.
    ("compression", ["libz.so.1"], [{"libz.so.1": ["zlib"]}], {"libz.so.1": ["compression", "zlib"]}),
    # Two dependencies reaching the same library (a diamond) name it once.
    ("so", [], [{"libz.so.1": ["zlib"]}, {"libz.so.1": ["zlib"], "liblzma.so.5": ["compression"]}], {"liblzma.so.5": ["compression"], "libz.so.1": ["zlib"]}),
]

def dist_opens_cases():
    """Fails when `opens_refusals` or `merge_opens` gets a case wrong, each
    refusal word for word."""
    for opens, platforms, want in _REFUSAL_CASES:
        got = opens_refusals(opens, platforms, _HOSTS)
        if got != want:
            fail("opens_refusals({}, {}) is {}, want {}".format(repr(opens), repr(platforms), repr(got), repr(want)))
    for name, own, deps, want in _MERGE_CASES:
        got = merge_opens(name, own, deps)
        if got != want:
            fail("merge_opens({}, {}, {}) is {}, want {}".format(repr(name), repr(own), repr(deps), repr(got), repr(want)))
