"""`iceberg_write_files`: the Iceberg tables komira writes, as one build
action, for DuckDB's iceberg extension to read back.

The action runs `iceberg_write_runner` (iceberg_write_runner/main.mojo) with
the output directory:

    iceberg_write_runner --out-dir <out>

Each entry of `outputs` is `{sub-target name: path under <out>}`: the file the
runner wrote there (a table's metadata JSON, manifest lists, manifests and
data files, `db/<table>/metadata/...` and `db/<table>/data/...`) is the
sub-target `[<name>]`, which a `sql_oracle` takes as an input in its dict form.
A write the sink refuses fails the action. Nothing here reads an environment
variable; the program takes its settings as flags.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")

def _iceberg_write_files_impl(ctx):
    runner = ctx.attrs.runner[MojoRunnableInfo]
    out = ctx.actions.declare_output("komira", dir = True)
    ctx.actions.run(
        cmd_args(
            runner.command,
            "--out-dir",
            out.as_output(),
        ),
        category = "iceberg_write_files",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {name: [DefaultInfo(default_output = out.project(path))] for name, path in ctx.attrs.outputs.items()},
    )]

_iceberg_write_files = rule(
    impl = _iceberg_write_files_impl,
    doc = "Runs `runner` (the iceberg_write_runner program), which writes tables through the Iceberg write sink and the files named in `outputs` ({sub-target name: path under the output directory}), each a sub-target `[<name>]`.",
    attrs = {
        "outputs": attrs.dict(attrs.string(), attrs.string()),
        "runner": attrs.exec_dep(providers = [MojoRunnableInfo]),
    },
)

def _iceberg_write_files_macro(**kwargs):
    # The oracle that reads these files runs the pinned DuckDB, which is
    # linux x86_64; the files are written on the same platform.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _iceberg_write_files(**kwargs)

iceberg_write_files = declares_docs(_iceberg_write_files_macro)
