"""Mojo rules for Buck2: mojo_library, mojo_binary, mojo_test.

Every action runs the hermetic toolchain from `toolchains//:mojo` through
`mojo_wrapper.sh`; see that file for the environment the compiler sees.

Output layout of a library `L` with import name `I`:

    L/ungated/I.mojoc      the compiler's output (sub-target `[ungated]`: files
                           only, no MojoInfo, so it cannot be named in `deps`)
    L/pkg/I.mojoc          the public package: a copy of the ungated one that
                           takes every test's PASS marker as an input
    L/src/I/...            the staged package sources
    L[gen]                 with `gen`: that target's DefaultInfo, re-exported
                           whole, sub-targets included (for gcp_client: the
                           generated directory, `[gen][<file>]`, and the
                           staged `.proto` inputs `[gen][proto]`)
    L/tests/<t>/...        per test: its binary, its staged tree `root/`
                           (bin/<t> and share/, see _test_root) and its marker

Each `-I` directory given to the compiler holds exactly one `.mojoc`, so a
staged source directory can never shadow a package.
"""

load("@prelude//linking:link_info.bzl", "LinkStrategy", "MergedLinkInfo", "create_merged_link_info_for_propagation")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "MojoProgramInfo", "MojoRunnableInfo", "MojoToolchainInfo")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/package:conda.bzl", "conda_package")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

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

# `mojo build --optimization-level`. Tests compile at 1 and shipped code at 3:
# a test is built, run once and thrown away, so its compile time is most of
# its cost, while a binary or shared library runs in production. Each rule
# states its default below; `optimization_level` / `test_optimization_level`
# override it per target. The level is the compiling target's own: a test
# linking a shared library links that library as its own target built it.
_OPT_LEVELS = ["0", "1", "2", "3"]
TEST_OPT_LEVEL = "1"
SHIPPED_OPT_LEVEL = "3"

