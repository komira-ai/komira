# komira_bench_runner

The program that runs one benchmark query on both engines and writes the result. For each query it:

1. starts the pinned DuckDB (`komira_bench_duckdb`) with the thread count and memory limit of the run, and registers the dataset as one view per Parquet file;
2. prepares the komira arm with the same tables, thread count and memory limit;
3. runs the query on DuckDB in JSON mode (the reference rows) and on the arm with its rows materialized;
4. compares the two by signature (exact for integers and text, a relative tolerance for floats) and, when the query has `ORDER BY` keys, checks the arm's row order;
5. times the query only if the answers match: warm (sweeps of reps) and, if asked and possible, cold (the file cache dropped before every rep of either engine). Every run is kept: nothing is run to be thrown away and no run is dropped from the result, the first of each sweep included. Each run is recorded with its time and the minor and major page faults its engine's process took during it;
6. fills a `BenchResult` (`komira_bench_report`) per temperature and writes it.

It implements these parts of `docs/design/lowering_and_pipeline.md` section 7.4: both engines at the same thread count and memory limit, cold and warm reported separately, results checked before timing under a stated float tolerance, refusals listed. It does not implement the disclosure rule: shortcuts both engines take (a `COUNT(*)` from the footer) and options that cost throughput for reproducibility (grain state) are not marked.

**Derived from TPC-H; not comparable to published TPC-H results.** Where a run reads the `tpch` suite, the console report says so once (`suite tpch-derived: ...`); no number this program writes is a TPC-H result. The suite id in data stays `tpch`. ClickBench query text is not shipped or assumed here: the program takes the query text as a file.

## The komira arm

`EngineArm` is the whole interface of the engine under test:

```text
label() -> String
prepare(tables, threads, memory_limit_bytes) raises
run(query, materialize) raises -> ArmAnswer
close() raises
```

