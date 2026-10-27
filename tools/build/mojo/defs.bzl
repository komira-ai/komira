"""Mojo rules for Buck2: mojo_library, mojo_binary, mojo_test (and mojo_shared_lib, in shared_lib.bzl).

Every compile runs the hermetic toolchain from `toolchains//:mojo` through the
toolchain's compile wrapper (`mojo_compile_cmd`, compile.bzl; on Linux
tools/mojo_compile.zig, whose header states the environment the compiler sees).

Output layout of a library `L` with import name `I`:

    L/ungated/I.mojoc      the compiler's output (sub-target `[ungated]`: files
                           only, no MojoInfo, so it cannot be named in `deps`)
    L/pkg/I.mojoc          the public package: a copy of the ungated one that
                           takes every test's PASS marker as an input
    L/src/I/...            the staged package sources
    L[gen]                 with `gen`: that target's DefaultInfo, re-exported
                           whole, sub-targets included (for mojo_gcp_client: the
                           generated directory, `[gen][<file>]`, and the
                           staged `.proto` inputs `[gen][proto]`)
    L/tests/<t>/...        per test: its binary, its staged tree `root/`
                           (bin/<t> and share/, see _test_root) and its marker

Each `-I` directory given to the compiler holds exactly one `.mojoc`, so a
staged source directory can never shadow a package.
"""

load("@prelude//linking:link_info.bzl", "LinkStrategy", "MergedLinkInfo", "create_merged_link_info_for_propagation")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "mojo_pkg_children", "MojoProgramInfo", "MojoRunnableInfo", "MojoToolchainInfo", "welded_tests_info")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/package:conda.bzl", "conda_package")
load(":coverage.bzl", "COVERAGE_ATTRS", "COVERAGE_SHARED_LIB_ATTRS", "COVERAGE_TEST_ATTRS", "coverage_gate", "coverage_kwargs", "coverage_link_dir", "coverage_readme", "coverage_run", "coverage_branch_of", "coverage_shared_lib", "coverage_shared_lib_macro", "coverage_sub_targets", "coverage_test", "coverage_test_kwargs")
load(":test_deps.bzl", "check_test_deps", "test_c_link", "test_closure")
load(":mutation.bzl", "MUTATION_ATTRS", "mutation_kwargs", "mutation_sub_targets")
load(":test_runtime.bzl", _arg_args = "arg_args", _data_map = "data_map", _env_args = "env_args", _test_root = "test_root", gate_mojo = "gate_mojo")
load(":defines.bzl", "BINARY_DEFINE_ATTRS", "LIBRARY_DEFINE_ATTRS", "TEST_DEFINE_ATTRS", "cap_flags", "define_args", "memory_cap")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load(":native_facts.bzl", "NATIVE_ATTRS", "native_facts", "native_refusal")
load(":native_reach.bzl", "NATIVE_REACH_ATTRS", "native_reach", "native_reach_kwargs")
load(":opt_level.bzl", "MojoOptLevelInfo", "SHIPPED_OPT_LEVEL", "TEST_OPT_LEVEL", "opt_level_args")
load(":dlopen.bzl", "DLOPEN_ATTRS", "dlopen_refusal", "dlopen_rows")
load(":helpers.bzl", "HELPER_ATTRS", "helper_files")
load(":readme.bzl", "readme_gate", "readme_kwargs")
load(":run_check.bzl", "run_check_validation")
load(":test_limit.bzl", "HANG_LIMIT_ATTRS", "TEST_LIMIT_ATTRS", "deadline_flags", "hang_limit_flags", "with_test_limit")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load(":compile.bzl", _TOOLCHAIN_ATTR = "toolchain_attr", _build_executable = "build_executable", _c_link = "c_link", _check_deps = "check_deps", _dep_closure = "dep_closure", _dirname = "dirname", _join = "join", _link_tail = "link_tail", _main_src = "main_src", _stem = "stem", _toolchain = "toolchain", _mojo_compile_cmd = "mojo_compile_cmd", _mojo_precompile_cmd = "mojo_precompile_cmd")
load(":shared_lib.bzl", _mojo_shared_lib_rule = "mojo_shared_lib_rule")

