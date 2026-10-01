"""Vendored googleapis .proto files, checked by protoc against their pin.

    proto_check(
        name = "logging_v2_check",
        roots = ["google/logging/v2/logging.proto"],
        srcs = glob(["google/**/*.proto"]),
        pin = "PIN.tsv",
        license = "LICENSE",
    )

`proto_check` stages `srcs` at their import paths (less `strip_prefix`) and
runs proto_check.sh over them, one action under the pinned busybox on a light
worker: the tree must be exactly PIN.tsv (its commit, roots, LICENSE and
per-file sha256), and protoc (`toolchains//:mojo_proto`, the protoc every
mojo_proto_library runs) must parse the roots with nothing on its path but
the tree and its own well-known types, writing a descriptor set
(--include_imports) whose files are exactly the tree's. So a file the closure
needs and the tree lacks fails here, and so does a vendored file nothing
imports.

The default output is that descriptor set; `[tree]` is the checked copy of
the tree, written only when every check passes. `ProtoSrcsInfo` carries that
copy, so a mojo_proto_library may take the target as a `proto_deps` entry and
read only checked files.

`proto_check_case` runs the same check over a fixture and asserts its verdict:
accepted when `expect` is empty, otherwise refused with a message holding
`expect`. BUCK holds the cases over testdata/; every proto_check target
depends on them, so a check that stops refusing fails the build of every
vendored tree, not only of its own test.

This rule lives with the files it checks until tools/build/cloud/vendor.bzl
(the aws_model rule) is on main; then it moves there.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo", "ProtoSrcsInfo")

# Checking runs on the light workers: it parses a few files and compiles nothing.
_LIGHT = ["komira//tools/build/platforms:light"]

def _stage(ctx):
    """`srcs` staged at their import paths: (directory, import paths)."""
    prefix = ctx.attrs.strip_prefix.strip("/")
    staged = {}
    for s in ctx.attrs.srcs:
        path = s.short_path
        if prefix:
            if not path.startswith(prefix + "/"):
                fail("proto_check {}: {} is not under strip_prefix {}".format(ctx.label.name, path, prefix))
            path = path[len(prefix) + 1:]
        staged[path] = s
    return ctx.actions.copied_dir(ctx.attrs.name + ".srcs", staged), sorted(staged.keys())

def _check_args(ctx):
    """The busybox, and proto_check.sh's arguments up to the two outputs."""
    tc = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo]
    tree, paths = _stage(ctx)
    return tc.busybox, paths, cmd_args(tc.busybox, tc.protoc, tree, ctx.attrs.pin, ctx.attrs.license)

def _proto_check_impl(ctx):
    out_set = ctx.actions.declare_output(ctx.attrs.name + ".descriptor_set.pb")
    out_tree = ctx.actions.declare_output(ctx.attrs.name + ".tree", dir = True)
    bb, paths, args = _check_args(ctx)
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            ctx.attrs._script,
            args,
            out_set.as_output(),
            out_tree.as_output(),
            ctx.attrs.roots,
            # The self-test's verdicts: the check runs only once it has
            # refused every bad fixture (BUCK, proto_check_selftest).
            hidden = [d[DefaultInfo].default_outputs for d in ctx.attrs._selftest],
        ),
        category = "proto_check",
        identifier = ctx.attrs.name,
    )
    return [
        DefaultInfo(default_output = out_set, sub_targets = {"tree": [DefaultInfo(default_output = out_tree)]}),
        ProtoSrcsInfo(trees = [out_tree], import_paths = paths),
    ]

_COMMON = {
    "license": attrs.source(),
    "pin": attrs.source(),
    "roots": attrs.list(attrs.string()),
    "srcs": attrs.list(attrs.source()),
    "strip_prefix": attrs.string(default = ""),
    "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    "_script": attrs.source(default = "komira//tools/vendor/googleapis:proto_check.sh"),
    # A validation: the lint of proto_check.sh and vendor.sh.
    "_script_lint": attrs.list(attrs.dep(), default = ["komira//tools/vendor/googleapis:shell_lint"]),
}

_proto_check = rule(
    impl = _proto_check_impl,
    doc = "Vendored .proto files (`srcs`, staged at their import paths less `strip_prefix`), refused unless they are exactly `pin` and exactly the import closure protoc parses for `roots`. The default output is the descriptor set; `[tree]` is the checked copy, which ProtoSrcsInfo carries.",
    attrs = _COMMON | {
        "_selftest": attrs.list(attrs.dep(), default = ["komira//tools/vendor/googleapis:proto_check_selftest"]),
    },
)

# The check's outputs go to a scratch directory: a refusal must write
# neither, and an acceptance must write both.
_CASE_SCRIPT = """
SCRIPT="$1"; EXPECT="$2"; REPORT="$3"; BB="$4"; shift 3
T="$PWD/.proto_check_case"
"$BB" rm -rf "$T"
"$BB" mkdir -p "$T"
# The check's arguments: BB PROTOC TREE PIN LICENSE, the outputs, the roots.
B1="$1"; B2="$2"; B3="$3"; B4="$4"; B5="$5"; shift 5
rc=0
"$BB" sh "$SCRIPT" "$B1" "$B2" "$B3" "$B4" "$B5" "$T/set.pb" "$T/tree" "$@" 2> "$T/err" || rc=$?
if [ -z "$EXPECT" ]; then
    if [ "$rc" -ne 0 ]; then
        echo "proto_check_case: the check refused a tree it must accept:" >&2
        "$BB" cat "$T/err" >&2
        exit 1
    fi
    "$BB" test -s "$T/set.pb" || { echo "proto_check_case: the check wrote no descriptor set" >&2; exit 1; }
    "$BB" diff -r "$B3" "$T/tree" > /dev/null || { echo "proto_check_case: the checked tree differs from the vendored one" >&2; exit 1; }
    echo "accepted" > "$REPORT"
elif [ "$rc" -eq 0 ]; then
    echo "proto_check_case: the check accepted a tree it must refuse with: $EXPECT" >&2
    exit 1
elif ! "$BB" grep -qF -- "$EXPECT" "$T/err"; then
    echo "proto_check_case: the check refused, but not with: $EXPECT" >&2
    "$BB" cat "$T/err" >&2
    exit 1
elif [ -e "$T/set.pb" ] || [ -e "$T/tree" ]; then
    echo "proto_check_case: the check refused but wrote an output" >&2
    exit 1
else
    { echo "refused"; "$BB" cat "$T/err"; } > "$REPORT"
fi
"$BB" rm -rf "$T"
"""

def _proto_check_case_impl(ctx):
    report = ctx.actions.declare_output(ctx.attrs.name + ".verdict.txt")
    bb, _, args = _check_args(ctx)
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _CASE_SCRIPT, "sh", ctx.attrs._script, ctx.attrs.expect, report.as_output(), args, ctx.attrs.roots),
        category = "proto_check_case",
        identifier = ctx.attrs.name,
    )
    return [DefaultInfo(default_output = report)]

_proto_check_case = rule(
    impl = _proto_check_case_impl,
    doc = "The proto_check check over a fixture, with its verdict asserted: accepted when `expect` is empty, otherwise refused with a message holding `expect`.",
    attrs = _COMMON | {
        "expect": attrs.string(default = ""),
    },
)

def proto_check(**kwargs):
    _proto_check(exec_compatible_with = _LIGHT, **kwargs)

def proto_check_case(**kwargs):
    _proto_check_case(exec_compatible_with = _LIGHT, **kwargs)

proto_check = declares_docs(proto_check)
proto_check_case = declares_docs(proto_check_case)
