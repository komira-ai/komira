"""The no-shell list: no build file starts a shell, and no shell script sits outside a place the list names.

The build files (BUCK, `.bzl`, `.bxl`) of the tree are scanned for the ways a
rule runs a shell: `busybox_sh`, a shell's name or option word as an
argument, a shell by path, a `.sh` script named in a rule, the `genrule` and
`sh_*` rules. Each file's count per category must equal its row in the list
(`use`, path, category, count, reason): more is a new use of a shell, fewer is
a row to lower, so the list only shrinks. The shell scripts of the tree (by
extension or `#!` line) each need a `script` row (an action's or test's
script that is still to be ported) or must sit under a `human` row (a path or
a directory ending in `/`: where scripts that only people and CI runners run
may live). The check is the Zig tool //tools/build/lint/no_shell
(src/rules.zig says each finding), run in a remote action with no shell; its
verdict is a `ValidationInfo`, so `./buck2 build //...` (and the pull
request's check) fails on a finding.

The files are the repository's committed files as the build graph holds them,
as for the interpreter list (interpreter_budget.bzl): `tree` (the root
doc_tree), `dotfiles`, `cells` and `files` (single files at a path of the
caller's choosing, for a planted case). `expect` turns a target into a planted
case: it passes only when the check refuses, with findings holding each
expected text.

Not checked here, and held by review: a new row needs a reason review accepts.
A scan reads spellings, not meaning: a shell started through a computed name
is not seen.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_doc_trees", "declares_docs")

def _no_shell_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for d in ctx.attrs.dotfiles:
        files.update(d[DocTreeInfo].files)
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    for path, f in ctx.attrs.files.items():
        if path in files:
            fail("no_shell {}: `files` stages {}, which the tree holds already".format(ctx.label, path))
        files[path] = f
    if ctx.attrs.list not in files:
        fail("no_shell {}: the list {} is not a file of the tree".format(ctx.label, ctx.attrs.list))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    cmd = cmd_args(ctx.attrs._tool[RunInfo], "--tree", staged, "--list", ctx.attrs.list)
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    cmd.add("--out", result.as_output())
    ctx.actions.run(cmd, category = "no_shell")
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "no_shell", validation_result = result)]),
    ]

no_shell_rule = rule(
    impl = _no_shell_impl,
    doc = "The build files (BUCK, .bzl, .bxl) of `tree` (a doc_tree target: the root one holds every file of the cell), of the doc_tree targets in `dotfiles`, of `cells` (another cell's doc_tree, at its path) and of `files` (path: source) start no shell beyond the counts of `list` (its path in that tree; a TSV of kind, path, category, count, reason), and every shell script of the tree has a `script` row or sits under a `human` row. The verdict is a validation; with `expect`, it passes only when the findings hold each expected text.",
    attrs = {
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        "dotfiles": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
        "expect": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "list": attrs.string(),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/no_shell:no_shell", providers = [RunInfo]),
    },
)

def _no_shell(**kwargs):
    # Only in a cell whose packages declare doc_trees (doc_tree.bzl,
    # declares_doc_trees): komira's own checkout, or a cell a repository using
    # komira names in `[komira] doc_tree_cells`.
    if not declares_doc_trees():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    no_shell_rule(**kwargs)

no_shell = declares_docs(_no_shell)