# Re-exported: other files and BUCK files load these names from here.
mojo_compile_cmd = _mojo_compile_cmd
mojo_precompile_cmd = _mojo_precompile_cmd
mojo_shared_lib_rule = _mojo_shared_lib_rule

def _check_closure_excludes(ctx, dep_closure):
    """Fail analysis when a package `closure_excludes` names is in the closure of `deps`.

    A closure holds one `<import name>.mojoc` per package, so the file name is
    the package's import name. Direct and transitive dependencies are refused
    alike: the closure is what a consumer of this library compiles and links.
    """
    if not ctx.attrs.closure_excludes:
        return
    refused = {n + ".mojoc": n for n in ctx.attrs.closure_excludes}
    for pkg in dep_closure.traverse():
        if pkg.basename in refused:
            fail("{}: `{}` is in the closure of `deps`, which `closure_excludes` refuses; remove the dependency that brings it".format(ctx.label.raw_target(), refused[pkg.basename]))

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

# ---- mojo_library ----------------------------------------------------------

def _test_key(ctx, t):
    """The package-relative path of test source `t`: its test_data key."""
    p = t.short_path
    pkg = ctx.label.package
    if pkg and p.startswith(pkg + "/"):
        p = p[len(pkg) + 1:]
    return p

# The test runtime contract (the staged tree a test runs from, its data,
# environment and arguments) is in test_runtime.bzl.

def _admit_test_data(ctx):
    """{test_srcs key: {dest: artifact}} for mojo_library's `test_data`."""
    keys = [_test_key(ctx, t) for t in ctx.attrs.test_srcs]
    where = "{}: test_data".format(ctx.label.raw_target())
    out = {}
    for entry, data in ctx.attrs.test_data.items():
        if entry not in keys:
            fail("{}[{}]: not a test_srcs entry (entries: {}). Data keyed to no test is staged for nothing.".format(where, repr(entry), ", ".join(keys)))
        out[entry] = _data_map(ctx, "{}[{}]".format(where, repr(entry)), data)
    return out

def _check_import_name(ctx, name):
    # The `.mojoc` basename is the import name. A name that is not a Mojo
    # identifier (a dot, a dash) yields a package that cannot be imported and
    # no error, so refuse it here.
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        fail("{}: import name `{}` is not a Mojo identifier; set `import_name`".format(ctx.label, name))

def _conda_facts(ctx, import_name, c_link, has_tests, native):
    """(conda name, refusal) of this library's conda package.

    The name is None when the library opted out. The refusal is None when the
    package can be built, else the reason it cannot: a reason known without
    reading a source (native code, a `dlopen` system_libs.bzl lacks, no tests, a
    dependency with no package, a name that is not a conda name). The package target still builds, as a directory
    holding the reason (tools/build/package/conda.bzl).
    """
    if not ctx.attrs.conda:
        return None, None
    name = ctx.attrs.conda_name or import_name
    if not regex_match("^[a-z][a-z0-9_]*$", name):
        return name, "`{}` is not a conda name (a lowercase letter, then lowercase letters, digits and _); set `conda_name`".format(name)
    native_why = native_refusal(ctx.label, native) if c_link != None else None
    if native_why != None:
        return name, native_why
    if dlopen_refusal(ctx) != None:
        return name, dlopen_refusal(ctx)
    if not has_tests:
        return name, "{} has no tests, so its package would not be gated by any; declare test_srcs on the library".format(ctx.label.raw_target())
    for d in ctx.attrs.deps:
        if MojoInfo in d:
            di = d[MojoInfo]
            if di.conda_name == None:
                return name, "it depends on {}, which has no conda package (`conda = False`, or it is not a mojo_library)".format(d.label.raw_target())
            if di.conda_refusal != None:
                return name, "it depends on {}, which has no conda package: {}".format(d.label.raw_target(), di.conda_refusal)
    return name, None

