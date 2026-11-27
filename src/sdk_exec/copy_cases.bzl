"""`copy_cases`: the Parquet, CSV and JSON files komira writes for a cases
file of COPY statements, as one build action, for DuckDB to read back.

The action runs `copy_runner` (copy_runner/main.mojo) with the cases file,
a directory holding `inputs` (each at its name), and the output directory:

    copy_runner --cases <cases.sql> --input-dir <inputs> --out-dir <out>

Every name in `outputs` (each case's destination file, or the directory a
partitioned case writes, and `counts.tsv`,
the `Count` each case answered) is a sub-target `[<name>]`, which a
`sql_oracle` takes as an input in its dict form. A refused case fails the
action. Nothing here reads an environment variable; the program takes its
settings as flags.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _copy_cases_impl(ctx):
    runner = ctx.attrs.runner[MojoRunnableInfo]
    inputs = ctx.actions.copied_dir("inputs", ctx.attrs.inputs)
    out = ctx.actions.declare_output("komira", dir = True)
    ctx.actions.run(
        cmd_args(
            runner.command,
            "--cases",
            ctx.attrs.cases,
            "--input-dir",
            inputs,
            "--out-dir",
            out.as_output(),
        ),
        category = "copy_cases",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {o: [DefaultInfo(default_output = out.project(o))] for o in ctx.attrs.outputs},
    )]

_copy_cases = rule(
    impl = _copy_cases_impl,
    doc = "Runs `runner` (the copy_runner program) over the COPY lines of `cases`, reading `inputs` ({name: source}) and writing the files and counts.tsv named in `outputs`, each a sub-target `[<name>]`.",
    attrs = {
        "cases": attrs.source(),
        "inputs": attrs.dict(attrs.string(), attrs.source()),
        "outputs": attrs.list(attrs.string()),
        "runner": attrs.exec_dep(providers = [MojoRunnableInfo]),
    },
)

def _copy_cases_macro(**kwargs):
    # The oracle that reads these files runs the pinned DuckDB, which is
    # linux x86_64; the files are written on the same platform.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _copy_cases(**kwargs)

copy_cases = declares_docs(_copy_cases_macro)
