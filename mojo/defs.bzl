"""Mojo rules for Buck2: mojo_library, mojo_binary, mojo_test.

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

load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoToolchainInfo")

def _toolchain(ctx):
    return ctx.attrs.toolchain[MojoToolchainInfo]

def _mojo_cmd(tc, args):
    return cmd_args(
        tc.busybox,
        "sh",
        tc.wrapper,
        tc.busybox,
        tc.compiler,
        tc.zig,
        tc.cc_target,
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

def _build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets."""
    staged = ctx.actions.copied_dir(out_path + ".src", {s.short_path: s for s in srcs})
    exe = ctx.actions.declare_output(out_path)
    closure = ctx.actions.tset(MojoPkgTSet, children = closure_tsets)
    ctx.actions.run(
        _mojo_cmd(tc, [
            "build",
            "--optimization-level",
            opt_level,
            "--target-cpu",
            tc.target_cpu,
            closure.project_as_args("include"),
            staged.project(main.short_path),
            "-o",
            exe.as_output(),
        ]),
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

def _run_check(ctx, tc, exe):
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    args = [tc.busybox, "sh", tc.run_check, _launch_args(tc, exe), out.as_output()]
    if ctx.attrs.expected_stdout != None:
        args.append(ctx.actions.write(ctx.label.name + ".expected", ctx.attrs.expected_stdout))
    ctx.actions.run(cmd_args(args), category = "mojo_run_check")
    return out

def _launch_args(tc, exe):
    # A linked binary carries no run path (the link step drops it, see
    # mojo_wrapper.sh), so it is started through `launch.sh`, which points
    # the loader at the toolchain's runtime libraries.
    #
    # The rules publish no RunInfo. A RunInfo carrying this command would make
    # every `buck2 build` of a binary materialize the whole compiler closure
    # on the client (buck2 builds and materializes RunInfo inputs by
    # default), and a bare executable cannot start outside an action. Run a
    # binary remotely with `[run_check]`, which uses this command.
    return cmd_args(tc.busybox, "sh", tc.launcher, tc.busybox, tc.compiler, exe)

def _binary_impl(ctx):
    tc, exe = _executable(ctx, "mojo_build")
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {"run_check": [DefaultInfo(default_output = _run_check(ctx, tc, exe))]},
        ),
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
    return [
        DefaultInfo(default_output = exe),
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
