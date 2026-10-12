"""limits: every limit of the build is declared at its site and listed in limits.tsv.

A limit is a place the build says it builds for one platform only
(tools/build/platforms/README.md, "Limits, and the golden"). The check is the
Zig tool //tools/build/platforms/limits:limits_check (src/limits.zig says each
finding) in its `tree` mode, run in a remote action with no shell; its verdict
is a `ValidationInfo`, so `./buck2 build //...` (and the pull request's check)
fails on a finding: a malformed row, a platform restriction with no marker, a
marker with no row, or a row with no marker.

The files are the repository's committed files as the build graph holds them,
not a `git` call: `tree` (the root doc_tree: every file of the cell), `srcs`
(files of this package a glob skips, the dotfiles) and `cells` (the doc tree
of each other cell, at its path). Not read: the toolchains cell's one BUCK
file, which no doc_tree holds; review holds it.

Whether a row's retiring PR has merged is read from the commit subjects of
main, which no build action can see: the tool's `merged` mode, run by
tests//functional/platform_table (check.sh).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "DocTreeInfo", "declares_docs", "docs_checked")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _limits_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for f in ctx.attrs.srcs:
        files[f.short_path] = f
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    if ctx.attrs.limits not in files:
        fail("limits {}: the limits file {} is not a file of the tree".format(ctx.label, ctx.attrs.limits))
    for e in ctx.attrs.exclude:
        if not e.endswith("/") and e not in files:
            fail("limits {}: `exclude` names {}, which is no file of the tree (a directory ends in /)".format(ctx.label, e))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    excludes = []
    for e in ctx.attrs.exclude:
        excludes += ["--exclude", e]
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], "tree", "--tree", staged, "--limits", ctx.attrs.limits, excludes, "--out", result.as_output()),
        category = "limits",
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "limits", validation_result = result)]),
    ]

limits_rule = rule(
    impl = _limits_impl,
    doc = "Every limit of the build is declared at its site by a marker and listed in `limits` (its path in the tree, a TSV of id, retired_by, reason), and every row has its marker, over the files of `tree` (a doc_tree target), `srcs` and `cells` but `exclude` (a path, or a directory ending in /) and Markdown. The verdict is a validation.",
    attrs = {
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        # The check's own sources, data and fixtures, which spell the marker and the restriction.
        "exclude": attrs.list(attrs.string(), default = []),
        "limits": attrs.string(),
        "srcs": attrs.list(attrs.source(), default = []),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/platforms/limits:limits_check", providers = [RunInfo]),
    },
)

def _limits(**kwargs):
    # Only where the doc_tree targets exist: komira's own checkout, not a
    # repository using komira as a cell (doc_tree.bzl, docs_checked).
    if not docs_checked():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    limits_rule(**kwargs)

limits = declares_docs(_limits)
