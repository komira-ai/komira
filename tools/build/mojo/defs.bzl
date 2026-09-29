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

load("@prelude//linking:link_info.bzl", "LinkStrategy", "MergedLinkInfo", "create_merged_link_info_for_propagation")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoProgramInfo", "MojoRunnableInfo", "MojoToolchainInfo")

def _toolchain(ctx):
    return ctx.attrs.toolchain[MojoToolchainInfo]

def _watchdog_flags(tc):
    # The compile watchdog's knobs, for a wrapper that has one (the toolchain
    # sets them; see mojo_toolchain's watchdog_idle_secs).
    if tc.watchdog_idle_secs == None:
        return []
    if tc.watchdog_idle_secs < 0 or tc.watchdog_sample_secs < 1:
        fail("mojo toolchain: watchdog_idle_secs must be >= 0 and watchdog_sample_secs >= 1")
    return [
        "--watchdog-idle-secs={}".format(tc.watchdog_idle_secs),
        "--watchdog-sample-secs={}".format(tc.watchdog_sample_secs),
    ]

def _mojo_cmd(tc, args, runpath = None, source_root = None, link_tail = None):
    return cmd_args(
        tc.busybox,
        "sh",
        tc.wrapper,
        tc.busybox,
        tc.compiler,
        tc.link,
        tc.cc_target,
        ["--runpath=" + runpath] if runpath else [],
        [cmd_args(source_root, format = "--source-root={}")] if source_root else [],
        # Appended by the wrapper's `cc` shim to the END of the link line, after
        # the compiler's own objects and archive (see mojo_wrapper.sh).
        [cmd_args(link_tail, format = "--link-tail={}")] if link_tail else [],
        _watchdog_flags(tc),
        "--",
        args,
    )

# `deps` takes two kinds of target, told apart by provider:
#   MojoInfo        a Mojo package (mojo_library): its closure goes on `-I`.
#   MergedLinkInfo  a C/C++ library (the prelude's cxx_library, or anything
#                   else providing it): linked, statically and PIC, into every
#                   executable built with this target in its closure.
# Anything else is refused.
def _check_deps(ctx):
    for d in ctx.attrs.deps:
        if MojoInfo not in d and MergedLinkInfo not in d:
            fail("{}: dep {} provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)".format(ctx.label, d.label))

def _dep_closure(ctx):
    return [d[MojoInfo].pkgs for d in ctx.attrs.deps if MojoInfo in d]

def _c_link(ctx):
    """MergedLinkInfo of every C/C++ library this target's code may call, or None."""
    infos = []
    for d in ctx.attrs.deps:
        if MojoInfo in d:
            if d[MojoInfo].c_link != None:
                infos.append(d[MojoInfo].c_link)
        elif MergedLinkInfo in d:
            infos.append(d[MergedLinkInfo])
    if not infos:
        return None
    return create_merged_link_info_for_propagation(ctx, infos)

def _link_tail(c_link):
    """The link arguments of `c_link` in dependency order (dependents first)."""
    if c_link == None:
        return None

    # The prelude's own link steps read the per-strategy link infos the same
    # way (link_info.bzl, get_link_args_for_strategy).
    infos = c_link._infos.get(LinkStrategy("static_pic"))
    if infos == None:
        return None
    return infos.project_as_args("default", ordering = "preorder")

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

def _build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier, c_link, shared = False):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets, linking c_link.

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
        ], runpath = "$ORIGIN/../.." if shared else None, source_root = staged, link_tail = _link_tail(c_link)),
        category = category,
        identifier = identifier,
    )
    return exe

# ---- mojo_library ----------------------------------------------------------

