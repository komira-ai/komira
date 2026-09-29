"""Hermetic C/C++ toolchain for the prelude's `cxx_library`, driven by zig.

`zig_cxx_toolchain` provides the prelude's C/C++ toolchain providers
(`cxx_toolchain_infos`), so `cxx_library` works unchanged. Every tool it
names is an input of the action that runs it:

    compiler, assembler, archiver   `zig_cc_launcher <zig> cc|c++|ar|ranlib`
    nm, objcopy, strip              not provided: a refusal (exit 2) naming the tool
    prelude internal tools          not provided: a refusal (exit 2) naming the tool

The prelude's internal tools are Python programs; nothing here runs Python.
The features that need them (dependency files, diagnostics concatenation,
compilation databases, header maps, remapping the working directory, thin LTO)
are off, so none of them is on the path of a compile, an archive or a link.
A build that reaches one fails with `cxx toolchain: <tool> is not provided`
instead of searching the worker for it.

zig's clang targets `target` (a glibc-versioned triple) and `target_cpu`
whatever worker runs it, and compiles with `-g0` by default: debug info would
record the action's working directory. The C++ standard library is zig's
libc++, linked statically (see `komira//tools/build/toolchains:libcxx`).
"""

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "AsCompilerInfo",
    "AsmCompilerInfo",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "DistLtoToolsInfo",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "ShlibInterfacesMode",
    "cxx_toolchain_infos",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//linking:link_info.bzl", "LinkStyle")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")

def _refusal(bb, what):
    # A tool the toolchain does not provide. It is still a declared input (the
    # busybox), so reaching it fails the action with a message, never a
    # search of the worker's PATH.
    return RunInfo(args = cmd_args(
        bb,
        "sh",
        "-c",
        "echo \"cxx toolchain: {} is not provided (see tools/build/mojo/cxx.bzl)\" >&2; exit 2".format(what),
    ))

def _zig_tool(launcher, zig, sub):
    # `zig_cc_launcher` expands nested response files (zig refuses them) and
    # gives zig a cache directory relative to the action's working directory.
    return RunInfo(args = cmd_args(launcher, zig, sub))

