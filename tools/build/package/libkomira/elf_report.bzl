"""`libkomira_elf_report`: the ELF record of libkomira and the libraries it loads.

    libkomira_elf_report(
        name = "libkomira_elf_report",
        lib = "//src/so:libkomira",
        native_owners = [...],        # the `native_owners` of `lib`
    )

One action runs `so_report` (tools/build/native/so_report.zig) on the built
library, each owner's shared library (and, through them, the owners they need)
and the Mojo runtime libraries of the platform row's `runtime_libs`, taken from
the toolchain. The output is a markdown file: size, SONAME, RUNPATH, DT_NEEDED
and the highest GLIBC, GLIBCXX and CXXABI version of each file, which owners
the library reaches, and the wheel tag its glibc floor allows. The report is a
record; the gates of `lib` and `libkomira_install` hold the behaviour. Linux
x86_64 only (ELF files, glibc versions): another target platform skips it.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:table.bzl", "os_floor_version", "row")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    lib = ctx.attrs.lib[DefaultInfo].default_outputs[0]
    owners = {}
    for o in ctx.attrs.native_owners:
        owners[o[NativeSharedInfo].soname] = o[NativeSharedInfo].so
    out = ctx.actions.declare_output(ctx.label.name + ".md")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._report[RunInfo],
            "--out",
            out.as_output(),
            "--floor",
            os_floor_version("linux-x86_64"),
            "--target",
            lib.basename,
            lib,
            [cmd_args("--owner", soname, so) for soname, so in sorted(owners.items())],
            [cmd_args("--runtime", n, tc.compiler.project("lib/" + n)) for n in row("linux-x86_64")["runtime_libs"]],
        ),
        env = salted(),
        category = "libkomira_elf_report",
    )
    return [DefaultInfo(default_output = out)]

_libkomira_elf_report = rule(
    impl = _impl,
    attrs = {
        "lib": attrs.dep(),
        "native_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo]), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "_report": attrs.exec_dep(default = "komira//tools/build/native:so_report", providers = [RunInfo]),
    },
)

def libkomira_elf_report(**kwargs):
    _libkomira_elf_report(
        exec_compatible_with = LINUX_X86_64,
        target_compatible_with = LINUX_X86_64,  # komira-limit:libkomira-elf-linux-x86-64
        **kwargs
    )

libkomira_elf_report = declares_docs(libkomira_elf_report)