def _library_impl(ctx):
    tc = _toolchain(ctx)
    import_name = ctx.attrs.import_name or ctx.label.name
    _check_import_name(ctx, import_name)
    root = _package_root(ctx, ctx.attrs.srcs)
    src_dir = _stage(ctx, "src/" + import_name, ctx.attrs.srcs, root)
    _check_deps(ctx)
    deps = _dep_closure(ctx)
    c_link = _c_link(ctx)
    native = native_facts(ctx, import_name)  # native_facts.bzl

    ungated = ctx.actions.declare_output("ungated/" + import_name + ".mojoc")
    dep_closure = ctx.actions.tset(MojoPkgTSet, children = deps)
    _check_closure_excludes(ctx, dep_closure)

    # The first gate of a generated library (tools/build/gen/defs.bzl): the
    # committed sources are what the generator writes now. A hidden input of
    # the compile, so nothing is compiled, no test is built, and no package
    # exists while it is red.
    first = [ctx.attrs.fresh_gate[DefaultInfo].default_outputs[0]] if ctx.attrs.fresh_gate else []
    ctx.actions.run(
        cmd_args(mojo_precompile_cmd(tc, dep_closure.project_as_args("include"), src_dir, ungated.as_output()), hidden = first),
        category = "mojo_precompile",
    )
    ungated_tset = ctx.actions.tset(MojoPkgTSet, value = ungated, children = deps)
    check_test_deps(ctx)
    tests_closure = test_closure(ctx, ungated_tset)
    tests_c_link = test_c_link(ctx, c_link)

    test_data = _admit_test_data(ctx)
    env_args = _env_args("{}: test_env".format(ctx.label.raw_target()), ctx.attrs.test_env)
    where = str(ctx.label.raw_target())
    test_defines = define_args(where, "test_assert_level", ctx.attrs.test_assert_level, "test_defines", ctx.attrs.test_defines)
    cap = memory_cap(where, "test_memory_cap_mib", ctx.attrs.test_memory_cap_mib, ctx.attrs.test_assert_level)
    hang = hang_limit_flags(where, ctx.attrs.test_hang_limit_s)

    # The gate: one build + one run per test, against the UNGATED package.
    markers = []
    test_subtargets = {}
    levels = {}
    # A coverage build (coverage.bzl): per test, written or generated, a
    # second binary at -O0 with line tables and its run under kcov, under
    # cov/. None when coverage is off.
    cov_link = coverage_link_dir(ctx)
    cov_bins, cov_runs, cov_branch = {}, {}, {}  # cov_branch: coverage_branch.bzl
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
            tests_closure,
            ctx.attrs.test_optimization_level,
            "mojo_build_test",
            stem,
            tests_c_link,
            defines = test_defines,
            levels = levels,
        )
        marker = ctx.actions.declare_output("tests/{}.passed".format(stem))
        key = _test_key(ctx, t)
        test_dir, staged = _test_root(ctx, "tests/{}/root".format(stem), exe, test_data.get(key, {}))
        ctx.actions.run(
            cmd_args(
                gate_mojo(tc, "{}:{}".format(ctx.label.raw_target(), t.short_path), staged, marker.as_output(), cap_flags(cap) + hang, env_args),
                hidden = test_dir,
            ),
            env = rerun_env(ctx),
            category = "mojo_gated_test",
            identifier = stem,
        )
        test_subtargets[stem] = [DefaultInfo(default_output = marker, other_outputs = [test_dir])]
        markers.append(marker)
        if cov_link:
            cov_bins[stem] = _build_executable(ctx, tc, "cov/tests/{}/{}".format(stem, stem), [t], t, tests_closure, "0", "mojo_build_cov_test", stem, tests_c_link, debug_link = cov_link, defines = test_defines)
            cov_runs[stem] = coverage_run(ctx, tc, t, stem, cov_bins[stem], src_dir, import_name, root, test_data.get(key, {}), env_args)
            cov_branch.update(coverage_branch_of(ctx, tc, t, stem, tests_closure, mojo_compile_cmd, _link_tail(tests_c_link), test_data.get(key, {}), env_args, src_dir, root, test_defines))

    # Whether the conda package is gated by a test: the test_srcs only. A
    # README's examples are not counted, since analysis cannot tell whether
    # it holds any (see readme.bzl, readme_gate).
    has_tests = len(markers) > 0
    conda_name, conda_refusal = _conda_facts(ctx, import_name, c_link, has_tests, native)

    # A README that ships (the library has a conda package the build can make,
    # which installs it at share/doc/<conda name>/README.md) refuses relative
    # links: the installed copy has no neighbours.
    ships = conda_name != None and conda_refusal == None
    readme_marker = readme_gate(ctx, tc, import_name, ungated_tset, _link_tail(c_link), env_args, ships, _readme_test, owner = bool(native.c_direct), rerun = rerun_env(ctx))
    if readme_marker != None:
        if "readme" in test_subtargets:
            fail("{}: a test_srcs file is named `readme.mojo`; `[tests][readme]` is the README's examples".format(ctx.label))
        # [generated] and [file]: the programs and README.md the gate ran, for kci_validate's golden test;
        # [objects]: an owner's README programs as objects, for its shared library's README check (shared.bzl).
        test_subtargets["readme"] = [DefaultInfo(default_output = readme_marker[0], other_outputs = [readme_marker[1]], sub_targets = {"file": [DefaultInfo(default_output = ctx.attrs.readme)], "generated": [DefaultInfo(default_output = readme_marker[1])], "objects": [DefaultInfo(default_output = readme_marker[3])]})]
        markers.append(readme_marker[0])
        if cov_link:
            coverage_readme(ctx, tc, _build_executable, readme_marker, ungated_tset, _link_tail(c_link), src_dir, import_name, root, env_args, cov_bins, cov_runs)

    # With coverage on, the README's run (above) and the gate (coverage.bzl);
    # only the conda package waits for them and the runs, never this package.
    cov_gate, cov_providers = coverage_gate(ctx, tc, cov_runs, cov_branch, src_dir, import_name, root) if cov_link else (None, [])
    reach = native_reach(ctx, src_dir, deps)  # native_reach.bzl: (providers, sub-targets)
    mutation = mutation_sub_targets(ctx, tc, mojo_compile_cmd, src_dir, root, deps, tests_closure[1:], _link_tail(tests_c_link), test_data, env_args, test_defines, cap)  # mutation.bzl
    if markers or first:
        public = ctx.actions.declare_output("pkg/" + import_name + ".mojoc")
        ctx.actions.run(
            cmd_args(
                tc.act,
                "copy",
                ungated,
                public.as_output(),
                hidden = first + markers,
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
            } | ({"gen": [ctx.attrs.gen[DefaultInfo]]} if ctx.attrs.gen else {}) | (coverage_sub_targets(cov_bins, cov_runs, cov_gate, cov_branch) if cov_link else {}) | mutation | reach[1],
        ),
        MojoInfo(
            c_link = c_link,
            conda_name = conda_name,
            conda_refusal = conda_refusal,
            dlopen = dlopen_rows(ctx),
            direct = sorted([d[MojoInfo].import_name for d in ctx.attrs.deps if MojoInfo in d]),
            direct_conda = {
                d[MojoInfo].import_name: struct(name = d[MojoInfo].conda_name, refusal = d[MojoInfo].conda_refusal)
                for d in ctx.attrs.deps
                if MojoInfo in d
            },
            import_name = import_name,
            native = native,
            pkgs = ctx.actions.tset(MojoPkgTSet, value = public, children = deps),
            pkgs_def = MojoPkgTSet,
            readme = ctx.attrs.readme,
        ),
        welded_tests_info(ctx.attrs.test_srcs),
        MojoOptLevelInfo(levels = levels),
        rerun_info(ctx),
    ] + cov_providers + reach[0]

