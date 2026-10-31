"""The compile and link core of the Mojo rules.

The pieces every Mojo rule builds on, moved out of defs.bzl unchanged so
mojo_shared_lib (shared_lib.bzl) and defs.bzl can both load them: the toolchain
accessor, the compile wrapper command lines (`mojo_compile_cmd`,
`mojo_precompile_cmd`), the `deps` checks and closure, the C link arguments and
`_build_executable`, the one `mojo build` action. A name here that starts with
`_` is exported without it (a `_` name cannot be loaded); loaders rename it back.
"""

load("@prelude//linking:link_info.bzl", "LinkStrategy", "MergedLinkInfo", "create_merged_link_info_for_propagation")
load(":providers.bzl", "MojoInfo", "MojoPkgTSet", "mojo_pkg_children", "MojoToolchainInfo")
load(":opt_level.bzl", "opt_level_args")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")


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

def mojo_compile_cmd(tc, args, runpath = None, source_root = None, link_tail = None, link = None):
    """The command line of one Mojo compile (`mojo precompile`, `build`, `doc`).

    Every rule that runs the compiler builds its command here: mojo_library,
    mojo_binary, mojo_test and their coverage and mutation actions,
    mojo_doc_json (doc.bzl) and the proto packages (proto.bzl).

    `link` replaces the toolchain's link directory: a coverage build's
    (coverage.bzl), whose `zig` keeps and relocates the debug info. Linux
    only. `link_tail` is appended by the wrapper's `cc` shim to the END of
    every link line, after the compiler's own objects and archive.

    The wrapper is the Zig program mojo_compile (tools/mojo_compile.zig on
    Linux, tools/mojo_compile_macos.zig on macOS), and the toolchain's
    watchdog knobs are always passed. On macOS the deployment target and the
    host identities a compile may run on (`macos_hosts`) take the place of
    the zig directory and target.
    """
    tail = [cmd_args(link_tail, format = "--link-tail={}")] if link_tail else []
    if tc.os == "darwin":
        if link:
            fail("mojo_compile_cmd: `link` (a coverage link directory) is Linux only")
        return cmd_args(
            tc.wrapper,
            cmd_args(tc.compiler, format = "--compiler={}"),
            "--deployment-target=" + tc.cc_target,
            ["--macos-host=" + h for h in tc.macos_hosts],
            ["--runpath=" + runpath] if runpath else [],
            [cmd_args(source_root, format = "--source-root={}")] if source_root else [],
            tail,
            _watchdog_flags(tc),
            "--",
            args,
        )
    return cmd_args(
        tc.wrapper,
        cmd_args(tc.compiler, format = "--compiler={}"),
        cmd_args(link or tc.link, format = "--zig={}"),
        "--cc-target=" + tc.cc_target,
        ["--runpath=" + runpath] if runpath else [],
        [cmd_args(source_root, format = "--source-root={}")] if source_root else [],
        tail,
        _watchdog_flags(tc),
        "--",
        args,
    )

def mojo_precompile_cmd(tc, include, src_dir, out):
    """The command line of one `mojo precompile` of the staged package `src_dir`.

    Every `.mojoc` that ships is built here (mojo_library, proto.bzl). The
    compiler records each source of a package by the path it was given, so a
    package compiled as `buck-out/<isolation dir>/.../src/<name>` would carry
    that path and differ per isolation directory. `src_dir` is passed as
    `--source-root`: the wrapper (tools/mojo_compile.zig, compile_args.runDir)
    then runs the compiler from its parent and names the package by its
    basename, so the `.mojoc` records `<name>/<file>.mojo` wherever the action
    runs (`-strip-file-prefix` does not reach `precompile`). No
    `--target-cpu`: `mojo precompile` rejects it; a `.mojoc` holds no machine
    code. tools/build/tests/functional/mojoc_path checks it.
    """
    return mojo_compile_cmd(tc, ["precompile", include, src_dir, "-o", out], source_root = src_dir)

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
    return mojo_pkg_children(ctx, [d[MojoInfo] for d in ctx.attrs.deps if MojoInfo in d])

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

def _build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier, c_link, shared = False, abi_lib = False, link_extra = None, debug_link = None, defines = [], levels = None, emit_object = False, link_head = None):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets, linking c_link.

    Reads only `ctx.actions` and `ctx.label`, so a dynamic action passes
    `struct(actions = ..., label = ...)` (see _readme_test).

    With `shared`, emits a shared library instead: DT_SONAME is the output's
    file name and its one run path is `$ORIGIN/../..`, the bundle's lib/
    seen from lib/glibc-hwcaps/<level>/.

    With `abi_lib`, emits a shared library straight from `main`, a file of
    `@export` C-ABI functions: no generated entry and no `komira_main`.
    DT_SONAME is the output's file name (the caller names it, with no `lib`
    prefix forced) and the run path is the default `$ORIGIN/lib`
    (`mojo_shared_lib` adds `$ORIGIN` on Linux through `link_extra`).
    `link_extra` is appended to the link tail after the C libraries (the
    force-loaded archives of mojo_shared_lib). `link_head` is put before
    them (the owners' shared libraries of mojo_shared_lib: a symbol one of
    them defines is bound there, so the archive that also holds it is not
    pulled in).

    With `debug_link` (a coverage build's link directory, coverage.bzl), the
    compile keeps line tables (`--debug-level line-tables`) and links through
    that directory instead of the toolchain's.

    `defines`: `-D` arguments from defines.bzl's define_args, after
    `--target-cpu`; none are written when it is empty. `levels`: see opt_level.bzl.

    With `emit_object`, emits the program's object file instead (`--emit
    object`), linked to nothing: every `external_call` the program reaches
    is an undefined symbol of it (the README check, shared.bzl).
    """
    opt_args = opt_level_args(ctx.label, opt_level, category, levels)
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
    if link_head:
        tail = cmd_args(link_head, tail) if tail else cmd_args(link_head)
    if link_extra:
        tail = cmd_args(tail, link_extra) if tail else cmd_args(link_extra)
    if emit_object:
        emit, tail = ["--emit", "object"], None
    ctx.actions.run(
        mojo_compile_cmd(tc, [
            "build",
            emit,
            opt_args,
            "--target-cpu",
            tc.target_cpu,
            defines,
            ["--debug-level", "line-tables"] if debug_link else [],
            closure.project_as_args("include"),
            staged.project(entry),
            "-o",
            exe.as_output(),
        ], runpath = "$ORIGIN/../.." if shared else None, source_root = staged, link_tail = tail, link = debug_link),
        env = salted(),
        category = category,
        identifier = identifier,
    )
    return exe

_TOOLCHAIN_ATTR = {
    "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
}

def _main_src(ctx):
    if ctx.attrs.main:
        return ctx.attrs.main
    if len(ctx.attrs.srcs) != 1:
        fail("{}: set `main` when srcs has more than one file".format(ctx.label))
    return ctx.attrs.srcs[0]


# Exported without the leading `_` (see the header).
toolchain = _toolchain
check_deps = _check_deps
dep_closure = _dep_closure
c_link = _c_link
link_tail = _link_tail
stem = _stem
dirname = _dirname
join = _join
build_executable = _build_executable
toolchain_attr = _TOOLCHAIN_ATTR
main_src = _main_src
