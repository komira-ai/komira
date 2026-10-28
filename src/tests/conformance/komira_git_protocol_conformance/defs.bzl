"""The pinned git's transcripts that komira_git_protocol_conformance reads,
the oracle of komira_git's protocol code.

`git_transcripts` runs capture (capture.zig) in one build action with the git
distribution of //third_party/git. The output is a directory, one subdirectory
per scenario (capture.zig says which and what each holds).
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _transcripts_impl(ctx):
    out = ctx.actions.declare_output("transcripts", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._capture[RunInfo],
            _out(ctx.attrs.git),
            out.as_output(),
        ),
        category = "git_transcripts",
    )
    return [DefaultInfo(default_output = out)]

_git_transcripts = rule(
    impl = _transcripts_impl,
    doc = "Runs capture with the git distribution `git`: real git on both ends of fetch (protocol v2) and push (receive-pack) over ssh (this program as the ssh), recording the bytes each way and the server's state. The output is a directory.",
    attrs = {
        "git": attrs.exec_dep(doc = "The git distribution, //third_party/git:git."),
        "_capture": attrs.exec_dep(default = "komira//src/tests/conformance/komira_git_protocol_conformance:capture", providers = [RunInfo]),
    },
)

git_transcripts = declares_docs(_git_transcripts)