# ---- README examples ----------------------------------------------------------
#
# readme.bzl's readme_gate declares the README's `generate` action and this
# dynamic action, which compiles and runs each example (the convention and
# the gate are described there).

def _readme_test_impl(actions, label, gate_label, examples, package, src, marker, objects, owner, tc, closure, opt_level, link_tail, env_args, rerun, hang_flags):
    lines = [x.strip() for x in examples.read_string().split("\n") if x.strip()]
    if not lines:
        actions.write(marker, "NO EXAMPLE {}: no ```mojo example, so nothing was compiled or run\n".format(gate_label))
        actions.copied_dir(objects, {})
        return []
    shim = struct(actions = actions, label = label)
    markers = []
    built = {}
    for line in lines:
        stem = "readme_{}_{}".format(package, line)
        program = src.project(stem + ".mojo")
        exe = _build_executable(shim, tc, "tests/readme/bin/" + stem, [program], program, [closure], opt_level, "mojo_build_test", "readme_" + line, None, link_extra = link_tail)
        if owner:
            built[stem + ".o"] = _build_executable(shim, tc, "tests/readme/obj/" + stem + ".o", [program], program, [closure], opt_level, "mojo_readme_object", "readme_" + line, None, emit_object = True)
        root, staged = _test_root(shim, "tests/readme/root/" + line, exe, {})
        m = actions.declare_output("tests/readme/{}.passed".format(line))
        actions.run(
            cmd_args(
                gate_mojo(tc, "{}:{}".format(gate_label, line), staged, m.as_output(), hang_flags, env_args),
                hidden = root,
            ),
            env = rerun,
            category = "mojo_gated_test",
            identifier = "readme_" + line,
        )
        markers.append(m)
    actions.run(
        cmd_args(tc.act, "cat", marker, markers),
        category = "mojo_readme_join",
    )
    actions.copied_dir(objects, built)
    return []

