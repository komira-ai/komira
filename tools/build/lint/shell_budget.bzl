"""The shell list: no shell script appears without a row, and no row outlives its script.

Every shell script of the repository (a `.sh` or `.bash` file, or any file
whose `#!` line names a shell) has a row in the allowlist (path, reason), and
every row names such a script. Existence only: a script's size is never read,
so editing a listed script never touches the allowlist. The check is the Zig
tool //tools/build/lint/shell_budget (src/budget.zig says each finding), run
in a remote action with no shell; its verdict is a `ValidationInfo`, so
`./buck2 build //...` (and the pull request's check) fails on a finding.

The files are the repository's committed files as the build graph holds them,
not a `git` call: `tree` (the root doc_tree: every file of the cell),
`dotfiles` (doc_tree targets of the files a glob skips) and `cells` (the doc
tree of each other cell, at its path). So a file the guard cannot see is one
no doc_tree holds: the toolchains cell's one BUCK file, and the dotfiles at
the root other than `.github/`.

Not checked here, and held by review: a new row needs a reason review
accepts. A row whose script is deleted (or is no longer shell) is a finding,
so the row is removed in the same change and the list only shrinks.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_docs", "docs_checked")

def _shell_budget_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for d in ctx.attrs.dotfiles:
        files.update(d[DocTreeInfo].files)
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    if ctx.attrs.allowlist not in files:
        fail("shell_budget {}: the allowlist {} is not a file of the tree".format(ctx.label, ctx.attrs.allowlist))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], "--tree", staged, "--allowlist", ctx.attrs.allowlist, "--out", result.as_output()),
        category = "shell_budget",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "shell_budget", validation_result = result)]),
    ]

shell_budget_rule = rule(
    impl = _shell_budget_impl,
    doc = "Every shell script of `tree` (a doc_tree target: the root one holds every file of the cell), of the doc_tree targets in `dotfiles` (paths in the cell) and of `cells` (another cell's doc_tree, at its path) has a row in `allowlist` (its path in that tree; a TSV of path, reason), and every row names one. Existence only: no size is checked. The verdict is a validation.",
    attrs = {
        "allowlist": attrs.string(),
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        "dotfiles": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/shell_budget:shell_budget", providers = [RunInfo]),
    },
)

def _shell_budget(**kwargs):
    # Only where the doc_tree targets exist: komira's own checkout, not a
    # repository using komira as a cell (doc_tree.bzl, docs_checked).
    if not docs_checked():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    shell_budget_rule(**kwargs)

shell_budget = declares_docs(_shell_budget)
