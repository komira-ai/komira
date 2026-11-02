"""komira_c_abi_check: a C program, built against the generated header, run against the shared library.

    komira_c_abi_check(name, driver, lib, native_owners = [])

`driver` is a `cxx_binary` whose C includes the header `komira_abi_golden`
made and opens `./<file of lib>` with `dlopen`; `lib` is the `mojo_shared_lib`
it opens. The target's one output is the marker `PASS <label>`, written only if
the driver exited 0, so a header that disagrees with the binary (a different
version, a status code, an argument type that changes a call) goes red here and
nowhere else.

The driver runs from a staged tree like a Mojo gate driver (test_runtime.bzl):
the library is the one data file, at `share/<file>`, where the program's current
directory is; each of `native_owners` (the library's own, as in its
`mojo_shared_lib`) and everything it needs is at `share/lib/<SONAME>`, where the
library's run path finds it; and the Mojo runtime is on the loader path. `lib` is
the published library, so the driver does not run unless the library's own gate
passed.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/native:shared.bzl", "NativeSharedInfo")
load("@komira//tools/build/rerun:rerun.bzl", "RERUN_ATTRS", "rerun_env", "rerun_info")
load(":compile.bzl", _TOOLCHAIN_ATTR = "toolchain_attr", _toolchain = "toolchain")
load(":test_limit.bzl", "HANG_LIMIT_ATTRS", "hang_limit_flags")
load(":test_runtime.bzl", _test_root = "test_root", gate_mojo = "gate_mojo")
load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")

def _impl(ctx):
    tc = _toolchain(ctx)
    lib = ctx.attrs.lib[DefaultInfo].default_outputs[0]
    exes = ctx.attrs.driver[DefaultInfo].default_outputs
    if len(exes) != 1:
        fail("{}: driver {} has {} outputs, want its one executable".format(ctx.label, ctx.attrs.driver.label, len(exes)))
    data = {lib.basename: lib}
    for o in ctx.attrs.native_owners:
        for soname, so in o[NativeSharedInfo].closure.items():
            data["lib/" + soname] = so
    root, staged = _test_root(ctx, "root", exes[0], data)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    ctx.actions.run(
        cmd_args(
            gate_mojo(tc, str(ctx.label.raw_target()), staged, marker.as_output(), hang_limit_flags(str(ctx.label.raw_target()), ctx.attrs.test_hang_limit_s)),
            hidden = root,
        ),
        env = salted(rerun_env(ctx)),
        category = "c_abi_check",
    )
    return [DefaultInfo(default_output = marker), rerun_info(ctx)]

komira_c_abi_check_rule = rule(
    impl = _impl,
    doc = "Runs the C program `driver` (a cxx_binary) against the shared library `lib` (a mojo_shared_lib) from a staged tree, with the library and the `native_owners` it needs beside it; the marker exists only if the driver exited 0. See c_abi_check.bzl.",
    attrs = {
        "driver": attrs.dep(),
        "lib": attrs.dep(),
        "native_owners": attrs.list(attrs.dep(providers = [NativeSharedInfo]), default = []),
    } | _TOOLCHAIN_ATTR | HANG_LIMIT_ATTRS | RERUN_ATTRS,
)

komira_c_abi_check = declares_docs(komira_c_abi_check_rule)
