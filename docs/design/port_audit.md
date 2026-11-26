# Port audit: where the earlier tree's SDK-path code went

This audit replaces the earlier comparison by file basename. For every package on the path of the Python SDK (`engine_dispatch`, `engine_operators`, `engine_v2`, `compiler`, `parquet`, `sdk`, `sdk_exec`, `flight`, `core`, `async`, the plan packages and `pyffi`) it says, file by file and declared name by declared name, whether the behaviour is MOVED, REPLACED, DROPPED or a GAP in the current tree. It also audits the earlier claim that the 236 package directories split about 65 / 108 / 63 into apps, platform and engine.

"The earlier tree" is the code base the current engine was ported from. Paths in the tables are relative to its `src/` directory (`komira_<package>/<file>`); current paths are repository paths.

## Method

1. Every non-test `.mojo` file of each package (not under `tests/`, not `test_*`, not `__init__.mojo`) was listed, and the names it declares (`struct`, `fn`, `def`, `trait`, `alias`, `comptime`; leading underscore excluded) were looked up among the names declared in non-test files under `src/`.
2. Files with no same-named current file (the unmatched files), and same-named files with declarations found nowhere in `src/`, were each read, then compared with the candidate current file, the package READMEs and the lowering designs ([lowering and pipeline](lowering_and_pipeline.md), `src/lowering/README.md`, `src/pipeline_exec/README.md`, `src/sdk_exec/README.md`).
3. Each file got one disposition:
   - **MOVED**: same behaviour in a current file, under the same or another name.
   - **REPLACED**: a different current mechanism provides the behaviour; PARTLY is written in the note where it covers only part, and the rest is listed as a gap.
   - **DROPPED**: absent on purpose, with the reason (benchmark-shape-specific route, superseded, not on the local SQL path, belongs to a later feature such as S3, Iceberg, UDFs or remote jobs).
   - **GAP**: behaviour the local-files SQL and DataFrame SDK needs and no current file provides.
4. Every current path cited in the tables was checked to exist.

A name match is a hint only: it can be a collision, and a file can be moved under a new name. The counts below are of rows, not of coverage.

## Result by package

| package | non-test files | same-named current file | unmatched files | table |
|---|---|---|---|---|
| engine_dispatch | 161 | 35 | 126 | [engine_dispatch](port_audit/engine_dispatch.md) |
| engine_operators | 286 | 159 | 127 | [engine_operators](port_audit/engine_operators.md) |
| parquet | 118 | 101 | 17 | [parquet, compiler, engine_v2](port_audit/parquet_compiler_engine_v2.md) |
| compiler | 26 | 15 | 11 | same table |
| engine_v2 | 4 | 3 | 1 | same table |
| sdk | 38 | 20 | 18 | [sdk, sdk_exec, plan_endpoint, pyffi, core](port_audit/sdk_group.md) |
| sdk_exec | 44 | 13 | 31 | same table |
| plan_endpoint | 6 | 0 | 6 | same table |
| pyffi | 1 | 0 | 1 | same table (one row per exported symbol group) |
| core | 251 | 247 | 4 | same table |
| flight, async, plan_wire, pplan_wire | 3, 92, 3, 2 | all | 0 | no table needed; every file has a same-named current file |
| same-named files with declarations found nowhere in `src/` | 69 files, 8 packages | yes | n/a | [renamed_symbols](port_audit/renamed_symbols.md) |

Rows by disposition (counted from the tables with `grep` and `awk` over the table rows):

| table | MOVED | REPLACED | DROPPED | GAP |
|---|---|---|---|---|
| engine_dispatch (126 files) | 8 | 32 | 63 | 23 |
| engine_operators (127 files; 3 REPLACED are PARTLY) | 24 | 48 | 52 | 3 |
| parquet, compiler, engine_v2 (29 files) | 10 | 8 | 9 | 2 |
| sdk group (90 rows) | 9 | 16 | 51 | 14 |
| same-named files with missing names (69 files) | 58 | 7 | 4 | 0 |