_readme_test = dynamic_actions(
    impl = _readme_test_impl,
    attrs = {
        "closure": dynattrs.value(typing.Any),
        "env_args": dynattrs.value(list[str]),
        "examples": dynattrs.artifact_value(),
        "gate_label": dynattrs.value(str),
        "hang_flags": dynattrs.value(list[str]),
        "label": dynattrs.value(Label),
        "link_tail": dynattrs.value(typing.Any),
        "marker": dynattrs.output(),
        "opt_level": dynattrs.value(str),
        "package": dynattrs.value(str),
        "rerun": dynattrs.value(dict[str, str]),
        "objects": dynattrs.output(),
        "owner": dynattrs.value(bool),
        "src": dynattrs.value(Artifact),
        "tc": dynattrs.value(typing.Any),
    },
)

mojo_library_rule = rule(
    impl = _library_impl,
    attrs = {
        # The library's conda package (tools/build/package/conda.bzl): the macro
        # declares `<name>_conda` unless `conda = False`; `conda_name` is the
        # published name when it is not the import name. Both are read here so
        # that a dependent's package can name this one by its published name.
        "conda": attrs.bool(default = True),
        "conda_name": attrs.option(attrs.string(), default = None),
        # Import names of packages that must not be in the closure of `deps`;
        # see _check_closure_excludes.
        "closure_excludes": attrs.list(attrs.string(), default = []),
        # Mojo packages and C/C++ libraries; see _check_deps.
        "deps": attrs.list(attrs.dep(), default = []),
        # Optional: the target that generated `srcs` (mojo_gcp_client, for example).
        # Its DefaultInfo is re-exported whole as the `[gen]` sub-target, so a
        # reader or an IDE finds the generated code (and what it was generated
        # from); nothing else reads it. Unchecked: nothing verifies that `srcs`
        # come from this target, which is acceptable for a reader-only view.
        "gen": attrs.option(attrs.dep(), default = None),
        # Optional: the freshness check of a library built from committed
        # generated sources (`<name>_fresh`, tools/build/gen/defs.bzl). Its
        # marker is the library's first gate: an input of the compile and of
        # the join that makes the public package.
        "fresh_gate": attrs.option(attrs.dep(), default = None),
        "import_name": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "test_srcs": attrs.list(attrs.source(), default = []),
        # Mojo packages the welded tests (test_srcs) are compiled against
        # besides the library and its deps; see test_deps.bzl.
        "test_deps": attrs.list(attrs.dep(), default = []),
        # {test_srcs path: data}, data as in mojo_test's `data`; see _admit_test_data.
        "test_data": attrs.dict(attrs.string(), attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source())), default = {}),
        # Environment for every gated test of this library.
        "test_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # The package's README.md and the tool that runs its examples; the
        # macro sets both, or neither (readme.bzl, readme_gate). No default tool: the tool is
        # itself built from a mojo_library, so a default would be a cycle.
        "readme": attrs.option(attrs.source(), default = None),
        "readme_tool": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
    } | COVERAGE_ATTRS | DLOPEN_ATTRS | MUTATION_ATTRS | NATIVE_ATTRS | NATIVE_REACH_ATTRS | LIBRARY_DEFINE_ATTRS | HANG_LIMIT_ATTRS | RERUN_ATTRS | _TOOLCHAIN_ATTR,
)

