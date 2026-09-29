"""Lints that are part of the build.

Each rule here runs one lint in a remote action and returns its verdict as a
`ValidationInfo`. Buck2 runs a target's validations whenever a `buck2 build`
or `buck2 test` resolves a graph holding that target, and fails the command
when one reports failure. So a lint target is not a separate step: it is
checked by `buck2 build //...`, and by the build of every target that depends
on it. The rule layer depends on the lint of its own scripts
(`_script_lint` in mojo/toolchain.bzl and rust/defs.bzl), so no Mojo or Rust
target builds while a script the rules run has a finding.

A validation is not an input of the targets it guards: adding or fixing a
lint changes no other action's digest.

The lint action is lint.sh, under the pinned busybox; the linters are pinned
downloads (tools/build/lint/BUCK). Each rule's default output is the validation
result, a JSON file whose message holds the findings.
"""

_LIGHT = ["komira//tools/build/platforms:light"]

_COMMON = {
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    "_script": attrs.source(default = "komira//tools/build/lint:lint.sh"),
}

def _lint(ctx, kind, tools, args):
    result = ctx.actions.declare_output("validation.json")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, bb, result.as_output(), kind, tools, "--", args),
        category = "lint_" + kind,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = kind, validation_result = result)]),
    ]

def _tool(dep):
    return dep[DefaultInfo].default_outputs[0]

def _shell_lint_impl(ctx):
    if not ctx.attrs.srcs:
        fail("shell_lint {}: srcs is empty, so it would check nothing".format(ctx.label))
    excludes = dict(ctx.attrs.excludes)
    pairs = []
    for src in ctx.attrs.srcs:
        pairs.append(src)
        pairs.append(excludes.pop(src.short_path, "-"))
    if excludes:
        # An exclusion must not outlive the file it was written for.
        fail("shell_lint {}: excludes name {}, which is not in srcs; delete the entry".format(ctx.label, ", ".join(excludes.keys())))
    return _lint(ctx, "shellcheck", [_tool(ctx.attrs._shellcheck)], pairs)

shell_lint_rule = rule(
    impl = _shell_lint_impl,
    doc = "shellcheck (severity warning) over `srcs`. `excludes` maps a src path, relative to the package, to the comma-separated codes excluded for it; the reason belongs in a comment beside the entry.",
    attrs = _COMMON | {
        "excludes": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "srcs": attrs.list(attrs.source()),
        "_shellcheck": attrs.exec_dep(default = "komira//tools/build/lint:shellcheck"),
    },
)

def _workflow_lint_impl(ctx):
    if not ctx.attrs.srcs:
        fail("workflow_lint {}: srcs is empty, so it would check nothing".format(ctx.label))
    return _lint(ctx, "actionlint", [_tool(ctx.attrs._actionlint), _tool(ctx.attrs._shellcheck), ctx.attrs.config], ctx.attrs.srcs)

workflow_lint_rule = rule(
    impl = _workflow_lint_impl,
    doc = "actionlint over GitHub workflow files, with shellcheck over their `run:` steps. `config` is the actionlint configuration (the self-hosted runner labels).",
    attrs = _COMMON | {
        "config": attrs.source(),
        "srcs": attrs.list(attrs.source()),
        "_actionlint": attrs.exec_dep(default = "komira//tools/build/lint:actionlint"),
        "_shellcheck": attrs.exec_dep(default = "komira//tools/build/lint:shellcheck"),
    },
)

def _action_pins_impl(ctx):
    return _lint(ctx, "action_pins", [], ctx.attrs.srcs)

action_pins_rule = rule(
    impl = _action_pins_impl,
    doc = "Every `uses:` in the workflow files names a full 40-hex commit SHA. Refuses a set with no `uses:` at all.",
    attrs = _COMMON | {"srcs": attrs.list(attrs.source())},
)

def _no_endpoint_impl(ctx):
    return _lint(ctx, "no_endpoint", [], [ctx.attrs.buckconfig, ctx.attrs.gitignore] + ctx.attrs.srcs)

no_endpoint_rule = rule(
    impl = _no_endpoint_impl,
    doc = "No committed file configures remote execution: `buckconfig` names no endpoint or instance, `gitignore` ignores /.buckconfig.local, and no file in `srcs` names a grpc address outside example.* domains.",
    attrs = _COMMON | {
        "buckconfig": attrs.source(),
        "gitignore": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

def _tar_member_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name)
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(
            bb,
            "sh",
            "-euc",
            'd="$3.x"; "$1" mkdir -p "$d"; "$1" tar -x -f "$2" -C "$d" "$4"; "$1" mv "$d/$4" "$3"; "$1" rm -rf "$d"; "$1" chmod +x "$3"',
            "sh",
            bb,
            ctx.attrs.archive[DefaultInfo].default_outputs[0],
            out.as_output(),
            ctx.attrs.member,
        ),
        category = "tar_member",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

tar_member_rule = rule(
    impl = _tar_member_impl,
    doc = "One executable member of a pinned tar archive (busybox tar detects xz and gzip).",
    attrs = {
        "archive": attrs.dep(),
        "member": attrs.string(),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

def _light(kwargs):
    kwargs.setdefault("exec_compatible_with", _LIGHT)
    return kwargs

# Every lint runs on the light worker class: it reads a few files.
def shell_lint(**kwargs):
    shell_lint_rule(**_light(kwargs))

def workflow_lint(**kwargs):
    workflow_lint_rule(**_light(kwargs))

def action_pins(**kwargs):
    action_pins_rule(**_light(kwargs))

def no_endpoint(**kwargs):
    no_endpoint_rule(**_light(kwargs))

def tar_member(**kwargs):
    tar_member_rule(**_light(kwargs))
