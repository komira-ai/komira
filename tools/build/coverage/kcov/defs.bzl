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
    doc = "Runs `script` under busybox sh as `sh <script> <busybox> <result.json> <tool> <dir>`, where `<dir>` holds `script` and `data` at their paths in the package. The script exits non-zero on a wrong result and writes a successful validation result otherwise.",
    attrs = {
        "data": attrs.list(attrs.source(), default = [], doc = "Fixtures the script reads."),
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

kcov_tool_cases = declares_docs(_kcov_tool_cases)
kcov_tool = declares_docs(_kcov_tool)
