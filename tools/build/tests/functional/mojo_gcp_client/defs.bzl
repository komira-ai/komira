"""`gen_check` and `tests_check`: what a mojo_gcp_client generated and ran, checked as build actions.

`gen` is a generated directory, here a library's `<name>_gen` target (what the
generator writes now; the library is built from the committed directory, which
`<name>_fresh` holds equal to it). The action
fails unless the directory holds exactly `files`, no file holds a string of
`absent`, some file holds each string of `present` (which keeps an
absence check from passing over an empty output), and each file named in
`identical` is byte for byte the file it maps to. `buck2 build` of the
target IS the check. `tests_check` is described above its definition.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _gen_check_impl(ctx):
    if not ctx.attrs.present:
        fail("{}: `present` is empty; an absence check alone passes over an empty output".format(ctx.label))
    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "gen-check",
            ctx.attrs.gen,
            mark.as_output(),
            " ".join(sorted(ctx.attrs.files)),
            str(len(ctx.attrs.absent)),
            str(len(ctx.attrs.identical)),
            ctx.attrs.absent,
            [cmd_args(name, src) for name, src in sorted(ctx.attrs.identical.items())],
            ctx.attrs.present,
        ),
        category = "gcp_client_gen_check",
    )
    return [DefaultInfo(default_output = mark)]

_gen_check = rule(
    impl = _gen_check_impl,
    attrs = {
        "absent": attrs.list(attrs.string(), default = []),
        "files": attrs.list(attrs.string()),
        "gen": attrs.source(allow_directory = True),
        "identical": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "present": attrs.list(attrs.string()),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    },
)

gen_check = declares_docs(_gen_check)

def _tests_check_impl(ctx):
    if not ctx.attrs.expect:
        fail("{}: `expect` is empty; name the welded tests the library must run".format(ctx.label))
    mark = ctx.actions.declare_output("checked")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._act[RunInfo],
            "tests-check",
            mark.as_output(),
            " ".join(sorted(ctx.attrs.expect)),
            ctx.attrs.markers[DefaultInfo].default_outputs,
        ),
        category = "gcp_client_tests_check",
    )
    return [DefaultInfo(default_output = mark)]

_tests_check = rule(
    impl = _tests_check_impl,
    attrs = {
        "expect": attrs.list(attrs.string()),
        "markers": attrs.dep(),
        "_act": attrs.exec_dep(default = "tests//tools:tests_act", providers = [RunInfo]),
    },
)

# `tests_check`: which welded tests a library ran, checked as a build action.
# `markers` is a library's `[tests]` sub-target, whose outputs are its pass
# markers. The action fails unless their names are exactly `expect` and each
# marker records a PASS. gen_check reads the generated
# directory and cannot see whether the layout probe is welded; this can.
tests_check = declares_docs(_tests_check)