# `tests_known_failing` -- a hold on a red test, which INVERTS rather than
# mutes. A held test still builds and runs as an action of the library's gate;
# its marker is produced only if it FAILS. So:
#   an unheld test that fails   -> the gate is red (GATED TEST FAILED)
#   a held test that fails      -> satisfied (marker `HELD <label>`)
#   a held test that passes     -> red (LEDGER STALE), naming its row: delete it
# A hold therefore silences nothing: the red is asserted on every build, and
# the fix is reported as a build failure until the row goes.
#
# A row is `{"issue": ..., "reason": ...}`. `issue` is the GitHub issue that
# will remove the hold (`123`, `#123` or its https://github.com/<o>/<r>/issues/
# URL); `reason` says why THIS test fails. Refused at analysis, before any
# action: a key that is not a `test_srcs` entry, another field, a missing or
# malformed issue, an empty reason, two rows with byte-identical reasons (one
# investigation pasted over a second test), and holding every test (a gate
# that asserts nothing passes).
_KNOWN_FAILING_FIELDS = ["issue", "reason"]
_ISSUE_REF = "^(#?[1-9][0-9]*|https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*)$"

def _test_key(ctx, t):
    """The package-relative path of test source `t`: its tests_known_failing key."""
    p = t.short_path
    pkg = ctx.label.package
    if pkg and p.startswith(pkg + "/"):
        p = p[len(pkg) + 1:]
    return p

def _admit_known_failing(ctx):
    held = ctx.attrs.tests_known_failing
    if not held:
        return {}
    keys = [_test_key(ctx, t) for t in ctx.attrs.test_srcs]
    where = "{}: tests_known_failing".format(ctx.label.raw_target())
    seen = {}
    for entry, row in held.items():
        if entry not in keys:
            fail("{}[{}]: not a test_srcs entry (entries: {}). A hold that matches no test reads as applied and is not; fix the path, or delete the row if the test is gone.".format(where, repr(entry), ", ".join(keys)))
        for field in row:
            if field not in _KNOWN_FAILING_FIELDS:
                fail("{}[{}]: unknown field `{}`; a row has exactly `issue` and `reason`.".format(where, repr(entry), field))
        issue = row.get("issue", "")
        reason = row.get("reason", "")
        if not issue:
            fail("{}[{}]: no `issue`. A hold is debt; name the GitHub issue that will remove it (`123`, `#123` or its URL).".format(where, repr(entry)))
        if not regex_match(_ISSUE_REF, issue):
            fail("{}[{}]: issue {} is not a GitHub issue number (`123`, `#123`) or https://github.com/<owner>/<repo>/issues/<n> URL.".format(where, repr(entry), repr(issue)))
        if not reason.strip():
            fail("{}[{}]: empty `reason`. Say what this test shows is broken; a reader deciding whether the hold is still honest has nothing else to go on.".format(where, repr(entry)))
        if reason in seen:
            fail("{}[{}] and [{}] carry byte-identical reasons. If they share a cause, say what each test shows; otherwise the second test was never examined.".format(where, repr(seen[reason]), repr(entry)))
        seen[reason] = entry
    if len(held) >= len(keys):
        fail("{}: holds all {} tests. That gate asserts nothing passes; a library whose whole suite is red has a defect, not a debt.".format(where, len(keys)))
    return held

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
    _check_deps(ctx)
    deps = _dep_closure(ctx)
    c_link = _c_link(ctx)

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

    held = _admit_known_failing(ctx)

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
            c_link,
        )
        marker = ctx.actions.declare_output("tests/{}.passed".format(stem))
        key = _test_key(ctx, t)
        hold = [key, held[key]["issue"], held[key]["reason"]] if key in held else []
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
                hold,
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
            c_link = c_link,
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
        # Mojo packages and C/C++ libraries; see _check_deps.
        "deps": attrs.list(attrs.dep(), default = []),
        "import_name": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = "3"),
        "test_srcs": attrs.list(attrs.source(), default = []),
        # {test_srcs path: {"issue": ..., "reason": ...}}; see _admit_known_failing.
        "tests_known_failing": attrs.dict(attrs.string(), attrs.dict(attrs.string(), attrs.string()), default = {}),
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
    _check_deps(ctx)
    exe = _build_executable(ctx, tc, ctx.label.name, srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, category, None, _c_link(ctx))
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
    return _build_executable(ctx, tc, "shared/lib{}.so".format(ctx.label.name), srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, "mojo_build_shared", None, _c_link(ctx), shared = True)

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
    # Mojo packages and C/C++ libraries; see _check_deps.
    "deps": attrs.list(attrs.dep(), default = []),
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
