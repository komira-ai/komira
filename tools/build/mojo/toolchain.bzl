"""Hermetic Mojo toolchain.

Every tool an action runs is an input of that action: a static busybox (shell
and file utilities), the zig distribution (C link driver, and the compiler for
`conda_unpack`), and the compiler closure unpacked from the pinned `.conda`.
Actions never search the worker's PATH.
"""

load(":providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def busybox_sh(busybox, script, *args):
    """argv running `script` under the declared busybox shell.

    The script receives the busybox path as $1 so it can install applet links
    into a private directory and set PATH to that directory only.
    """
    return cmd_args(busybox, "sh", "-euc", script, "sh", busybox, *args)

_PRELUDE = """
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

zig_dist_rule = rule(
    impl = _zig_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "strip_prefix": attrs.string(),
    },
)

# A Zig source file other Zig targets import by name: `@import("<name>")`
# in a `zig_exe` or `zig_test` that lists the target in `deps`. Zig refuses
# a relative `@import` of a file outside the importing file's directory, so a
# file shared by tools in two packages is passed to the compiler as a module
# of its own (`-M<name>=<root>`). A module imports no other module (it has
# no `deps` of its own); that is added when a module first needs one.
ZigModuleInfo = provider(fields = {
    # The import name: the target's name.
    "name": provider_field(str),
    # The module's root source file.
    "root": provider_field(typing.Any),
    # What a compile importing the module takes as inputs: the files `root`
    # imports by a relative name, and the `.passed` output of each of the
    # module's `unit_tests`, so nothing imports the module unless its tests
    # passed.
    "inputs": provider_field(list),
})

def _zig_module_impl(ctx):
    passed = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests]
    return [
        DefaultInfo(default_output = ctx.attrs.src, other_outputs = passed),
        ZigModuleInfo(name = ctx.label.name, root = ctx.attrs.src, inputs = ctx.attrs.imports + passed),
    ]

zig_module_rule = rule(
    impl = _zig_module_impl,
    attrs = {
        # Files `src` imports by a relative name (beside it).
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        # `zig_test` targets of the module; every importer waits for them.
        "unit_tests": attrs.list(attrs.dep(), default = []),
    },
)

def _zig_root(ctx):
    """What the compile is given as its root: `src`; with `deps`, an argument
    file naming `src` as the root module and each dep as a module it may
    import (`@file` is zig's own argument file, read in place of the
    argument). Without `deps` the command line is the one it always was, so
    no existing action changes its key."""
    if not ctx.attrs.deps:
        return ctx.attrs.src
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    args = [cmd_args("--dep", m.name) for m in mods]
    args.append(cmd_args(ctx.attrs.src, format = "-Mroot={}"))
    args += [cmd_args(m.root, format = "-M" + m.name + "={}") for m in mods]
    argfile, _ = ctx.actions.write(ctx.label.name + ".zig_modules", cmd_args(args), allow_args = True)
    return cmd_args(argfile, format = "@{}", hidden = [ctx.attrs.src] + [m.root for m in mods] + [i for m in mods for i in m.inputs])

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
    cmd = busybox_sh(bb, script, zig, _zig_root(ctx), out.as_output())
    if ctx.attrs.imports:
        # Files `src` imports by a relative name: inputs at their paths, so
        # beside it, and not on the command line.
        cmd = cmd_args(cmd, hidden = ctx.attrs.imports)
    if ctx.attrs.unit_tests:
        # Each `zig_test`'s output is an input: the executable is not built
        # unless they passed.
        cmd = cmd_args(cmd, hidden = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests])
    ctx.actions.run(
        cmd,
        category = "zig_build_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

zig_exe_rule = rule(
    impl = _zig_exe_impl,
    attrs = {
        "busybox": attrs.dep(),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        # `zig_test` targets the executable waits for.
        "unit_tests": attrs.list(attrs.dep(), default = []),
        "zig": attrs.dep(),
    },
)

def _zig_test_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    # The tests run with the busybox applets as their PATH and a TMPDIR of
    # their own, inside the action's scratch directory.
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"; TMPDIR="$T/tmp"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME TMPDIR
mkdir -p "$TMPDIR"
"$1/zig" test -target x86_64-linux-musl "$2"
echo passed > "$3"
rm -rf "$T"
"""
    ctx.actions.run(
        cmd_args(busybox_sh(bb, script, zig, _zig_root(ctx), out.as_output()), hidden = ctx.attrs.imports),
        category = "zig_test",
    )
    return [DefaultInfo(default_output = out)]

# `zig test` of `src` (and the `test` blocks of the files it imports, the
# `imports`), run as a build action: the target exists only if every test
# passed. A `zig_exe` names it in `unit_tests` to be built behind it.
zig_test_rule = rule(
    impl = _zig_test_impl,
    attrs = {
        "busybox": attrs.dep(),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        "zig": attrs.dep(),
    },
)

def _conda_closure_impl(ctx):
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("compiler", dir = True)
    # The unpacker is a static executable: it runs with no shell and no PATH.
    libs = []
    for member in ctx.attrs.keep:
        libs.extend(["--keep", member])
    for member, package in sorted(ctx.attrs.libs.items()):
        libs.extend(["--lib", package[DefaultInfo].default_outputs[0], member])
    ctx.actions.run(
        cmd_args(tool, ctx.attrs.package[DefaultInfo].default_outputs[0], out.as_output(), libs),
        category = "conda_unpack",
    )
    return [DefaultInfo(default_output = out)]

conda_closure_rule = rule(
    impl = _conda_closure_impl,
    attrs = {
        # More package members to extract, beyond bin/mojo, lib/ and
        # modular.cfg (e.g. bin/lld, which the osx-arm64 compiler links with).
        "keep": attrs.list(attrs.string(), default = []),
        # member path under lib/ -> the pinned package it is taken from. These
        # land next to the compiler's own libraries, so the loader resolves
        # them from the toolchain (LD_LIBRARY_PATH, and the compiler's
        # $ORIGIN/../lib run path) instead of from the worker.
        "libs": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "package": attrs.dep(),
        "unpacker": attrs.dep(),
    },
)

def _conda_libs_impl(ctx):
    tool = ctx.attrs.unpacker[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("libs", dir = True)
    libs = []
    for member, package in sorted(ctx.attrs.libs.items()):
        libs.extend(["--lib", package[DefaultInfo].default_outputs[0], member])
    ctx.actions.run(
        cmd_args(tool, "--only-libs", out.as_output(), libs),
        category = "conda_unpack",
    )
    return [DefaultInfo(default_output = out)]

# Shared libraries taken out of pinned conda packages, for a tool that is not
# the Mojo compiler: `<out>/lib/<name>`, each a regular file (a library's
# SONAME link is resolved to the bytes it names).
conda_libs_rule = rule(
    impl = _conda_libs_impl,
    attrs = {
        # member path under lib/ -> the pinned package it is taken from.
        "libs": attrs.dict(attrs.string(), attrs.dep()),
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
mojo_runtime_rule = rule(
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
            link = ctx.attrs.zig[DefaultInfo].default_outputs[0],
            cc_target = ctx.attrs.cc_target,
            target_cpu = ctx.attrs.target_cpu,
            wrapper = ctx.attrs._wrapper[DefaultInfo].default_outputs[0],
            watchdog_idle_secs = ctx.attrs.watchdog_idle_secs,
            watchdog_sample_secs = ctx.attrs.watchdog_sample_secs,
            gate_runner = ctx.attrs._gate_runner[DefaultInfo].default_outputs[0],
            run_check = ctx.attrs._run_check[DefaultInfo].default_outputs[0],
            launcher = ctx.attrs._launcher[DefaultInfo].default_outputs[0],
            runtime = ctx.attrs.runtime[DefaultInfo].default_outputs[0],
        ),
    ]

mojo_toolchain_rule = rule(
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
        # The compile watchdog (mojo_wrapper.sh): a compile whose whole process
        # tree uses no CPU for `watchdog_idle_secs` is a deadlocked compiler; it
        # is killed and the action fails with exit 124 instead of holding a
        # worker until the executor's action timeout. 0 turns it off. A slow
        # compile uses CPU throughout and is never killed.
        "watchdog_idle_secs": attrs.int(default = 300),
        "watchdog_sample_secs": attrs.int(default = 30),
        "zig": attrs.exec_dep(),
        "_gate_runner": attrs.dep(default = "komira//tools/build/mojo:gate_runner.sh"),
        "_launcher": attrs.dep(default = "komira//tools/build/mojo:launch.sh"),
        "_run_check": attrs.dep(default = "komira//tools/build/mojo:run_check.sh"),
        # The lint of every script the Mojo rules run (tools/build/lint): a
        # validation, so no Mojo target builds while one of them has a
        # finding. Not an input of any action.
        "_script_lint": attrs.list(attrs.dep(), default = [
            "komira//tools/build/lint:shell_lint",
            "komira//tools/build/mojo:shell_lint",
            "komira//tools/build/mojo/darwin:shell_lint",
        ]),
        "_wrapper": attrs.dep(default = "komira//tools/build/mojo:mojo_wrapper.sh"),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
conda_closure = declares_docs(conda_closure_rule)
conda_libs = declares_docs(conda_libs_rule)
mojo_runtime = declares_docs(mojo_runtime_rule)
mojo_toolchain = declares_docs(mojo_toolchain_rule)
zig_dist = declares_docs(zig_dist_rule)
zig_exe = declares_docs(zig_exe_rule)
zig_test = declares_docs(zig_test_rule)
zig_module = declares_docs(zig_module_rule)
