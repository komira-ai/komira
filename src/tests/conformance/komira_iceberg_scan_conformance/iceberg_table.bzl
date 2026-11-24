"""`iceberg_table`: an Iceberg table directory written by a Mojo program, as
one build action, for DuckDB to read and for tests to stage.

The action runs `writer` (a `mojo_binary`; runner/main.mojo) with the output
directory:

    <writer> --out-dir <out>

The program writes the table's files under `<out>`. Every entry of `outputs`
({sub-target name: path under <out>}) is a sub-target `[<name>]`, which a
`sql_oracle` takes as an input in its dict form and a test as `test_data`;
a path the program did not write fails the action. Nothing here reads an
environment variable; the program takes its setting as a flag.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _iceberg_table_impl(ctx):
    writer = ctx.attrs.writer[MojoRunnableInfo]
    out = ctx.actions.declare_output("table", dir = True)
    ctx.actions.run(
        cmd_args(writer.command, "--out-dir", out.as_output()),
        category = "iceberg_table",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {name: [DefaultInfo(default_output = out.project(path))] for name, path in ctx.attrs.outputs.items()},
    )]

_iceberg_table = rule(
    impl = _iceberg_table_impl,
    doc = "Runs `writer` (a mojo_binary) with `--out-dir`; every {name: path} of `outputs` is a sub-target `[<name>]` of the file the program wrote at that path under the directory.",
    attrs = {
        "outputs": attrs.dict(attrs.string(), attrs.string()),
        "writer": attrs.exec_dep(providers = [MojoRunnableInfo]),
    },
)

def _iceberg_table_macro(**kwargs):
    # The files are read by the pinned DuckDB, which is linux x86_64.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _iceberg_table(**kwargs)

iceberg_table = declares_docs(_iceberg_table_macro)
