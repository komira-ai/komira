"""The pinned git's packs that komira_git_pack_conformance reads, the oracle
of komira_git's pack reader.

`git_packs` runs gen_packs (gen_packs.zig) in one build action with the pinned git
(gen_packs.zig says what each file is). The git distribution is an `exec_dep`,
so the action runs the git built for the machine it runs on. The output is
one directory, staged as test data.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _git_packs_impl(ctx):
    out = ctx.actions.declare_output("packs", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._gen[RunInfo],
            out.as_output(),
            _out(ctx.attrs.git),
        ),
        category = "git_packs",
    )
    return [DefaultInfo(default_output = out)]

_git_packs = rule(
    impl = _git_packs_impl,
    doc = "Runs gen_packs with the pinned git: a directory of packs, their indexes, `git verify-pack -v` listings and `git cat-file --batch` dumps.",
    attrs = {
        "git": attrs.exec_dep(doc = "komira//third_party/git:git, the checked git distribution."),
        "_gen": attrs.exec_dep(default = "komira//src/tests/conformance/komira_git_pack_conformance:gen_packs", providers = [RunInfo]),
    },
)

git_packs = declares_docs(_git_packs)
