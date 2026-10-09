# bench_report

`komira//tools/build/bench_report` is a Zig tool that checks bench reports
against their schema and merges them into one parallelism table. A bench report is the `[report]`
of a report test: a `py_test` with a `run_id`
([Report tests](../python/README.md#report-tests)).

```
bench_report --out <table.md> --report <report.json> [--report <report.json>]...
```

The table is written only if every report passes the check. On a refusal
nothing is written, and standard error has one of these (the first refusal
only):

| exit | message |
|---|---|
| 2 | `bench_report: <why>`, and the usage line under it |
| 1 | `bench_report: <file>: cannot read: <error name>`, or `cannot read: not UTF-8` |
| 1 | `bench_report: <file>: not JSON: byte <offset>: <why>` |
| 1 | `bench_report: <file>: <where>: <why>`, from the schema check (`<where>` a key path such as `rows[0].latency_ns`) |
| 1 | `bench_report: <variant> <function> N=<n> is in <target> and in <target>`, the earlier report's target first |
| 1 | `bench_report: cannot write <file>: <error name>` |

## The rule

```
load("@komira//tools/build/bench_report:defs.bzl", "bench_table")

bench_table(
    name = "udf_table",
    reports = [":a_bench[report]", ":b_bench[report]"],
)
```

`bench_table` runs `bench_report` as a build action over `reports`, in the
order given, and writes `<name>.md`. A report that fails the check fails the
action, so the table exists only for good reports.

## The schema, `komira-bench-report-1`

The full list of keys is at the top of [`src/report.zig`](src/report.zig). Every
key is required, and a key the schema does not name is refused, so a
misspelt field is an error rather than a dropped number.

- `run_id` and `target`, written by the py_test runner.
- `host`: the affinity size (`cpus`), the CPU model, the cgroup's `cpu.max`,
  the load average, and how much the cgroup's `nr_throttled` and
  `throttled_usec` grew during the run.
- `build`: the optimization level of each component, whether it was a
  coverage build, and the versions of interpreters and runtimes.
- `rows`, one per variant, function and thread count: rows, batches,
  runtime calls, wall time, user and system CPU time, involuntary context
  switches, memory (`pss`, `uss`, `rss_delta_per_thread`, `memory_report`:
  at least one), and the latency of a call in
  nanoseconds (warm-up batches discarded, at least 30 samples, min, median,
  p90, max, in order).
- A row's `calls` must equal its `batches`: a runtime is called once per
  batch, so a runtime called once per row is refused. This replaces a
  latency ceiling, which would flake.
- The memory kinds name no language or runtime: what a runtime holds
  outside Arrow buffers (an interpreter's heap among it) is what its
  `memory_report` entry returns.
- Counts are whole JSON numbers from 0 to 2^53. The JSON reader
  ([`src/json.zig`](src/json.zig)) refuses a key written twice, NaN,
  infinities, a number out of the range of a double and input that is not
  UTF-8. A report test's own runner refuses the same in what its script
  writes, before the report exists
  ([Report tests](../python/README.md#report-tests)), so a key written twice
  is never dropped on the way.

## The table

[`src/table.zig`](src/table.zig) makes one line per variant, function and
thread count N: N = 1, 4 and 16, and every other N a report holds.

| column | value |
|---|---|
| rows/s | rows / wall time |
| rows/s per thread | rows/s / N |
| efficiency | rows/s(N) / (N x rows/s(1)), with N = 1 of the same variant and function; `-` without one |
| memory | each memory kind of the row, in MiB |
| latency ns | median / p90 |
| flags | `noisy`: user + system CPU time is below 0.8 x wall x N; `throttled`: the cgroup throttled the run |

A row with more threads than the CPUs of its own report's host reads
`not measured: <cpus> cpus`. A missing N reads the same when it is above the
most CPUs of any report holding that variant and function, with that report's
CPUs and run id (the first such report, in the order given); any other missing
N reads `missing`, since a host with enough CPUs ran the function. The same
variant, function and N in two rows is an error. Groups (a variant and a
function) keep the order in which the reports, in the order given, first
hold them; they are not sorted. When the reports hold more than one run id, a
line above the table names each once, sorted (`The reports are of 2 runs:
r1, r2.`). Below the table, one line per report, in the order given, gives
its host and build facts.

## Tests

`:bench_report` is published behind `:bench_report_unit`, `zig test` of
`src/main.zig`, whose test block imports every `src/*_test.zig`: the JSON
reader, each schema refusal and the reports that must pass (equal latency
quantiles among them), the table's numbers and flags (a row at N equal to
the host's CPUs among them), its order (reports given in neither ascending
nor descending order) and its runs line, and the command line, each message
above among it. Every comparison and
range has a case that passes at its boundary and one refused just past it,
and every field the check or the table reads has a case where its value
differs from the other fields' and between rows and reports, so a value
read from the wrong field, row or report changes the result.
`report_demo` and `report_wiring` in
[`src/tests/helpers/komira_test_python`](../../../src/tests/helpers/komira_test_python/README.md)
check the whole path: a report test's `[report]`, the `bench_table` made
of it against a golden table, and a `bench_table` of two report tests (the
second's variant sorts first) against another, in the order its `reports`
give.
