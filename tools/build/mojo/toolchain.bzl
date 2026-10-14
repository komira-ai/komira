"""Hermetic Mojo toolchain.

Every tool an action runs is an input of that action: a static busybox (shell
and file utilities), the zig distribution (C link driver, and the compiler for
`conda_unpack`), and the compiler closure unpacked from the pinned `.conda`.
Actions never search the worker's PATH.
"""

load(":providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")

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
# of its own (`-M<name>=<root>`). A module may import other modules by name:
# its `deps` are `zig_module` targets, and a compile that imports it is given
# the whole closure, each module with the imports of its own `deps` only (as
# `zig build` wires `addImport`).
ZigModuleInfo = provider(fields = {
    # The import name: the target's name.
    "name": provider_field(str),
    # The module's root source file.
    "root": provider_field(typing.Any),
    # What a compile importing the module takes as inputs: the files `root`
    # imports by a relative name, and the `.passed` output of each of the
    # module's `unit_tests`, so nothing imports the module unless its tests
    # passed. (The same of its `deps` are in `closure`.)
    "inputs": provider_field(list),
    # The modules this one imports by name, as import names.
    "deps": provider_field(list),
    # The target's label, as a string (what two modules of one name are told
    # apart by).
    "label": provider_field(str),
    # Every module this one reaches through `deps`, direct ones first, each
    # once: structs of name, label, root, inputs and deps (import names).
    "closure": provider_field(list),
})

# Names zig gives modules of its own: the importing file is `root`, and
# `std` and `builtin` are always there. A module of one of these names would
# clash with them.
_ZIG_RESERVED_MODULES = ["root", "std", "builtin"]

