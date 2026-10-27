"""`udf_bench`: runs the bench program (bench/bench_main.mojo) in one build
action and keeps its stdout, one JSON object, as the target's output.

The action stages `data` in one directory (the runtime libraries and the
layout node_worker.so finds beside itself), changes into it and runs the
binary from its runnable directory with `args`, then the run id: the first
line of the `run_id` file. The run id file is an input of this action only,
so bumping it re-runs the bench and nothing else; every welded test keeps
its action key and stays a cache hit. Numbers from a cache hit are the
numbers of the run that wrote them, and their `run_id` says which.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _udf_bench_impl(ctx):
    runnable = ctx.attrs.binary[MojoRunnableInfo]
    data = ctx.actions.symlinked_dir(ctx.label.name + ".data", ctx.attrs.data)
    out = ctx.actions.declare_output(ctx.label.name + ".json")
    ctx.actions.run(
        cmd_args(
            ctx.attrs._run[RunInfo],
            cmd_args(runnable.run_dir.project(runnable.binary), hidden = runnable.run_dir),
            data,
            out.as_output(),
            ctx.attrs.run_id,
            ctx.attrs.args,
        ),
        category = "udf_bench",
    )
    return [DefaultInfo(default_output = out)]

_udf_bench = rule(
    impl = _udf_bench_impl,
    doc = "Runs a bench mojo_binary over a staged data directory and keeps its stdout (one JSON object) as the output, with the run id file's first line as the last argument.",
    attrs = {
        "args": attrs.list(attrs.string(), default = [], doc = "Arguments before the run id."),
        "binary": attrs.dep(providers = [MojoRunnableInfo], doc = "The bench program (a mojo_binary)."),
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}, doc = "{path in the data directory: file or directory}; the program runs there."),
        "run_id": attrs.source(doc = "A file whose first line names the run."),
        "_run": attrs.exec_dep(default = "komira//src/tests/helpers/komira_udf_spike_node_worker:bench_run", providers = [RunInfo]),
    },
)

udf_bench = declares_docs(_udf_bench)
