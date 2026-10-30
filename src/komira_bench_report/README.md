# komira_bench_report

The result model and the report of a benchmark run. It holds what a run measured (a cell per query, with how komira's run ended, whether the values matched the reference, and the ratio to DuckDB), the fingerprint of the machine and the inputs, the `result.json` writer and strict reader, the counts and geomean per suite, and the human table. It is pure data and text: it runs no engine, starts no process, reads no file and no environment variable. A harness fills a `BenchResult` and hands it to this package.

The rules it enforces:

- A ratio exists only for a cell whose run ended in `EXEC_OK`, whose values are `IDENTICAL` or a `DEPARTURE`, and that was measured on both sides. The table shows a dash for any other cell, and the reader refuses a document that gives one.
- A `DEPARTURE:<reason>` cell has exactly equal values and declared column types that differ in a way the Arrow representation forces (the table of allowed departures in `komira_bench_duckdb`; today HUGEINT as DECIMAL(38,0)). It keeps its ratio and enters the geomean, but its verdict is `DEPARTURE` whatever the ratio, never `PASS`; the summary counts it in `n_departure` (not in `n_pass`, `n_fail` or `n_value_identical`) and the headline says `DEPARTURE n/m` when there is one. The table shows `DEPART` in the values column and `DEPARTURE(<reason>)` as the verdict. A `DEPARTURE` is a value verdict and carries its reason like `UNVERIFIED` carries its cause.
- A cell komira refused (`UNSUPPORTED:<construct>`), failed, or whose values diverged stays in the denominator of every count. Only the geomean is over the cells that have a ratio, and the line that reports it says how many.
- A PASS count is always printed with the pass threshold and the DuckDB version and pin beside it. The threshold is a parameter of the run, not a constant.
- No run is dropped from the data. A side holds every run of every sweep, first run first (`runs_ms`), and the page faults each run took where they were measured, and `result.json` writes all of them. Faults are all or nothing per side: if any run of a side, its first run included, had no reading, the whole side's faults are `null`, never partial and never zero. A cell states its numbers in separate columns, and what they are is defined here and nowhere else (`STEADY_STATE_DEFINITION`): the **first run** is the first execution of the query on that engine, the run that checks the answer, executed before the sweeps (`first_run` in the file, with its own time and page faults): it is what a user's first query pays. What each first run includes differs by engine, so read the ratio with that in mind: DuckDB's is measured marker to marker in its child process, the query plus the rendering of every result row as JSON to stdout; komira's is the host clock around `arm.run` with rows, the execution plus the conversion of Arrow batches to rows. Neither includes the harness's own parsing of the answer, and the two overheads differ, so a large result set skews the first-run ratio (and a timed run materializes nothing, so neither overhead is in the sweeps). The runner alternates which engine's check run goes first, by the query's position; the **steady-state time** (`min_of_sweep_median`, `steady_state_ms`) is the median of all the reps of each sweep, and the least of those medians over the sweeps (nothing is excluded from it: every rep is in `runs_ms` and in the median), and the least of those medians over the sweeps; the **spread** is how far apart those sweep medians are, in percent of the least. A cell has a steady-state ratio (komira over DuckDB, on the steady-state times) and a first-run ratio (on the first runs); the verdict and the PASS count follow the steady-state ratio, and the headline states the steady-state geomean and median with the first-run ones beside them.
- The environment fingerprint holds an opaque host class (lower-case letters, digits, `-` and `_`), the CPU model, the core count, the memory, the OS, the komira version, the DuckDB version, binary digest and pin, and the digest of the dataset lock. A `/`, a `\` or a control character in any of those text fields, or in the construct of `UNSUPPORTED`, the cause of `UNVERIFIED` or the reason of `DEPARTURE`, is refused, and so is an `@` in the environment's text fields unless a space stands on both sides of it (`Intel(R) Xeon(R) CPU E5-4669 v4 @ 2.20GHz`, as `/proc/cpuinfo` writes it, is accepted; `user@host`, `a @b`, `a@ b`, `@host` and `cpu @` are not), and so is a dot in the host class, so a path, a dotted host name or an address is not written. The package cannot tell a class from a host name that has no such character: the harness must pass a class it chose (for example an instance type) and never the output of `hostname`, and must pass an OS and a CPU model that name no host (the kernel release, not `uname -a`).
- `exit_code` is 0 only when every cell ran and its values were verified (`IDENTICAL` or a `DEPARTURE`). A run of mode `komira` or `duckdb` verifies nothing, so its exit code is 1 by this rule; a harness that wants a single-engine run to exit 0 reads `n_ran` and `n_cells` of the summary instead.
- A `Side` refuses a time of zero or less. A query faster than the timer resolution is not a result this package can hold: the harness clamps it to the resolution or leaves the side out and records the cell as failed.
- A cell's ratio is printed to three places, so a ratio just above the threshold is not shown as equal to it. A number of 1e15 or more is printed as `>=1e15`.

## Examples

The statistics of a cell, on timings (every rep of a sweep counts):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_bench_report import geomean, min_of_sweep_medians, ratio_of

var first = List[Float64]()
first.append(50.0)
first.append(10.0)
first.append(12.0)
first.append(11.0)
var second = List[Float64]()
second.append(50.0)
second.append(9.0)
second.append(30.0)
second.append(10.0)
var sweeps = List[List[Float64]]()
sweeps.append(first^)
sweeps.append(second^)
assert_equal(min_of_sweep_medians(sweeps), 11.5)
assert_equal(ratio_of(15.0, 10.0), 1.5)
var ratios = List[Float64]()
ratios.append(1.0)
ratios.append(4.0)
ratios.append(16.0)
assert_equal(Int(geomean(ratios) + 0.5), 4)
```

A cell with its derived ratio and verdict, the median and spread helpers, and the text of its verdicts:

```mojo module
from std.testing import assert_equal, assert_true
from komira_bench_report import (
    Cell,
    Side,
    StageOutcome,
    ValueVerdict,
    cell_verdict,
    derive_ratio,
    maximum,
    median,
    minimum,
    spread_pct,
    sweep_median,
    sweep_medians,
)

def sweeps_of(m1: Float64, m2: Float64) -> List[List[Float64]]:
    var a = List[Float64]()
    a.append(99.0)
    a.append(m1)
    a.append(m1)
    var b = List[Float64]()
    b.append(99.0)
    b.append(m2)
    b.append(m2)
    var out = List[List[Float64]]()
    out.append(a^)
    out.append(b^)
    return out^


def main() raises:
    var komira = Optional[Side](Side.from_sweeps(10, sweeps_of(3.0, 5.0)))
    var duckdb = Optional[Side](Side.from_sweeps(10, sweeps_of(2.0, 2.0)))
    var cell = Cell.build(
        String("tpch/q01"), String("tpch"), 3, StageOutcome.exec_ok(),
        komira.copy(), duckdb.copy(), ValueVerdict.identical(), 1.05,
    )
    assert_equal(cell.ratio.value(), 1.5)
    assert_equal(cell.verdict, String("FAIL"))
    assert_equal(cell_verdict(cell.ratio, 1.5), String("PASS"))

    var diverged = Cell.build(
        String("tpch/q02"), String("tpch"), 3, StageOutcome.exec_ok(),
        komira.copy(), duckdb.copy(), ValueVerdict.divergent(), 1.05,
    )
    assert_true(not Bool(diverged.ratio))
    assert_true(not Bool(derive_ratio(
        StageOutcome.unsupported(String("window frame")), komira, duckdb,
        ValueVerdict.identical(),
    )))
    assert_equal(diverged.verdict, String("NO_RATIO"))
    assert_equal(StageOutcome.unsupported(String("window frame")).text(), String("UNSUPPORTED:window frame"))
    assert_equal(ValueVerdict.unverified(String("not run")).text(), String("UNVERIFIED:not run"))

    var reps = List[Float64]()
    reps.append(100.0)
    reps.append(1.0)
    reps.append(2.0)
    reps.append(3.0)
    assert_equal(sweep_median(reps), 2.5)
    assert_equal(median(reps), 2.5)
    assert_equal(minimum(reps), 1.0)
    assert_equal(maximum(reps), 100.0)
    assert_equal(spread_pct(reps), 9900.0)
    var one = List[List[Float64]]()
    one.append(reps.copy())
    assert_equal(sweep_medians(one)[0], 2.5)
```

A result, written as `result.json` text, read back strictly, summarized and rendered:

```mojo module
from std.testing import assert_equal, assert_true
from komira_bench_report import (
    BenchResult,
    Cell,
    DuckDbPin,
    Environment,
    RESULT_SCHEMA,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    Side,
    StageOutcome,
    ValueVerdict,
    exit_code,
    format_fixed,
    pad_left,
    pad_right,
    parse_result_json,
    render_table,
    result_json,
    summarize,
    summary_json,
    summary_line,
    validate_cell,
    validate_result,
    write_result_json,
)

def side(rows: Int64, ms: Float64) raises -> Optional[Side]:
    var reps = List[Float64]()
    reps.append(99.0)
    reps.append(ms)
    reps.append(ms)
    var sweeps = List[List[Float64]]()
    sweeps.append(reps.copy())
    sweeps.append(reps^)
    return Optional[Side](Side.from_sweeps(rows, sweeps.copy(), Optional[Float64](99.0)))


def main() raises:
    var cells = List[Cell]()
    cells.append(Cell.build(
        String("tpch/q01"), String("tpch"), 3, StageOutcome.exec_ok(),
        side(4, 3.0), side(4, 2.0), ValueVerdict.identical(), 2.0,
    ))
    cells.append(Cell.build(
        String("tpch/q02"), String("tpch"), 3,
        StageOutcome.unsupported(String("window frame")), Optional[Side](),
        side(9, 5.0), ValueVerdict.unverified(String("not run")), 2.0,
    ))
    var run = RunInfo(
        String("both"), String("sf"), 1, 2, 3,
        String(STATISTIC_MIN_OF_SWEEP_MEDIAN), 8, 2.0,
    )
    var lock = String("a1b2c3d4")
    while lock.byte_length() < 64:
        lock += String("0")
    var env = Environment(
        String("class-a"), String("Example CPU"), 8, 17179869184,
        String("Linux 6.1"), String("1.0.0"),
        DuckDbPin(String("v1.5.6"), lock.copy(), String("PINNED")), lock^,
    )
    var result = BenchResult(run^, env^, cells^)

    validate_result(result)
    validate_cell(result.cells[0], result.run)
    var text = write_result_json(result)
    assert_true(text.startswith(String('{"schema":"') + String(RESULT_SCHEMA)))
    assert_equal(result_json(result).serialize(), text)
    var back = parse_result_json(text)
    assert_equal(write_result_json(back), text)

    var summary = summarize(back)
    assert_equal(summary.overall.n_cells, 2)
    assert_equal(summary.overall.n_pass, 1)
    assert_equal(exit_code(summary), 1)
    assert_true(summary_json(back).serialize() != String(""))
    assert_equal(
        summary_line(summary.overall, back.run.pass_max, back.env.duckdb),
        String(
            "PASS 1/2 at <= 2.0x vs duckdb v1.5.6 (PINNED) | steady-state geomean 1.50x over 1/2 value-verified"
            " | steady-state median 1.50x | first-run geomean 1.00x median 1.00x"
        ),
    )
    var table = render_table(back)
    assert_true(table.find(String("NO_RATIO(UNSUPPORTED:window frame)")) >= 0)
    assert_equal(format_fixed(1.005, 1), String("1.0"))
    assert_equal(pad_left(String("7"), 3), String("  7"))
    assert_equal(pad_right(String("7"), 3), String("7  "))
```

Anything the schema does not allow is refused, naming where:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_bench_report import parse_result_json

var message = String()
try:
    _ = parse_result_json('{"schema":"komira-bench-result/3"}')
except e:
    message = String(e)
assert_true(message.startswith(String("BenchResultError: result: missing member")))
```

## The schema

`result.json` is one line of compact JSON (`komira-bench-result/3`) with these members, in this order:

| member | what |
|---|---|
| `schema` | the string `komira-bench-result/3`; `komira-bench-result/2` is also read (see below); `komira-bench-result/1` is refused with a message naming the versions read, since its numbers mean something else; any other is refused |
| `run` | `mode` (`both`, `komira`, `duckdb`), `scale` (`{"sf": N}` or `{"rows": N}`), `sweeps`, `reps` (at least 2), `statistic` (`min_of_sweep_median`), `threads`, `pass_max` |
| `env` | `hostclass`, `cpu_model`, `cores`, `mem_total_bytes`, `os`, `komira_version`, `duckdb` (`version`, `sha256`, `pin`: `PINNED` or `UNPINNED:<reason>`), `dataset_lock_sha256` |
| `cells` | per cell: `id` (`<suite>/<name>`), `suite`, `reps`, `stage` (`EXEC_OK`, `BIND_FAIL`, `EXEC_FAIL`, `UNSUPPORTED:<construct>`), `komira` and `duckdb` (null or `rows`, `ms` (the steady-state time), `ms_per_sweep` (the median of all the reps of each sweep), `spread_pct`, `runs_ms` (every run of every sweep, first run first), `minor_faults` and `major_faults` (the page faults each run took, in the shape of `runs_ms`, or null where they were not measured), `first_run` (`ms`, `minor_faults`, `major_faults`: the check run, counts both integers or both null, null exactly when the sweeps' are)), `value` (`IDENTICAL`, `DIVERGENT`, `DEPARTURE:<reason>`, `UNVERIFIED:<cause>`), `ratio` (the steady-state ratio: a number or null), `verdict` (`PASS`, `FAIL`, `DEPARTURE`, `NO_RATIO`), `first_ratio` (komira's first run over DuckDB's: a number or null), `check_runs` (null for a timed cell; for a cell that was not timed, `komira` and `duckdb`, each null or `ms`, `minor_faults`, `major_faults`: the check runs that were executed, with the cell still unverified) |
| `summary` | the counts (`n_cells`, `n_ran`, `n_value_identical`, `n_ratio`, `n_pass`, `n_fail`, `n_departure`), geomean and median of the steady-state ratios, `n_first_ratio` with the geomean and median of the first-run ratios, a `per_suite` list and the `headline`, all recomputed by the reader from the cells: counts and text must be equal, the floats must agree to 1e-9 (the geomean goes through the platform's `log` and `exp`, so it is not bit-exact across platforms), and the geomean figure in the headline must be the rounding of the recomputed or the stored geomean |

A result of schema `komira-bench-result/2` (the change that added `n_departure` and the DEPARTURE verdict) is still read. It holds no runs, no page faults, no first run and no check runs, no `first_ratio`, and its headline calls the geomean and median unqualified; its summary is compared with the summary of that schema. Its times were computed differently: the median of each sweep left the sweep's first rep out, where schema 3 takes all the reps, so a schema 2 number and a schema 3 number of the same run can differ. A side read from it has empty `runs_ms` and no first run, a cell has no `first_ratio`, the table shows dashes in the first-run columns and the summary has no first-run figure. A schema 2 document that carries `runs_ms`, `first_run`, `check_runs` or `first_ratio`, or a schema 3 one that lacks them, is refused. A result read from schema 2 is not written back: a side without its runs is refused by the writer, so schema 3 never holds a side whose runs or first run are missing.

The reader refuses a missing or unknown member at any level, a member named twice, an integer written as a float, a time that is not the least of its sweeps, runs that are not the run's sweeps by reps or whose medians after each first run are not `ms_per_sweep`, page faults that are negative, not integers, of another shape than the runs, present for only one of minor and major, or present for the first run and not for the sweeps (or the reverse), a first run that is missing or whose time is not positive, check runs on a cell that was timed (or with a time that is not positive, or one of two counts), a first-run ratio that is not komira's first run over DuckDB's, a komira side on a cell whose run was refused, a ratio on a cell that may not have one, values marked `IDENTICAL` or `DIVERGENT` with no DuckDB side or outside a run of mode `both` (and `IDENTICAL` with unequal row counts), a DuckDB side in a run of mode `komira`, no DuckDB side on a cell komira ran in a run of mode `both`, a control character in a cell id, a verdict that does not follow from the ratio and `pass_max`, a cell id outside its suite, and a summary that is not the cells' summary.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_bench_report`, version 0.1.0
(`mopm.toml`). The library is `src/komira_bench_report/`, its tests are `tests/`. It depends on one package,
`komira_json`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_json", version = "0.1" }`),
so the `.conda` of this package records `mojo-komira_json >=0.1,<0.2` as a dependency and holds none of that
package's files: installing `komira_bench_report` installs `komira_json` with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependency, as `mopm lock` writes them (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_json`, and exists only once every test has passed.
After any change to a source, a test, a manifest of this package or of the sibling, run `buildrules mojo sync` with
both packages staged, commit what it writes, and build `komira//src/komira_bench_report:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_bench_report-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`),
which therefore exists only once the tests have passed. `:conda_holds` reads it back and requires the one dependency
`mojo-komira_json >=0.1,<0.2`. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that
file, not a build action.

`:komira_bench_report` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
