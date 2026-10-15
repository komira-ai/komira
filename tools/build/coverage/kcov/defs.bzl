"""The coverage path tools as build targets whose tests gate them.

`kcov_tool` is the tool as other targets use it: the `zig_exe`'s outputs
(`DefaultInfo`, `RunInfo`), with its cases targets as dependencies. Buck2 runs
the validations of every target in the graph it builds, so no build that uses
the tool succeeds unless its cases pass. The tool only runs inside actions, so
both `kcov_tool` and the cases take it as an `exec_dep`: with the same
`exec_compatible_with` on both, they resolve the same execution platform, so
the binary the cases test and the binary `kcov_tool` hands out are one
configured target, the same bytes. A tool whose cases are `zig_test` unit
tests (debug_relocate, cov_normalize, cov_zig) has its `zig_exe` built behind
them (`unit_tests`), so the executable does not exist unless they pass; those
tests build the tool from source, so they do not test the shipped bytes. Its
process cases are a `zig_test` that names the executable in `env_tools`
(the same configured target; its path reaches the test in the environment)
and runs it: a validation, listed in `cases`.

`cov_link_dir` and `cov_run_dir` are the two directories a coverage build of
a `mojo_library` uses (tools/build/mojo/coverage.bzl): the one its test
binaries link through, and the one each test's kcov run runs from.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _tool_impl(ctx):
    exe = ctx.attrs.exe
    return [exe[DefaultInfo], exe[RunInfo]]

_kcov_tool = rule(
    impl = _tool_impl,
    doc = "The executable `exe` (configured for the execution platform), gated by the validations in `cases` and by the `zig_test` targets `exe` is built behind.",
    attrs = {
        "cases": attrs.list(attrs.dep(providers = [ValidationInfo]), default = [], doc = "Validations that run `exe`: a `zig_test` naming it in `env_tools`."),
        "exe": attrs.exec_dep(providers = [RunInfo]),
    },
)

def _link_dir_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    out = ctx.actions.copied_dir("cov_link", {
        "debug_relocate": ctx.attrs.relocate[DefaultInfo].default_outputs[0],
        "real": tc.link,
        "zig": ctx.attrs.zig[DefaultInfo].default_outputs[0],
    })
    return [DefaultInfo(default_output = out)]

_cov_link_dir = rule(
    impl = _link_dir_impl,
    doc = "The link directory of a coverage build: what mojo_compile takes as --zig=<dir>. It holds `zig` (cov_zig), `debug_relocate`, and `real/`, the Mojo toolchain's own link directory (the pinned zig), so a coverage link uses the zig a release link uses.",
    attrs = {
        "relocate": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/kcov:debug_relocate"),
        "zig": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/kcov:cov_zig"),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

kcov_tool = declares_docs(_kcov_tool)
cov_link_dir = declares_docs(_cov_link_dir)

# The bound of one coverage run, in seconds (cov_run reads it from the
# file `limit` of its directory). kcov waits for every process the test
# started, so a test that leaves a child running would hold the run open
# until the executor gave up. The slowest run measured took 119.6 s of
# worker time; 450 s is over three times that, and under 600 s, buck2's
# default timeout of a test action, so the run fails with its own message.
COV_RUN_LIMIT_S = 450

def _run_dir_impl(ctx):
    limit = ctx.attrs.limit_s
    if limit != COV_RUN_LIMIT_S and ctx.label.cell != "tests":
        fail("{}: limit_s is {} s for every coverage run; only a fixture of the tests cell may set another".format(ctx.label.raw_target(), COV_RUN_LIMIT_S))
    if limit < 1:
        fail("{}: limit_s must be at least 1 s, not {}".format(ctx.label.raw_target(), limit))
    out = ctx.actions.copied_dir("cov_run", {
        "cov_normalize": ctx.attrs.normalize[DefaultInfo].default_outputs[0],
        "cov_run": ctx.attrs.tool[DefaultInfo].default_outputs[0],
        "kcov": ctx.attrs.kcov[DefaultInfo].default_outputs[0],
        "limit": ctx.actions.write("cov_run_limit", "{}\n".format(limit)),
    })
    return [DefaultInfo(default_output = out)]

_cov_run_dir = rule(
    impl = _run_dir_impl,
    doc = "The directory a coverage run of a mojo_library test runs from (tools/build/mojo/coverage.bzl): `cov_run` (`tool`, a Zig program), `kcov/` (the kcov distribution), `cov_normalize` and `limit` (`limit_s`, the seconds one run may take). The program finds the others beside itself.",
    attrs = {
        "kcov": attrs.exec_dep(default = "komira//tools/build/toolchains/kcov:kcov"),
        "limit_s": attrs.int(default = COV_RUN_LIMIT_S),
        "normalize": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/kcov:cov_normalize"),
        "tool": attrs.exec_dep(default = "komira//tools/build/coverage/kcov:cov_run_bin"),
    },
)

cov_run_dir = declares_docs(_cov_run_dir)