def _zig_cxx_toolchain_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    launcher = ctx.attrs.launcher[DefaultInfo].default_outputs[0]
    cc = _zig_tool(launcher, zig, "cc")
    cxx = _zig_tool(launcher, zig, "c++")

    # Flags every compile gets, before the target's own.
    base = ["-target", ctx.attrs.target, "-mcpu=" + ctx.attrs.target_cpu.replace("-", "_"), "-fPIC", "-g0"]
    c_info = CCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base, ctx.attrs.c_compiler_flags),
        preprocessor_flags = cmd_args(),
    )
    asm_info = AsmCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base),
        preprocessor_flags = cmd_args(),
    )
    as_info = AsCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base),
        preprocessor_flags = cmd_args(),
    )
    cxx_info = CxxCompilerInfo(
        compiler = cxx,
        compiler_type = "clang",
        compiler_flags = cmd_args(base, ctx.attrs.cxx_compiler_flags),
        preprocessor_flags = cmd_args(),
    )
    linker_type = LinkerType("gnu")
    linker_info = LinkerInfo(
        archiver = _zig_tool(launcher, zig, "ar"),
        archiver_type = "gnu",
        archiver_supports_argfiles = True,
        archive_objects_locally = False,
        binary_extension = "",
        generate_linker_maps = False,
        link_binaries_locally = False,
        link_libraries_locally = False,
        link_style = LinkStyle("static_pic"),
        link_weight = 1,
        linker = cxx,
        linker_flags = cmd_args("-target", ctx.attrs.target),
        object_file_extension = "o",
        shlib_interfaces = ShlibInterfacesMode("disabled"),
        shared_dep_runtime_ld_flags = [],
        shared_library_name_default_prefix = "lib",
        shared_library_name_format = "{}.so",
        shared_library_versioned_name_format = "{}.so.{}",
        static_dep_runtime_ld_flags = [],
        static_library_extension = "a",
        static_pic_dep_runtime_ld_flags = [],
        independent_shlib_interface_linker_flags = [],
        type = linker_type,
        use_archiver_flags = True,
        is_pdb_generated = False,
    )
    refuse = lambda what: _refusal(bb, what)
    internal_tools = CxxInternalTools(
        check_nonempty_output = refuse("check_nonempty_output"),
        clang_tidy_wrapper = refuse("clang_tidy_wrapper"),
        concatenate_diagnostics = refuse("concatenate_diagnostics"),
        dep_file_processor = refuse("dep_file_processor"),
        dist_lto = DistLtoToolsInfo(
            planner = {linker_type: refuse("dist_lto planner")},
            opt = {linker_type: refuse("dist_lto opt")},
            prepare = {linker_type: refuse("dist_lto prepare")},
            copy = refuse("dist_lto copy"),
            archive_mapper = refuse("dist_lto archive_mapper"),
            compiler_stats_merger = refuse("dist_lto compiler_stats_merger"),
        ),
        filter_argsfile = refuse("filter_argsfile"),
        hmap_wrapper = refuse("hmap_wrapper"),
        make_comp_db = refuse("make_comp_db"),
        remap_cwd = refuse("remap_cwd"),
        serialized_diagnostics_to_json_wrapper = refuse("serialized_diagnostics_to_json_wrapper"),
        stderr_to_file = refuse("stderr_to_file"),
        stub_header_unit = refuse("stub_header_unit"),
    )
    return [DefaultInfo()] + cxx_toolchain_infos(
        internal_tools = internal_tools,
        platform_name = "x86_64",
        c_compiler_info = c_info,
        cxx_compiler_info = cxx_info,
        asm_compiler_info = asm_info,
        as_compiler_info = as_info,
        linker_info = linker_info,
        binary_utilities_info = BinaryUtilitiesInfo(
            dwp = None,
            nm = refuse("nm"),
            objcopy = refuse("objcopy"),
            ranlib = _zig_tool(launcher, zig, "ranlib"),
            strip = refuse("strip"),
        ),
        header_mode = HeaderMode("symlink_tree_only"),
        # Every object is compiled once, position-independent (`-fPIC` above):
        # the same archive serves static and PIC links.
        pic_behavior = PicBehavior("always_enabled"),
        use_dep_files = False,
    )

zig_cxx_toolchain = rule(
    impl = _zig_cxx_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "c_compiler_flags": attrs.list(attrs.string(), default = []),
        "cxx_compiler_flags": attrs.list(attrs.string(), default = []),
        # A `zig_exe` of mojo/tools/zig_cc_launcher.zig.
        "launcher": attrs.exec_dep(),
        # zig target triple, with the glibc floor, e.g. x86_64-linux-gnu.2.34.
        "target": attrs.string(),
        # e.g. x86-64-v3; passed to zig as -mcpu.
        "target_cpu": attrs.string(),
        "zig": attrs.exec_dep(),
    },
)

def _no_python_bootstrap_toolchain_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(),
        PythonBootstrapToolchainInfo(interpreter = cmd_args(
            bb,
            "sh",
            "-c",
            "echo 'python bootstrap toolchain: no Python interpreter is provided (see tools/build/mojo/cxx.bzl)' >&2; exit 2",
            "sh",
        )),
    ]

# `toolchains//:python_bootstrap`. The prelude's `cxx_library` names a few
# Python helper programs as attributes, so configuring one needs this
# toolchain even though no action of a C/C++ compile, archive or link runs
# them. It provides no interpreter: a helper that does run fails, naming this
# file, instead of finding a Python on the worker.
no_python_bootstrap_toolchain = rule(
    impl = _no_python_bootstrap_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {"busybox": attrs.exec_dep()},
)
