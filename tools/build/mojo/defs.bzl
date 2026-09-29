"""Mojo rules for Buck2: mojo_library, mojo_binary, mojo_test, mojo_multi_numa_test.

Every action runs the hermetic toolchain from `toolchains//:mojo` through
`mojo_wrapper.sh`; see that file for the environment the compiler sees.

Output layout of a library `L` with import name `I`:

    L/ungated/I.mojoc      the compiler's output (sub-target `[ungated]`: files
                           only, no MojoInfo, so it cannot be named in `deps`)
    L/pkg/I.mojoc          the public package: a copy of the ungated one that
                           takes every test's PASS marker as an input
    L/src/I/...            the staged package sources
    L/tests/<t>/...        one binary and one PASS marker per test

Each `-I` directory given to the compiler holds exactly one `.mojoc`, so a
staged source directory can never shadow a package.
"""

load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoProgramInfo", "MojoRunnableInfo", "MojoToolchainInfo")

def _toolchain(ctx):
    return ctx.attrs.toolchain[MojoToolchainInfo]

def _mojo_cmd(tc, args, runpath = None, source_root = None):
    return cmd_args(
        tc.busybox,
        "sh",
        tc.wrapper,
        tc.busybox,
        tc.compiler,
        tc.zig,
        tc.cc_target,
        ["--runpath=" + runpath] if runpath else [],
        [cmd_args(source_root, format = "--source-root={}")] if source_root else [],
        "--",
        args,
    )

def _dep_closure(ctx):
    return [d[MojoInfo].pkgs for d in ctx.attrs.deps]

def _package_root(ctx, srcs):
    """Package-relative directory holding the shallowest `__init__.mojo`."""
    inits = [s.short_path for s in srcs if s.basename == "__init__.mojo"]
    if not inits:
        fail("{}: mojo_library needs an __init__.mojo in srcs".format(ctx.label))
    shallowest = sorted(inits, key = lambda p: (p.count("/"), p))[0]
    return shallowest[:-len("__init__.mojo")].rstrip("/")

def _stage(ctx, name, srcs, root):
    mapping = {}
    for s in srcs:
        rel = s.short_path
        if root:
            if not rel.startswith(root + "/"):
                fail("{}: {} is outside the package root {}".format(ctx.label, rel, root))
            rel = rel[len(root) + 1:]
        mapping[rel] = s
    return ctx.actions.copied_dir(name, mapping)

def _stem(src):
    b = src.basename
    return b[:-len(".mojo")] if b.endswith(".mojo") else b

def _dirname(p):
    i = p.rfind("/")
    return p[:i] if i >= 0 else ""

def _join(d, f):
    return d + "/" + f if d else f

# The entry file of a program built as a shared library. The launcher calls
# `komira_main(argc, argv)`, which runs the program's `main` through the same
# standard-library function a Mojo executable's own `main` runs it through:
# it starts the runtime, records argv, installs the fault handler, reports an
# unhandled error the way an executable does (exit status 1), and destroys
# the runtime's globals.
_ENTRY = """from std.builtin._startup import __wrap_and_execute_raising_main
from {module} import main as _komira_program_main


@export
def komira_main(
    argc: Int32,
    argv: __mlir_type[`!kgen.pointer<!kgen.pointer<scalar<ui8>>>`],
) abi("C") -> Int32:
    return __wrap_and_execute_raising_main[_komira_program_main](argc, argv)
"""

