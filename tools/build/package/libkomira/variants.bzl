"""The native directory of libkomira with every CPU level a platform row ships, and the check that each level loads from it.

    libkomira_variants(name, libs, native_owners, omit = [])

One directory, laid out as docs/design/isa_variants.md (decision 2) states, for linux-x86_64:

    VARIANTS                          the manifest: one line per variant, lowest first
    libkomira.so                      the floor variant (x86-64-v2)
    variants/<level>/libkomira.so     every other variant (x86-64-v3); run path $ORIGIN/../../lib
    lib/<owner>.so.1                  the native owners, one copy for every variant
    lib/<Mojo runtime library>        the compiler's three runtime libraries, one copy

`libs` maps each variant name of the row's `isa_variants`
(tools/build/platforms/isa_variants.bzl) to its link of libkomira (src/so/BUCK); it must name
exactly the row's variants. The manifest is written from the row, so the table is the only place
the variants and the CPU features each needs are stated. The owners are the files of
`native_owners` and everything they need, compiled once at the floor CPU (the C toolchain's), and
the runtime libraries are the toolchain's. The host's C++ runtime (libstdc++.so.6, libgcc_s.so.1)
is not in it: a host provides it as it provides glibc. `omit` leaves the named paths out: a
negative fixture of the check below, never a shipped directory.

    libkomira_variants_load(name, dir, driver, variant, expect_failure = None)

Copies `dir` to another path of buck-out and runs the C program `driver` (variants_load.c, a
`cxx_binary`) on the copy, as a build action on a linux x86_64 worker, with an environment of
`LC_ALL=C` and nothing else: no library path. The driver reads the copy's VARIANTS, opens the
line named `variant` by absolute path with RTLD_NOW, calls komira_abi_version() against komira.h,
and requires that file and no other libkomira to be mapped, and the libraries it loads from the
copy's lib/. The output `<name>.pass` exists only if that passed or, with `expect_failure`, only
if the first failure was exactly that line (the copy written `<dir>`). Building the target is
running the check. Every linux x86_64 worker implements x86-64-v3 (the host floor,
tools/build/toolchains/README.md), so each variant of the row runs where it is checked.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/mojo:shared_lib.bzl", "HOST_CXX_RUNTIME")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:isa_variants.bzl", "variant_path", "variants_manifest")
load("@komira//tools/build/platforms:table.bzl", "row")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

# The row these rules build for: the one row with more than one variant.
_ROW = "linux-x86_64"

_LIB_FILE = "libkomira.so"

def _variants_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    r = row(_ROW)
    names = [v["name"] for v in r["isa_variants"]]
    if sorted(ctx.attrs.libs.keys()) != sorted(names):
        fail("{}: libs names {}, but row {} ships the variants {}".format(ctx.label, sorted(ctx.attrs.libs.keys()), _ROW, names))
    for n in HOST_CXX_RUNTIME:
        if n not in r["runtime_libs"]:
            fail("{}: host C++ runtime library {} is not one of row {}'s runtime_libs {}".format(ctx.label, n, _ROW, r["runtime_libs"]))
    files = {"VARIANTS": ctx.actions.write("VARIANTS", variants_manifest(r, _LIB_FILE))}
    for v in r["isa_variants"]:
        outs = ctx.attrs.libs[v["name"]][DefaultInfo].default_outputs
        if len(outs) != 1 or outs[0].basename != _LIB_FILE:
            fail("{}: libs[{}] is not one {}: {}".format(ctx.label, repr(v["name"]), _LIB_FILE, outs))
        files[variant_path(r, v, _LIB_FILE)] = outs[0]
    for n in r["runtime_libs"]:
        if n not in HOST_CXX_RUNTIME:
            files["lib/" + n] = tc.runtime.project(n)
    for o in ctx.attrs.native_owners:
        for soname, so in o[NativeSharedInfo].closure.items():
            if "lib/" + soname in files and files["lib/" + soname] != so:
                fail("{}: two libraries are named lib/{}".format(ctx.label, soname))
            files["lib/" + soname] = so
    for p in ctx.attrs.omit:
        if p not in files:
            fail("{}: omit names {}, which the directory does not hold ({})".format(ctx.label, p, ", ".join(sorted(files))))
        files.pop(p)
    return [DefaultInfo(default_output = ctx.actions.copied_dir(ctx.label.name, files))]

_libkomira_variants = rule(
    impl = _variants_impl,
    doc = "The native directory of libkomira with every CPU level of the linux-x86_64 row: VARIANTS, the floor at libkomira.so, the others under variants/<level>/, and one lib/ of owners and Mojo runtime libraries. See variants.bzl.",
    attrs = {
        "libs": attrs.dict(attrs.string(), attrs.dep()),
        "native_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo])),
        "omit": attrs.list(attrs.string(), default = []),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _load_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    src = ctx.attrs.dir[DefaultInfo].default_outputs[0]
    exes = ctx.attrs.driver[DefaultInfo].default_outputs
    if len(exes) != 1:
        fail("{}: driver {} has {} outputs, want its one executable".format(ctx.label, ctx.attrs.driver.label, len(exes)))

    # Another path than the one the directory was built at: the run paths are relative to it.
    moved = ctx.actions.copy_file("elsewhere/a/b/native", src)
    out = ctx.actions.declare_output(ctx.label.name + ".pass")
    cmd = cmd_args(exes[0], "--dir", moved, "--variant", ctx.attrs.variant, "--out", out.as_output())
    for n in HOST_CXX_RUNTIME:
        cmd.add("--host-lib", tc.runtime.project(n))
    if ctx.attrs.expect_failure != None:
        cmd.add("--expect-failure", ctx.attrs.expect_failure)
    ctx.actions.run(cmd, env = salted({"LC_ALL": "C"}), category = "libkomira_variants_load")
    return [DefaultInfo(default_output = out)]

_libkomira_variants_load = rule(
    impl = _load_impl,
    doc = "Copies the variants directory `dir` elsewhere and loads its variant `variant` with the C program `driver`, with no library path; the output exists only if it loaded from the copy and answered the header's ABI version (or, with `expect_failure`, failed with exactly that line). See variants.bzl.",
    attrs = {
        "dir": attrs.dep(),
        "driver": attrs.dep(),
        "expect_failure": attrs.option(attrs.string(), default = None),
        "toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
        "variant": attrs.string(),
    },
)

def _libkomira_variants_macro(**kwargs):
    _libkomira_variants(**kwargs)

def _libkomira_variants_load_macro(**kwargs):
    _libkomira_variants_load(exec_compatible_with = LINUX_X86_64, **kwargs)

libkomira_variants = declares_docs(_libkomira_variants_macro)
libkomira_variants_load = declares_docs(_libkomira_variants_load_macro)
