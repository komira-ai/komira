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
negative fixture of the check below, never a shipped directory. Linux x86_64 only, like
the variants it links: another target platform skips it and the check (`libkomira_variants_manifest`
is unmarked).

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

It is `libkomira_dist_load` (dist.bzl) for a directory of more than one library: the same copy,
environment, host C++ runtime and `expect_failure` contract, with the library chosen by its
manifest line and the check that no other variant is mapped.

    libkomira_variants_manifest(name)

The file `VARIANTS` alone, the same text `libkomira_variants` writes into the directory, without
linking any variant: the manifest the language packages' selector tests read
(python/tests/test_variants.py), so their expected choices follow the row.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")
load("@komira//tools/build/mojo:shared_lib.bzl", "HOST_CXX_RUNTIME")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/platforms:isa_variants.bzl", "variant_libs_refusals", "variant_path", "variants_manifest")
load("@komira//tools/build/platforms:table.bzl", "row")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

# The row these rules build for: the one row with more than one variant.
_ROW = "linux-x86_64"

_LIB_FILE = "libkomira.so"

def _variants_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    r = row(_ROW)
    refusals = variant_libs_refusals(_ROW, r, ctx.attrs.libs.keys())
    if refusals:
        fail("{}: {}".format(ctx.label, "; ".join(refusals)))
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
        # A path the directory does not hold fails here: pop has no default.
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

def _manifest_impl(ctx):
    return [DefaultInfo(default_output = ctx.actions.write("VARIANTS", variants_manifest(row(_ROW), _LIB_FILE)))]

_libkomira_variants_manifest = rule(
    impl = _manifest_impl,
    doc = "The VARIANTS manifest of the linux-x86_64 row alone, the text `libkomira_variants` writes into its directory. See variants.bzl.",
    attrs = {},
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
    _libkomira_variants(
        target_compatible_with = LINUX_X86_64,  # komira-limit:isa-variants-linux-x86-64
        **kwargs
    )

def _libkomira_variants_load_macro(**kwargs):
    _libkomira_variants_load(
        exec_compatible_with = LINUX_X86_64,
        target_compatible_with = LINUX_X86_64,  # komira-limit:isa-variants-linux-x86-64
        **kwargs
    )

libkomira_variants = declares_docs(_libkomira_variants_macro)
libkomira_variants_load = declares_docs(_libkomira_variants_load_macro)
libkomira_variants_manifest = declares_docs(_libkomira_variants_manifest)