def _build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier, c_link, shared = False, abi_lib = False, link_extra = None):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets, linking c_link.

    With `shared`, emits a shared library instead: DT_SONAME is the output's
    file name and its one run path is `$ORIGIN/../..`, the bundle's lib/
    seen from lib/glibc-hwcaps/<level>/.

    With `abi_lib`, emits a shared library straight from `main`, a file of
    `@export` C-ABI functions: no generated entry and no `komira_main`.
    DT_SONAME is the output's file name (the caller names it, with no `lib`
    prefix forced) and the run path is the default `$ORIGIN/lib`.
    `link_extra` is appended to the link tail after the C libraries (the
    force-loaded archives of mojo_shared_lib).
    """
    if opt_level not in _OPT_LEVELS:
        fail("{}: optimization level `{}` is not one of {}".format(ctx.label, opt_level, ", ".join(_OPT_LEVELS)))
    mapping = {s.short_path: s for s in srcs}
    entry = main.short_path
    if shared and abi_lib:
        fail("{}: shared and abi_lib are exclusive".format(ctx.label))
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
    if abi_lib:
        # The library's name for the loader: ELF DT_SONAME, Mach-O install
        # name. On macOS an unnamed dylib records the -o path as given, which
        # is a build directory; `@rpath/<file>` is the same
        # no-directory name the soname is.
        emit = [
            "--emit",
            "shared-lib",
            "-Xlinker",
            "-install_name" if tc.os == "darwin" else "-soname",
            "-Xlinker",
            ("@rpath/" + exe.basename) if tc.os == "darwin" else exe.basename,
        ]
    tail = _link_tail(c_link)
    if link_extra:
        tail = cmd_args(tail, link_extra) if tail else cmd_args(link_extra)
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
        ], runpath = "$ORIGIN/../.." if shared else None, source_root = staged, link_tail = tail),
        category = category,
        identifier = identifier,
    )
    return exe

# ---- mojo_library ----------------------------------------------------------

def _test_key(ctx, t):
    """The package-relative path of test source `t`: its test_data key."""
    p = t.short_path
    pkg = ctx.label.package
    if pkg and p.startswith(pkg + "/"):
        p = p[len(pkg) + 1:]
    return p

# ---- the test runtime contract ------------------------------------------
#
# A test runs from a staged tree built for it alone:
#
#     root/bin/<test>        the test binary (a copy, so /proc/self/exe is here)
#     root/share/<dest>      each declared data file
#
# gate_runner.sh starts the test with root/share as its current directory, so
# a relative path to a declared file opens and any other relative path names
# nothing. komira//tools/build/mojo/runtime_paths finds root/share from the
# executable, the same way a bundle finds its share/.

# Names the runner sets itself; a test may not override them through env.
_RUNNER_ENV = ["PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "TMPDIR", "TEST_TMPDIR", "HOME", "PWD"]

def _data_map(ctx, where, data):
    """{dest: artifact} for a `data` value: a list of sources (each staged at
    its path from the cell root) or a dict {dest: source}."""
    if type(data) == type([]):
        out = {}
        pkg = ctx.label.package
        for a in data:
            if not a.is_source:
                fail("{}: {} is a build output; a list entry is staged at its source path, so name a build output in the dict form, {{dest: source}}".format(where, a))
            # A source's short_path is relative to its package.
            out[pkg + "/" + a.short_path if pkg else a.short_path] = a
    else:
        out = dict(data)
    prefixes = {}
    for dest in out:
        if dest == "" or dest.startswith("/") or dest.endswith("/"):
            fail("{}: data destination {} must be a relative file path".format(where, repr(dest)))
        parts = dest.split("/")
        for part in parts:
            if part in ("", ".", ".."):
                fail("{}: data destination {} holds an empty, `.` or `..` segment".format(where, repr(dest)))
        for i in range(1, len(parts)):
            prefixes["/".join(parts[:i])] = dest
    for dest in out:
        if dest in prefixes:
            fail("{}: data destination {} is both a file and the directory of {}".format(where, repr(dest), repr(prefixes[dest])))
    return out

def _env_args(where, env):
    """`--env NAME=VALUE` runner arguments, after refusing names the runner owns."""
    args = []
    for name in sorted(env.keys()):
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            fail("{}: env name {} is not a shell variable name".format(where, repr(name)))
        if name in _RUNNER_ENV:
            fail("{}: env sets {}, which the test runner sets itself (runner-owned: {})".format(where, name, ", ".join(_RUNNER_ENV)))
        args += ["--env", "{}={}".format(name, env[name])]
    return args

def _test_root(ctx, path, exe, data):
    """The staged tree of one test; returns (root, binary inside it)."""
    name = exe.basename
    files = {"bin/" + name: exe}
    for dest, a in data.items():
        files["share/" + dest] = a
    root = ctx.actions.copied_dir(path, files)
    return root, root.project("bin/" + name)

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

def _conda_facts(ctx, import_name, c_link, has_tests):
    """(conda name, refusal) of this library's conda package.

    The name is None when the library opted out. The refusal is None when the
    package can be built, else the reason it cannot: a reason known without
    reading a source (native code, no tests, a dependency with no package, a name
    that is not a conda name). The package target still builds, as a directory
    holding the reason (tools/build/package/conda.bzl).
    """
    if not ctx.attrs.conda:
        return None, None
    name = ctx.attrs.conda_name or import_name
    if not regex_match("^[a-z][a-z0-9_]*$", name):
        return name, "`{}` is not a conda name (a lowercase letter, then lowercase letters, digits and _); set `conda_name`".format(name)
    if c_link != None:
        return name, "{} links native code. A `.mojoc` holds none, so a consumer would fail at its own link; no conda package for it until native code is supported".format(ctx.label.raw_target())
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

    test_data = _admit_test_data(ctx)
    env_args = _env_args("{}: test_env".format(ctx.label.raw_target()), ctx.attrs.test_env)

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
        root, staged = _test_root(ctx, "tests/{}/root".format(stem), exe, test_data.get(key, {}))
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "sh",
                tc.gate_runner,
                tc.busybox,
                tc.compiler,
                "{}:{}".format(ctx.label.raw_target(), t.short_path),
                staged,
                marker.as_output(),
                env_args,
                hidden = root,
            ),
            category = "mojo_gated_test",
            identifier = stem,
        )
        test_subtargets[stem] = [DefaultInfo(default_output = marker, other_outputs = [root])]
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

    conda_name, conda_refusal = _conda_facts(ctx, import_name, c_link, len(markers) > 0)
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
            } | ({"gen": [ctx.attrs.gen[DefaultInfo]]} if ctx.attrs.gen else {}),
        ),
        MojoInfo(
            c_link = c_link,
            conda_name = conda_name,
            conda_refusal = conda_refusal,
            direct = sorted([d[MojoInfo].import_name for d in ctx.attrs.deps if MojoInfo in d]),
            direct_conda = {
                d[MojoInfo].import_name: struct(name = d[MojoInfo].conda_name, refusal = d[MojoInfo].conda_refusal)
                for d in ctx.attrs.deps
                if MojoInfo in d
            },
            import_name = import_name,
            pkgs = ctx.actions.tset(MojoPkgTSet, value = public, children = deps),
        ),
    ]

_TOOLCHAIN_ATTR = {
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
}

mojo_library_rule = rule(
    impl = _library_impl,
    attrs = {
        # The library's conda package (tools/build/package/conda.bzl): the macro
        # declares `<name>_conda` unless `conda = False`; `conda_name` is the
        # published name when it is not the import name. Both are read here so
        # that a dependent's package can name this one by its published name.
        "conda": attrs.bool(default = True),
        "conda_name": attrs.option(attrs.string(), default = None),
        # Mojo packages and C/C++ libraries; see _check_deps.
        "deps": attrs.list(attrs.dep(), default = []),
        # Optional: the target that generated `srcs` (gcp_client, for example).
        # Its DefaultInfo is re-exported whole as the `[gen]` sub-target, so a
        # reader or an IDE finds the generated code (and what it was generated
        # from); nothing else reads it. Unchecked: nothing verifies that `srcs`
        # come from this target, which is acceptable for a reader-only view.
        "gen": attrs.option(attrs.dep(), default = None),
        "import_name": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
        "test_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "test_srcs": attrs.list(attrs.source(), default = []),
        # {test_srcs path: data}, data as in mojo_test's `data`; see _admit_test_data.
        "test_data": attrs.dict(attrs.string(), attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source())), default = {}),
        # Environment for every gated test of this library.
        "test_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
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

def _run_check(ctx, tc, command):
    # Runs the RunInfo command itself, in a remote action with no library
    # path, so a runnable directory that cannot start on its own fails here.
    # The action runs on this target's execution platform.
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    args = [tc.busybox, "sh", tc.run_check, tc.busybox, command, out.as_output()]
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
    "srcs": attrs.list(attrs.source()),
} | _TOOLCHAIN_ATTR

mojo_binary_rule = rule(
    impl = _binary_impl,
    attrs = _EXECUTABLE_ATTRS | {
        "optimization_level": attrs.string(default = SHIPPED_OPT_LEVEL),
        # When set, `[run_check]` fails unless the binary's stdout equals this.
        "expected_stdout": attrs.option(attrs.string(), default = None),
    },
)

def _test_impl(ctx):
    tc, exe = _executable(ctx, "mojo_build_test")
    where = str(ctx.label.raw_target())
    data = _data_map(ctx, where + ": data", ctx.attrs.data)
    env_args = _env_args(where + ": env", ctx.attrs.env)
    root, staged = _test_root(ctx, ctx.label.name + ".testroot", exe, data)
    command = cmd_args(
        tc.busybox,
        "sh",
        tc.gate_runner,
        tc.busybox,
        tc.compiler,
        where,
        staged,
        "/dev/null",
        env_args,
        hidden = root,
    )
    run_dir, run_command = _runnable(ctx, tc, exe)
    return [
        DefaultInfo(
            default_output = exe,
            sub_targets = {
                "runnable": [DefaultInfo(default_output = run_dir), RunInfo(args = run_command)],
                "testroot": [DefaultInfo(default_output = root)],
            },
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

mojo_test_rule = rule(
    impl = _test_impl,
    attrs = _EXECUTABLE_ATTRS | {
        "optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        # Files staged under the test's share/, its current directory: a list
        # of sources (each at its path from the cell root) or {dest: source}.
        "data": attrs.one_of(attrs.list(attrs.source()), attrs.dict(attrs.string(), attrs.source()), default = []),
        # Environment for the test; names the runner sets are refused.
        "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

# ---- mojo_shared_lib --------------------------------------------------------
#
# A C-ABI shared library: `mojo build --emit shared-lib` of one file of
# `@export` functions, over the closure of `deps`. Linux (`.so`) and macOS
# arm64 (`.dylib`); mojo_binary's `[shared]` and the bundles are Linux only,
# and the darwin wrapper still refuses `--emit shared-lib` for them.
#
#   out_name       the file is `<out_name>.so` (Linux) or `<out_name>.dylib`
#                  (macOS), its DT_SONAME / install name `@rpath/<file>`: no
#                  `lib` prefix is forced (mojo_binary's `[shared]` forces
#                  one). Drivers open `./<out_name>.so` or `./<out_name>.dylib`
#                  by `CompilationTarget.is_macos()`.
#   exports        the symbols the library must export. The gate dlopens the
#                  library (RTLD_NOW, so an unresolved symbol fails there) and
#                  fails unless every one resolves.
#   exports_exact  default False. True links with a version script that makes
#                  `exports` the whole dynamic symbol table: nothing else is
#                  visible, so a symbol of a static C dependency does not
#                  leak into the ABI. The gate then also sees an @export the
#                  list omits as MISSING for any driver that calls it.
#   gate_srcs      linked-run drivers: Mojo mains that dlopen `./<out_name>.so`
#                  (the gate stages it as their one data file) and call it.
#   force_load     C/C++ libraries linked whole (--whole-archive): every object
#                  of their archives is in the library, referenced or not.
#
# The published file is `<name>/<out_name>.so`: a copy of `ungated/<out_name>.so`
# that takes the PASS marker of every gate run as an input, so it cannot exist
# unless the exports check and every driver passed. The same pattern as
# mojo_library's tests.

_EXPORTS_DRIVER = """from std.ffi import OwnedDLHandle


