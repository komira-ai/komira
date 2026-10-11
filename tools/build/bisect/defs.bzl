"""bisect's scenarios (README.md, "Tests").

`bisect_scenario` is one build action: the scenario binary
(testing/scenario.zig) builds a throwaway repository with the pinned git,
runs the bisect under test against it with testing/fake_buck2.zig as its
buck2, checks the verdict, and writes its output only when every check held.
The public `:bisect` is built behind every scenario.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _bisect_scenario_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    ctx.actions.run(
        cmd_args(
            ctx.attrs.scenario[RunInfo],
            "--scenario",
            ctx.label.name,
            "--bisect",
            ctx.attrs.bisect[RunInfo],
            "--fake-buck2",
            ctx.attrs.fake_buck2[RunInfo],
            "--git-dist",
            _out(ctx.attrs.git),
            "--out",
            out.as_output(),
        ),
        category = "bisect_scenario",
    )
    return [DefaultInfo(default_output = out)]

_bisect_scenario = rule(
    impl = _bisect_scenario_impl,
    doc = "One bisect scenario, named by the target (testing/scenario.zig's table), run as a build action: the target exists only if the scenario's checks held.",
    attrs = {
        "bisect": attrs.exec_dep(providers = [RunInfo], doc = "The bisect under test (`:bisect_unchecked`)."),
        "fake_buck2": attrs.exec_dep(providers = [RunInfo], doc = "The buck2 stand-in, testing/fake_buck2.zig."),
        "git": attrs.exec_dep(doc = "komira//third_party/git:git, the pinned git distribution."),
        "scenario": attrs.exec_dep(providers = [RunInfo], doc = "testing/scenario.zig, built."),
    },
)

bisect_scenario = declares_docs(_bisect_scenario)
