"""Precompiles one package twice, through the command every `.mojoc` is built
with (tools/build/mojo/precompile.bzl), with its sources and its dependency
staged under different paths each time, and fails unless the two packages
are byte-identical. The two staging paths stand in for two buck-out
isolation directories (or two checkouts' working directories): before the
compile ran from a fixed directory, the package recorded each source file by
its buck-out path, so the bytes differed and so did every archive built
from them.
"""

load("@komira//tools/build/mojo:precompile.bzl", "precompile_cmd")
load("@komira//tools/build/mojo:providers.bzl", "MojoInfo", "MojoToolchainInfo")

# Two staging prefixes of different depth and length.
_PREFIXES = ["a", "bb/ccc/dddd"]

_COMPARE = """set -eu
bb=$1
"$bb" test -s "$2" && "$bb" test -s "$3" || { echo "BAD: a precompile wrote an empty package" >&2; exit 1; }
if ! "$bb" cmp -s "$2" "$3"; then
    echo "BAD: the same package precompiled under two staging paths differs: the .mojoc records where it was built ($2 $3)" >&2
    exit 1
fi
echo "same bytes: $("$bb" sha256sum "$2" | "$bb" cut -c1-64)" > "$4"
"""

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    dep_name = ctx.attrs.dep[MojoInfo].import_name
    dep_pkg = ctx.attrs.dep[DefaultInfo].default_outputs[0]
    outs = []
    for i, prefix in enumerate(_PREFIXES):
        src = ctx.actions.copied_dir(
            "{}/src/{}".format(prefix, ctx.attrs.import_name),
            {s.basename: s for s in ctx.attrs.srcs},
        )
        inc = ctx.actions.copied_dir("{}/inc/{}".format(prefix, dep_name), {dep_name + ".mojoc": dep_pkg})
        out = ctx.actions.declare_output("{}/out/{}.mojoc".format(prefix, ctx.attrs.import_name))
        ctx.actions.run(
            precompile_cmd(tc, cmd_args(inc, format = "-I{}"), src, out.as_output()),
            category = "mojoc_path_precompile",
            identifier = str(i),
        )
        outs.append(out)
    report = ctx.actions.declare_output("same_bytes.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", _COMPARE, "--", tc.busybox, outs[0], outs[1], report.as_output()),
        category = "mojoc_path_compare",
    )
    return [DefaultInfo(default_output = report, other_outputs = outs)]

mojoc_path_cases = rule(
    impl = _impl,
    attrs = {
        "dep": attrs.dep(providers = [MojoInfo]),
        "import_name": attrs.string(),
        "srcs": attrs.list(attrs.source()),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
