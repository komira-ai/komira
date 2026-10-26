"""The wall-clock ledger: no Zig file reads a clock or sleeps beyond the counts its list states.

A test never asserts on elapsed time and never waits on a deadline that fails
it; the gate's tests move the clock they run on (tools/build/run/testkit.zig).
The Zig files of the tree are scanned for the ways to read real time or wait
for it (src/rules.zig names them); each file's count per token must equal its
row in the list (`use`, path, token, count, reason): more is a new use of real
time, fewer is a row to lower, so the list only shrinks. The check is the Zig
tool //tools/build/lint/timing, run in a remote action with no shell; its
verdict is a `ValidationInfo`, so `./buck2 build //...` (and the pull request's
check) fails on a finding.

The files are the repository's committed files as the build graph holds them,
as for the no-shell list (no_shell.bzl): `tree` (the root doc_tree),
`dotfiles`, `cells` and `files` (single files at a path of the caller's
choosing, for a planted case). `expect` turns a target into a planted case: it
passes only when the check refuses, with findings holding each expected text.

Not checked here, and held by review: a new row needs a reason review accepts
(a fixture that must block until it is killed is one; an assertion on elapsed
time is not). A scan reads spellings, not meaning.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_doc_trees", "declares_docs")

def _timing_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for d in ctx.attrs.dotfiles:
        files.update(d[DocTreeInfo].files)
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    for path, f in ctx.attrs.files.items():
        if path in files:
            fail("timing {}: `files` stages {}, which the tree holds already".format(ctx.label, path))
        files[path] = f
    if ctx.attrs.list not in files:
        fail("timing {}: the list {} is not a file of the tree".format(ctx.label, ctx.attrs.list))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    cmd = cmd_args(ctx.attrs._tool[RunInfo], "--tree", staged, "--list", ctx.attrs.list)
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    cmd.add("--out", result.as_output())
    ctx.actions.run(cmd, category = "timing")
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "timing", validation_result = result)]),
    ]

timing_rule = rule(
    impl = _timing_impl,
    doc = "The Zig files of `tree` (a doc_tree target: the root one holds every file of the cell), of the doc_tree targets in `dotfiles`, of `cells` (another cell's doc_tree, at its path) and of `files` (path: source) read real time (a clock, a sleep) no more than the counts of `list` (its path in that tree; a TSV of kind, path, token, count, reason) say. The verdict is a validation; with `expect`, it passes only when the findings hold each expected text.",
    attrs = {
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        "dotfiles": attrs.list(attrs.dep(providers = [DocTreeInfo]), default = []),
        "expect": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "list": attrs.string(),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/timing:timing", providers = [RunInfo]),
    },
)

def _timing(**kwargs):
    # Only in a cell whose packages declare doc_trees (doc_tree.bzl,
    # declares_doc_trees): komira's own checkout, or a cell a repository using
    # komira names in `[komira] doc_tree_cells`.
    if not declares_doc_trees():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    timing_rule(**kwargs)

timing = declares_docs(_timing)
