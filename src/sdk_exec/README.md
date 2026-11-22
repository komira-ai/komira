# sdk_exec

The engine-execution layer of the SDK: twelve modules, ten leaves that need
nothing from the rest of the package except each other, and the plan gates
(`plan_validation_gate`, `parquet_glob_options`), which build on `sdk`;
and the engine context with its SQL door (`engine_*` below), which runs a SQL
query over Parquet files, and over CSV files named by `read_csv` (plain or
`.gz`, `.zst`, `.lz4`), from text to record batches, and writes a query's
result to a local Parquet file with `COPY ... TO`. Views, other writes, the
plan cache and the plan gates' call sites are not wired into the context yet.

| module | does |
|---|---|
| `sink_variant_tags` | the 16 `SINK_VARIANT_FILE_*` arm-lookup tags (`UInt8`), with no imports, so a module that needs only the integers does not pull in the write stack |
| `plan_compile_cache` | the two-layer plan-compile cache (`PlanCompileCache`): Layer 1 keyed by the plan's structural hash, Layer 2 keyed by `compose_full_cache_key` (structural hash, log2-bucketed cardinality fingerprint from `compute_stats_hash`, and a per-sink-kind salt that excludes the output path); capped at `RESOLVED_CACHE_CAP` entries with LRU eviction that skips pinned entries and raises when every entry is pinned |
| `plan_validation_routes` | the ledger of terminal execution routes and what the plan validation gate does about each (`COVERED`, `WIRED_UNPROVEN`, `UNCOVERED`, test harness); `route_index_for_entry` looks an entry token up and `ledger_self_check` refuses a contradictory ledger |
| `plan_validation_gate` | the dev-flag gate over `validate_plan`: `plan_validation_outcome` returns what the gate did for a plan at a ledger entry (`VALIDATED`, `NOT_VALIDATED` naming the first plan tag the validator does not model, or `FAILED` with the validator's finding) and raises on an entry the ledger does not name; `validate_plan_at_entry` prints one line and raises only on `FAILED`; `assert_plan_integrity`; `plan_tag_name`; `plan_validation_enabled(armed)` takes the caller's switch, default off, and reads no environment variable |
| `parquet_glob_options` | `to_glob_options`: `ParquetReadOptions` to the discovery layer's `GlobDiscoveryOptions` (the empty-match policy) |
| `scan_binding_gate_wiring` | runs the scan-binding epoch gate at a route against the caller's resolver (`check_scan_bindings_at_entry`, or `..._unbound` for a caller with no registry) and raises on an entry token the ledger does not name |
| `post_rewrite_gate` | `plan_values_are_admissible` and `check_values_after_rewrite`: a rewrite may not introduce a literal the plan wire value check refuses, judged as a difference between the plan the optimizer was handed and the plan it produced |
| `paginated_result` | `PaginatedResult` (the value a caller holds) and `PaginatedState` (the context-side pre-chunked result, cursor and cache pin) for a result that is materialized eagerly and handed out in pages, and the cap on open results |
| `view_handle` | `ViewHandle`: a registered view's name plus a generation, with no context back-reference, so a re-registered name invalidates old handles |
| `materialized_view_handle` | `MaterializedViewHandle`: the same shape for a view whose result is stored |
| `secret_capability` | `SecretCapability`: the handle a plan holds for a secret-bearing node, carrying only the node id (never the value, never the secret ref); `open_connection_for` lifts the plan's `SecretBindings` into a `SecretRegistry` over the supplied store and reveals that node's secret to a `CredentialConsumer` inside the call, so the value never escapes |
| `session_stats` | `SessionStats`: a plain snapshot of the worker counts |

### The engine context and `run_sql`

Import each module by name. The context is a small state struct; what it can
do is a free function in a module of its own.

| module | does |
|---|---|
| `engine_options` | `EngineOptions`: `worker_count` and `memory_budget_bytes`, each `Optional` (absent means the host profile's own value). Values the caller fills from its flags; no environment variable is read |
| `engine_context` | `EngineContext(options)`: probes the host once, applies the options over the profile, starts the worker runtime. Holds the catalog, the registered tables, `footers` (a `ParquetFooters`), `host_profile` and `runtime`. A count or budget below 1 is refused with `ENGINE_OPTIONS_INVALID`. `begin_query` drops the footer cache |
| `engine_catalog` | `register_parquet(ctx, name, path)`: the table's schema is its file's footer |
| `engine_lower` | `lowering_inputs` (the facts of each scan, from `ctx.footers`, in the cutter's scan order; a registered table's scan is checked against its registered schema) and `lower_for_context` |
| `engine_execute` | `run_lowered_plan(ctx, lowered)`: a `RealBuilder` over a per-run metadata cache and expression pool, the segment pool sized from the memory budget, each in-memory source of the plan (`params.batches`) as one resident batch in plan order, the aggregation and sort sink data (`params.agg`, `params.sort`) in plan order, `run_plan` on `ctx.runtime` with the host profile's thread count; returns the result segment's batch |
| `engine_write` | `write_parquet_result(batch, dest, codec)`: the result batch as a Parquet file at the local path `dest`, through `fs.atomic_write.write_file_atomic` (all or nothing), returning the rows written; `count_result(rows)`, the one-row BIGINT `Count` batch a COPY answers; `check_copy_target(dest, fmt)`, the refusals of a URL and of CSV or JSON |
| `engine_sql` | `run_sql(ctx, text) -> SqlOutcome`: tokenize and parse, `bind_statement`, `optimize`, lower, run, and for a `COPY ... TO` write the file and answer `Count`. Nothing raises: `SqlOutcome.refusal` holds the step (`parse`, `bind`, `optimize`, `lower`, `execute`) and that step's own message |

**COPY ... TO a local Parquet file.** `COPY <table> TO '<path>'` and
`COPY (<query>) TO '<path>' (FORMAT parquet, COMPRESSION <codec>)` run the
query like any other and write its result. The statement answers what DuckDB
answers: one row, one BIGINT NOT NULL column `Count`, the rows written.

- The format comes from `FORMAT`, or from the extension as DuckDB infers it
  (`sql.sql_copy_format`); a name with no format's extension is
  `COPY_FORMAT_NOT_INFERRED` at `parse`. CSV and JSON, inferred or named, are
  refused with `COPY_FORMAT_UNSUPPORTED` at `bind`.
- `COMPRESSION` is snappy (the default), uncompressed, zstd (level 3), gzip
  (level 6), or lz4 or lz4_raw (both LZ4_RAW in the footer).
- The write is all or nothing: a temporary `.<name>.<random>.tmp` in the
  destination's directory, synced and renamed over the destination, then the
  directory synced. A failure removes the temporary file and leaves the
  destination as it was, so `COPY (SELECT * FROM 'a.parquet') TO 'a.parquet'`
  is safe. An existing file is replaced, as DuckDB replaces it.
- The path is taken as written; a relative path resolves against the working
  directory. A missing directory is `STORAGE_NOT_FOUND` and is not created;
  any other failure (no space, a directory at the path, ...) is `STORAGE_IO`
  naming the step and the errno; both at `execute`. A destination URL
  (`s3://...`) is `STORAGE_URL_REFUSED` at `bind`.
- The file: the result's column names in order; a nullable column OPTIONAL and
  a NOT NULL one REQUIRED; one row group per 122,880 rows; DATE annotated
  DATE, DECIMAL as FIXED_LEN_BYTE_ARRAY(16) with its precision and scale,
  strings UTF8. An empty result writes the schema with no rows. A column of a
  type the writer cannot annotate (TIMESTAMP, TIME, INTERVAL and the like, the
  unsigned and narrow integers, BLOB, nested) is `COPY_TYPE_UNSUPPORTED` at
  `execute`, before any file is touched.
- `CREATE TABLE ... AS` writes into a catalog table, and no catalog is bound:
  it is refused with `STATEMENT_NOT_A_QUERY` at `bind`, naming the COPY that
  writes a file.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.tempfile import mkdtemp
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql

var ctx = EngineContext(EngineOptions(worker_count=1))
var dir = mkdtemp(prefix="komira_copy_readme_")
var out = run_sql(ctx, "COPY (SELECT 1 AS n UNION ALL SELECT 2) TO '" + dir + "/n.parquet'")
assert_equal(out.batches[0].schema.field_name(0), "Count")
assert_equal(Int(out.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 2)
var back = run_sql(ctx, "SELECT count(*) AS rows FROM '" + dir + "/n.parquet'")
assert_equal(Int(back.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 2)
```

**The footer cache is pinned to a query.** `parquet_footers.FooterCache`
has no cap, so the context does not keep it: `run_sql` starts by replacing it
with an empty one (`begin_query`). Within a call the binder and lowering read
one version of each file's footer (`ParquetFooters` and `lowering_facts` share
the cache and refuse a file whose identity changed since it was read). The next
call reads each file it names again, so a file replaced between queries is read
as the new file, and is refused at step `lower` (naming the table) when its
schema no longer matches the registered table. That a file replaced by identity
(size, time, inode) is refused cannot be reached from `run_sql`, because the
cache is fresh for every call; the package's own tests cover it.

What this does not close: the scan opens the file afresh. `run_lowered_plan`
builds a new `parquet.ParquetMetadataCache` for the run, so the scan
reads the footer a second time, and a file replaced between lowering and the
scan is read with the old plan's schema and min/max (komira#2024 adds the
check at scan time). A same-schema replacement with new min/max is correct
across queries only because no plan is cached between them; wiring
`plan_compile_cache` into `run_sql` would reopen that hole. The price of the
pin is the footer reads: one by the footer cache per file per query, and one
more by the scan.

**Served: one table, several files.** `register_parquet` takes a file, a
glob or a directory (every `.parquet` file under it); the files are listed at
registration and every query re-reads each footer. `read_parquet('<glob>')` in
SQL expands a glob the same way. Hive `key=value` directories become columns
after the data columns (DATE, TIMESTAMP, BIGINT or VARCHAR by DuckDB's rule),
and a filter on one prunes files. Rows come back in no promised order across
files. Refused by name: no file matches (`PARQUET_GLOB_NO_MATCH`), a directory
given to SQL `read_parquet` (`PARQUET_PATH_IS_DIRECTORY`), files whose schemas
differ (`PARQUET_FILES_SCHEMA_MISMATCH`), and the Hive shapes the footer
package lists (`HIVE_PARTITION_*`).

**Refused here, by name.** The COPY refusals above, `CREATE TABLE ... AS`
(`STATEMENT_NOT_A_QUERY`, step `bind`); a scalar subquery (the optimizer keeps
it in the plan as a CROSS join, which lowering refuses with
`LOWERING_JOIN_UNSERVED`; the
door also refuses with `OPTIMIZE_UNRESOLVED_SCALAR` a plan whose optimization
asks for a scalar to be executed first, a guard no query tested here reaches); a sink denied its memory by the
budget, a sum outside its declared type and a pool not whole after a run (step
`execute`); and whatever lowering, the binder or the parser refuses (an INNER
equi-join is served; any other join is `LOWERING_JOIN_UNSERVED` at `lower`).
Lowering given fewer scan facts than
the plan has scans refuses by name (`LOWERING_INPUTS_SCAN_COUNT`);
`lowering_inputs` descends only scan, filter, project, limit, aggregate,
distinct, sort, union and join nodes (a union's branches in order; a join's
left child, then its right, for every join, so a join the cutter refuses has
its scans' facts read first) and gives a facts entry per scan it reaches; the
cutter refuses any other node by name before it asks for the scans below it.
`worker_count` and
`memory_budget_bytes` have a lower bound of 1 and no upper bound. A
cancellation token is local to a call, so cancel is not reachable from
`run_sql`. After a refusal the context is unchanged and runs the next query.

## Tests

The tests run when the package is built.

- `test_run_sql_copy_parquet`: `COPY ... TO` a local Parquet file answers one
  BIGINT NOT NULL row `Count`; the file read back equals the query that wrote
  it (a table of BIGINT, DOUBLE, VARCHAR, BOOLEAN, DATE and DECIMAL columns with
  NULLs, a query, an empty result, 130,000 rows in two row groups, a COPY over
  the file it reads, a relative path), and its footer names the codec asked
  for, for each of the six; CSV and JSON, an unknown extension, a URL, CREATE
  TABLE AS and a TIMESTAMP column are named refusals that create no file; a
  missing directory, a directory at the path and a full disk injected through
  the file system's test seam are named and leave no temporary file and the old
  file whole.

- `test_plan_cache_full_sink_hash`: the sink kind is part of the Layer 2 key
  and the path is not.
- `test_resolved_cache_pin_count`: a pinned entry survives an eviction wave,
  pins are counted, and a cache of only pinned entries refuses an insert.
- `test_resolved_cache_lru_eviction_stress`: past the cap the oldest unpinned
  entry is evicted.
- `test_plan_validation_gate_direct`: the gate's outcome for a scan, for a union
  under either child of a join (not validated, naming `PLAN_UNION`) and for a
  filter on a missing column (failed); the entry token must be a ledger row;
  `validate_plan_at_entry` raises only on a failure; the 16 tag names; the
  glob-options mapping; the switch defaults off.
- `test_plan_validation_routes_ledger`: the ledger's self check and lookups,
  and the wiring's refusal of an unregistered token and of a handle from
  another epoch.
- `test_run_sql_csv`: `read_csv` through `run_sql` answers what the pinned
  DuckDB answers (the `:csv_oracle` build action) for every case of
  `tests/csv/cases.sql`: the inferred types and the rows of typed, quoted,
  NULL-bearing and `|`-delimited files and of a header with no row, filters,
  grouped and ungrouped aggregates and `all_varchar`, each over the committed
  file and over a gzip copy; a missing file is refused at bind and
  `header=false` at lowering.
- `test_run_sql_q6`: TPC-H Q6's text from `bench_corpus` over a lineitem-shaped
  Parquet file gives the integer oracle's DECIMAL(38,4); a join of a kind lowering does not serve, a syntax error,
  an unknown table, a missing file, CREATE TABLE AS and a replaced file are named
  refusals, as are a tiny memory budget, an INT64 sum out of range, a scalar
  subquery (refused by lowering); the context runs on after a refusal; the
  footer cache reads each file once per query and shares it between bind and
  lower; a file replaced between queries is read again; options are validated;
  contexts are created and dropped repeatedly, the segment pool whole after
  each run.
- `test_run_sql_distinct`: SELECT DISTINCT over an INT64 and a STRING column
  gives each value once and one NULL row (NULL and the empty string are two
  rows), below a filter and with ORDER BY; COUNT(DISTINCT x) ignores NULL, is
  an INT64 that is 0 for no rows and for all NULL, counts per group (the NULL
  key and an all-NULL group included), runs beside SUM and over a STRING;
  SELECT DISTINCT over two INT64 columns is refused at `lower` with
  `LOWERING_SINK_UNSERVED`.
- `test_run_sql_group_keys`: GROUP BY one DATE32, BOOL, DECIMAL(12, 2) or
  DECIMAL(30, 4) column over a Parquet table of six row groups equals an oracle
  computed in the test, the NULL key being one group (count(*), count(v) and
  sum(v) per group; the key keeps its type, precision and scale; decimal keys
  past INT64 are exact); min and max of dates and the sum of decimals run under
  a BOOL key; a WHERE before the grouping keeps only the passing rows; an
  all-NULL key is one group; `group by d, b` groups by the pair.
- `test_run_sql_group_keys_mixed`: over a Parquet table the pinned DuckDB
  writes (`:group_keys_mixed_oracle`, five row groups, NULLs in every column,
  the empty string), each query of `tests/group_keys_mixed/cases.sql` answers
  what DuckDB answers, on one and on three workers: GROUP BY an INTEGER, a
  VARCHAR and a DATE (in both orders, with count, sum, min and max), a BIGINT
  and an INTEGER, a BOOLEAN, a DECIMAL and a VARCHAR; under a WHERE and a
  HAVING; count(DISTINCT) per mixed key; SELECT DISTINCT over three columns;
  an all-NULL key; no row.
- `test_run_sql_int_sum`: an integer `sum()` over INT64 and INT32 columns is
  DECIMAL(38, 0) and exact past the INT64 range; an empty or all-NULL sum is
  NULL; expressions, CASE and HAVING over the sum run.
- `test_run_sql_multifile`: a table of several Parquet files from a directory
  (files at any depth; a dot-name and a non-Parquet file skipped), a glob, a
  brace glob, `read_parquet('<glob>')` and `FROM '<glob>'`; a Hive tree whose
  keys are columns after the data columns, with filters on a key (files
  pruned) and on a data column, GROUP BY a key, count(*), ORDER BY and LIMIT;
  `hive_partitioning = false`; a glob with no file, a directory in SQL text and
  files of different schemas are named refusals at their step; a replaced file
  is read again.
- `test_run_sql_no_from`: `SELECT 1 AS n` is one row, an INT32 column `n`
  holding 1, DuckDB's answer; a result literal is INT32 from -2147483647 to
  2147483647 and INT64 past either bound and at -2147483648 (as in DuckDB);
  one past BIGINT is refused at bind; a literal a derived table holds stays
  INT64 (`n + 5000000000` over a derived `1 AS n` is the INT64 5000000001)
  and `SELECT 1 AS n UNION ALL SELECT 2` binds to INT32, as in DuckDB; `7 / 2`, `count(*)` and a false WHERE with no FROM;
  `SELECT 1 FROM` a Parquet table; an in-memory source of two batches is read
  whole and one of none gives no rows with its schema.
- `test_run_sql_union_all`: UNION ALL over six small Parquet tables answers
  what DuckDB answers for the same SQL: INTEGER with BIGINT is BIGINT,
  INTEGER with FLOAT is FLOAT, BIGINT or FLOAT or a DECIMAL with DOUBLE is
  DOUBLE, DECIMAL(12,2) with DECIMAL(10,4) is DECIMAL(14,4) and with INTEGER
  DECIMAL(12,2), values exact and NULLs kept; three branches with a FROM-less
  one, count(*), sum, GROUP BY and WHERE over `FROM (... UNION ALL ...) u`, an
  empty branch, the first branch's names, LIMIT, integer literal branches
  (INTEGER, or BIGINT when one needs it); a VARCHAR with an INTEGER is refused
  at bind and an ORDER BY before UNION ALL at parse.
- `test_secret_capability_reveal`: a capability reveals exactly the secret
  bound to its own node id, once and after one store resolve; two capabilities
  over one bindings table each reveal their own value; an unbound node or a
  removed ref raises before the consumer is called.

## Limits

The context does not yet hold a source registry, a plan cache, spill options or
the plan validation switch. `run_sql` serves the plans `lowering` cuts: Parquet scans (one file or several), `read_csv`
scans of one local file with a header row (decoded whole before the first
morsel; `header=false` is refused at lowering, because the reader would name
the columns `col_0`, `col_1`, ... where DuckDB names them `column0`,
`column1`, ...), the one-row relation a SELECT with no FROM reads (an integer
literal of the result's SELECT list or of a UNION ALL branch's is INT32 when it fits, as in DuckDB; an
integer literal anywhere else, `1 + 1` included, is still INT64), filter,
projection, limit, aggregation, distinct and sort, and UNION ALL, the
concatenation of its branches. The post-rewrite gate and
the plan validation gate are not called from `run_sql`.

`post_rewrite_gate` is a free-standing check; its call sites belong to the
engine context. The plan validation gate that `plan_validation_routes` is the
ledger for is `plan_validation_gate`; its call sites (the `@parameter if` and
switch guards at each route) belong to the engine context, a later slice. No
ledger row is COVERED yet: the guard tests the first-draft rows named are not
in this slice, so those rows are WIRED_UNPROVEN until their tests arrive, and a
test here checks that a COVERED row only names a test file this package ships.
`deps` in the BUCK file is the full transitive closure; a later slice that
pulls a new library adds it in the same change.
