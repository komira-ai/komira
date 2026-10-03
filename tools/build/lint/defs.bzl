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

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "collect_docs", "declares_docs")

_COMMON = {
    "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    "_script": attrs.source(default = "komira//tools/build/lint:lint.sh"),
}

def _stage(ctx, files):
    """Copies source files into one output directory, keyed by their path in
    the package, and returns {path: the copy}.

    A source file's path in an action is relative to the project root, so it
    differs between a standalone checkout and a repository mounting komira as
    a cell (`komira/tools/...`), and so would the action digest. The copies
    live under buck-out at the same path in both, so the lint actions share
    cache entries across checkouts, as every other action here does.
    """
    staged = ctx.actions.copied_dir("lint_srcs", {f.short_path: f for f in files})
    return staged, {f.short_path: staged.project(f.short_path) for f in files}

def _lint(ctx, kind, tools, args, staged):
    result = ctx.actions.declare_output("validation.json")
    bb = ctx.attrs._busybox[DefaultInfo].default_outputs[0]
    package = ctx.label.package + "/" if ctx.label.package else ""
    ctx.actions.run(
        cmd_args(bb, "sh", ctx.attrs._script, bb, result.as_output(), kind, staged, "{}//{}".format(ctx.label.cell, package), tools, "--", args),
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
    staged, copy = _stage(ctx, ctx.attrs.srcs)
    excludes = dict(ctx.attrs.excludes)
    pairs = []
    for src in ctx.attrs.srcs:
        pairs.append(copy[src.short_path])
        pairs.append(excludes.pop(src.short_path, "-"))
    if excludes:
        # An exclusion must not outlive the file it was written for.
        fail("shell_lint {}: excludes name {}, which is not in srcs; delete the entry".format(ctx.label, ", ".join(excludes.keys())))
    return _lint(ctx, "shellcheck", [_tool(ctx.attrs._shellcheck)], pairs, staged)

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
    staged, copy = _stage(ctx, [ctx.attrs.config] + ctx.attrs.srcs)
    tools = [_tool(ctx.attrs._actionlint), _tool(ctx.attrs._shellcheck), copy[ctx.attrs.config.short_path]]
    return _lint(ctx, "actionlint", tools, [copy[s.short_path] for s in ctx.attrs.srcs], staged)

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
    staged, copy = _stage(ctx, ctx.attrs.srcs)
    return _lint(ctx, "action_pins", [], [copy[s.short_path] for s in ctx.attrs.srcs], staged)

action_pins_rule = rule(
    impl = _action_pins_impl,
    doc = "Every `uses:` in the workflow files names a full 40-hex commit SHA. Refuses a set with no `uses:` at all.",
    attrs = _COMMON | {"srcs": attrs.list(attrs.source())},
)

def _no_endpoint_impl(ctx):
    if not ctx.attrs.buckconfigs:
        fail("no_endpoint {}: buckconfigs is empty, so it would check nothing".format(ctx.label))
    files = [ctx.attrs.gitignore] + ctx.attrs.buckconfigs + ctx.attrs.srcs
    staged, copy = _stage(ctx, files)
    args = [copy[ctx.attrs.gitignore.short_path], str(len(ctx.attrs.buckconfigs))]
    args += [copy[f.short_path] for f in ctx.attrs.buckconfigs + ctx.attrs.srcs]
    return _lint(ctx, "no_endpoint", [], args, staged)

no_endpoint_rule = rule(
    impl = _no_endpoint_impl,
    doc = "No committed file configures remote execution: no file in `buckconfigs` (every committed buckconfig) sets an endpoint or instance key, `gitignore` ignores /.buckconfig.local, and no file in `buckconfigs` or `srcs` names a grpc address outside example.* domains.",
    attrs = _COMMON | {
        "buckconfigs": attrs.list(attrs.source()),
        "gitignore": attrs.source(),
        "srcs": attrs.list(attrs.source(), default = []),
    },
)

def _push_verdicts_impl(ctx):
    staged, copy = _stage(ctx, ctx.attrs.srcs)
    return _lint(ctx, "push_verdicts", [], [copy[s.short_path] for s in ctx.attrs.srcs], staged)

push_verdicts_rule = rule(
    impl = _push_verdicts_impl,
    doc = "Every workflow triggered by `push` whose top-level `concurrency` group can hold more than one push keys that group on `github.sha`, so no push loses its run: GitHub keeps one pending run per group and a newer one cancels it. Refuses a set with no push-triggered workflow.",
    attrs = _COMMON | {"srcs": attrs.list(attrs.source())},
)

def _lint_suite_impl(ctx):
    if not ctx.attrs.lints:
        fail("lint_suite {}: lints is empty".format(ctx.label))
    return [DefaultInfo(default_outputs = [d[DefaultInfo].default_outputs[0] for d in ctx.attrs.lints])]

lint_suite_rule = rule(
    impl = _lint_suite_impl,
    doc = "Depends on lint targets another build graph does not reach, so their validations run in any build holding this target. Its outputs are their results.",
    attrs = {"lints": attrs.list(attrs.dep())},
)


def _markdown_docs_impl(ctx):
    if not [f for f in ctx.attrs.srcs if f.short_path.endswith(".md")]:
        fail("markdown_docs {}: no Markdown in `srcs`".format(ctx.label))
    if ctx.attrs.packages and ctx.label.package:
        fail("markdown_docs {}: `packages` stages files at their paths in the cell, so it is for a target of the cell's root package".format(ctx.label))
    staged = ctx.actions.copied_dir("doc_tree", collect_docs("", ctx.attrs.srcs + ctx.attrs.tree, ctx.attrs.packages))
    inspect = ctx.attrs._inspect[DefaultInfo].default_outputs[0]
    args = [staged, ",".join(ctx.attrs.unchecked) or "-"]
    for prefix, tree in sorted(ctx.attrs.cells.items()):
        args += [prefix, tree[DefaultInfo].default_outputs[0]]
    return _lint(ctx, "doc_links", [inspect], args, staged)

markdown_docs_rule = rule(
    impl = _markdown_docs_impl,
    doc = "Markdown whose relative links must resolve. Building it does nothing; its validation stages `srcs` and `tree` at their paths in the package, and the files of the doc_tree targets in `packages` at their paths in the cell (so only a target of the cell's root package may name `packages`), and requires every relative link and `#anchor` in every Markdown file there to resolve to a staged file, directory or heading (the Markdown reader of //tools/build/inspect). `cells` places the tree of another cell (a doc_tree target there) at that cell's path. A link leaving the staged tree, or to a file none of them holds, is dead. `unchecked` names Markdown files (paths in the tree) whose links are not read: planted dead links of a negative test.",
    attrs = _COMMON | {
        "srcs": attrs.list(attrs.source()),
        "cells": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "packages": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
        "tree": attrs.list(attrs.source(), default = []),
        "unchecked": attrs.list(attrs.string(), default = []),
        "_inspect": attrs.exec_dep(default = "komira//tools/build/inspect:inspect[runnable]"),
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

def _linux(kwargs):
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    return kwargs

# Every lint runs linux x86_64 tools (busybox, shellcheck): it reads a few files.
def shell_lint(**kwargs):
    shell_lint_rule(**_linux(kwargs))

def workflow_lint(**kwargs):
    workflow_lint_rule(**_linux(kwargs))

def action_pins(**kwargs):
    action_pins_rule(**_linux(kwargs))

def no_endpoint(**kwargs):
    no_endpoint_rule(**_linux(kwargs))

def push_verdicts(**kwargs):
    push_verdicts_rule(**_linux(kwargs))

def tar_member(**kwargs):
    tar_member_rule(**_linux(kwargs))

# Markdown: see markdown_docs_rule. The root BUCK applies it to the
# repository's documentation (//:docs).
def markdown_docs(**kwargs):
    markdown_docs_rule(**_linux(kwargs))

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (doc_tree.bzl), so no BUCK file names one.
action_pins = declares_docs(action_pins)
lint_suite = declares_docs(lint_suite_rule)
markdown_docs = declares_docs(markdown_docs)
no_endpoint = declares_docs(no_endpoint)
push_verdicts = declares_docs(push_verdicts)
shell_lint = declares_docs(shell_lint)
tar_member = declares_docs(tar_member)
workflow_lint = declares_docs(workflow_lint)
