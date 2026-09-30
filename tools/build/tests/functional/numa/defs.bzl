"""Exercises tools/build/mojo/numa_guard.sh against made-up NUMA topologies,
in a remote action. Nothing here needs a multi-NUMA worker: the guard reads its topology
from `--root`, so every verdict (run or refuse) is checked on any worker.

numa_gate_run runs a mojo_multi_numa_test's own `buck2 test` command minus
its NUMA guard (MojoGateRunInfo) in one action, so the gate runner is reached
with exactly the arguments the rule gives it, on any worker.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoGateRunInfo", "MojoToolchainInfo")

def _impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("guard_cases.txt")
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", ctx.attrs.script, tc.busybox, tc.numa_guard, report.as_output()),
        category = "numa_guard_cases",
    )
    return [DefaultInfo(default_output = report)]

numa_guard_cases = rule(
    impl = _impl,
    attrs = {
        "script": attrs.source(),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)

def _gate_run_impl(ctx):
    tc = ctx.attrs._toolchain[MojoToolchainInfo]
    report = ctx.actions.declare_output("gate_run.txt")
    # Always succeeds; the report's first line is `rc <exit status>`, then the
    # runner's output, for run_tests.sh to judge and quote.
    script = 'out=$1; shift; rc=0; "$@" > gate_run.log 2>&1 || rc=$?; { echo "rc $rc"; cat gate_run.log; } > "$out"'
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", "-c", script, "gate_run", report.as_output(), ctx.attrs.test[MojoGateRunInfo].command),
        category = "numa_gate_run",
    )
    return [DefaultInfo(default_output = report)]

numa_gate_run = rule(
    impl = _gate_run_impl,
    attrs = {
        "test": attrs.dep(providers = [MojoGateRunInfo]),
        "_toolchain": attrs.toolchain_dep(default = "toolchains//:mojo", providers = [MojoToolchainInfo]),
    },
)