`run` ends one of four ways, which are the stages of the result: rows (`ARM_ROWS`; `ArmAnswer.with_rows` for the check run, `ArmAnswer.counted` for a timed run that consumes the result as the engine's own sink would), a refusal (`ARM_REFUSED`, with the construct as a token: `UNSUPPORTED:<construct>` in the result), a bind failure or an execution failure. A raise is a fault of the arm and ends the run.

The query is passed whole (`QuerySpec`: suite, id, dataset, text, `ORDER BY` keys, and `sha256()` of the text), so an arm can serve a query from the text (`run_sql`) or from a plan it holds for `query.key()`. `RefusalArm` refuses every query with one construct (`no_engine_arm` by default); it is for the tests of the runner. The line that builds the arm in `entrypoint.mojo` is the seam, and it builds `KomiraArm`.

`KomiraArm` (`komira_arm.mojo`) is the komira engine through `komira_sdk_exec`:

- `prepare` builds an `EngineContext` with `EngineOptions(worker_count = threads, memory_budget_bytes = memory_limit_bytes)` and registers every table as a Parquet table. A table the engine cannot register is a raise that names it (the run ends). Preparing again first closes the context it holds.
- `run` hands `query.text` to `run_sql`. Batches are the answer: the typed rows when `materialize`, the row count alone otherwise (the result is still executed in full). A refusal is `UNSUPPORTED:<step>.<CODE>` in the result, for example `UNSUPPORTED:lower.LOWERING_UNCUTTABLE_NODE` (a join today): the step that refused and the code that starts the engine's message; a message with no code gives the step alone (`parse`). The token never holds the engine's text because the result refuses a token with a path in it; the whole message is in the arm's `last_refusal`. A result column type the conversion does not map is a refusal `UNSUPPORTED:result_type_unsupported`, never a wrong value.
- A refusal from `run_sql` is recorded by what it means (`outcome_of_refusal`), because the engine reports every failure as a refusal naming a step:

| the engine's refusal | recorded as |
|---|---|
| any `parse` refusal; a lowering refusal (`LOWERING_*`, a join today); `EXECUTE_UNSUPPORTED_*`; `OPTIMIZE_UNRESOLVED_SCALAR`; `STATEMENT_NOT_A_QUERY`; a binder message starting `SQL not supported` | `UNSUPPORTED:<token>`: unserved, not a failure |
| any other refusal at `bind` (unknown column or table, a type error) | `BIND_FAIL` |
| any other refusal at `optimize`, `lower` or `execute` (an INT64 sum out of range, a memory budget denied, a pool not whole) | `EXEC_FAIL` |

  The engine's message of a `BIND_FAIL` or `EXEC_FAIL` is on the console (the failed list), never in the result.
- `close` drops the context. A cold rep closes and prepares again.

The rows are the cells `komira_bench_duckdb` makes from DuckDB's JSON output, so the two signatures are built from the same kinds of cell (`convert.mojo`). DuckDB's shell quotes DECIMAL, HUGEINT, UHUGEINT and UBIGINT values; the session reads them by the column types of `DESCRIBE <query>` (the query itself is never rewritten or cast):

| engine column | DuckDB JSON | cell |
|---|---|---|
| DECIMAL(p, s) | `"123.4567"` (quoted) | exact decimal: the canonical text of the exact value, at any scale, scale 0 included (never a float division, never a double) |
| DOUBLE / FLOAT | `1.5` | real (a FLOAT from its shortest text) |
| TINYINT to BIGINT, UTINYINT to UINTEGER | `7` | integer |
| UBIGINT | `"7"` (quoted) | integer inside 63 bits, else exact decimal (scale 0) |
| VARCHAR | `"abc"` | text |
| DATE | `"1994-01-01"` | text `YYYY-MM-DD` (years 0001 to 9999) |
| NULL | `null` | null |

A HUGEINT is read as an exact decimal whatever its size, the representation of the engine's DECIMAL(38,0), the only column type Arrow has for it. DuckDB's HUGEINT against the arm's DECIMAL(38,0) with exactly equal values is the one allowed departure (the table in the README of `komira_bench_duckdb`, "Allowed departures"): the cell is timed and keeps its ratio, its value is `DEPARTURE:Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)` and its verdict `DEPARTURE`, never `PASS`; the summary line says `DEPARTURE n/m` and `comparison.txt` lists the allowed departures. Unequal values, HUGEINT against INT64 and every other pair of declared types are wrong answers.

A decimal column is compared exactly (count, sum, minimum, maximum and a hash of every value), and against a double column it is a difference of kinds. Which types DuckDB's JSON quotes is taken from the quoting rule of the shell's JSON renderer in DuckDB's source, and what it prints for NaN from its documented output; neither is checked against a fixture of the real binary here; the first real run checks it (a mismatch shows as a wrong answer, not a silent pass).

Each column also carries a declared type from its Arrow type (`arrow_declared_type`, `ResultSet.types`): `DECIMAL128(p,s)` is `DECIMAL(p,s)`, `INT64` is `BIGINT`, `INT32` is `INTEGER`, `FLOAT64` is `DOUBLE`, `STRING` is `VARCHAR`, `DATE32` is `DATE`, and so on; the whole table, with DuckDB's names, is in the README of `komira_bench_duckdb` (Declared column types). The comparison fails by name when the two declared types differ even if every value is equal (`column 0 declared type differs: INTEGER against BIGINT`), and a type outside the table is reported as not in the mapping. The declared type is not the cell kind: an `INT32` and an `INT64` column both give integer cells and still differ.

Not mapped yet, and so refused: dictionary-encoded strings, booleans, timestamps, times, intervals and nested types.

## What a run leaves

| file | holds |
|---|---|
| `warm/result.json` | the warm result: `komira-bench-result/2`, with every run of every sweep and its page faults |
| `cold/result.json` | the cold result, only when cold was measured |
| `comparison.txt` | the tolerance the answers were compared under: floats within the larger of `float_rel_tol` times the larger magnitude and `float_abs_floor`, everything else (declared column types included) exact, then one `allowed departure <reason>` line per entry of the table of allowed departures; it is also printed |
| `queries.sha256` | `<suite>/<id> <sha256 of the text>` per query in run order, then `listing_sha256` of those lines |

## First run, steady state, and page faults

A cell reports its first run (the first run of the first sweep, which is what a user's first query pays, the same for both engines), its steady-state time and the spread of its sweep medians in separate columns, and the headline states the steady-state ratio with the first-run ratio beside it. `komira_bench_report` defines the words once (`STEADY_STATE_DEFINITION`): the steady-state time is the median of each sweep's runs after that sweep's first run, and the least of those medians over the sweeps. The first run is not hidden by a warm-up and not discarded by the harness: a wide run's first runs take many more page faults than later ones, and that cost is the engine's to remove.

The page faults of a run come from the process counters, read just before the run and just after it:

- komira: `getrusage(RUSAGE_SELF)` of the runner process, through `EngineArm.faults` (the engine runs inside the runner, on its own worker threads). An arm that cannot read it reports none.
- DuckDB: the DuckDB process is a child of the runner, so its counters are the minor and major fault fields of `/proc/<pid>/stat` of that child, read by `ProcessTransport.child_faults` around each timed query (before it is sent and after its end marker is read). On a platform without `/proc` the reading is absent, and the result records the faults of that side as not measured (null), never as zero.

Warm and cold are two results because the result model holds one number of reps per run and has no temperature field. The schema has no field for the digest of a query either, hence `queries.sha256`.

A query the arm answers wrongly is a cell with stage `EXEC_FAIL` and value `UNVERIFIED:answer differs from duckdb` (or `rows not in ORDER BY order`), and no time on either side: the model cannot hold a `DIVERGENT` cell without a komira time, and a wrong answer is not timed. The first difference is on the console, in the "failed" list.

The console report lists the shared settings as DuckDB read them back, the warm table and its PASS line, the cold table or why there is none, the queries the arm refused ("unserved", with the token) and the ones that failed.

## Cold runs

Cold means the operating system's file cache is dropped, and the komira arm is closed and prepared again before each of its cold reps, so what it caches in its process (footers, metadata) is gone. Limits: the drop writes to the control file without a `sync` first (the inputs are read-only files, so they hold no dirty pages; a sync would need a foreign call this package does not make), and DuckDB's session is not restarted, so what DuckDB caches in its own process survives a cold rep. A cold number is the cache-dropped one, not a fresh-process one.

A cold rep drops the file cache first. The runner asks a `CacheDropper`; `ProcDropCaches` writes `3` to the kernel's drop-caches control file (`--drop-caches-file`), which needs the privilege to do so. If the host cannot drop (or the first drop fails), cold is not measured and the report says why; warm is unaffected. A drop that fails later, in the middle of a cold measurement, is a fault of the run: the program exits 2 and writes no result. `--cold-reps` is ignored when `--cold-sweeps` is 0.

## The program

```text
komira_bench_runner_main
  --duckdb PATH --cache-dir DIR --out-dir DIR
  --dataset NAME --scale SCALE --suite NAME --query ID --sql-file PATH
  [--order-key COLUMN[:desc][:nulls_first]]...
  --hostclass LABEL --cpu-model TEXT --os TEXT --komira-version TEXT --cores N --mem-bytes N
  [--threads N] [--memory-limit-bytes N] [--duckdb-version V]
  [--warm-sweeps N] [--warm-reps N] [--cold-sweeps N --cold-reps N --drop-caches-file PATH]
  [--pass-max X] [--max-silence-ms N]
```

Every value is a flag; nothing is read from the environment. The DuckDB binary is checked against the pin before it is started. The dataset is verified against its manifest, and its lock (`<cache-dir>/locks/`) is read and verified or, if there is none, written from that verification; the lock's fingerprint is in the result. The query text is the file with its trailing newlines and spaces removed. The host class is an opaque label you choose, never the output of `hostname`. `--cores` and `--mem-bytes` are asserted by the caller and written to the result as given; the program does not detect them (the default thread count is `--cores`).

Exit status: 0 only when every query ran and its values matched, 1 otherwise (a refused query is 1), 2 for a bad argument or a fault of the run.

## Limits

- It drives the arm and DuckDB one query at a time. The komira arm is timed on the host clock around `run`; DuckDB from marker to marker in its session. A time the clock cannot resolve ends the run: use a dataset where the query is long next to one pipe read.
- Every timed komira run must return the row count of its verified run, or the run ends. A timed DuckDB run renders nothing, so its row count is not seen; DuckDB's answer is checked by the run that fetched it.
- DuckDB is not timed for a query the arm refused or answered wrongly.
- The corpus (`komira_bench_corpus`) is not a dependency; the query text is a file. A corpus query maps to `QuerySpec` field for field.

## Tests

`tests/test_inputs.mojo` (digests, tables and scale, flags, the refusal arm, settings), `tests/test_runner.mojo` (the run over a DuckDB transport, an arm and a cache dropper that live in the test, with a manual clock) and `tests/test_komira_arm.mojo` (the real engine arm over a lineitem-shaped Parquet file and a DuckDB stand-in whose Q6 answer is computed in the test, and the conversion of result batches). No test asserts a duration the machine produced: every time is a number the fakes add to the clock. Each test file's header says what each test proves.
