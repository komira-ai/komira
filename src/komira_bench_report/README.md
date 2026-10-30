# komira_bench_report

The result model and the report of a benchmark run. It holds what a run measured (a cell per query, with how komira's run ended, whether the values matched the reference, and the ratio to DuckDB), the fingerprint of the machine and the inputs, the `result.json` writer and strict reader, the counts and geomean per suite, and the human table. It is pure data and text: it runs no engine, starts no process, reads no file and no environment variable. A harness fills a `BenchResult` and hands it to this package.

The rules it enforces:

- A ratio exists only for a cell whose run ended in `EXEC_OK`, whose values are `IDENTICAL`, and that was measured on both sides. The table shows a dash for any other cell, and the reader refuses a document that gives one.
- A cell komira refused (`UNSUPPORTED:<construct>`), failed, or whose values diverged stays in the denominator of every count. Only the geomean is over the cells that have a ratio, and the line that reports it says how many.
- A PASS count is always printed with the pass threshold and the DuckDB version and pin beside it. The threshold is a parameter of the run, not a constant.
- The time of a cell is `min_of_sweep_median`: rep 0 of each sweep is dropped, each sweep is reduced to its median, and the cell's time is the least of those.
- The environment fingerprint holds an opaque host class (lower-case letters, digits, `-` and `_`), the CPU model, the core count, the memory, the OS, the komira version, the DuckDB version, binary digest and pin, and the digest of the dataset lock. A `/`, a `\` or a control character in any of those text fields, or in the construct of `UNSUPPORTED` or the cause of `UNVERIFIED`, is refused, and so is an `@` in the environment's text fields unless a space stands on both sides of it (`Intel(R) Xeon(R) CPU E5-4669 v4 @ 2.20GHz`, as `/proc/cpuinfo` writes it, is accepted; `user@host`, `a @b`, `a@ b`, `@host` and `cpu @` are not), and so is a dot in the host class, so a path, a dotted host name or an address is not written. The package cannot tell a class from a host name that has no such character: the harness must pass a class it chose (for example an instance type) and never the output of `hostname`, and must pass an OS and a CPU model that name no host (the kernel release, not `uname -a`).
- `exit_code` is 0 only when every cell ran and its values were verified. A run of mode `komira` or `duckdb` verifies nothing, so its exit code is 1 by this rule; a harness that wants a single-engine run to exit 0 reads `n_ran` and `n_cells` of the summary instead.
- A `Side` refuses a time of zero or less. A query faster than the timer resolution is not a result this package can hold: the harness clamps it to the resolution or leaves the side out and records the cell as failed.
- A cell's ratio is printed to three places, so a ratio just above the threshold is not shown as equal to it. A number of 1e15 or more is printed as `>=1e15`.

## Examples

The statistics of a cell, on timings (rep 0 first in each sweep):

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
assert_equal(min_of_sweep_medians(sweeps), 10.0)
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
    drop_first_rep,
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
    assert_equal(len(drop_first_rep(reps)), 3)
    assert_equal(sweep_median(reps), 2.0)
    assert_equal(median(reps), 2.5)
    assert_equal(minimum(reps), 1.0)
    assert_equal(maximum(reps), 100.0)
    assert_equal(spread_pct(drop_first_rep(reps)), 200.0)
    var one = List[List[Float64]]()
    one.append(reps.copy())
    assert_equal(sweep_medians(one)[0], 2.0)
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
    return Optional[Side](Side.from_sweeps(rows, sweeps))


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
        String("PASS 1/2 at <= 2.0x vs duckdb v1.5.6 (PINNED) | geomean 1.50x over 1/2 value-verified | median 1.50x"),
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
    _ = parse_result_json('{"schema":"komira-bench-result/1"}')
except e:
    message = String(e)
assert_true(message.startswith(String("BenchResultError: result: missing member")))
```

## The schema

`result.json` is one line of compact JSON (`komira-bench-result/1`) with these members, in this order:

| member | what |
|---|---|
| `schema` | the string `komira-bench-result/1`; any other is refused |
| `run` | `mode` (`both`, `komira`, `duckdb`), `scale` (`{"sf": N}` or `{"rows": N}`), `sweeps`, `reps` (at least 2), `statistic` (`min_of_sweep_median`), `threads`, `pass_max` |
| `env` | `hostclass`, `cpu_model`, `cores`, `mem_total_bytes`, `os`, `komira_version`, `duckdb` (`version`, `sha256`, `pin`: `PINNED` or `UNPINNED:<reason>`), `dataset_lock_sha256` |
| `cells` | per cell: `id` (`<suite>/<name>`), `suite`, `reps`, `stage` (`EXEC_OK`, `BIND_FAIL`, `EXEC_FAIL`, `UNSUPPORTED:<construct>`), `komira` and `duckdb` (null or `rows`, `ms`, `ms_per_sweep`, `spread_pct`), `value` (`IDENTICAL`, `DIVERGENT`, `UNVERIFIED:<cause>`), `ratio` (a number or null), `verdict` (`PASS`, `FAIL`, `NO_RATIO`) |
| `summary` | the counts, geomean and median of the ratios, a `per_suite` list and the `headline`, all recomputed by the reader from the cells: counts and text must be equal, the floats must agree to 1e-9 (the geomean goes through the platform's `log` and `exp`, so it is not bit-exact across platforms), and the geomean figure in the headline must be the rounding of the recomputed or the stored geomean |

The reader refuses a missing or unknown member at any level, a member named twice, an integer written as a float, a time that is not the least of its sweeps, a komira side on a cell whose run was refused, a ratio on a cell that may not have one, values marked `IDENTICAL` or `DIVERGENT` with no DuckDB side or outside a run of mode `both` (and `IDENTICAL` with unequal row counts), a DuckDB side in a run of mode `komira`, no DuckDB side on a cell komira ran in a run of mode `both`, a control character in a cell id, a verdict that does not follow from the ratio and `pass_max`, a cell id outside its suite, and a summary that is not the cells' summary.

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
