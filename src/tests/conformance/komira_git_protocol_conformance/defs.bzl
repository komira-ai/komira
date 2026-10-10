"""The pinned git's transcripts that komira_git_protocol_conformance reads,
the oracle of komira_git's protocol code.

`git_transcripts` runs capture.sh in one build action with the pinned busybox
and the git distribution of //third_party/git. The output is a directory, one
subdirectory per scenario (capture.sh says which and what each holds). The
checks in `checks` (the script's shell_lint) are validations of the target.
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
