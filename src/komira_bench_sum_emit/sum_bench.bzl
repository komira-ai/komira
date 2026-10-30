"""`sum_emit_bench`: run the sum-emit bench program on the farm.

One action: the bench program generates its table, runs the statements and
writes `bench/sum_emit.json`. The output is `[sum_emit.json]` (a sub-target);
the target's default output is the `bench/` directory. Every setting is a flag
of the program; nothing here reads an environment variable.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _impl(ctx):
    bench = ctx.attrs.bench[MojoRunnableInfo]
    out = ctx.actions.declare_output("bench", dir = True)
    ctx.actions.run(
        cmd_args(
            bench.command,
            "--out-dir",
            out.as_output(),
            "--label",
            ctx.attrs.label,
            "--threads",
            ctx.attrs.threads,
            "--runs",
            str(ctx.attrs.runs),
            "--rows",
            str(ctx.attrs.rows),
            "--memory-limit-gib",
            str(ctx.attrs.memory_limit_gib),
        ),
        category = "sum_emit_bench",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {
            "sum_emit.json": [DefaultInfo(default_output = out.project("sum_emit.json"))],
        },
    )]

_sum_emit_bench = rule(
    impl = _impl,
    doc = "Runs the SQL sum() INT32/INT64 bench on the farm.",
    attrs = {
        "bench": attrs.dep(providers = [MojoRunnableInfo]),
        "label": attrs.string(default = ""),
        "memory_limit_gib": attrs.int(default = 32),
        "rows": attrs.int(default = 16000000),
        "runs": attrs.int(default = 9),
        "threads": attrs.string(default = "1,8"),
    },
)

def sum_emit_bench(**kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _sum_emit_bench(**kwargs)
