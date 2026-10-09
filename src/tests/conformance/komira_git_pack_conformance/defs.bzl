"""The pinned git's packs that komira_git_pack_conformance reads, the oracle
of komira_git's pack reader.

`git_packs` runs gen_packs.sh in one build action with the pinned git
(gen_packs.sh says what each file is). The git distribution is an `exec_dep`,
so the action runs the git built for the machine it runs on. The output is
one directory, staged as test data. The checks in `checks` (the script's
shell_lint) are validations of the target.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _git_packs_impl(ctx):
    # The script is copied under buck-out first: a source's path in an action
    # differs between a standalone checkout and a repository that mounts
    # komira as a cell, and so would the action's digest.
    staged = ctx.actions.copied_dir("gen_srcs", {ctx.attrs.script.short_path: ctx.attrs.script})
    out = ctx.actions.declare_output("packs", dir = True)
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            _out(ctx.attrs._busybox),
            out.as_output(),
            _out(ctx.attrs.git),
        ),
        category = "git_packs",
    )
    return [DefaultInfo(default_output = out)]

_git_packs = rule(
    impl = _git_packs_impl,
    doc = "Runs gen_packs.sh with the pinned git: a directory of packs, their indexes, `git verify-pack -v` listings and `git cat-file --batch` dumps.",
    attrs = {
        "checks": attrs.list(attrs.dep(), default = [], doc = "Validations of the target (the script's shell_lint)."),
        "git": attrs.exec_dep(doc = "komira//third_party/git:git, the checked git distribution."),
        "script": attrs.source(doc = "gen_packs.sh"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

git_packs = declares_docs(_git_packs)
