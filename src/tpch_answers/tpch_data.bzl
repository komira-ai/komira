"""`tpch_sf1_data`: TPC-H scale factor 1 and DuckDB's answers to its 22
queries, as cached build actions on the farm. Nothing is committed and no data
is shipped; the bytes are a function of the pinned DuckDB, its pinned tpch
extension and the staging settings below, so the action's cache key is the
identity of the data.

Two actions:

  1. `tpch_stage`: the staging program (bench_data's staging of the pinned
     DuckDB and its tpch extension) writes the eight tables under `data/`,
     in the layout `data/tpch/sf1/<table>.parquet`. It does not depend on the
     answers program, so a change to that program stages nothing again.
  2. `tpch_answers`: the answers program verifies and locks those files, then
     runs q1 .. q22 of the corpus in the same pinned DuckDB and writes
     `answers/answers.txt` (recorded signatures, the text bench_duckdb reads
     as references) and `answers/locks/tpch_sf1.lock` (the size and sha256 of
     every staged file and a fingerprint of them, which the answers file
     names) and `answers/queries/q<N>.sql`, the text of each of the 22 queries
     as the corpus holds it.

Sub-targets, for a test that consumes the data:

  [data]         the directory holding `tpch/sf1/<table>.parquet`
  [answers.txt]  the recorded answers
  [lock]         the data lock
  [queries]      the directory of `q1.sql` .. `q22.sql`

The default output is the `answers/` directory, so building the target builds
both actions. Nothing reads an environment variable but the actions' fixed
`LC_ALL`, `TZ` and library path; every setting is a flag.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/sql:defs.bzl", "DuckdbInfo")

def _impl(ctx):
    dist = ctx.attrs._duckdb[DuckdbInfo]
    stage = ctx.attrs.stage[MojoRunnableInfo]
    answers = ctx.attrs.answers[MojoRunnableInfo]
    ext = ctx.attrs.tpch_extension[DefaultInfo].default_outputs[0]
    env = {
        "LC_ALL": "C",
        "LD_LIBRARY_PATH": cmd_args(dist.native_libs, format = "{}/lib"),
        "TZ": "UTC",
    }

    data = ctx.actions.declare_output("data", dir = True)
    ctx.actions.run(
        cmd_args(
            stage.command,
            "--duckdb",
            dist.binary,
            "--tpch-extension",
            ext,
            "--cache-dir",
            data.as_output(),
            "--memory-limit-gib",
            str(ctx.attrs.stage_memory_gib),
        ),
        env = env,
        category = "tpch_stage",
    )

    out = ctx.actions.declare_output("answers", dir = True)
    ctx.actions.run(
        cmd_args(
            answers.command,
            "--duckdb",
            dist.binary,
            "--cache-dir",
            data,
            "--out-dir",
            out.as_output(),
            "--memory-limit-gib",
            str(ctx.attrs.answers_memory_gib),
        ),
        env = env,
        category = "tpch_answers",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {
            "answers.txt": [DefaultInfo(default_output = out.project("answers.txt"))],
            "data": [DefaultInfo(default_output = data)],
            "lock": [DefaultInfo(default_output = out.project("locks/tpch_sf1.lock"))],
            "queries": [DefaultInfo(default_output = out.project("queries"))],
        },
    )]

_tpch_sf1_data = rule(
    impl = _impl,
    doc = "Stages TPC-H sf1 with the pinned DuckDB and records its answers to q1..q22, on the farm.",
    attrs = {
        "answers": attrs.dep(providers = [MojoRunnableInfo]),
        "answers_memory_gib": attrs.int(default = 8),
        "stage": attrs.dep(providers = [MojoRunnableInfo]),
        "stage_memory_gib": attrs.int(default = 8),
        "tpch_extension": attrs.dep(),
        "_duckdb": attrs.exec_dep(providers = [DuckdbInfo], default = "komira//third_party/duckdb:duckdb"),
    },
)

def tpch_sf1_data(**kwargs):
    # The pinned DuckDB is linux x86_64.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _tpch_sf1_data(**kwargs)
