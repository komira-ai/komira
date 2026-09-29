"""Packaging for Mojo programs: the bundle every package format is made from.

`load("@komira//package:defs.bzl", "mojo_bundle")`

    mojo_bundle(name, binary, version, data = {"share/<path>": <source>})

builds `<name>/`, the program and everything it needs besides glibc and the
kernel, for the target platform (linux x86_64):

    bin/<program>                              launcher (baseline x86-64)
    lib/glibc-hwcaps/<target_cpu>/lib<program>.so   the program
    lib/<runtime libraries>                    Mojo runtime, C++ runtime
    share/...                                  `data`
    VERSION                                    sorted key=value lines
    SHA256SUMS                                 every other file, sorted by path

The launcher checks the CPU's x86-64 level against the level the program was
compiled for (the toolchain's `target_cpu`, the one setting behind the compile
flag, the directory name and the check), refuses with one line naming it when
the CPU is below it, and otherwise loads the program through the loader's
glibc-hwcaps search. Every run path is `$ORIGIN`-relative, so the bundle runs
from wherever it is copied. A program finds its data through
/proc/self/exe: `<dirname>/../share`.

Sub-targets: `[test_launcher]` is the same launcher built with the test hook
(it judges the made-up CPU named by $KOMIRA_TEST_CPU); it is never part of
the bundle. `[launcher]` is the shipped one.
"""

load("@mojo//:providers.bzl", "MojoProgramInfo")
load("@mojo//:toolchain.bzl", "busybox_sh")

# x86-64 levels: target_cpu -> the level the launcher requires.
_LEVELS = {
    "x86-64-v2": 2,
    "x86-64-v3": 3,
    "x86-64-v4": 4,
}

_CC_TARGET = "x86_64-linux-gnu.2.34"

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _launcher(ctx, out_name, program, level, test_hook):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(out_name)
    script = _PRELUDE + """
ZIG="$1"; SRC="$2"; OUT="$3"; NAME="$4"; LEVEL="$5"; shift 5
case "$ZIG" in /*) ;; *) ZIG="$PWD/$ZIG" ;; esac
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$ZIG/zig" cc -target {cc_target} -mcpu=baseline -O2 -fno-stack-protector \\
    -Wall -Wextra -Werror -I "$SRC" \\
    "-DKOMIRA_NAME=\\"$NAME\\"" "-DKOMIRA_MIN_LEVEL=$LEVEL" "$@" \\
    -Wl,--enable-new-dtags '-Wl,-rpath,$ORIGIN/../lib' -Wl,--strip-all -Wl,--build-id=none \\
    -o "$OUT" "$SRC/launcher.c"
rm -rf "$T"
test -s "$OUT"
""".replace("{cc_target}", _CC_TARGET)
    ctx.actions.run(
        busybox_sh(bb, script, zig, src, out.as_output(), program, str(level), ["-DKOMIRA_TEST_CPU_HOOK"] if test_hook else []),
        category = "komira_launcher",
        identifier = out_name,
    )
    return out