def _zig_closure(where, deps):
    """The modules `deps` (ZigModuleInfo of the direct deps, in order) reach,
    each once, direct ones first. Fails when two different targets of one
    import name are reached."""
    out = []
    labels = {}
    for dep in deps:
        for e in [struct(name = dep.name, label = dep.label, root = dep.root, inputs = dep.inputs, deps = dep.deps)] + dep.closure:
            if e.name in labels:
                if labels[e.name] != e.label:
                    fail("{}: two different modules are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(where, e.name, labels[e.name], e.label))
                continue
            labels[e.name] = e.label
            out.append(e)
    return out

def _zig_module_impl(ctx):
    if ctx.label.name in _ZIG_RESERVED_MODULES:
        fail("{}: a zig_module may not be named {} (zig's own module names: {})".format(ctx.label.raw_target(), ctx.label.name, ", ".join(_ZIG_RESERVED_MODULES)))
    passed = [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.unit_tests]
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    names = [m.name for m in mods]
    if len(names) != len(set(names)):
        fail("{}: two deps are imported by one name (a zig_module's import name is its target name): {}".format(ctx.label.raw_target(), ", ".join(names)))
    where = str(ctx.label.raw_target())
    return [
        DefaultInfo(default_output = ctx.attrs.src, other_outputs = passed),
        ZigModuleInfo(
            name = ctx.label.name,
            root = ctx.attrs.src,
            inputs = ctx.attrs.imports + passed,
            deps = names,
            label = where,
            closure = _zig_closure(where, mods),
        ),
    ]

zig_module_rule = rule(
    impl = _zig_module_impl,
    attrs = {
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        # Files `src` imports by a relative name (beside it).
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        # `zig_test` targets of the module; every importer waits for them.
        "unit_tests": attrs.list(attrs.dep(), default = []),
    },
)

def _zig_root(ctx):
    """What the compile is given as its root: `src`; with `deps`, an argument
    file naming `src` as the root module and each module it may import (the
    `deps` and what they import, with the imports of each module declared
    before it; `@file` is zig's own argument file, read in place of the
    argument). Without `deps` the command line is the one it always was, so
    no existing action changes its key. Two deps of one import name (the
    same target twice, or two targets of one name) fail analysis rather
    than zig's compile."""
    if not ctx.attrs.deps:
        return ctx.attrs.src
    mods = [d[ZigModuleInfo] for d in ctx.attrs.deps]
    seen = {}
    for d, m in zip(ctx.attrs.deps, mods):
        if m.name in seen:
            fail("{}: two deps are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(ctx.label.raw_target(), m.name, seen[m.name], d.label.raw_target()))
        seen[m.name] = d.label.raw_target()
    closure = _zig_closure(str(ctx.label.raw_target()), mods)
    args = [cmd_args("--dep", m.name) for m in mods]
    args.append(cmd_args(ctx.attrs.src, format = "-Mroot={}"))
    for e in closure:
        args += [cmd_args("--dep", n) for n in e.deps]
        args.append(cmd_args(e.root, format = "-M" + e.name + "={}"))
    argfile, _ = ctx.actions.write(ctx.label.name + ".zig_modules", cmd_args(args), allow_args = True)
    return cmd_args(argfile, format = "@{}", hidden = [ctx.attrs.src] + [e.root for e in closure] + [i for e in closure for i in e.inputs])

# zig's optimization modes, for `optimize`.
ZIG_OPTIMIZE_MODES = ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]

def _zig_optimize(ctx):
    if ctx.attrs.optimize not in ZIG_OPTIMIZE_MODES:
        fail("{}: optimize {} is not a zig optimization mode ({})".format(ctx.label.raw_target(), repr(ctx.attrs.optimize), ", ".join(ZIG_OPTIMIZE_MODES)))
    return ctx.attrs.optimize

def _zig_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" build-exe -OReleaseSafe -target TARGET -fstrip "$2" "-femit-bin=$3"
rm -rf "$T"
"""
    # The target, the optimization mode and the strip flag are written into
    # the script, so that with the defaults the command (and the action key)
    # of every zig_exe is what it was before the attributes existed.
    if not regex_match("^[a-z0-9_.-]+$", ctx.attrs.target):
        fail("{}: target {} is not a zig target triple".format(ctx.label, repr(ctx.attrs.target)))
    script = script.replace("-OReleaseSafe -target TARGET -fstrip ", "-O{} -target {} {} ".format(_zig_optimize(ctx), ctx.attrs.target, "-fstrip" if ctx.attrs.strip else "-fno-strip"))
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
        # zig's -O: the optimization mode.
        "optimize": attrs.string(default = "ReleaseSafe"),
        "src": attrs.source(),
        # Strip symbols and debug information from the executable.
        "strip": attrs.bool(default = True),
        # zig's -target: what the executable runs on (it is built on the
        # linux execution platform whatever this says).
        "target": attrs.string(default = "x86_64-linux-musl"),
        # `zig_test` targets the executable waits for.
        "unit_tests": attrs.list(attrs.dep(), default = []),
        "zig": attrs.dep(),
    },
)

def _zig_test_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    # A test that runs tools (`env_tools`) is also a validation: a target
    # that hands a tool out lists the test that runs it (`kcov_tool`'s
    # `cases`), as the test cannot be an input of the tool it runs. Its
    # result is then a validation result; a test without tools writes
    # `passed`, as it always did.
    validation = bool(ctx.attrs.env_tools)
    out = ctx.actions.declare_output(ctx.label.name + (".json" if validation else ".passed"))
    passed = """printf '{"version": 1, "data": {"status": "success", "message": "zig test passed"}}\\n' > "$3"\n""" if validation else "echo passed > \"$3\"\n"
    # The tests run with the busybox applets as their PATH and a TMPDIR of
    # their own, inside the action's scratch directory.
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"; TMPDIR="$T/tmp"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME TMPDIR
mkdir -p "$TMPDIR"
"$1/zig" test -target TARGET "$2"
""" + passed + """rm -rf "$T"
"""
    # The target and the optimization mode are written into the script; with
    # the defaults (`x86_64-linux-musl`, `Debug`: no flag, zig's own default)
    # the command, and the action key, are what they were before the
    # attributes existed.
    if not regex_match("^[a-z0-9_.-]+$", ctx.attrs.target):
        fail("{}: target {} is not a zig target triple".format(ctx.label, repr(ctx.attrs.target)))
    script = script.replace("test -target TARGET ", "test {}-target {} ".format("" if _zig_optimize(ctx) == "Debug" else "-O" + ctx.attrs.optimize + " ", ctx.attrs.target))
    # The pinned tools a test runs, as environment variables naming their
    # paths.
    env = {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.env_tools.items()}
    env.update(rerun_env(ctx))
    ctx.actions.run(
        cmd_args(busybox_sh(bb, script, zig, _zig_root(ctx), out.as_output()), hidden = ctx.attrs.imports),
        category = "zig_test",
        env = env,
    )
    if validation:
        return [
            DefaultInfo(default_output = out),
            ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = out)]),
            rerun_info(ctx),
        ]
    return [DefaultInfo(default_output = out), rerun_info(ctx)]

