# komira_bench_sum_emit

A benchmark of SQL `sum()` over INT32 and INT64 columns through `run_sql`: what
a user of the SQL door pays for the type the engine answers a sum in.

## What it measures

One table `t(k INT64, v INT64, i INT32)` of 16 million rows (flag `--rows`) in
Parquet row groups of one million (`--row-group-rows`), generated in memory
from fixed formulas and written into the output directory. Five statements, each
run once unrecorded and then `--runs` times (at least 5, default 9), timed
around `run_sql` alone, at each thread count of `--threads` (default 1 and 8):

| statement | what it is |
|---|---|
| `select sum(v) from t` | ungrouped sum of an INT64 column |
| `select sum(i) from t` | ungrouped sum of an INT32 column |
| `select k, sum(v) from t group by k` | 16 groups, INT64 |
| `select k, sum(i) from t group by k` | 16 groups, INT32 |
| `select min(v) from t` | control: no sum, moves with the machine only |

The values are small, so no statement overflows INT64. The answer of every run
is checked against totals the generator computes, whatever type the engine
declares the sum in (INT64, or DECIMAL(38, 0)); the JSON records the declared
type of each result column, so a build of any engine version can be compared
with another.

## Running it

On the build farm, never on a shared box:

    ./buck2 build komira//src/komira_bench_sum_emit:sum_emit_bench[sum_emit.json] --show-output

The JSON holds, per statement and thread count, the median, the quartiles and the
range of the wall time in milliseconds and every run. To compare two versions of
the engine, build this target from a checkout of each, with `label` set (the
target's `label` attribute) so the files say which is which, and compare medians
with their interquartile ranges. The control statement tells drift of the farm
host from a change of the engine.

## How far to trust it

The wall time includes the Parquet decode, the filter-free scan and the merge of
the workers' partials, not only the sum. A difference smaller than the
interquartile range of either side is not a result. It runs in memory-resident
data of one file on one host class; it says nothing about a table that does not
fit the page cache.