The headline: the unmatched files are mostly not lost behaviour. The earlier route ladders and untyped sink families are DROPPED or REPLACED by `lowering` plus `pipeline_exec` ([design](lowering_and_pipeline.md)); same-named files that lack some names are renames. What is a GAP is concentrated in the same few capabilities, listed next.

## Gaps and the task each belongs to

The tables carry many per-file gap rows; they collapse to these capabilities. Task names in the per-file "Gaps" sections are mapped to these ids; "new" marks a capability for which no task existed when this audit was written.

| gap | what is missing today | tables | task |
|---|---|---|---|
| Joins (inner, outer, semi, anti, cross, residual) | kernels exist (`src/op_join_build`, `src/op_join_probe`, `src/op_join_sinks`, `src/join_assembly`, `src/dispatch_join_kernels`); lowering refuses joins and `pipeline_exec` has no build or probe arm | dispatch, operators | pysdk-engine-join-inner, pysdk-engine-join-outer-semi-anti |
| Window functions and per-partition top-N | window functions served: lowering cuts a window node into a SINK_PARTITION_BY segment (`src/lowering/cut_window.mojo`) run by `src/pipeline_exec/sink_window.mojo`, and a shape it does not serve is refused as LOWERING_WINDOW_UNSERVED; ROWS and RANGE frames with offsets are served; a parallel window sink and per-partition top-N are not built | dispatch, operators, sdk group | pysdk-engine-window-frames |
| SELECT DISTINCT and COUNT(DISTINCT) | served: lowering cuts DISTINCT into a grouped sink with no aggregate (`src/lowering/cut_distinct.mojo`) and the pipeline_exec aggregation sinks fold COUNT(DISTINCT) (`src/pipeline_exec/count_distinct.mojo`); `src/op_agg_distinct` stays a library | dispatch, operators | none |
| Top-N, LIMIT with OFFSET, LIMIT over a sort | served: lowering cuts a `SINK_TOPN` (`src/lowering/cut_topn.mojo`), `src/pipeline_exec/sink_sort.mojo` keeps the range; an offset over unsorted rows and a filter between a limit and its sort are still refused | dispatch, operators | pysdk-engine-topn-limit-offset |
| UNION, INTERSECT, EXCEPT | UNION ALL served (`src/lowering/cut_union.mojo`); UNION (bare and UNION DISTINCT) served, bound by `src/sql/sql_bind_set_op.mojo` onto a distinct over UNION ALL; INTERSECT and EXCEPT served, bound there onto UNION ALL, a grouped aggregation and a filter; INTERSECT ALL and EXCEPT ALL refused by name | dispatch | pysdk-engine-union-all, pysdk-engine-intersect-except |
| Scalar, IN and correlated subqueries, CTEs and views, shared subplans | uncorrelated scalar, IN and NULL-aware NOT IN subqueries are served (`src/sdk_exec/README.md`, Subqueries; a scalar body not provably one row is refused by name); correlated scalars correlated by equalities and EXISTS / NOT EXISTS as a WHERE conjunct are served, an EXISTS needing a join residual (TPC-H Q21) is refused by name; `EngineContext` has no views. A CTE is inlined by the binder, and `run_sql` holds a repeated subtree once and lowering cuts it once (`cut_shared`) | dispatch, sdk group, renamed_symbols | pysdk-engine-scalar-subquery, pysdk-engine-correlated-subquery, pysdk-engine-cte-view |
| Float SUM/AVG/MIN/MAX and extended aggregates (median, corr, string MIN/MAX, largest-k) | float SUM/AVG/MIN/MAX served by the ungrouped sink and refused by name in the grouped sinks; extended aggregates refused by name in the aggregate sinks | dispatch, operators, parquet group | pysdk-engine-float-agg; extended aggregates: new, "pysdk-engine-extended-aggregates" |
| Sort keys of date, decimal, float32 (single date, decimal and bool group keys, and multi-column mixed-type group keys, are served) | the sort sink refuses with a named error | dispatch, operators | pysdk-engine-group-keys-date-decimal-bool, pysdk-engine-group-keys-mixed |
| NDJSON scans and CSV over several files (Parquet files, globs, directories and Hive sets, and one local CSV file, are served) | no NDJSON scan arm; the CSV arm reads one file | dispatch, parquet group, sdk group | pysdk-engine-multifile-scan |
| CSV and NDJSON sources in SQL | libraries exist; lowering refuses non-Parquet sources | parquet group, sdk group | pysdk-engine-csv-source, pysdk-engine-jsonl-source |
| In-memory tables (register an Arrow stream or batch) | served in C: `komira_register_arrow_stream` (ABI 1.9, `src/so/_c_abi.mojo`) drains an Arrow C stream into a table `run_sql` scans and joins (`src/so/sources.mojo` `register_arrow`); `komira_add_sql_binding` (ABI 1.10) binds a table name to a `WireBoundSource`; not built: a Python `Session.register_arrow` and an in-memory source on the plan wire | dispatch, sdk group | pysdk-engine-inmem-table (C done); the Python binding is a follow-up |
| Local Parquet write sink | `src/parquet_writer` is not reachable from a plan; no write sink | dispatch, parquet group, sdk group | pysdk-engine-write-parquet, pysdk-engine-write-csv-jsonl |
| Plan bytes to result front door (plan endpoint) | built: `komira_plan_stream` (ABI 1.8) runs a serialized plan into an Arrow C stream (`src/so/sources.mojo` plan_result, `src/sdk_exec/engine_plan.mojo` run_plan) under the ABI's input byte limit; the earlier endpoint's timing and its own refusal code table are not carried | sdk group, categories | pysdk-design-abi-run-door, pysdk-abi-run-plan |
| C ABI calls that run SQL or a plan into an Arrow stream | built: `komira_sql_stream` (ABI 1.3), `komira_sql_stream_run` (1.6) and `komira_plan_stream` (1.8) in `src/so/abi/komira.tsv` | sdk group, categories | pysdk-abi-run-sql, pysdk-abi-run-plan, pysdk-abi-arrow-stream-export |
| CAST to VARCHAR operator | no cast-to-string operator in `pipeline_exec` | operators | new, "pysdk-engine-cast-varchar" |
| Driver for `operator_api` sinks | morsel sinks in `src/op_*` have no driver in `pipeline_exec` | operators | covered by the operator tasks above (pysdk-refactor-lowering-split first) |

