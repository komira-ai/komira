# komira_bench_runner

The program that runs one benchmark query on both engines and writes the result. For each query it:

1. starts the pinned DuckDB (`komira_bench_duckdb`) with the thread count and memory limit of the run, and registers the dataset as one view per Parquet file;
2. prepares the komira arm with the same tables, thread count and memory limit;
3. runs the query on DuckDB in JSON mode (the reference rows) and on the arm with its rows materialized;
4. compares the two by signature (exact for integers and text, a relative tolerance for floats) and, when the query has `ORDER BY` keys, checks the arm's row order;
5. times the query only if the answers match: warm (sweeps of reps; rep 0 of each sweep is dropped, each sweep is reduced to its median, and the cell's time is the least of the sweep medians: not one median after one discarded run) and, if asked and possible, cold (the file cache dropped before every rep of either engine);
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

The query is passed whole (`QuerySpec`: suite, id, dataset, text, `ORDER BY` keys, and `sha256()` of the text), so an arm can serve a query from the text (`run_sql`) or from a plan it holds for `query.key()`. `RefusalArm` refuses every query with one construct (`no_engine_arm` by default); it is the arm of `komira_bench_runner_main` until an engine exists. The line that builds the arm in `entrypoint.mojo` is the seam.

## What a run leaves

| file | holds |
|---|---|
| `warm/result.json` | the warm result: `komira-bench-result/1` |
| `cold/result.json` | the cold result, only when cold was measured |
| `comparison.txt` | the tolerance the answers were compared under: floats within the larger of `float_rel_tol` times the larger magnitude and `float_abs_floor`, everything else exact; it is also printed |
| `queries.sha256` | `<suite>/<id> <sha256 of the text>` per query in run order, then `listing_sha256` of those lines |

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

`tests/test_inputs.mojo` (digests, tables and scale, flags, the refusal arm, settings) and `tests/test_runner.mojo` (the run over a DuckDB transport, an arm and a cache dropper that live in the test, with a manual clock). No test asserts a duration the machine produced: every time is a number the fakes add to the clock. Each test file's header says what each test proves.
