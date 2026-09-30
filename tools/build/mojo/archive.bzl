"""`archive_files`: named files out of a sha256-pinned source archive.

A remote action unpacks the archive with the declared busybox and copies out
exactly the files listed in `files` (and `templates`); each becomes its own
output and a sub-target named by its path, so a `cxx_library` can name
`:<target>[snappy.cc]` as a source. A listed file missing from the archive
fails the action.

With `one_tree`, the files are one directory output instead, and each
sub-target is a projection of it (see the attribute).

`templates` maps an output path to a file in the archive; every key of
`substitutions` is replaced, literally, by its value in each template (the
configure step of a CMake `configure_file`, without CMake).
"""

load(":toolchain.bzl", "busybox_sh")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/x"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
ARCHIVE="$1"; PREFIX="$2"; SED="$3"; shift 3
case "$ARCHIVE" in
    *.tar.gz | *.tgz) tar -xzf "$ARCHIVE" -C "$T/x" ;;
    *.tar.xz) tar -xJf "$ARCHIVE" -C "$T/x" ;;
    *.tar) tar -xf "$ARCHIVE" -C "$T/x" ;;
    *) echo "archive_files: unsupported archive type: $ARCHIVE" >&2; exit 2 ;;
esac
SRC="$T/x/$PREFIX"
TREE=
while [ "$#" -gt 0 ]; do
    if [ "$1" = --tree ]; then TREE="$2/"; shift 2; continue; fi
    kind="$1"; rel="$2"; out="$TREE$3"; shift 3
    if [ ! -f "$SRC/$rel" ]; then
        echo "archive_files: $rel is not a file in $ARCHIVE (under '$PREFIX')" >&2
        exit 2
    fi
    mkdir -p "$(dirname "$out")"
    case "$kind" in
        file) cp "$SRC/$rel" "$out" ;;
        template) sed -f "$SED" "$SRC/$rel" > "$out" ;;
    esac
done
rm -rf "$T"
"""

def _sed_escape(s, specials):
    for c in specials:
        s = s.replace(c, "\\" + c)
    return s

def _archive_files_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    archive = ctx.attrs.archive[DefaultInfo].default_outputs[0]
    lines = []
    for k, v in sorted(ctx.attrs.substitutions.items()):
        lines.append("s/{}/{}/g".format(
            _sed_escape(k, ["\\", "/", ".", "*", "[", "]", "^", "$"]),
            _sed_escape(v, ["\\", "/", "&"]),
        ))
    sed = ctx.actions.write("substitutions.sed", "\n".join(lines) + "\n")
    args = []
    sub_targets = {}
    outs = []
    tree = None
    if ctx.attrs.one_tree:
        tree = ctx.actions.declare_output("files", dir = True)
        args.extend(["--tree", tree.as_output()])
        outs.append(tree)
        for d in ctx.attrs.tree_dirs:
            sub_targets[d] = [DefaultInfo(default_output = tree.project(d))]
    elif ctx.attrs.tree_dirs:
        fail("{}: tree_dirs needs one_tree = True".format(ctx.label))
    for kind, pairs in [("file", [(f, f) for f in ctx.attrs.files]), ("template", sorted(ctx.attrs.templates.items()))]:
        for name, rel in pairs:
            if name in sub_targets:
                fail("{}: {} is listed twice".format(ctx.label, name))
            if tree:
                args.extend([kind, rel, name])
                sub_targets[name] = [DefaultInfo(default_output = tree.project(name))]
            else:
                out = ctx.actions.declare_output("files/" + name)
                args.extend([kind, rel, out.as_output()])
                sub_targets[name] = [DefaultInfo(default_output = out)]
                outs.append(out)
    ctx.actions.run(
        busybox_sh(bb, _SCRIPT, archive, ctx.attrs.strip_prefix, sed, args),
        category = "archive_files",
    )
    return [DefaultInfo(default_outputs = outs, sub_targets = sub_targets)]

archive_files_rule = rule(
    impl = _archive_files_impl,
    attrs = {
        # A pinned_file holding the archive; its name must end in the format.
        "archive": attrs.dep(),
        "busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "files": attrs.list(attrs.string(), default = []),
        # One output, a directory holding every file at its path in the
        # archive (each file's sub-target is a projection of it), so that a
        # source finds what it includes by relative path ("../internal.h").
        # Separate outputs may each get a content-based path of their own.
        "one_tree": attrs.bool(default = False),
        "strip_prefix": attrs.string(default = ""),
        "substitutions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "templates": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # With one_tree: directories of the tree that are sub-targets of their
        # own, for an -I flag ($(location :<target>[include])).
        "tree_dirs": attrs.list(attrs.string(), default = []),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
archive_files = declares_docs(archive_files_rule)