Per-file gap rows, with the exact earlier files, are in each table's "Gaps" section.

## What did not carry over on purpose

Not gaps, and listed per file in the tables with the reason: the benchmark-shape routes of `engine_dispatch` and the flat, perfect-hash and radix aggregation ladders of `engine_operators`; the typed compile-time stage-program path of `sdk` and `compiler`; the plan-capture packages `pplan`, `pplan_capture`, `pplan_chain` and `pplan_emit`; the Excel packages; in-process Python UDF trampolines (UDFs run in worker processes, see [UDF runtimes](udf_runtime_interface.md)); and, as later work rather than 0.1, object-store and Iceberg scans, spill and remote jobs.

## The category split

See [the 236 package directories by category](port_audit/categories.md). The earlier 65 / 108 / 63 split came from a name regex and was not right. Read per package, the directories are APP 54, PLATFORM 90, ENGINE 36, SDK-SURFACE 23, STORAGE-CONNECT 23, TEST-PROBE 6, OTHER 4 (total 236). Folding to the three old buckets gives 54 / 94 / 88. The three old numbers summed to 236 only because a regex with a catch-all bucket always does. The regex mis-sorted cloud-named storage clients (`aws_s3`, `azure_blob`, `gcp_storage`), plan and wire front doors (`plan_endpoint`, `plan_wire`, `pplan_wire`, `so`, `pyffi`) and probe or carrier packages.

The `komira` source directory of the earlier tree has 255 entries: 236 package directories and 19 other entries (build-rule files, lint ledgers, ABI test and measurement directories). An earlier list of 246 lines held the 236 packages and only 10 of the 19; the 19 are itemized in the categories table.

## Reading order for the owners of the gap tasks

1. The per-file table for the capability (links above) names the earlier file that held the behaviour and the closest current code.
2. The earlier file is the specification of the behaviours to keep; the behaviour tests of the new task are written against DuckDB results, not against the earlier code.
