"""Golden checks of protoc-gen-mojo, as build actions.

`proto_codegen_golden` runs protoc with the toolchain's protoc-gen-mojo (or
protoc-gen-mojo-db, `plugin = "mojo-db"`) over a
`.proto` corpus with one option string (searching `import_roots`, such as the
pinned googleapis protos, after the corpus), then checks the result in a
second action whose output is the target's default output, so `buck2 build`
of the target IS the check:

  * with `golden`: protoc succeeded and the generated files are exactly the
    golden files (`<name>.mojo.golden` holds `<name>.mojo`), byte for byte;
  * with `expect_error`: protoc failed, its stderr holds that text, and the
    plugin wrote nothing;
  * no generated file holds a string of `absent`, and some generated file
    holds each string of `present` (which keeps an absence check from
    passing over an empty output).

With `service_config`, that file is passed to the plugin as its
`service_config` option, after `options`.

`proto_codegen_rest_helpers` cuts the REST URL helpers block out of one
generated file, for a mojo_library whose welded test runs them.

The `out` sub-target is the generated directory itself, checked or not:
`buck2 build '<target>[out]' --out <dir>` is how a golden is (re)written.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:proto.bzl", "MojoProtoToolchainInfo")

# The busybox prelude of the Mojo proto rules: the applets on PATH and a
# private scratch directory $T.
_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

# $1 protoc dir, $2 plugin (protoc knows it as protoc-gen-mojo, whichever
# binary it is), $3 corpus dir, $4 output dir, $5 options, $6 the count of
# further import roots; then those roots, then the import paths to generate.
# protoc searches the corpus first, then the roots in order, then its own
# well-known types. Always exits 0: the outcome is recorded in the output
# (files/, stderr, rc) for the check action to judge.
_GEN = """
PROTOC="$1"; PLUGIN="$2"; CORPUS="$3"; OUT="$4"; OPT="$5"; N="$6"; shift 6
case "$PLUGIN" in /*) ;; *) PLUGIN="$PWD/$PLUGIN" ;; esac
mkdir -p "$OUT/files" "$T/tmp"
TMPDIR="$T/tmp"; HOME="$T"; export TMPDIR HOME
# Move the roots behind the import paths, as --proto_path flags (protoc reads
# flags and files in any order; the search order is the flags' order).
while [ "$N" -gt 0 ]; do
    r="$1"; shift
    set -- "$@" "--proto_path=$r"
    N=$((N - 1))
done
rc=0
"$PROTOC/bin/protoc" "--proto_path=$CORPUS" "$@" "--proto_path=$PROTOC/include" \\
    "--plugin=protoc-gen-mojo=$PLUGIN" "--mojo_out=$OUT/files" "--mojo_opt=$OPT" \\
    2> "$OUT/stderr" || rc=$?
echo "$rc" > "$OUT/rc"
rm -rf "$T"
"""

# $1 generated dir, $2 golden dir ("" when an error is expected), $3 the
# expected error ("" when golden), $4 marker; then the count of absent
# strings, those strings, then the present strings.
_CHECK = """
GEN="$1"; GOLDEN="$2"; EXPECT="$3"; MARK="$4"; N="$5"; shift 5
rc="$(cat "$GEN/rc")"
if [ -n "$EXPECT" ]; then
    if [ "$rc" = 0 ]; then
        echo "protoc-gen-mojo was expected to fail with: $EXPECT; it succeeded" >&2
        exit 1
    fi
    if ! grep -qF -- "$EXPECT" "$GEN/stderr"; then
        echo "protoc-gen-mojo failed, but not with: $EXPECT" >&2
        cat "$GEN/stderr" >&2
        exit 1
    fi
    if [ -n "$(ls -A "$GEN/files")" ]; then
        echo "protoc-gen-mojo failed but wrote files:" >&2
        ls -A "$GEN/files" >&2
        exit 1
    fi
else
    if [ "$rc" != 0 ]; then
        echo "protoc-gen-mojo failed (exit $rc):" >&2
        cat "$GEN/stderr" >&2
        exit 1
    fi
    if ! diff -r -u "$GOLDEN" "$GEN/files" >&2; then
        echo "the generated files differ from the golden files (above)" >&2
        exit 1
    fi
fi
while [ "$N" -gt 0 ]; do
    if grep -rlF -- "$1" "$GEN/files" >&2; then
        echo "the generated files above hold \\`$1\\`, which must be absent" >&2
        exit 1
    fi
    shift; N=$((N - 1))
done
for s in "$@"; do
    if ! grep -rqF -- "$s" "$GEN/files"; then
        echo "no generated file holds \\`$s\\`" >&2
        exit 1
    fi
done
echo ok > "$MARK"
rm -rf "$T"
"""

def _rel(ctx, src, under):
    """`src`'s path below `under/` of this package."""
    p = src.short_path
    pkg = ctx.label.package + "/"
    if p.startswith(pkg):
        p = p[len(pkg):]
    if not p.startswith(under + "/"):
        fail("{}: `{}` is not under {}/".format(ctx.label, src.short_path, under))
    return p[len(under) + 1:]

def _proto_codegen_golden_impl(ctx):
    ptc = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo]
    if ctx.attrs.golden and ctx.attrs.expect_error:
        fail("{}: state `golden` or `expect_error`, not both".format(ctx.label))
    corpus = ctx.actions.copied_dir(
        "corpus",
        {_rel(ctx, s, "corpus"): s for s in ctx.attrs.srcs},
    )
    if ctx.attrs.plugin == "mojo":
        plugin = ptc.plugin
    elif ctx.attrs.plugin == "mojo-db":
        plugin = ptc.db_plugin
    else:
        fail("{}: `plugin` is `mojo` or `mojo-db`, not `{}`".format(ctx.label, ctx.attrs.plugin))
    gen = ctx.actions.declare_output("gen", dir = True)
    options = ctx.attrs.options
    if ctx.attrs.service_config:
        options = cmd_args(options, ",service_config=", ctx.attrs.service_config, delimiter = "")
    ctx.actions.run(
        cmd_args(
            ptc.busybox,
            "sh",
            "-euc",
            _PRELUDE + _GEN,
            "sh",
            ptc.busybox,
            ptc.protoc,
            plugin,
            corpus,
            gen.as_output(),
            options,
            str(len(ctx.attrs.import_roots)),
            ctx.attrs.import_roots,
            ctx.attrs.generate,
        ),
        category = "proto_codegen_gen",
    )

    golden_dir = ""
    if not ctx.attrs.expect_error:
        # No golden file is an empty golden directory: the diff then names
        # every generated file.
        mapping = {}
        for g in ctx.attrs.golden:
            name = g.basename
            if not name.endswith(".golden"):
                fail("{}: golden file `{}` is not `<generated name>.golden`".format(ctx.label, g.short_path))
            mapping[name[:-len(".golden")]] = g
        golden_dir = ctx.actions.copied_dir("golden", mapping)

    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            ptc.busybox,
            "sh",
            "-euc",
            _PRELUDE + _CHECK,
            "sh",
            ptc.busybox,
            gen,
            golden_dir,
            ctx.attrs.expect_error,
            mark.as_output(),
            str(len(ctx.attrs.absent)),
            ctx.attrs.absent,
            ctx.attrs.present,
        ),
        category = "proto_codegen_check",
    )
    return [DefaultInfo(
        default_output = mark,
        sub_targets = {"out": [DefaultInfo(default_output = gen)]},
    )]

proto_codegen_golden_rule = rule(
    impl = _proto_codegen_golden_impl,
    attrs = {
        "absent": attrs.list(attrs.string(), default = []),
        "expect_error": attrs.string(default = ""),
        # Import paths (below corpus/) to generate.
        "generate": attrs.list(attrs.string()),
        "golden": attrs.list(attrs.source(), default = []),
        # Directories protoc searches after the corpus, in order, each holding
        # .proto files at their import paths: the pinned googleapis protos a
        # REST fixture imports (//tools/vendor/googleapis:api_client[tree]).
        "import_roots": attrs.list(attrs.source(allow_directory = True), default = []),
        # The `--mojo_opt` string, as the Mojo proto rules pass it.
        "options": attrs.string(),
        # The plugin run: protoc-gen-mojo (`mojo`) or protoc-gen-mojo-db
        # (`mojo-db`), both from the proto toolchain.
        "plugin": attrs.string(default = "mojo"),
        "present": attrs.list(attrs.string(), default = []),
        # A service configuration YAML, passed as the `service_config` option.
        "service_config": attrs.option(attrs.source(), default = None),
        # The corpus, every file under corpus/ at its import path.
        "srcs": attrs.list(attrs.source()),
        "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    },
)

def _all_impl(ctx):
    return [DefaultInfo(default_outputs = [d[DefaultInfo].default_outputs[0] for d in ctx.attrs.checks])]

# Every check of the package, by one name.
proto_codegen_goldens_rule = rule(
    impl = _all_impl,
    attrs = {"checks": attrs.list(attrs.dep())},
)

# Exported wrapped, so a BUCK file using them declares its doc_tree: the
# tests cell's doc_tree reads every subpackage's.
proto_codegen_golden = declares_docs(proto_codegen_golden_rule)
proto_codegen_goldens = declares_docs(proto_codegen_goldens_rule)

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
    bb = ctx.attrs._proto_toolchain[MojoProtoToolchainInfo].busybox
    out = ctx.actions.declare_output(ctx.attrs.out)
    src = ctx.attrs.gen.project(ctx.attrs.file)
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _EXTRACT, "sh", bb, src, out.as_output()),
        category = "proto_codegen_extract",
    )
    return [DefaultInfo(default_output = out)]

# The URL helpers block of one generated file (`file`, inside the `[out]`
# directory `gen`, so `files/<name>.mojo`), written to `out`: the source a
# mojo_library compiles so its welded test can run the helpers the plugin
# emits.
proto_codegen_rest_helpers_rule = rule(
    impl = _extract_impl,
    attrs = {
        "file": attrs.string(),
        "gen": attrs.source(),
        "out": attrs.string(),
        "_proto_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_proto", providers = [MojoProtoToolchainInfo]),
    },
)

proto_codegen_rest_helpers = declares_docs(proto_codegen_rest_helpers_rule)
