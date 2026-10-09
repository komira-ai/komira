"""The pinned git's outputs that komira_git_conformance reads: its
transcripts, the oracle of komira_git's protocol code, and its packs, the
oracle of komira_git's pack reader.

`git_transcripts` runs capture.sh in one build action with the pinned busybox
and the git distribution of //third_party/git. The output is a directory, one
subdirectory per scenario (capture.sh says which and what each holds). The
checks in `checks` (the script's shell_lint) are validations of the target.

`git_packs` runs gen_packs.sh in one build action with the pinned git
(gen_packs.sh says what each file is). The git distribution is an `exec_dep`,
so the action runs the git built for the machine it runs on. The output is
one directory, staged as test data.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _transcripts_impl(ctx):
    # The script is copied under buck-out first: a source's path in an action
    # differs between a standalone checkout and a repository that mounts
    # komira as a cell, and so would the action's digest.
    staged = ctx.actions.copied_dir("capture_srcs", {ctx.attrs.script.short_path: ctx.attrs.script})
    out = ctx.actions.declare_output("transcripts", dir = True)
    ctx.actions.run(
        cmd_args(
            _out(ctx.attrs._busybox),
            "sh",
            staged.project(ctx.attrs.script.short_path),
            _out(ctx.attrs._busybox),
            _out(ctx.attrs.git),
            out.as_output(),
        ),
        category = "git_transcripts",
    )
    return [DefaultInfo(default_output = out)]

_git_transcripts = rule(
    impl = _transcripts_impl,
    doc = "Runs capture.sh with the git distribution `git`: real git on both ends of fetch (protocol v2) and push (receive-pack) over file://, recording the bytes each way and the server's state. The output is a directory.",
    attrs = {
        "checks": attrs.list(attrs.dep(), default = [], doc = "Validations of the target (the script's shell_lint)."),
        "git": attrs.exec_dep(doc = "The git distribution, //third_party/git:git."),
        "script": attrs.source(doc = "capture.sh"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

git_transcripts = declares_docs(_git_transcripts)

def _git_packs_impl(ctx):
    # Staged under buck-out for the same reason as capture.sh above.
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
        "git": attrs.exec_dep(doc = "komira//third_party/git:git, the checked git distribution."),
        "script": attrs.source(doc = "gen_packs.sh"),
        "_busybox": attrs.exec_dep(default = "komira//tools/build/toolchains:busybox"),
    },
)

git_packs = declares_docs(_git_packs)
