"""`third_party_srcs`: the source lists of a vendored C library, generated
from its pinned release archive by :gen, and held to the committed copy.

    third_party_srcs(
        name = "srcs",
        library = "aws-lc",                 # or "s2n-tls"
        archive = ":aws-lc-1.39.0.tar.gz",  # a pinned_file
        committed = "srcs.bzl",             # the checked-in copy, in this package
    )

declares `:srcs_gen`, the generated file (regenerate the committed copy with
`./buck2 build //<package>:srcs_gen --out <package>/srcs.bzl`), and
`:srcs_drift`, a test that fails, naming the first differing lines, while the
committed copy and the archive disagree. Both run on the farm.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

_GEN_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
ARCHIVE="$1"; OUT="$2"; GEN="$3"; shift 3
case "$GEN" in /*) ;; *) GEN="$PWD/$GEN" ;; esac
gzip -dc "$ARCHIVE" > "$T/archive.tar"
rc=0
"$GEN" "$1" "$T/archive.tar" "$OUT" "$2" "$3" "$4" || rc=$?
rm -rf "$T"
exit "$rc"
"""

def _gen_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    gen = ctx.attrs._gen[MojoRunnableInfo]
    out = ctx.actions.declare_output("srcs.bzl")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            _GEN_SCRIPT,
            "sh",
            bb,
            ctx.attrs.archive,
            out.as_output(),
            gen.run_dir.project(gen.binary),
            ctx.attrs.library,
            ctx.attrs.gen_label,
            ctx.attrs.drift_label,
            ctx.attrs.committed_path,
            hidden = gen.run_dir,
        ),
        category = "third_party_srcs",
    )
    return [DefaultInfo(default_output = out)]

_third_party_srcs_gen = rule(
    impl = _gen_impl,
    doc = "Runs :gen over a .tar.gz release archive. The three strings only fill in the generated file's header.",
    attrs = {
        "archive": attrs.source(),
        "committed_path": attrs.string(),
        "drift_label": attrs.string(),
        "gen_label": attrs.string(),
        "library": attrs.enum(["aws-lc", "s2n-tls"]),
        "_gen": attrs.dep(default = "komira//tools/build/third_party_srcs:gen", providers = [MojoRunnableInfo]),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

_DRIFT_SCRIPT = """
BB="$1"; GOT="$2"; HAVE="$3"
if "$BB" cmp -s "$GOT" "$HAVE"; then
    echo "third_party_srcs: $HAVE matches the archive"
    exit 0
fi
echo "third_party_srcs: $HAVE differs from what the archive gives (- committed, + generated):"
"$BB" diff -U 0 "$HAVE" "$GOT" | "$BB" grep -E '^[-+][^-+]' | "$BB" head -n 6
echo "regenerate: $4"
exit 1
"""

def _drift_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    generated = ctx.attrs.generated[DefaultInfo].default_outputs[0]
    command = cmd_args(bb, "sh", "-c", _DRIFT_SCRIPT, "sh", bb, generated, ctx.attrs.committed, ctx.attrs.regenerate)
    return [
        DefaultInfo(default_output = generated),
        ExternalRunnerTestInfo(type = "custom", command = [command], labels = ctx.attrs.labels),
    ]

_third_party_srcs_drift_test = rule(
    impl = _drift_impl,
    doc = "Fails while `committed` differs from `generated`, naming the first differing lines.",
    attrs = {
        "committed": attrs.source(),
        "generated": attrs.dep(),
        "labels": attrs.list(attrs.string(), default = []),
        "regenerate": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def third_party_srcs(name, library, archive, committed, visibility = None):
    package = package_name()
    gen_label = "//{}:{}_gen".format(package, name)
    committed_path = "{}/{}".format(package, committed) if package else committed
    _third_party_srcs_gen(
        name = name + "_gen",
        exec_compatible_with = LINUX_X86_64,
        library = library,
        archive = archive,
        gen_label = gen_label,
        drift_label = "//{}:{}_drift".format(package, name),
        committed_path = committed_path,
        visibility = visibility,
    )
    _third_party_srcs_drift_test(
        name = name + "_drift",
        exec_compatible_with = LINUX_X86_64,
        generated = ":" + name + "_gen",
        committed = committed,
        regenerate = "./buck2 build {} --out {}".format(gen_label, committed_path),
    )

def _fixture_archive_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    prefix = ctx.attrs.strip_prefix + "/"
    files = {}
    for f in ctx.attrs.srcs:
        if not f.short_path.startswith(prefix):
            fail("fixture_archive {}: {} is not under {}".format(ctx.label, f.short_path, ctx.attrs.strip_prefix))
        files[ctx.attrs.top + "/" + f.short_path.removeprefix(prefix)] = f
    tree = ctx.actions.copied_dir("tree", files)
    out = ctx.actions.declare_output(ctx.attrs.top + ".tar.gz")
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", '"$1" tar -czf "$2" -C "$3" "$4"', "sh", bb, out.as_output(), tree, ctx.attrs.top),
        category = "fixture_archive",
    )
    return [DefaultInfo(default_output = out)]

# A .tar.gz of `srcs` (package-relative paths, `strip_prefix` removed) under
# one top directory `top`: a made-up release archive. busybox tar stores a
# file whose bytes equal an earlier one as a hard link when the worker's
# materializer linked them, and a hard link is not a regular file to :gen (nor
# to tarfile), so every fixture file has its own bytes.
_fixture_archive = rule(
    impl = _fixture_archive_impl,
    attrs = {
        "srcs": attrs.list(attrs.source()),
        "strip_prefix": attrs.string(),
        "top": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def fixture_archive(**kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    _fixture_archive(**kwargs)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
fixture_archive = declares_docs(fixture_archive)
third_party_srcs = declares_docs(third_party_srcs)
