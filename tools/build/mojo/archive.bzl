"""`archive_files`: named files out of a sha256-pinned source archive.

A remote action unpacks the archive with the declared busybox and copies out
exactly the files listed in `files` (and `templates`); each becomes its own
output and a sub-target named by its path, so a `cxx_library` can name
`:<target>[snappy.cc]` as a source. A listed file missing from the archive
fails the action.

`templates` maps an output path to a file in the archive; every key of
`substitutions` is replaced, literally, by its value in each template (the
configure step of a CMake `configure_file`, without CMake).
"""

load(":toolchain.bzl", "busybox_sh")

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
while [ "$#" -gt 0 ]; do
    kind="$1"; rel="$2"; out="$3"; shift 3
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
    for kind, pairs in [("file", [(f, f) for f in ctx.attrs.files]), ("template", sorted(ctx.attrs.templates.items()))]:
        for name, rel in pairs:
            if name in sub_targets:
                fail("{}: {} is listed twice".format(ctx.label, name))
            out = ctx.actions.declare_output("files/" + name)
            args.extend([kind, rel, out.as_output()])
            sub_targets[name] = [DefaultInfo(default_output = out)]
            outs.append(out)
    ctx.actions.run(
        busybox_sh(bb, _SCRIPT, archive, ctx.attrs.strip_prefix, sed, args),
        category = "archive_files",
    )
    return [DefaultInfo(default_outputs = outs, sub_targets = sub_targets)]

archive_files = rule(
    impl = _archive_files_impl,
    attrs = {
        # A pinned_file holding the archive; its name must end in the format.
        "archive": attrs.dep(),
        "busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "files": attrs.list(attrs.string(), default = []),
        "strip_prefix": attrs.string(default = ""),
        "substitutions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "templates": attrs.dict(attrs.string(), attrs.string(), default = {}),
    },
)
