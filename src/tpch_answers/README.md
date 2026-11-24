# tpch_answers

TPC-H scale factor 1 as a cached farm build, with DuckDB's answers to the 22 corpus queries recorded as signatures. Nothing is committed and nothing ships: the data and the answers are build outputs, keyed by their inputs, so the farm computes them once and every target that consumes them reads the cached copy.

**Derived from TPC-H; not comparable to published TPC-H results.** The data is DuckDB's `dbgen` output, not the specification's generator, and the answers are what the pinned DuckDB returns for the corpus text over it.

## The target

```text
./buck2 build komira//src/tpch_answers:tpch_sf1
./buck2 build komira//src/tpch_answers:tpch_sf1[answers.txt] --show-output
```

| sub-target | holds |
|---|---|
| `[data]` | a directory with `tpch/sf1/<table>.parquet` for the eight tables, the layout `bench_data` and `bench_runner` read (`DECIMAL(15,2)` and `DATE` kept) |
| `[answers.txt]` | the recorded answers, one record per query, in `bench_duckdb`'s reference format |
| `[lock]` | the size and sha256 of every staged file and a fingerprint of them (`bench_data`'s lock) |
| `[queries]` | a directory of `q1.sql` .. `q22.sql`: each query's corpus text, byte for byte, written by the answers program next to the answers it recorded for them, so a consumer that is not written in Mojo runs the text the answers belong to |

A test that consumes them names the sub-target as an input (`test_data`, or the `data` of another build action). Two actions make them (`tpch_data.bzl`): `tpch_stage` stages the tables with the pinned DuckDB and its pinned `tpch` extension through `bench_data`, as the Q6 phase probe does; `tpch_answers` then verifies and locks those files and records the answers in the same pinned DuckDB. A change to the answers program does not stage again.

## Determinism

The staging runs DuckDB on one thread with insertion order preserved, so the same pinned DuckDB and extension write the same bytes; the answers run on one thread too, so the sums of doubles do not depend on the worker. The answers file names the lock's fingerprint (`# data lock fingerprint`), so a recorded answer says which bytes it was computed over. The action's cache key is the identity of the data: it changes only when the DuckDB pin, the extension pin, the staging program or its settings change.

## The answers file

```text
# derived from TPC-H; not comparable to published TPC-H results
# suite tpch sha256 <digest of the 22 query texts>
# duckdb v<version>
# data lock fingerprint <fingerprint>
format 3
query tpch/q1
rows 4
order 0:a:l,1:a:l
column ...
end
```

`bench_duckdb.parse_references` reads it (the `#` lines are skipped). Per query it holds the row count, the ORDER BY keys as result column positions (`keys.mojo`), and for every column its order-independent signature (count, nulls, sums, extremes, exact decimal sum, hash) and declared type; compare an engine's result with `signature_of` and `compare_signatures`, and check its row order with `check_order`. The recorder checks DuckDB's own rows against the keys before it records them, so a key table that does not match a query fails the action, not a consumer. A query that returns no rows fails the action as well (such an answer records no columns).

## The library

| name | what it is |
|---|---|
| `produce_tpch_sf1_answers`, `ANSWERS_FILE`, `QUERIES_DIR` | verify and lock the staged files, start DuckDB on them, record the 22 answers, write the answers file, the lock and the query texts; an existing answers file is never replaced |
| `record_answers`, `register_tables`, `tpch_header` | the answers text of a suite over a `DuckDbSession`; one view per table; the comment lines on top |
| `tpch_order_keys` | the keys of a query's ORDER BY |
| `parse_answer_args`, `AnswerSettings`, `DEFAULT_MEMORY_GIB` | the flags of `komira_tpch_answers_main`: `--duckdb FILE --cache-dir DIR --out-dir DIR [--memory-limit-gib N]` |

```mojo
from std.testing import assert_equal
from tpch_answers import DEFAULT_MEMORY_GIB, QUERIES_DIR, parse_answer_args, tpch_order_keys

var keys = tpch_order_keys("q3")
assert_equal(len(keys), 2)
assert_equal(keys[0].column, 1)          # revenue, descending
assert_equal(len(tpch_order_keys("q6")), 0)

# Query texts sit under QUERIES_DIR of an answers directory, one file per query.
var q1_text_file = String("out/") + String(QUERIES_DIR) + String("/q1.sql")
assert_equal(q1_text_file, "out/queries/q1.sql")

# The flags of the answers program; the memory limit defaults to 8 GiB.
var args = List[String]()
for word in ["--duckdb", "duckdb", "--cache-dir", "data", "--out-dir", "out"]:
    args.append(String(word))
var settings = parse_answer_args(args)
assert_equal(settings.cache_dir, "data")
assert_equal(settings.memory_limit_gib, DEFAULT_MEMORY_GIB)
```

## What it does not do

- It stages only scale factor 1, and only on linux x86_64 (the pinned DuckDB is that build).
- It records no timing and compares nothing: a consumer holds the engine.
- It does not record the data's checksums in the manifest: `bench_data` records those after a measured, repeated staging, and until then the lock of a run names the bytes it used.
