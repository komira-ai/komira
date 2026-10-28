"""One mopm: every package's `mopm-toolchain.toml` names the same mopm version.

Each package built with `mojo_package` names its mopm in its own
`mopm-toolchain.toml`. The lock check holds each table to its own `mopm.lock`
and the toolchain check holds each lock to its own file, so a package put back
on another mopm together with its own relock stays green; nothing compares
packages with each other. This lint does: the Zig tool
//tools/build/lint/one_mopm reads every `mopm-toolchain.toml` of the tree,
in a remote action with no shell, and refuses unless they all name one
version, naming each package that differs and both versions. Its verdict is a
`ValidationInfo`, so `./buck2 build //...` (and the pull request's check) fails
on a finding.

The release flow's version is compared too: `release` is the label the README
e2e installs mopm with (`MOPM` in release/readme_e2e/packages.bzl,
`toolchains//:mopm_<major>_<minor>_<patch>`), and the version it names must be
the one the packages name.

Fixture trees that exist to test a version (the mopm_migrate fixtures, which
pin the tool's default) are `except` rows of `list` (path, reason), so a new
one is a visible change; a row whose file is gone is a finding. An empty set
is a finding, not a pass.

The files are the repository's committed files as the build graph holds them,
as for the timing ledger (timing.bzl): `tree` (the root doc_tree), `cells` and
`files` (single files at a path of the caller's choosing, for a planted case).
`expect` turns a target into a planted case: it passes only when the check
refuses, with findings holding each expected text.
"""

load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load(":doc_tree.bzl", "DocTreeInfo", "declares_doc_trees", "declares_docs")

_LABEL_PREFIX = "toolchains//:mopm_"

def mopm_version_of_label(label):
    """The version a mopm toolchain label names: `toolchains//:mopm_0_0_86` is `0.0.86`."""
    if not label.startswith(_LABEL_PREFIX):
        fail("one_mopm: `{}` is not a mopm toolchain label (`{}<major>_<minor>_<patch>`)".format(label, _LABEL_PREFIX))
    parts = label[len(_LABEL_PREFIX):].split("_")
    if len(parts) != 3 or not all([p.isdigit() for p in parts]):
        fail("one_mopm: `{}` is not a mopm toolchain label (`{}<major>_<minor>_<patch>`)".format(label, _LABEL_PREFIX))
    return ".".join(parts)

def _one_mopm_impl(ctx):
    files = dict(ctx.attrs.tree[DocTreeInfo].files)
    for prefix, tree in ctx.attrs.cells.items():
        for path, f in tree[DocTreeInfo].files.items():
            files[prefix + "/" + path] = f
    for path, f in ctx.attrs.files.items():
        if path in files:
            fail("one_mopm {}: `files` stages {}, which the tree holds already".format(ctx.label, path))
        files[path] = f
    if ctx.attrs.list not in files:
        fail("one_mopm {}: the list {} is not a file of the tree".format(ctx.label, ctx.attrs.list))
    staged = ctx.actions.copied_dir("tree", files)
    result = ctx.actions.declare_output("validation.json")
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "--tree",
        staged,
        "--list",
        ctx.attrs.list,
        "--release",
        mopm_version_of_label(ctx.attrs.release),
    )
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    cmd.add("--out", result.as_output())
    ctx.actions.run(cmd, category = "one_mopm")
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = "one_mopm", validation_result = result)]),
    ]

one_mopm_rule = rule(
    impl = _one_mopm_impl,
    doc = "Every `mopm-toolchain.toml` of `tree` (a doc_tree target: the root one holds every file of the cell), of `cells` (another cell's doc_tree, at its path) and of `files` (path: source) that `list` (its path in that tree; a TSV of except, path, reason) does not except names one mopm version, and it is the one `release` (a mopm toolchain label) names. The verdict is a validation; with `expect`, it passes only when the findings hold each expected text.",
    attrs = {
        "cells": attrs.dict(attrs.string(), attrs.dep(providers = [DocTreeInfo]), default = {}),
        "expect": attrs.list(attrs.string(), default = []),
        "files": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "list": attrs.string(),
        "release": attrs.string(),
        "tree": attrs.dep(providers = [DocTreeInfo]),
        "_tool": attrs.exec_dep(default = "komira//tools/build/lint/one_mopm:one_mopm", providers = [RunInfo]),
    },
)

def _one_mopm(**kwargs):
    # Only in a cell whose packages declare doc_trees (doc_tree.bzl,
    # declares_doc_trees): komira's own checkout, or a cell a repository using
    # komira names in `[komira] doc_tree_cells`.
    if not declares_doc_trees():
        return
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)
    one_mopm_rule(**kwargs)

one_mopm = declares_docs(_one_mopm)
