"""The coverage path tools as build targets whose tests gate them.

`kcov_tool_cases` runs a cases script (a busybox sh script) against one tool
in a build action. The script exits non-zero on the first wrong result, which
fails the action and the build; on success it writes a validation result, so
the target is also a `ValidationInfo`.

`kcov_tool` is the tool as other targets use it: the `zig_exe`'s outputs
(`DefaultInfo`, `RunInfo`), with its cases targets as dependencies. Buck2 runs
the validations of every target in the graph it builds, so no build that uses
the tool succeeds unless its cases pass. The tool only runs inside actions, so
both `kcov_tool` and the cases take it as an `exec_dep`: with the same
`exec_compatible_with` on both, they resolve the same execution platform, so
the binary the cases test and the binary `kcov_tool` hands out are one
configured target, the same bytes.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoToolchainInfo")

def _cases_impl(ctx):
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    tool = ctx.attrs.tool[DefaultInfo].default_outputs[0]

    # The script and fixtures are copied under buck-out first: a source's path
    # in an action differs between a standalone checkout and a repository that
    # mounts komira as a cell, and so would the action's digest.
    files = [ctx.attrs.script] + ctx.attrs.data
    staged = ctx.actions.copied_dir("cases_srcs", {f.short_path: f for f in files})
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            staged.project(ctx.attrs.script.short_path),
            bb,
            result.as_output(),
            tool,
            staged,
            [h[DefaultInfo].default_outputs[0] for h in ctx.attrs.helpers],
        ),
        category = "kcov_tool_cases",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_kcov_tool_cases = rule(
    impl = _cases_impl,
    doc = "Runs `script` under busybox sh as `sh <script> <busybox> <result.json> <tool> <dir> [<helper>...]`, where `<dir>` holds `script` and `data` at their paths in the package and each `<helper>` is the default output of one of `helpers`, in order. The script exits non-zero on a wrong result and writes a successful validation result otherwise.",
    attrs = {
        "data": attrs.list(attrs.source(), default = [], doc = "Fixtures the script reads."),
        "helpers": attrs.list(attrs.exec_dep(), default = [], doc = "Other tools the cases run, configured like `tool`."),
        "script": attrs.source(),
        "tool": attrs.exec_dep(providers = [RunInfo]),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _tool_impl(ctx):
    exe = ctx.attrs.exe
    return [exe[DefaultInfo], exe[RunInfo]]

_kcov_tool = rule(
    impl = _tool_impl,
    doc = "The executable `exe` (configured for the execution platform), gated by the `kcov_tool_cases` targets in `cases`.",
    attrs = {
        "cases": attrs.list(attrs.dep(providers = [ValidationInfo])),
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
    doc = "The link directory of a coverage build: what mojo_wrapper.sh takes as <zig_dir>. It holds `zig` (cov_zig), `debug_relocate`, and `real/`, the Mojo toolchain's own link directory (the pinned zig), so a coverage link uses the zig a release link uses.",
    attrs = {
        "relocate": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/kcov:debug_relocate"),
        "zig": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/kcov:cov_zig"),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

kcov_tool_cases = declares_docs(_kcov_tool_cases)
kcov_tool = declares_docs(_kcov_tool)
cov_link_dir = declares_docs(_cov_link_dir)
