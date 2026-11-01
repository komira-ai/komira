"""A target that shows the environment `salted` gives an action, in its
provider dump (`buck2 audit providers`): the scenario selftest/bench_salt.zig
reads it with `-c komira.bench_salt` unset, empty and set.
"""

load("@komira//tools/build/bench_salt:bench_salt.bzl", "salted")
load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _impl(ctx):
    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(type = "custom", command = ["true"], env = salted({"KOMIRA_BENCH_SALT_FIXTURE": "1"})),
    ]

_salted_env = rule(impl = _impl, attrs = {})

salted_env = declares_docs(_salted_env)
