"""`gen_check` and `tests_check`: what a gcp_client generated and ran, checked as build actions.

`gen` is a generated directory, here a library's `[gen]` sub-target, so the
check also proves mojo_library's `gen` attribute re-exports it. The action
fails unless the directory holds exactly `files`, no file holds a string of
`absent`, and some file holds each string of `present` (which keeps an
absence check from passing over an empty output). `buck2 build` of the
target IS the check. `tests_check` is described above its definition.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo")

_CHECK = """
BB="$1"; GEN="$2"; MARK="$3"; FILES="$4"; N="$5"; shift 5
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
got="$("$BB" ls -A "$GEN" | "$BB" sort | "$BB" tr '\\n' ' ')"
if [ "$got" != "$FILES " ]; then
    echo "the generated directory holds: $got" >&2
    echo "expected exactly:              $FILES" >&2
    exit 1
fi
while [ "$N" -gt 0 ]; do
    if "$BB" grep -rlF -- "$1" "$GEN" >&2; then
        echo "the generated files above hold \\`$1\\`, which must be absent" >&2
        exit 1
    fi
    shift; N=$((N - 1))
done
for s in "$@"; do
    if ! "$BB" grep -rqF -- "$s" "$GEN"; then
        echo "no generated file holds \\`$s\\`" >&2
        exit 1
    fi
done
echo ok > "$MARK"
"""

def _gen_check_impl(ctx):
    if not ctx.attrs.present:
        fail("{}: `present` is empty; an absence check alone passes over an empty output".format(ctx.label))
    bb = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo].busybox
    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            _CHECK,
            "sh",
            bb,
            ctx.attrs.gen,
            mark.as_output(),
            " ".join(sorted(ctx.attrs.files)),
            str(len(ctx.attrs.absent)),
            ctx.attrs.absent,
            ctx.attrs.present,
        ),
        category = "gcp_client_gen_check",
    )
    return [DefaultInfo(default_output = mark)]

_gen_check = rule(
    impl = _gen_check_impl,
    attrs = {
        "absent": attrs.list(attrs.string(), default = []),
        "files": attrs.list(attrs.string()),
        "gen": attrs.source(allow_directory = True),
        "present": attrs.list(attrs.string()),
        "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    },
)

gen_check = declares_docs(_gen_check)

_TESTS_CHECK = """
BB="$1"; MARK="$2"; WANT="$3"; shift 3
got=""
for m in "$@"; do
    b="$("$BB" basename "$m")"
    case "$b" in *.passed) ;; *) echo "\\`$b\\` is not a test pass marker" >&2; exit 1 ;; esac
    if ! "$BB" grep -q '^PASS ' "$m"; then
        echo "the welded test ${b%.passed} did not pass: $("$BB" cat "$m")" >&2
        exit 1
    fi
    got="$got${b%.passed}
"
done
got="$(printf '%s' "$got" | "$BB" sort | "$BB" tr '\\n' ' ')"
if [ "$got" != "$WANT " ]; then
    echo "the library's welded tests that passed: $got" >&2
    echo "expected exactly:                       $WANT" >&2
    exit 1
fi
echo ok > "$MARK"
"""

def _tests_check_impl(ctx):
    if not ctx.attrs.expect:
        fail("{}: `expect` is empty; name the welded tests the library must run".format(ctx.label))
    bb = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo].busybox
    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            _TESTS_CHECK,
            "sh",
            bb,
            mark.as_output(),
            " ".join(sorted(ctx.attrs.expect)),
            ctx.attrs.markers[DefaultInfo].default_outputs,
        ),
        category = "gcp_client_tests_check",
    )
    return [DefaultInfo(default_output = mark)]

_tests_check = rule(
    impl = _tests_check_impl,
    attrs = {
        "expect": attrs.list(attrs.string()),
        "markers": attrs.dep(),
        "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    },
)

# `tests_check`: which welded tests a library ran, checked as a build action.
# `markers` is a library's `[tests]` sub-target, whose outputs are its pass
# markers. The action fails unless their names are exactly `expect` and each
# marker records a PASS (not a HELD test). gen_check reads the generated
# directory and cannot see whether the layout probe is welded; this can.
tests_check = declares_docs(_tests_check)