def main() raises:
    # RTLD_NOW (the default flags): an unresolved symbol fails here, not at
    # the first call.
    var lib = OwnedDLHandle("./{so}")
    var missing = 0
{checks}
    if missing != 0:
        raise Error("{so}: " + String(missing) + " expected export(s) missing")
"""

_EXPORT_CHECK = """    if not lib.check_symbol("{sym}"):
        print("MISSING EXPORT: {sym}")
        missing += 1
"""

def _shared_lib_impl(ctx):
    tc = _toolchain(ctx)
    out_name = ctx.attrs.out_name or ctx.label.name
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", out_name):
        fail("{}: out_name `{}` is not [A-Za-z_][A-Za-z0-9_]*".format(ctx.label, out_name))
    if not ctx.attrs.exports:
        fail("{}: `exports` is empty: a gate that expects no symbol checks nothing".format(ctx.label))
    for sym in ctx.attrs.exports:
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", sym):
            fail("{}: export `{}` is not a C symbol name".format(ctx.label, sym))
    main = _main_src(ctx)
    srcs = ctx.attrs.srcs if main in ctx.attrs.srcs else ctx.attrs.srcs + [main]
    _check_deps(ctx)
    for d in ctx.attrs.force_load:
        if MergedLinkInfo not in d:
            fail("{}: force_load {} provides no MergedLinkInfo (a C/C++ library)".format(ctx.label, d.label))
    force = None
    if ctx.attrs.force_load:
        force = _link_tail(create_merged_link_info_for_propagation(ctx, [d[MergedLinkInfo] for d in ctx.attrs.force_load]))
    darwin = tc.os == "darwin"
    link_extra = None
    if force != None:
        if darwin:
            # ld has no bracketed whole-archive: -force_load names one
            # archive, so each argument of the C libraries' link line is one.
            link_extra = cmd_args(force, format = "-Wl,-force_load,{}")
        else:
            link_extra = cmd_args("-Wl,--whole-archive", force, "-Wl,--no-whole-archive")
    if ctx.attrs.exports_exact:
        # The dynamic symbol table is `exports` and nothing else, so a symbol
        # of a static C dependency, or an @export the list does not name, is
        # local to the library. ELF: a version script. Mach-O: an exported
        # symbols list, whose names carry the C underscore.
        if darwin:
            script = ctx.actions.write(
                "exports.list",
                "".join(["_" + sym + "\n" for sym in ctx.attrs.exports]),
            )
            limit = cmd_args(script, format = "-Wl,-exported_symbols_list,{}")
        else:
            script = ctx.actions.write(
                "exports.map",
                "{ global: " + " ".join([sym + ";" for sym in ctx.attrs.exports]) + " local: *; };\n",
            )
            limit = cmd_args(script, format = "-Wl,--version-script={}")
        link_extra = cmd_args(link_extra, limit) if link_extra else cmd_args(limit)

    so_file = out_name + (".dylib" if darwin else ".so")
    ungated = _build_executable(
        ctx,
        tc,
        "ungated/" + so_file,
        srcs,
        main,
        _dep_closure(ctx),
        ctx.attrs.optimization_level,
        "mojo_build_shared_lib",
        None,
        _c_link(ctx),
        abi_lib = True,
        link_extra = link_extra,
    )

    # The gate: each driver is a Mojo program with no dependencies that
    # dlopens "./<out_name>.so", staged as its only data file.
    drivers = {}
    checks = "".join([_EXPORT_CHECK.format(sym = sym) for sym in ctx.attrs.exports])
    drivers["exports"] = ctx.actions.write(
        "gate/exports.mojo",
        _EXPORTS_DRIVER.format(so = so_file, checks = checks),
    )
    for g in ctx.attrs.gate_srcs:
        stem = _stem(g)
        if stem == "exports" or stem in drivers:
            fail("{}: gate_srcs has two drivers named `{}`".format(ctx.label, stem))
        drivers[stem] = g
    markers = []
    gate_subtargets = {}
    for stem in sorted(drivers.keys()):
        src = drivers[stem]
        exe = _build_executable(ctx, tc, "gate/{}/{}".format(stem, stem), [src], src, [], ctx.attrs.driver_optimization_level, "mojo_build_gate_driver", stem, None)
        root, staged = _test_root(ctx, "gate/{}/root".format(stem), exe, {so_file: ungated})
        marker = ctx.actions.declare_output("gate/{}.passed".format(stem))
        ctx.actions.run(
            cmd_args(
                tc.busybox,
                "sh",
                tc.gate_runner,
                tc.busybox,
                tc.compiler,
                "{}:{}".format(ctx.label.raw_target(), stem),
                staged,
                marker.as_output(),
                hidden = root,
            ),
            category = "mojo_shared_lib_gate",
            identifier = stem,
        )
        gate_subtargets[stem] = [DefaultInfo(default_output = marker, other_outputs = [root])]
        markers.append(marker)

    public = ctx.actions.declare_output("pub/" + so_file)
    ctx.actions.run(
        cmd_args(tc.busybox, "cp", ungated, public.as_output(), hidden = markers),
        category = "mojo_shared_lib_join",
    )
    return [DefaultInfo(
        default_output = public,
        sub_targets = {
            "gate": [DefaultInfo(default_outputs = markers, sub_targets = gate_subtargets)],
            # Files only: the library before its gate ran.
            "ungated": [DefaultInfo(default_output = ungated)],
        },
    )]

mojo_shared_lib_rule = rule(
    impl = _shared_lib_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "driver_optimization_level": attrs.string(default = TEST_OPT_LEVEL),
        "exports": attrs.list(attrs.string()),
        "exports_exact": attrs.bool(default = False),
        "force_load": attrs.list(attrs.dep(), default = []),
        "gate_srcs": attrs.list(attrs.source(), default = []),
        "main": attrs.option(attrs.source(), default = None),
        "optimization_level": attrs.string(default = SHIPPED_OPT_LEVEL),
        "out_name": attrs.option(attrs.string(), default = None),
        "srcs": attrs.list(attrs.source()),
    } | _TOOLCHAIN_ATTR,
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
    mojo_library_rule(**kwargs)
    if kwargs.get("conda", True):
        name = kwargs["name"]
        conda_package(
            name = name + "_conda",
            lib = ":" + name,
            summary = summary or "The `{}` Mojo library of komira, as a conda package.".format(kwargs.get("import_name") or name),
            target_compatible_with = LINUX_X86_64,
            visibility = ["PUBLIC"],
        )

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
mojo_binary = declares_docs(mojo_binary_rule)
mojo_library = declares_docs(_mojo_library)
mojo_shared_lib = declares_docs(mojo_shared_lib_rule)
mojo_test = declares_docs(mojo_test_rule)