def _build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier, shared = False):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets.

    With `shared`, emits a shared library instead: DT_SONAME is the output's
    file name and its one run path is `$ORIGIN/../..`, the bundle's lib/
    seen from lib/glibc-hwcaps/<level>/.
    """
    mapping = {s.short_path: s for s in srcs}
    entry = main.short_path
    if shared:
        # `mojo build --emit shared-lib` refuses a file defining `main`, so the
        # library is built from a generated entry file next to it, which
        # exports the C-ABI entry point `komira_main` (see _ENTRY).
        stem = _stem(main)
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", stem):
            fail("{}: {} is not importable as a Mojo module".format(ctx.label, main.short_path))
        entry = _join(_dirname(main.short_path), "_komira_entry.mojo")
        if entry in mapping:
            fail("{}: srcs may not contain {}".format(ctx.label, entry))
        mapping[entry] = ctx.actions.write(out_path + ".entry.mojo", _ENTRY.format(module = stem))
    staged = ctx.actions.copied_dir(out_path + ".src", mapping)
    exe = ctx.actions.declare_output(out_path)
    closure = ctx.actions.tset(MojoPkgTSet, children = closure_tsets)
    emit = []
    if shared:
        # The entry imports the program's main module from its own directory,
        # which the compiler does not search unless named with -I.
        entry_dir = _dirname(entry)
        emit = [
            "--emit",
            "shared-lib",
            "-Xlinker",
            "-soname",
            "-Xlinker",
            exe.basename,
            cmd_args(staged.project(entry_dir) if entry_dir else staged, format = "-I{}"),
        ]
    ctx.actions.run(
        _mojo_cmd(tc, [
            "build",
            emit,
            "--optimization-level",
            opt_level,
            "--target-cpu",
            tc.target_cpu,
            closure.project_as_args("include"),
            staged.project(entry),
            "-o",
            exe.as_output(),
        ], runpath = "$ORIGIN/../.." if shared else None, source_root = staged),
        category = category,
        identifier = identifier,
    )
    return exe

# ---- mojo_library ----------------------------------------------------------

def _check_import_name(ctx, name):
    # The `.mojoc` basename is the import name. A name that is not a Mojo
    # identifier (a dot, a dash) yields a package that cannot be imported and
    # no error, so refuse it here.
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: import name `{}` is not a Mojo identifier; set `import_name`".format(ctx.label, name))

def _library_impl(ctx):
    tc = _toolchain(ctx)
    import_name = ctx.attrs.import_name or ctx.label.name
    _check_import_name(ctx, import_name)
    root = _package_root(ctx, ctx.attrs.srcs)
    src_dir = _stage(ctx, "src/" + import_name, ctx.attrs.srcs, root)
    deps = _dep_closure(ctx)

    ungated = ctx.actions.declare_output("ungated/" + import_name + ".mojoc")
    dep_closure = ctx.actions.tset(MojoPkgTSet, children = deps)
    ctx.actions.run(
        _mojo_cmd(tc, [
            # No `--target-cpu`: `mojo precompile` rejects it ("unrecognized
            # argument"). A `.mojoc` holds no machine code; the CPU is fixed
            # where code is generated, in `mojo build`.
            "precompile",
            dep_closure.project_as_args("include"),
            src_dir,
            "-o",
            ungated.as_output(),
        ]),
        category = "mojo_precompile",
    )
    ungated_tset = ctx.actions.tset(MojoPkgTSet, value = ungated, children = deps)

    # The gate: one build + one run per test, against the UNGATED package.
    markers = []
    test_subtargets = {}
    for t in ctx.attrs.test_srcs:
        stem = _stem(t)
        if stem in test_subtargets:
            fail("{}: two test_srcs share the file name `{}`".format(ctx.label, t.basename))
        exe = _build_executable(
            ctx,
            tc,
            "tests/{}/{}".format(stem, stem),
            [t],
            t,
            [ungated_tset],
            ctx.attrs.test_optimization_level,
            "mojo_build_test",
            stem,
        )
        marker = ctx.actions.declare_output("tests/{}.passed".format(stem))
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "sh",
                tc.gate_runner,
                tc.busybox,
                tc.compiler,
                "{}:{}".format(ctx.label.raw_target(), t.short_path),
                exe,
                marker.as_output(),
            ),
            category = "mojo_gated_test",
            identifier = stem,
        )
        test_subtargets[stem] = [DefaultInfo(default_output = marker, other_outputs = [exe])]
        markers.append(marker)

    if markers:
        public = ctx.actions.declare_output("pkg/" + import_name + ".mojoc")
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "cp",
                ungated,
                public.as_output(),
                hidden = markers,
            ),
            category = "mojo_gate_join",
        )
    else:
        public = ungated

    return [
        DefaultInfo(
            default_output = public,
            sub_targets = {
                "src": [DefaultInfo(default_output = src_dir)],
                "tests": [DefaultInfo(default_outputs = markers, sub_targets = test_subtargets)],
                # Files only. It carries no MojoInfo, so `deps` rejects it:
                # the only way to compile against this library is through the
                # gated package. The tests above use the ungated package
                # in-rule, never through a label.
                "ungated": [DefaultInfo(default_output = ungated)],
            },
        ),
        MojoInfo(
            import_name = import_name,
            pkgs = ctx.actions.tset(MojoPkgTSet, value = public, children = deps),
        ),
    ]

_TOOLCHAIN_ATTR = {
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
}

mojo_library = rule(
    impl = _library_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [MojoInfo]), default = []),
        "import_name": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = "3"),
        "test_srcs": attrs.list(attrs.source(), default = []),
    } | _TOOLCHAIN_ATTR,
)

# ---- mojo_binary / mojo_test ----------------------------------------------

def _main_src(ctx):
    if ctx.attrs.main:
        return ctx.attrs.main
    if len(ctx.attrs.srcs) != 1:
        fail("{}: set `main` when srcs has more than one file".format(ctx.label))
    return ctx.attrs.srcs[0]

def _executable(ctx, category):
    tc = _toolchain(ctx)
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    exe = _build_executable(ctx, tc, ctx.label.name, srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, category, None)
    return tc, exe

def _runnable(ctx, tc, exe):
    """A directory holding the binary and lib/, the runtime libraries it loads.

    The binary's run path is `$ORIGIN/lib`, so it starts from this directory
    wherever the directory is, with no launcher and no environment. Copies,
    not links: the loader expands `$ORIGIN` from the binary's resolved path.
    Returns (directory, command running the binary).
    """
    name = exe.basename
    run_dir = ctx.actions.copied_dir(ctx.label.name + ".runnable", {
        "lib": tc.runtime,
        name: exe,
    })
    # The projection alone would fetch only the binary; the hidden directory
    # brings lib/ along. Nothing here names the compiler, so `buck2 run`
    # downloads the binary and its runtime libraries only.
    return run_dir, cmd_args(run_dir.project(name), hidden = run_dir)

def _run_check(ctx, tc, command, guard = []):
    # Runs the RunInfo command itself, in a remote action with no library
    # path, so a runnable directory that cannot start on its own fails here.
    # The action runs on this target's execution platform. `guard` is an
    # argv prefix that must let the run start (mojo_multi_numa_test).
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    args = guard + [tc.busybox, "sh", tc.run_check, tc.busybox, command, out.as_output()]
    if ctx.attrs.expected_stdout != None:
        args.append(ctx.actions.write(ctx.label.name + ".expected", ctx.attrs.expected_stdout))
    ctx.actions.run(cmd_args(args), category = "mojo_run_check")
    return out

def _shared(ctx, tc):
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    return _build_executable(ctx, tc, "shared/lib{}.so".format(ctx.label.name), srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, "mojo_build_shared", None, shared = True)

def _binary_impl(ctx):
    tc, exe = _executable(ctx, "mojo_build")
    run_dir, command = _runnable(ctx, tc, exe)
    shared = _shared(ctx, tc)
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {
                "shared": [DefaultInfo(default_output = shared)],
                "run_check": [DefaultInfo(default_output = _run_check(ctx, tc, command))],
                "runnable": [DefaultInfo(default_output = run_dir), RunInfo(args = command)],
            },
        ),
        RunInfo(args = command),
        MojoRunnableInfo(binary = exe.basename, command = command, run_dir = run_dir),
        MojoProgramInfo(name = ctx.label.name, shared = shared, runtime = tc.runtime, target_cpu = tc.target_cpu),
    ]

_EXECUTABLE_ATTRS = {
    "deps": attrs.list(attrs.dep(providers = [MojoInfo]), default = []),
    "main": attrs.option(attrs.source(), default = None),
    "optimization_level": attrs.string(default = "3"),
    "srcs": attrs.list(attrs.source()),
} | _TOOLCHAIN_ATTR

mojo_binary = rule(
    impl = _binary_impl,
    attrs = _EXECUTABLE_ATTRS | {
        # When set, `[run_check]` fails unless the binary's stdout equals this.
        "expected_stdout": attrs.option(attrs.string(), default = None),
    },
)

def _test_impl(ctx):
    tc, exe = _executable(ctx, "mojo_build_test")
    command = cmd_args(
        tc.busybox,
        "sh",
        tc.gate_runner,
        tc.busybox,
        tc.compiler,
        str(ctx.label.raw_target()),
        exe,
        "/dev/null",
    )
    run_dir, run_command = _runnable(ctx, tc, exe)
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {"runnable": [DefaultInfo(default_output = run_dir), RunInfo(args = run_command)]},
        ),
        # `buck2 run` of a test runs its binary directly, from the runnable
        # directory; `buck2 test` runs it through the gate runner on RE.
        RunInfo(args = run_command),
        MojoRunnableInfo(binary = exe.basename, command = run_command, run_dir = run_dir),
        ExternalRunnerTestInfo(
            type = "mojo",
            command = [command],
            labels = ctx.attrs.labels,
        ),
    ]

mojo_test = rule(
    impl = _test_impl,
    attrs = _EXECUTABLE_ATTRS | {
        "labels": attrs.list(attrs.string(), default = []),
    },
)

# ---- mojo_multi_numa_test ---------------------------------------------------
#
# Buck2 picks one execution platform per TARGET, so every action of a target
# (its compile, its gated tests, its run check) runs on the same kind of
# worker. A run that needs a worker spanning more than one NUMA node is
# therefore its own target: `binary` (a mojo_binary or mojo_test) is compiled
# by its own target on the default single-NUMA platform, and this target only
# RUNS it, on a platform providing `komira//tools/build/platforms:numa_multi`.
#
# Two refusals, because the constraint alone is only a claim:
#   - The toolchain is private and states `numa_multi`, so the requirement
#     cannot be dropped from a BUCK file. When no registered execution
#     platform provides `numa_multi`, the target fails to configure.
#   - Every run (the build's run check and the `buck2 test` command) starts
#     through numa_guard.sh, which exits 3 unless the action can use at least
#     `numa_nodes` NUMA nodes -- online, with memory, and allowed by its own
#     cpuset, affinity mask and memory binding. A platform whose property set
#     routes to a single-NUMA worker therefore goes red, not green.

def _multi_numa_test_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    runnable = ctx.attrs.binary[MojoRunnableInfo]
    if ctx.attrs.numa_nodes < 2:
        fail("mojo_multi_numa_test: numa_nodes must be at least 2, got {}".format(ctx.attrs.numa_nodes))
    guard = [tc.busybox, "sh", tc.numa_guard, tc.busybox, str(ctx.attrs.numa_nodes), "--"]
    # Building the target runs the binary (a build action on the multi-NUMA
    # platform): it must start with no library path, exit 0, and print
    # `expected_stdout` when that is set.
    stdout = _run_check(ctx, tc, runnable.command, guard)
    test_command = cmd_args(
        guard,
        tc.busybox,
        "sh",
        tc.gate_runner,
        tc.busybox,
        # gate_runner puts <dir>/lib on the library path; the runnable
        # directory holds lib/, so the compiler is not an input of the run.
        runnable.run_dir,
        str(ctx.label.raw_target()),
        runnable.run_dir.project(runnable.binary),
        "/dev/null",
    )
    return [
        DefaultInfo(default_output = stdout),
        RunInfo(args = runnable.command),
        ExternalRunnerTestInfo(
            type = "mojo",
            command = [test_command],
            labels = ctx.attrs.labels,
        ),
    ]

mojo_multi_numa_test = rule(
    impl = _multi_numa_test_impl,
    attrs = {
        "binary": attrs.dep(providers = [MojoRunnableInfo]),
        # When set, building this target fails unless the run's stdout equals it.
        "expected_stdout": attrs.option(attrs.string(), default = None),
        "labels": attrs.list(attrs.string(), default = []),
        # The run refuses to start on a worker where it can use fewer nodes.
        "numa_nodes": attrs.int(default = 2),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo_multi_numa", providers = [MojoToolchainInfo]),
    },
)