# ---- mojo_binary / mojo_test ----------------------------------------------

def _executable(ctx, category, levels):
    tc = _toolchain(ctx)
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    _check_deps(ctx)
    exe = _build_executable(ctx, tc, ctx.label.name, srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, category, None, _c_link(ctx), defines = _exe_defines(ctx), levels = levels)
    return tc, exe

def _exe_defines(ctx):
    return define_args(str(ctx.label.raw_target()), "assert_level", ctx.attrs.assert_level, "defines", ctx.attrs.defines)

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
    } | helper_files(ctx, name))  # a mojo_binary's `helpers`, beside it (helpers.bzl)
    # The projection alone would fetch only the binary; the hidden directory
    # brings lib/ along. Nothing here names the compiler, so `buck2 run`
    # downloads the binary and its runtime libraries only.
    return run_dir, cmd_args(run_dir.project(name), hidden = run_dir)

def _run_check(ctx, tc, command):
    # Runs the RunInfo command itself, in a remote action with no library
    # path, so a runnable directory that cannot start on its own fails here.
    # The action runs on this target's execution platform. With
    # `expected_stdout` it is also a validation of the binary (run_check.bzl).
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    args = [tc.act, "run-check", tc.busybox, command, out.as_output()]
    if ctx.attrs.expected_stdout == None:
        ctx.actions.run(cmd_args(args), env = rerun_env(ctx), category = "mojo_run_check")
        return out, []
    args.append(ctx.actions.write(ctx.label.name + ".expected", ctx.attrs.expected_stdout))
    ctx.actions.run(cmd_args(args), env = rerun_env(ctx), category = "mojo_run_check")
    return out, run_check_validation(ctx, out, ctx.attrs.expected_stdout)

def _shared(ctx, tc, levels):
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    return _build_executable(ctx, tc, "shared/lib{}.so".format(ctx.label.name), srcs, main, _dep_closure(ctx), ctx.attrs.optimization_level, "mojo_build_shared", None, _c_link(ctx), shared = True, defines = _exe_defines(ctx), levels = levels)

def _binary_impl(ctx):
    levels = {}
    tc, exe = _executable(ctx, "mojo_build", levels)
    run_dir, command = _runnable(ctx, tc, exe)
    shared = _shared(ctx, tc, levels)
    run_check, validation = _run_check(ctx, tc, command)
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {
                "shared": [DefaultInfo(default_output = shared)],
                "run_check": [DefaultInfo(default_output = run_check)],
                "runnable": [DefaultInfo(default_output = run_dir), RunInfo(args = command)],
            },
        ),
        RunInfo(args = command),
        MojoRunnableInfo(binary = exe.basename, command = command, run_dir = run_dir),
        MojoProgramInfo(name = ctx.label.name, shared = shared, runtime = tc.runtime, target_cpu = tc.target_cpu, helpers = helper_files(ctx, ctx.label.name)),
        MojoOptLevelInfo(levels = levels),
        rerun_info(ctx),
    ] + validation

_EXECUTABLE_ATTRS = {
    # Mojo packages and C/C++ libraries; see _check_deps.
    "deps": attrs.list(attrs.dep(), default = []),
    "main": attrs.option(attrs.source(), default = None),
    "srcs": attrs.list(attrs.source()),
} | RERUN_ATTRS | _TOOLCHAIN_ATTR

mojo_binary_rule = rule(
    impl = _binary_impl,
    attrs = _EXECUTABLE_ATTRS | BINARY_DEFINE_ATTRS | HELPER_ATTRS | {
        "optimization_level": attrs.string(default = SHIPPED_OPT_LEVEL),
        # When set, `[run_check]` fails unless the binary's stdout equals this;
        # it is then a validation, run by every build holding the binary.
        "expected_stdout": attrs.option(attrs.string(), default = None),
    },
)

