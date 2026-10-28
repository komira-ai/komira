"""The interpreter list: no interpreter file appears without a row, and no row outlives its file.

Every interpreter file of the repository has a row in the allowlist (path,
reason), and every row names such a file. An interpreter file is a shell,
Python, Perl, awk, sed or Ruby file: by its extension (`.sh`, `.bash`,
`.zsh`, `.ksh`, `.py`, `.pyw`, `.pl`, `.pm`, `.awk`, `.sed`, `.rb`) or by a
first `#!` line naming one of them, directly, through `env` or through
`busybox`. Existence only: a file's size is never read, so editing a listed
file never touches the allowlist. The check is the Zig tool
//tools/build/lint/interpreter_budget (src/budget.zig says each finding), run
in a remote action with no shell; its verdict is a `ValidationInfo`, so
`./buck2 build //...` (and the pull request's check) fails on a finding.

The files are the repository's committed files as the build graph holds them,
not a `git` call: `tree` (the root doc_tree: every file of the cell),
`dotfiles` (doc_tree targets of the files a glob skips), `cells` (the doc
tree of each other cell, at its path) and `files` (single files at a path of
the caller's choosing, for a planted case). So a file the guard cannot see is
one no doc_tree holds: the toolchains cell's one BUCK file, and the dotfiles
at the root other than `.github/`.

`scope` (path prefixes) limits the check to the files under them, and a row
outside them is a finding: a repository may start with a part of its tree.
`expect` turns a target into a planted case: it passes only when the check
refuses, with findings holding each expected text.

A repository using komira as a cell declares its own target in its own cell:
there `[komira] doc_tree_cells` of its root .buckconfig names that cell, so
its packages declare the doc_tree targets `tree` takes (doc_tree.bzl,
`declares_doc_trees`). komira's own target (tools/build/lint/BUCK) is
declared only in komira's checkout: it names the `tests` cell.

Not checked here, and held by review: a new row needs a reason review
accepts. A row whose file is deleted (or is no longer an interpreter file) is
a finding, so the row is removed in the same change and the list only shrinks.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_doc_trees", "declares_docs")

def _interpreter_budget_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for d in ctx.attrs.dotfiles:
        files.update(d[DocTreeInfo].files)
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    for path, f in ctx.attrs.files.items():
        if path in files:
            fail("interpreter_budget {}: `files` stages {}, which the tree holds already".format(ctx.label, path))
        files[path] = f
    if ctx.attrs.allowlist not in files:
        fail("interpreter_budget {}: the allowlist {} is not a file of the tree".format(ctx.label, ctx.attrs.allowlist))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    cmd = cmd_args(ctx.attrs._tool[RunInfo], "--tree", staged, "--allowlist", ctx.attrs.allowlist)
    for s in ctx.attrs.scope:
        cmd.add("--scope", s)
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    cmd.add("--out", result.as_output())
    ctx.actions.run(cmd, category = "interpreter_budget")
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "interpreter_budget", validation_result = result)]),
    ]

interpreter_budget_rule = rule(
    impl = _interpreter_budget_impl,
    doc = "Every interpreter file (shell, Python, Perl, awk, sed, Ruby; by extension or `#!` line) of `tree` (a doc_tree target: the root one holds every file of the cell), of the doc_tree targets in `dotfiles` (paths in the cell), of `cells` (another cell's doc_tree, at its path) and of `files` (path: source), under a prefix of `scope` (empty: everywhere), has a row in `allowlist` (its path in that tree; a TSV of path, reason), and every row names one. Existence only: no size is checked. The verdict is a validation; with `expect`, it passes only when the findings hold each expected text.",
    attrs = {
        "allowlist": attrs.string(),
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        "dotfiles": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
        "expect": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "scope": attrs.list(attrs.string(), default = []),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/interpreter_budget:interpreter_budget", providers = [RunInfo]),
    },
)

def _interpreter_budget(**kwargs):
    # Only in a cell whose packages declare doc_trees (doc_tree.bzl,
    # declares_doc_trees): komira's own checkout, or a cell a repository using
    # komira names in `[komira] doc_tree_cells`.
    if not declares_doc_trees():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    interpreter_budget_rule(**kwargs)

interpreter_budget = declares_docs(_interpreter_budget)
