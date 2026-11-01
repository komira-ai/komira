"""`ci_aggregate`: one target that builds every check.

`//ci:pr` (ci/BUCK) is a `ci_aggregate` whose `deps` are the roots of the
check set and whose `tests` are the standalone tests among them; both lists
are GENERATED (ci/targets.bzl, written by `targets.bxl:generate`) and held
complete by `guard.bxl:check`: a target can depend on listed labels only,
and no rule can query the graph.

Building it builds every dependency's outputs (so a library's welded tests,
which are build actions, run) and runs their validations (the lints).
`buck2 test //ci:pr` runs the standalone tests it names.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    outputs = []
    for dep in ctx.attrs.deps:
        info = dep[DefaultInfo]
        outputs += info.default_outputs
        outputs += info.other_outputs
    return [DefaultInfo(other_outputs = outputs)]

_ci_aggregate_rule = rule(
    impl = _impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = [], doc = "The roots of the check set."),
    },
    doc = "Builds the outputs of every dep. See aggregate.bzl.",
)

# Each rule a BUCK file calls declares its package's doc_tree.
ci_aggregate = declares_docs(_ci_aggregate_rule)
