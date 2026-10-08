"""The LLVM pieces of branch coverage, unpacked from pinned packages and checked (README.md).

`llvm_branch_unpack` runs unpack.sh in one build action: it writes named
members of pinned `.conda` packages into one directory, each a regular file
(a member that is a symbolic link in its package is written as the file it
resolves to), and nothing else.

`llvm_branch_check` runs a mode of check.sh in a build action and returns a
`ValidationInfo`. `llvm_branch_tool` is what other targets use: the two
directories and `LlvmBranchInfo`, with the checks as dependencies, so no
build that uses them succeeds unless the checks pass. The checks and the
tool take the directories as `exec_dep`s, each resolved on its own target's
execution platform. The checked bytes and the handed-out bytes are one
configured target only because every target here has the same
`exec_compatible_with` (LINUX_X86_64) and exactly one execution platform
matches it; a second linux-x86_64 execution platform would need the checks
to take the tool's configuration instead.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

# The raw profile version that code Mojo's lld instruments writes and that the
# pinned llvm-profdata accepts (README.md, The version coupling):
# `:raw_version_check` requires the one it measures to be this, and every
# branch coverage run requires each raw profile to have it
# (tools/build/coverage/branch). A new Mojo or new LLVM 23 pins that change it
# change this number.
RAW_PROFILE_VERSION = 11

LlvmBranchInfo = provider(
    doc = "The LLVM pieces of branch coverage (README.md), which tools/build/coverage/branch:cov_branch reads.",
    fields = {
        "lld": provider_field(typing.Any, default = None),  # cmd_args: `bin/lld` of `lld_dir`, with `lld_dir` (its lib/) as a hidden input
        "lld_dir": provider_field(typing.Any, default = None),  # artifact: Mojo's lld (LLVM 24) with the C++ runtime it loads
        "profdata": provider_field(typing.Any, default = None),  # cmd_args: `bin/llvm-profdata` of `tools_dir`, with `tools_dir` hidden
        "runtime": provider_field(typing.Any, default = None),  # artifact: the profile runtime, `runtime/libclang_rt.profile-x86_64.a`
        "tools_dir": provider_field(typing.Any, default = None),  # artifact: llvm-profdata, llvm-nm, their libraries and runtime/
    },
)

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _stage(ctx, name, files):
    # Sources are copied under buck-out first: a source's path in an action
    # differs between a standalone checkout and a repository that mounts
    # komira as a cell, and so would the action's digest.
    return ctx.actions.copied_dir(name, {f.short_path: f for f in files})

def _unpack_impl(ctx):
    staged = _stage(ctx, "unpack_srcs", [ctx.attrs.script])
    out = ctx.actions.declare_output("dist", dir = True)
    packages = [cmd_args(name, "=", _out(dep), delimiter = "") for name, dep in sorted(ctx.attrs.packages.items())]
    members = [cmd_args(dest, "=", src, delimiter = "") for dest, src in sorted(ctx.attrs.members.items())]
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            _out(ctx.attrs._busybox),
            _out(ctx.attrs.conda_payload),
            out.as_output(),
            packages,
            "--",
            members,
        ),
        category = "llvm_branch_unpack",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

_llvm_branch_unpack = rule(
    impl = _unpack_impl,
    doc = "A directory holding `members` (destination path -> `<package name>/<member path>`) of the pinned `.conda` `packages`, each a regular file, and nothing else; unpack.sh fails the action on a member that is missing or empty.",
    attrs = {
        "conda_payload": attrs.exec_dep(doc = "The tool that writes a .conda package's payload tar (toolchains/kcov:conda_payload)."),
        "members": attrs.dict(attrs.string(), attrs.string(), doc = "destination -> `<package name>/<member>`."),
        "packages": attrs.dict(attrs.string(), attrs.dep(), doc = "package name -> pinned .conda."),
        "script": attrs.source(doc = "unpack.sh"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _check_impl(ctx):
    # Runs `check.sh <mode> <busybox> <zig_dir> <report_dir> <lld_dir or -> <tools_dir or -> <fixture_dir or -> want...`.
    # One output: buck2 refuses a validation result whose action produces
    # more than one. The result is copied out of the directory.
    staged = _stage(ctx, "check_srcs", [ctx.attrs.script] + ctx.attrs.fixtures)
    report = ctx.actions.declare_output("report", dir = True)
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            ctx.attrs.mode,
            _out(ctx.attrs._busybox),
            _out(ctx.attrs._zig),
            report.as_output(),
            _out(ctx.attrs.lld) if ctx.attrs.lld else "-",
            _out(ctx.attrs.tools) if ctx.attrs.tools else "-",
            staged.project("fixtures") if ctx.attrs.fixtures else "-",
            [cmd_args(k, "=", v, delimiter = "") for k, v in sorted(ctx.attrs.want.items())],
        ),
        category = "llvm_branch_" + ctx.attrs.mode,
        identifier = ctx.label.name,
    )
    result = ctx.actions.copy_file("validation.json", report.project("validation.json"))
    return [
        DefaultInfo(default_output = result, sub_targets = {"report": [DefaultInfo(default_output = report)]}),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_llvm_branch_check = rule(
    impl = _check_impl,
    doc = "Runs `check.sh <mode>` (README.md, Checks) against the unpacked `lld` and `tools` directories, with `want` (key -> expected value) as its expectations. Fails the build on a wrong result; `[report]` holds what the check measured.",
    attrs = {
        "fixtures": attrs.list(attrs.source(), default = [], doc = "fixtures/: the C program the raw-version check instruments."),
        "lld": attrs.option(attrs.exec_dep(), default = None, doc = "The directory of :lld24."),
        "mode": attrs.enum(["lld", "tools", "raw_version"]),
        "script": attrs.source(doc = "check.sh"),
        "tools": attrs.option(attrs.exec_dep(), default = None, doc = "The directory of :llvm23."),
        "want": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
        "_zig": attrs.exec_dep(default = "komira//tools/build/toolchains:zig"),
    },
)

def _tool_impl(ctx):
    lld_dir = _out(ctx.attrs.lld)
    tools_dir = _out(ctx.attrs.tools)
    lld = cmd_args(lld_dir.project("bin/lld"), hidden = lld_dir)
    profdata = cmd_args(tools_dir.project("bin/llvm-profdata"), hidden = tools_dir)
    runtime = tools_dir.project("runtime/libclang_rt.profile-x86_64.a")
    return [
        DefaultInfo(
            default_outputs = [lld_dir, tools_dir],
            sub_targets = {
                "lld": [DefaultInfo(default_output = lld_dir)],
                "runtime": [DefaultInfo(default_output = runtime)],
                "tools": [DefaultInfo(default_output = tools_dir)],
            },
        ),
        LlvmBranchInfo(lld = lld, lld_dir = lld_dir, profdata = profdata, runtime = runtime, tools_dir = tools_dir),
    ]

_llvm_branch_tool = rule(
    impl = _tool_impl,
    doc = "The LLVM pieces of branch coverage as other targets use them (`LlvmBranchInfo`; `[lld]`, `[tools]` and `[runtime]`), configured for the execution platform and gated by the validations in `checks`.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "lld": attrs.exec_dep(),
        "tools": attrs.exec_dep(),
    },
)

llvm_branch_unpack = declares_docs(_llvm_branch_unpack)
llvm_branch_check = declares_docs(_llvm_branch_check)
llvm_branch_tool = declares_docs(_llvm_branch_tool)
