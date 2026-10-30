"""`q6_phase_probe`: stage TPC-H scale factor 1, then run the Q6 phase probe
on it, both as build actions on the farm.

Two actions:

  1. `q6_stage`: the staging program (`komira_bench_q6_stage_main`) runs the
     benchmark's staging of komira_bench_data with the pinned DuckDB and its
     tpch extension and writes the eight tables of TPC-H scale factor 1 under
     `cache/` (the layout `cache/tpch/sf1/<table>.parquet`). It does not depend
     on the probe program, so a change to the probe does not stage again.
  2. `q6_probe`: the probe program reads `cache/tpch/sf1/lineitem.parquet`,
     runs Q6 warm at each thread count and writes `probe/phases.json` and
     `probe/plan.txt`.

The outputs are `[phases.json]` and `[plan.txt]` (sub-targets of the target);
the target's default output is the `probe/` directory.

The DuckDB is the one `komira//third_party/duckdb:duckdb` pins, started by the
staging program with the library path the pin names. Nothing here reads an
environment variable; every setting is a flag of the two programs.
"""

load("@komira//tools/build/mojo:providers.bzl", "MojoRunnableInfo")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/sql:defs.bzl", "DuckdbInfo")

def _impl(ctx):
    dist = ctx.attrs._duckdb[DuckdbInfo]
    stage = ctx.attrs.stage[MojoRunnableInfo]
    probe = ctx.attrs.probe[MojoRunnableInfo]
    ext = ctx.attrs.tpch_extension[DefaultInfo].default_outputs[0]

    cache = ctx.actions.declare_output("cache", dir = True)
    ctx.actions.run(
        cmd_args(
            stage.command,
            "--duckdb",
            dist.binary,
            "--tpch-extension",
            ext,
            "--cache-dir",
            cache.as_output(),
            "--memory-limit-gib",
            str(ctx.attrs.stage_memory_gib),
        ),
        env = {
            "LC_ALL": "C",
            "LD_LIBRARY_PATH": cmd_args(dist.native_libs, format = "{}/lib"),
            "TZ": "UTC",
        },
        category = "q6_stage",
    )

    out = ctx.actions.declare_output("probe", dir = True)
    ctx.actions.run(
        cmd_args(
            probe.command,
            "--cache-dir",
            cache,
            "--out-dir",
            out.as_output(),
            "--threads",
            ctx.attrs.threads,
            "--runs",
            str(ctx.attrs.runs),
            "--memory-limit-gib",
            str(ctx.attrs.memory_limit_gib),
            "--expect-tpch-sf1",
        ),
        category = "q6_probe",
    )
    return [DefaultInfo(
        default_output = out,
        sub_targets = {
            "cache": [DefaultInfo(default_output = cache)],
            "phases.json": [DefaultInfo(default_output = out.project("phases.json"))],
            "plan.txt": [DefaultInfo(default_output = out.project("plan.txt"))],
        },
    )]

_q6_phase_probe = rule(
    impl = _impl,
    doc = "Stages TPC-H sf1 with the pinned DuckDB and runs the Q6 phase probe on it, on the farm.",
    attrs = {
        "memory_limit_gib": attrs.int(default = 32),
        "probe": attrs.dep(providers = [MojoRunnableInfo]),
        "runs": attrs.int(default = 9),
        "stage": attrs.dep(providers = [MojoRunnableInfo]),
        "stage_memory_gib": attrs.int(default = 8),
        "threads": attrs.string(default = "1,8,32,49,88"),
        "tpch_extension": attrs.dep(),
        "_duckdb": attrs.exec_dep(providers = [DuckdbInfo], default = "komira//third_party/duckdb:duckdb"),
    },
)

def q6_phase_probe(**kwargs):
    # The pinned DuckDB is linux x86_64.
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    _q6_phase_probe(**kwargs)
