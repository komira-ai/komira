"""Stand-ins for the planted defects of test 54.

`stand_in_npm` provides NpmPackageInfo (loaded from komira, so the provider is
the one the rules require) over a checked-in file, at the name and version a
fixture gives it. Nothing reads the file: analysis refuses each fixture first.

`stand_in_archive` builds a `.tar.gz` whose one top directory holds the files
a fixture names: `files` are written with one line of text (mode 644),
`programs` are copies of the pinned busybox (mode 755), which, run under a
name that is none of its applets (`node`), fails with "applet not found".
"""

load("@komira//tools/build/mojo:toolchain.bzl", "busybox_sh")
load("@komira//tools/build/node:defs.bzl", "NpmPackageInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _impl(ctx):
    return [
        DefaultInfo(),
        NpmPackageInfo(
            name = ctx.attrs.package,
            version = ctx.attrs.version,
            closure = {ctx.attrs.package: (ctx.attrs.version, ctx.attrs.dir)},
        ),
    ]

stand_in_npm = rule(
    impl = _impl,
    attrs = {
        "dir": attrs.source(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)

_ARCHIVE = """
BB="$1"; OUT="$2"; TOP="$3"; shift 3
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.komira_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/komira" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/komira" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
for f in "$@"; do
    p="$T/a/$TOP/${f#*:}"
    mkdir -p "${p%/*}"
    case "$f" in
        file:*) echo "a stand-in file of test 54" > "$p"; chmod 644 "$p" ;;
        program:*) cp "$BB" "$p"; chmod 755 "$p" ;;
    esac
done
tar -cf "$T/a.tar" -C "$T/a" "$TOP"
gzip -c "$T/a.tar" > "$OUT"
rm -rf "$T"
"""

def _archive_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".tar.gz")
    entries = ["file:" + f for f in ctx.attrs.files] + ["program:" + f for f in ctx.attrs.programs]
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(busybox_sh(bb, _ARCHIVE, out.as_output(), ctx.attrs.top, entries), category = "stand_in_archive")
    return [DefaultInfo(default_output = out)]

_stand_in_archive = rule(
    impl = _archive_impl,
    attrs = {
        "files": attrs.list(attrs.string(), default = []),
        "programs": attrs.list(attrs.string(), default = []),
        "top": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def stand_in_archive(**kwargs):
    _stand_in_archive(exec_compatible_with = LINUX_X86_64, **kwargs)
