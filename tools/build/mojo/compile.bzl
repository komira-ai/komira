"""One Mojo compile's command line, and `mojo build` of a program.

`mojo_compile_cmd` is the command line of every Mojo compile: each rule that
runs the compiler builds its command there (defs.bzl's rules and their
coverage and mutation actions, doc.bzl, proto.bzl). `build_executable` is
`mojo build` of one program against a closure of packages, as an executable,
a shared library with a generated entry, or a C-ABI library; mojo_library's
tests, mojo_binary, mojo_test and mojo_shared_lib (defs.bzl) build through
it.
"""

load("@prelude//linking:link_info.bzl", "LinkStrategy")
load(":providers.bzl", "MojoPkgTSet")

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

def mojo_compile_cmd(tc, args, runpath = None, source_root = None, link_tail = None, link = None, darwin_knobs = True):
    """The command line of one Mojo compile (`mojo precompile`, `build`, `doc`).

    Every rule that runs the compiler builds its command here: mojo_library,
    mojo_binary, mojo_test and their coverage and mutation actions,
    mojo_doc_json (doc.bzl) and the proto packages (proto.bzl).

    `link` replaces the toolchain's link directory: a coverage build's
    (coverage.bzl), whose `zig` keeps and relocates the debug info.
    `link_tail` is appended by the wrapper's `cc` shim to the END of every
    link line, after the compiler's own objects and archive.

    On Linux the wrapper is komira//tools/build/mojo:mojo_compile, a Zig
    program (tools/mojo_compile.zig), and the toolchain's watchdog knobs are
    always passed. The macOS toolchain still runs its shell wrapper
    (darwin/mojo_wrapper.sh) under the toolchain's busybox, with the
    command line it always had: `darwin_knobs = False` where that line had
    no knobs (doc.bzl, proto.bzl).
    """
    tail = [cmd_args(link_tail, format = "--link-tail={}")] if link_tail else []
    if tc.os == "darwin":
        return cmd_args(
            tc.busybox,
            "sh",
            tc.wrapper,
            tc.busybox,
            tc.compiler,
            link or tc.link,
            tc.cc_target,
            ["--runpath=" + runpath] if runpath else [],
            [cmd_args(source_root, format = "--source-root={}")] if source_root else [],
            tail,
            _watchdog_flags(tc) if darwin_knobs else [],
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

def c_link_tail(c_link):
    """The link arguments of `c_link` in dependency order (dependents first)."""
    if c_link == None:
        return None

    # The prelude's own link steps read the per-strategy link infos the same
    # way (link_info.bzl, get_link_args_for_strategy).
    infos = c_link._infos.get(LinkStrategy("static_pic"))
    if infos == None:
        return None
    return infos.project_as_args("default", ordering = "preorder")

def src_stem(src):
    b = src.basename
    return b[:-len(".mojo")] if b.endswith(".mojo") else b

def _dirname(p):
    i = p.rfind("/")
    return p[:i] if i >= 0 else ""

def join_path(d, f):
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

def build_executable(ctx, tc, out_path, srcs, main, closure_tsets, opt_level, category, identifier, c_link, shared = False, abi_lib = False, link_extra = None, debug_link = None, defines = []):
    """`mojo build` of `main` (one of `srcs`) against the packages in closure_tsets, linking c_link.

    Reads only `ctx.actions` and `ctx.label`, so a dynamic action passes
    `struct(actions = ..., label = ...)` (see defs.bzl's _readme_test).

    With `shared`, emits a shared library instead: DT_SONAME is the output's
    file name and its one run path is `$ORIGIN/../..`, the bundle's lib/
    seen from lib/glibc-hwcaps/<level>/.

    With `abi_lib`, emits a shared library straight from `main`, a file of
    `@export` C-ABI functions: no generated entry and no `komira_main`.
    DT_SONAME is the output's file name (the caller names it, with no `lib`
    prefix forced) and the run path is the default `$ORIGIN/lib`.
    `link_extra` is appended to the link tail after the C libraries (the
    force-loaded archives of mojo_shared_lib).

    With `debug_link` (a coverage build's link directory, coverage.bzl), the
    compile keeps line tables (`--debug-level line-tables`) and links through
    that directory instead of the toolchain's.

    `defines`: `-D` arguments from defines.bzl's define_args, after
    `--target-cpu`; none are written when it is empty.
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
        stem = src_stem(main)
        if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", stem):
            fail("{}: {} is not importable as a Mojo module".format(ctx.label, main.short_path))
        entry = join_path(_dirname(main.short_path), "_komira_entry.mojo")
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
    tail = c_link_tail(c_link)
    if link_extra:
        tail = cmd_args(tail, link_extra) if tail else cmd_args(link_extra)
    ctx.actions.run(
        mojo_compile_cmd(tc, [
            "build",
            emit,
            "--optimization-level",
            opt_level,
            "--target-cpu",
            tc.target_cpu,
            defines,
            ["--debug-level", "line-tables"] if debug_link else [],
            closure.project_as_args("include"),
            staged.project(entry),
            "-o",
            exe.as_output(),
        ], runpath = "$ORIGIN/../.." if shared else None, source_root = staged, link_tail = tail, link = debug_link),
        category = category,
        identifier = identifier,
    )
    return exe
