"""Hermetic Mojo toolchain.

Every tool an action runs is an input of that action: a static busybox (shell
and file utilities), the zig distribution (C link driver, and the compiler for
`conda_unpack`), and the compiler closure unpacked from the pinned `.conda`.
Actions never search the worker's PATH.
"""

load(":providers.bzl", "MojoToolchainInfo")

def busybox_sh(busybox, script, *args):
    """argv running `script` under the declared busybox shell.

    The script receives the busybox path as $1 so it can install applet links
    into a private directory and set PATH to that directory only.
    """
    return cmd_args(busybox, "sh", "-euc", script, "sh", busybox, *args)

_PRELUDE = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
T="$PWD/.komira_action"
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
"""

def _zig_dist_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("zig", dir = True)
    script = _PRELUDE + """
mkdir -p "$2.x"
tar -xJf "$1" -C "$2.x"
mv "$2.x/$3" "$2"
rm -rf "$2.x" "$T"
test -x "$2/zig"
"""
    ctx.actions.run(
        busybox_sh(bb, script, ctx.attrs.archive[DefaultInfo].default_outputs[0], out.as_output(), ctx.attrs.strip_prefix),
        category = "zig_unpack",
    )
    return [DefaultInfo(default_output = out)]

zig_dist = rule(
    impl = _zig_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "strip_prefix": attrs.string(),
    },
)

def _zig_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" build-exe -OReleaseSafe -target x86_64-linux-musl -fstrip "$2" "-femit-bin=$3"
rm -rf "$T"
"""
    ctx.actions.run(
        busybox_sh(bb, script, zig, ctx.attrs.src, out.as_output()),
        category = "zig_build_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

zig_exe = rule(
    impl = _zig_exe_impl,
    attrs = {
        "busybox": attrs.dep(),
        "src": attrs.source(),
        "zig": attrs.dep(),
    },
)

def _conda_closure_impl(ctx):
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("compiler", dir = True)
    # The unpacker is a static executable: it runs with no shell and no PATH.
    libs = []
    for member, package in sorted(ctx.attrs.libs.items()):
        libs.extend(["--lib", package[DefaultInfo].default_outputs[0], member])
    ctx.actions.run(
        cmd_args(tool, ctx.attrs.package[DefaultInfo].default_outputs[0], out.as_output(), libs),
        category = "conda_unpack",
    )
    return [DefaultInfo(default_output = out)]

conda_closure = rule(
    impl = _conda_closure_impl,
    attrs = {
        # member path under lib/ -> the pinned package it is taken from. These
        # land next to the compiler's own libraries, so the loader resolves
        # them from the toolchain (LD_LIBRARY_PATH, and the compiler's
        # $ORIGIN/../lib run path) instead of from the worker.
        "libs": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "package": attrs.dep(),
        "unpacker": attrs.dep(),
    },
)

def _mojo_runtime_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    compiler = ctx.attrs.compiler[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("lib", dir = True)
    # Copies each named library out of the unpacked compiler's lib/ into one
    # flat directory, and refuses a name that is missing or empty there.
    script = _PRELUDE + """
SRC="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
for lib in "$@"; do
    if [ ! -s "$SRC/lib/$lib" ]; then
        echo "mojo_runtime: REFUSING: lib/$lib is missing or empty in the compiler closure" >&2
        exit 2
    fi
    cp "$SRC/lib/$lib" "$OUT/$lib"
done
rm -rf "$T"
"""
    ctx.actions.run(
        busybox_sh(bb, script, compiler, out.as_output(), ctx.attrs.libs),
        category = "mojo_runtime",
    )
    return [DefaultInfo(default_output = out)]

# The shared libraries a built Mojo binary loads at run time, and nothing
# else: `buck2 run` downloads these next to the binary, never the compiler.
mojo_runtime = rule(
    impl = _mojo_runtime_impl,
    attrs = {
        "busybox": attrs.exec_dep(),
        "compiler": attrs.dep(),
        # File names under the compiler's lib/.
        "libs": attrs.list(attrs.string()),
    },
)

def _mojo_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        MojoToolchainInfo(
            busybox = ctx.attrs.busybox[DefaultInfo].default_outputs[0],
            compiler = ctx.attrs.compiler[DefaultInfo].default_outputs[0],
            zig = ctx.attrs.zig[DefaultInfo].default_outputs[0],
            cc_target = ctx.attrs.cc_target,
            target_cpu = ctx.attrs.target_cpu,
            wrapper = ctx.attrs._wrapper[DefaultInfo].default_outputs[0],
            gate_runner = ctx.attrs._gate_runner[DefaultInfo].default_outputs[0],
            run_check = ctx.attrs._run_check[DefaultInfo].default_outputs[0],
            numa_guard = ctx.attrs._numa_guard[DefaultInfo].default_outputs[0],
            launcher = ctx.attrs._launcher[DefaultInfo].default_outputs[0],
            runtime = ctx.attrs.runtime[DefaultInfo].default_outputs[0],
        ),
    ]

mojo_toolchain = rule(
    impl = _mojo_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "cc_target": attrs.string(),
        "compiler": attrs.exec_dep(),
        # A `mojo_runtime` over `compiler`. An exec dep like the compiler it
        # is cut from: every Mojo target builds on an execution platform with
        # its own os and cpu, so the compiler's runtime is the target's.
        "runtime": attrs.exec_dep(),
        "target_cpu": attrs.string(),
        "zig": attrs.exec_dep(),
        "_gate_runner": attrs.dep(default = "mojo//:gate_runner.sh"),
        "_launcher": attrs.dep(default = "mojo//:launch.sh"),
        "_numa_guard": attrs.dep(default = "mojo//:numa_guard.sh"),
        "_run_check": attrs.dep(default = "mojo//:run_check.sh"),
        "_wrapper": attrs.dep(default = "mojo//:mojo_wrapper.sh"),
    },
)
