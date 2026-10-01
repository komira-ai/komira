"""Check actions over protoc-gen-mojo: text goldens and refusals.

`proto_codegen_golden` runs protoc with the plugin over `generate` in one
action, whose directory is the `[gen]` sub-target, and compares every file it
wrote with `goldens` in a second action, the default output. The plugin must
write exactly the files `goldens` names. To update a golden after a deliberate
change to the emitter, build `[gen]` and copy the file over the golden.

`proto_codegen_refusal` runs the plugin on input it must refuse, and passes
only when protoc exits non-zero, says `expect` on stderr and writes no file.

`srcs` are the fixture `.proto` files under the package's `protos/`
directory, staged at their path below it (their protoc import path), with
protoc's own well-known types on the path as well.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo")

_PROTOS = "protos/"

# $1 busybox, $2 mode, $3 protoc dir, $4 plugin, $5 proto tree, $6 plugin
# options, then per mode:
#   gen    <out dir> <import paths...>
#   cmp    <stamp> <gen dir> then <name> <golden> pairs
#   refuse <stamp> <expected stderr text> <import paths...>
_SCRIPT = """
abspath() { case "$1" in /*) printf '%s\\n' "$1" ;; *) printf '%s/%s\\n' "$PWD" "$1" ;; esac; }
BB=$(abspath "$1"); MODE=$2; PROTOC=$(abspath "$3"); PLUGIN=$(abspath "$4"); TREE=$5; OPT=$6
shift 6
# Private scratch: a local action shares the checkout root with every other
# local action, so it takes the per-action directory buck2 names.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_proto_codegen" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/tools" "$T/tmp"
"$BB" --install -s "$T/tools"
PATH="$T/tools"; HOME="$T"; TMPDIR="$T/tmp"; export PATH HOME TMPDIR
protoc() { # out dir, import paths...
    out=$1; shift
    "$PROTOC/bin/protoc" "--proto_path=$TREE" "--proto_path=$PROTOC/include" \\
        "--plugin=protoc-gen-mojo=$PLUGIN" "--mojo_out=$out" "--mojo_opt=$OPT" "$@"
}
case "$MODE" in
gen)
    OUT=$1; shift
    mkdir -p "$OUT"
    protoc "$OUT" "$@"
    ;;
cmp)
    STAMP=$1; GEN=$2; shift 2
    bad=0; n=0
    while [ "$#" -gt 0 ]; do
        n=$((n + 1))
        if ! cmp -s "$GEN/$1" "$2"; then
            echo "proto_codegen: $GEN/$1 differs from the golden $2:" >&2
            diff -u "$2" "$GEN/$1" | head -60 >&2 || true
            bad=1
        fi
        shift 2
    done
    if [ "$(ls -A "$GEN" | wc -l)" != "$n" ]; then
        echo "proto_codegen: the plugin wrote files no golden names:" >&2
        ls -A "$GEN" >&2
        bad=1
    fi
    [ "$bad" = 0 ] || exit 1
    printf 'equal to the goldens: %s file(s)\\n' "$n" > "$STAMP"
    ;;
refuse)
    STAMP=$1; WANT=$2; shift 2
    mkdir -p "$T/out"
    rc=0
    protoc "$T/out" "$@" 2> "$T/stderr" || rc=$?
    if [ "$rc" = 0 ]; then
        echo "proto_codegen: expected a refusal, and protoc exited 0" >&2
        exit 1
    fi
    if ! grep -qF -- "$WANT" "$T/stderr"; then
        echo "proto_codegen: the refusal does not say: $WANT" >&2
        echo "it said:" >&2
        head -c 2000 "$T/stderr" >&2
        exit 1
    fi
    if [ -n "$(ls -A "$T/out")" ]; then
        echo "proto_codegen: the plugin refused but wrote: $(ls -A "$T/out")" >&2
        exit 1
    fi
    printf 'refused (exit %s): %s\\n' "$rc" "$WANT" > "$STAMP"
    ;;
*)
    echo "proto_codegen: unknown mode $MODE" >&2
    exit 2
    ;;
esac
rm -rf "$T"
"""

def _stage(ctx):
    return ctx.actions.symlinked_dir("protos", {
        _import_path(ctx, s): s
        for s in ctx.attrs.srcs
    })

def _run(ctx, tree, category, *args):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ptc = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo]
    plugin = ctx.attrs._plugin[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _SCRIPT, "sh", bb, args[0], ptc.protoc, plugin, tree, ctx.attrs.opt, list(args[1:])),
        category = category,
    )

def _import_path(ctx, src):
    # A source's short_path is relative to its package.
    if not src.short_path.startswith(_PROTOS):
        fail("{}: `{}` is not under `{}`".format(ctx.label, src.short_path, _PROTOS))
    return src.short_path[len(_PROTOS):]

def _golden_impl(ctx):
    gen_dir = ctx.actions.declare_output(ctx.label.name + "_gen", dir = True)
    tree = _stage(ctx)
    _run(ctx, tree, "proto_codegen_gen", "gen", gen_dir.as_output(), ctx.attrs.generate)
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    pairs = []
    for name, golden in sorted(ctx.attrs.goldens.items()):
        pairs.extend([name, golden])
    _run(ctx, tree, "proto_codegen_cmp", "cmp", stamp.as_output(), gen_dir, pairs)
    return [DefaultInfo(
        default_output = stamp,
        sub_targets = {"gen": [DefaultInfo(default_output = gen_dir)]},
    )]

def _refusal_impl(ctx):
    stamp = ctx.actions.declare_output(ctx.label.name + ".ok")
    _run(ctx, _stage(ctx), "proto_codegen_refuse", "refuse", stamp.as_output(), ctx.attrs.expect, ctx.attrs.generate)
    return [DefaultInfo(default_output = stamp)]

_COMMON = {
    # The import paths (below `protos/`) to generate code for.
    "generate": attrs.list(attrs.string()),
    # The plugin options, as mojo_proto_library passes them.
    "opt": attrs.string(),
    "srcs": attrs.list(attrs.source()),
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    # The plugin under test, built from this checkout.
    "_plugin": attrs.exec_dep(default = "komira//tools/build/proto-codegen:protoc-gen-mojo"),
    # protoc and its well-known types.
    "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
}

proto_codegen_golden_rule = rule(
    impl = _golden_impl,
    attrs = _COMMON | {
        # Generated file name -> its golden.
        "goldens": attrs.dict(attrs.string(), attrs.source()),
    },
)

proto_codegen_refusal_rule = rule(
    impl = _refusal_impl,
    attrs = _COMMON | {
        "expect": attrs.string(),
    },
)

# Each declares its package's doc_tree too (tools/build/lint/doc_tree.bzl).
proto_codegen_golden = declares_docs(proto_codegen_golden_rule)
proto_codegen_refusal = declares_docs(proto_codegen_refusal_rule)

# ---- the emitted URL helpers, as Mojo the check below compiles ---------------

# $1 busybox, $2 generated file, $3 output. Copies the lines from the begin
# marker to the end marker, both included, and fails unless each occurs
# exactly once: a helper moved out of the block fails to compile in the
# check rather than going unchecked.
_EXTRACT = """
BB=$1; SRC=$2; OUT=$3
BEGIN='# ---- REST URL helpers (one copy per REST file) ----'
END='# ---- end of REST URL helpers ----'
for m in "$BEGIN" "$END"; do
    n=$("$BB" grep -cxF -- "$m" "$SRC" || true)
    if [ "$n" != 1 ]; then
        echo "proto_codegen: $SRC holds the marker '$m' $n times, not once" >&2
        exit 1
    fi
done
"$BB" awk -v b="$BEGIN" -v e="$END" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$SRC" > "$OUT"
"""

def _extract_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.attrs.out)
    src = ctx.attrs.gen.project(ctx.attrs.file)
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _EXTRACT, "sh", bb, src, out.as_output()),
        category = "proto_codegen_extract",
    )
    return [DefaultInfo(default_output = out)]

# The URL helpers block of one generated file (`file`, inside the `[gen]`
# directory `gen`), written to `out`: the source a mojo_library compiles so
# its welded test can run the helpers the plugin emits.
proto_codegen_rest_helpers_rule = rule(
    impl = _extract_impl,
    attrs = {
        "file": attrs.string(),
        "gen": attrs.source(),
        "out": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

proto_codegen_rest_helpers = declares_docs(proto_codegen_rest_helpers_rule)