def _test_impl(ctx):
    levels = {}
    tc, exe = _executable(ctx, "mojo_build_test", levels)
    where = str(ctx.label.raw_target())
    data = _data_map(ctx, where + ": data", ctx.attrs.data)
    env_args = _env_args(where + ": env", ctx.attrs.env)
    root, staged = _test_root(ctx, ctx.label.name + ".testroot", exe, data)
    cap = memory_cap(where, "memory_cap_mib", ctx.attrs.memory_cap_mib, ctx.attrs.assert_level)
    command = cmd_args(
        gate_mojo(
            tc,
            where,
            staged,
            "/dev/null",
            deadline_flags(ctx, where) + cap_flags(cap),
            [env_args, _arg_args(ctx.attrs.args)],
        ),
        hidden = root,
    )
    run_dir, run_command = _runnable(ctx, tc, exe)
    cov_sub, cov_info = coverage_test(ctx, tc, _build_executable, _main_src(ctx), _dep_closure(ctx), _c_link(ctx), _exe_defines(ctx), data, env_args)
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {
                "runnable": [DefaultInfo(default_output = run_dir), RunInfo(args = run_command)],
                "testroot": [DefaultInfo(default_output = root)],
            } | cov_sub,
        ),
        # `buck2 run` of a test runs its binary directly, from the runnable
        # directory; `buck2 test` runs it through the gate runner on RE.
        RunInfo(args = run_command),
        MojoRunnableInfo(binary = exe.basename, command = run_command, run_dir = run_dir),
        ExternalRunnerTestInfo(
            type = "mojo",
            command = [command],
            env = rerun_env(ctx),
            labels = ctx.attrs.labels,
        ),
        welded_tests_info([_main_src(ctx)]),
        MojoOptLevelInfo(levels = levels),
        rerun_info(ctx),
    ] + cov_info

mojo_test_rule = rule(
    impl = _test_impl,
    attrs = _EXECUTABLE_ATTRS | TEST_DEFINE_ATTRS | COVERAGE_TEST_ATTRS | TEST_LIMIT_ATTRS | {
        "optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        # Files staged under the test's share/, its current directory: a list
        # of sources (each at its path from the cell root) or {dest: source}.
        "data": attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source()), default = []),
        # Environment for the test; names the runner sets are refused.
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # The test's command-line arguments under `buck2 test`, in order, with
        # `$(location ...)` / `$(exe_target ...)` expanded to absolute paths
        # of artifacts that are inputs of the test (see _arg_args). Not given
        # to `buck2 run` or `[runnable]`.
        "args": attrs.list(attrs.arg(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def _mojo_library(**kwargs):
    # Refused by name, so a stale BUCK file says why rather than buck2's
    # generic "unexpected parameter".
    if "tests_known_failing" in kwargs:
        fail("{}: tests_known_failing was removed: every welded test must pass".format(kwargs.get("name", "mojo_library")))
    # Every library has a conda package target, `<name>_conda`, unless it opts
    # out with `conda = False`. Nothing is published by that: the release tool's
    # artifact declarations say which packages are (tools/build/package/conda.bzl).
    summary = kwargs.pop("conda_summary", None)
    # The package's README.md, unless `readme = False` (readme.bzl).
    readme_kwargs(kwargs)
    cov_gate = coverage_kwargs(kwargs)
    mutation_kwargs(kwargs)
    native_reach_kwargs(kwargs)
    mojo_library_rule(**kwargs)
    if kwargs.get("conda", True):
        name = kwargs["name"]
        conda_package(
            name = name + "_conda",
            lib = ":" + name,
            native = kwargs.get("native"),
            # A library of the coverage ledger: its gate, `<name>_cov_gate`.
            coverage_gate = cov_gate,
            summary = summary or "The `{}` Mojo library of komira, as a conda package.".format(kwargs.get("import_name") or name),
            visibility = ["PUBLIC"],
        )

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
adopt_readme_test, adopt_link_tail = _readme_test, _link_tail  # the README gate's action and the link arguments of a C closure, for adopt.bzl
mojo_binary = declares_docs(mojo_binary_rule)
mojo_library = declares_docs(_mojo_library)
mojo_shared_lib = declares_docs(coverage_shared_lib_macro(mojo_shared_lib_rule))
mojo_test = declares_docs(coverage_test_kwargs(with_test_limit(mojo_test_rule)))
