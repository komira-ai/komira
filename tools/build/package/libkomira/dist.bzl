"""The native directory of libkomira that language packages carry
(`//src/so:libkomira[dist]`, tools/build/mojo/README.md), and the check that it
loads where it is copied: `picked_dir` and `libkomira_dist_load`.

    picked_dir(name, dir, paths)

The files `paths` of the directory `dir` builds, at the same paths in a new
directory: `dir` with everything else left out. The negative fixtures take
`[dist]` with one library left out this way. A path the directory does not
hold fails the action that reads it.

    libkomira_dist_load(name, dir, driver, expect_failure = None)

Copies `dir` (a `[dist]` directory, or a `picked_dir` of one) to another path
of buck-out and runs the C program `driver` (dist_load.c, a `cxx_binary`) on
the copy as a build action, with an environment of `LC_ALL=C` and nothing else:
no library path, no Python, nothing of Modular's. The driver opens the C++
runtime the host provides (the toolchain's `libstdc++.so.6` and
`libgcc_s.so.1`, standing in for the system's: a build worker has none), then
`<copy>/libkomira.so` with `RTLD_NOW | RTLD_LOCAL`, calls
`komira_abi_version()` against komira.h, and requires libkomira, its native
owners and the three Mojo runtime libraries to be mapped from the copy. The
output `<name>.pass` exists only if that passed, or, with `expect_failure`,
only if the first failure was exactly that line (the copy written `<dir>`).
Building the target is running the check. Linux x86_64 only.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/mojo:shared_lib.bzl", "HOST_CXX_RUNTIME")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

def _picked_dir_impl(ctx):
    src = ctx.attrs.dir[DefaultInfo].default_outputs[0]
    if len(ctx.attrs.paths) != len({p: None for p in ctx.attrs.paths}):
        fail("{}: paths names a path twice".format(ctx.label))
    out = ctx.actions.copied_dir(ctx.label.name, {p: src.project(p) for p in ctx.attrs.paths})
    return [DefaultInfo(default_output = out)]

_picked_dir = rule(
    impl = _picked_dir_impl,
    doc = "The files `paths` of the directory `dir` builds, at the same paths in one new directory.",
    attrs = {
        "dir": attrs.dep(),
        "paths": attrs.list(attrs.string()),
    },
)

def _dist_load_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    src = ctx.attrs.dir[DefaultInfo].default_outputs[0]
    exes = ctx.attrs.driver[DefaultInfo].default_outputs
    if len(exes) != 1:
        fail("{}: driver {} has {} outputs, want its one executable".format(ctx.label, ctx.attrs.driver.label, len(exes)))

    # Another path than the one the library target built it at.
    moved = ctx.actions.copy_file("elsewhere/a/b/native", src)
    out = ctx.actions.declare_output(ctx.label.name + ".pass")
    cmd = cmd_args(exes[0], "--dir", moved, "--out", out.as_output())
    for name in HOST_CXX_RUNTIME:
        cmd.add("--host-lib", tc.runtime.project(name))
    if ctx.attrs.expect_failure != None:
        cmd.add("--expect-failure", ctx.attrs.expect_failure)
    ctx.actions.run(cmd, env = salted({"LC_ALL": "C"}), category = "libkomira_dist_load")
    return [DefaultInfo(default_output = out)]

_libkomira_dist_load = rule(
    impl = _dist_load_impl,
    doc = "Copies the native directory `dir` elsewhere and loads libkomira from the copy with the C program `driver`, with no library path; the output exists only if it loaded and answered the header's ABI version from the copy (or, with `expect_failure`, failed with exactly that line). See dist.bzl.",
    attrs = {
        "dir": attrs.dep(),
        "driver": attrs.dep(),
        "expect_failure": attrs.option(attrs.string(), default = None),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _picked_dir_macro(**kwargs):
    _picked_dir(**kwargs)

def _libkomira_dist_load_macro(**kwargs):
    _libkomira_dist_load(exec_compatible_with = LINUX_X86_64, **kwargs)

picked_dir = declares_docs(_picked_dir_macro)
libkomira_dist_load = declares_docs(_libkomira_dist_load_macro)