def _bundle_impl(ctx):
    prog = ctx.attrs.binary[MojoProgramInfo]
    name = prog.name
    if not regex_match("^[A-Za-z0-9_][A-Za-z0-9_.+-]*$", name):
        fail("{}: program name `{}` cannot name bin/{} and lib{}.so".format(ctx.label, name, name, name))
    if prog.target_cpu not in _LEVELS:
        fail("{}: target_cpu `{}` is not an x86-64 level ({})".format(ctx.label, prog.target_cpu, ", ".join(_LEVELS.keys())))
    level = _LEVELS[prog.target_cpu]
    if not regex_match("^[0-9A-Za-z][0-9A-Za-z.+~-]*$", ctx.attrs.version):
        fail("{}: version `{}` is not a plain version string".format(ctx.label, ctx.attrs.version))

    launcher = _launcher(ctx, "launcher/" + name, name, level, False)
    test_launcher = _launcher(ctx, "test_launcher/" + name, name, level, True)

    data_args = []
    for dest, src in sorted(ctx.attrs.data.items()):
        if not regex_match("^share/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$", dest) or "/../" in dest + "/" or "/./" in dest + "/":
            fail("{}: data path `{}` must be a plain relative path under share/".format(ctx.label, dest))
        data_args.extend([dest, src])

    version_lines = sorted([
        "cpu_levels=" + prog.target_cpu,
        "min_cpu=" + prog.target_cpu,
        "name=" + name,
        "platform=linux-x86_64",
        "version=" + ctx.attrs.version,
    ])
    version = ctx.actions.write(ctx.label.name + ".VERSION", "\n".join(version_lines) + "\n")

    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    script = _PRELUDE + """
OUT="$1"; NAME="$2"; CPU="$3"; LAUNCHER="$4"; SO="$5"; RUNTIME="$6"; VERSION="$7"; shift 7
mkdir -p "$OUT/bin" "$OUT/lib/glibc-hwcaps/$CPU"
cp "$LAUNCHER" "$OUT/bin/$NAME"
cp "$SO" "$OUT/lib/glibc-hwcaps/$CPU/lib$NAME.so"
for f in "$RUNTIME"/*; do cp "$f" "$OUT/lib/"; done
while [ "$#" -gt 0 ]; do
    mkdir -p "$OUT/$(dirname "$1")"
    cp "$2" "$OUT/$1"
    shift 2
done
cp "$VERSION" "$OUT/VERSION"
find "$OUT" -type d -exec chmod 0755 {} +
find "$OUT" -type f -exec chmod 0644 {} +
chmod 0755 "$OUT/bin/$NAME"
cd "$OUT"
find . -type f | sed 's|^\\./||' | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done > "$T/sums"
mv "$T/sums" SHA256SUMS
chmod 0644 SHA256SUMS
cd /
rm -rf "$T"
"""
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        busybox_sh(bb, script, out.as_output(), name, prog.target_cpu, launcher, prog.shared, prog.runtime, version, data_args),
        category = "komira_bundle",
    )
    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {
                "launcher": [DefaultInfo(default_output = launcher)],
                "test_launcher": [DefaultInfo(default_output = test_launcher)],
            },
        ),
    ]

_mojo_bundle = rule(
    impl = _bundle_impl,
    attrs = {
        "binary": attrs.dep(providers = [MojoProgramInfo]),
        # bundle path under share/ -> file
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "version": attrs.string(),
        "_busybox": attrs.exec_dep(default = "toolchains//:busybox"),
        "_launcher_sources": attrs.dep(default = "komira//package/launcher:sources"),
        "_zig": attrs.exec_dep(default = "toolchains//:zig"),
    },
)

def mojo_bundle(**kwargs):
    # Compiling the launcher and copying files: light work.
    _mojo_bundle(exec_compatible_with = ["komira//platforms:light"], **kwargs)

def _level_test_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs._zig[DefaultInfo].default_outputs[0]
    src = ctx.attrs._launcher_sources[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".txt")
    script = _PRELUDE + """
ZIG="$1"; SRC="$2"; OUT="$3"
case "$ZIG" in /*) ;; *) ZIG="$PWD/$ZIG" ;; esac
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$ZIG/zig" cc -target x86_64-linux-musl -static -mcpu=baseline -O2 -Wall -Wextra -Werror \\
    -I "$SRC" -o "$T/level_test" "$SRC/level_test.c"
rc=0
"$T/level_test" > "$OUT" || rc=$?
cat "$OUT" >&2
rm -rf "$T"
exit "$rc"
"""
    ctx.actions.run(busybox_sh(bb, script, zig, src, out.as_output()), category = "launcher_level_test")
    return [DefaultInfo(default_output = out)]

# Builds and runs level_test.c (remotely): the launcher's level function
# against made-up CPUs. Building it fails on any wrong level.
launcher_level_test = rule(
    impl = _level_test_impl,
    attrs = {
        "_busybox": attrs.exec_dep(default = "toolchains//:busybox"),
        "_launcher_sources": attrs.dep(default = "komira//package/launcher:sources"),
        "_zig": attrs.exec_dep(default = "toolchains//:zig"),
    },
)