# `zig test` of `src` (and the `test` blocks of the files it imports, the
# `imports`), run as a build action: the target exists only if every test
# passed. A `zig_exe` names it in `unit_tests` to be built behind it. A test
# that runs tools names them in `env_tools`; it is then also a validation,
# which a target that hands a tool out lists (`kcov_tool`'s `cases`), as it
# cannot be an input of the executable it runs. It can still be in the
# `unit_tests` of an executable it does not run (cov_zig's unit tests run a
# stand-in zig and debug_relocate).
zig_test_rule = rule(
    impl = _zig_test_impl,
    attrs = {
        "busybox": attrs.dep(),
        # `zig_module` targets `src` imports by name.
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        # name -> a tool the tests run (its default output), in the
        # environment as its path. Configured for the execution platform like
        # the target that hands it out, so the same bytes. It may be a
        # directory of executables: the pinned zig
        # (komira//tools/build/toolchains:zig) is the directory holding `zig`.
        "env_tools": attrs.dict(attrs.string(), attrs.exec_dep(), default = {}),
        "imports": attrs.list(attrs.source(), default = []),
        # zig's -O: the optimization mode the tests are built with. `Debug`
        # is zig's own default (no flag is passed).
        "optimize": attrs.string(default = "Debug"),
        "src": attrs.source(),
        # zig's -target. The tests run as part of the action, so it must be a
        # target the execution platform runs (the default, or another libc
        # of its cpu).
        "target": attrs.string(default = "x86_64-linux-musl"),
        "zig": attrs.dep(),
    } | RERUN_ATTRS,
)

def _zig_test_binary_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    if not regex_match("^[a-z0-9_.-]+$", ctx.attrs.target):
        fail("{}: target {} is not a zig target triple".format(ctx.label, repr(ctx.attrs.target)))
    script = _PRELUDE + """
ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" test -target TARGET --test-no-exec "-femit-bin=$3" "$2"
rm -rf "$T"
""".replace("-target TARGET ", "-target {} ".format(ctx.attrs.target))
    ctx.actions.run(
        cmd_args(busybox_sh(bb, script, zig, _zig_root(ctx), out.as_output()), hidden = ctx.attrs.imports),
        category = "zig_test_binary",
    )
    return [DefaultInfo(default_output = out)]

# The `zig test` executable of `src` for another platform (`target`), built
# on the linux execution platform and not run: a `zig_test_run` on that
# platform runs it.
zig_test_binary_rule = rule(
    impl = _zig_test_binary_impl,
    attrs = {
        "busybox": attrs.dep(),
        "deps": attrs.list(attrs.dep(providers = [ZigModuleInfo]), default = []),
        "imports": attrs.list(attrs.source(), default = []),
        "src": attrs.source(),
        "target": attrs.string(),
        "zig": attrs.dep(),
    },
)

def _zig_test_run_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    # As zig_test's run: the applets as PATH, a TMPDIR of its own.
    script = _PRELUDE + """
HOME="$T/home"; TMPDIR="$T/tmp"
export HOME TMPDIR
mkdir -p "$TMPDIR" "$HOME"
"$1" > "$T/out" 2>&1 || { cat "$T/out" >&2; exit 1; }
# The marker is the runner's summary (`All N tests passed.`, or its
# count of passed and skipped tests).
tail -n 1 "$T/out" > "$2"
rm -rf "$T"
"""
    ctx.actions.run(
        busybox_sh(bb, script, ctx.attrs.binary[DefaultInfo].default_outputs[0], out.as_output()),
        category = "zig_test_run",
    )
    return [DefaultInfo(default_output = out)]

# Runs a `zig_test_binary` as a build action on this target's execution
# platform, with `busybox` (that platform's) for the applets: the target
# exists only if every test passed. A `zig_exe` names it in `unit_tests`.
zig_test_run_rule = rule(
    impl = _zig_test_run_impl,
    attrs = {
        "binary": attrs.dep(),
        "busybox": attrs.dep(),
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
            gate = ctx.attrs._gate[DefaultInfo].default_outputs[0],
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
        # The compile watchdog (tools/mojo_compile.zig): a compile whose whole process
        # tree uses no CPU for `watchdog_idle_secs` is a deadlocked compiler; it
        # is killed and the action fails with exit 124 instead of holding a
        # worker until the executor's action timeout. 0 turns it off. A slow
        # compile uses CPU throughout and is never killed.
        "watchdog_idle_secs": attrs.int(default = 300),
        "watchdog_sample_secs": attrs.int(default = 30),
        "zig": attrs.exec_dep(),
        # The gate (tools/build/run): runs every gated test and mutation
        # step. An exec dep: it runs in the actions, on the execution platform.
        "_gate": attrs.exec_dep(default = "komira//tools/build/run:gate"),
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
        # The compile wrapper (tools/mojo_compile.zig), an executable built
        # behind its unit tests; defs.bzl's mojo_compile_cmd runs it.
        "_wrapper": attrs.exec_dep(default = "komira//tools/build/mojo:mojo_compile"),
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
zig_test_binary = declares_docs(zig_test_binary_rule)
zig_test_run = declares_docs(zig_test_run_rule)
zig_module = declares_docs(zig_module_rule)
