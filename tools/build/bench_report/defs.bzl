"""`bench_table`: bench reports merged into the parallelism table.

A build action runs `bench_report` over the `reports` (each the `[report]`
of a `py_test` with a `run_id`, in the order given) and writes
`<name>.md`. The action fails, naming the file and the field, if any report
does not pass the schema check, so the table exists only for good reports.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _bench_table_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".md")
    cmd = cmd_args(ctx.attrs._bench_report[RunInfo], "--out", out.as_output())
    for r in ctx.attrs.reports:
        cmd.add("--report", r)
    ctx.actions.run(cmd, category = "bench_table")
    return [DefaultInfo(default_output = out)]

_bench_table = rule(
    impl = _bench_table_impl,
    doc = "The parallelism table of `reports` (report files, in order), written by `bench_report` to `<name>.md`; fails unless every report passes the schema check.",
    attrs = {
        "reports": attrs.list(attrs.source()),
        "_bench_report": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/bench_report:bench_report"),
    },
)

def _bench_table_macro(**kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _bench_table(**kwargs)

# Declares its package's doc_tree (tools/build/lint/doc_tree.bzl), as every
# rule a BUCK file calls does.
bench_table = declares_docs(_bench_table_macro)
