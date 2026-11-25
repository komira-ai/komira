# sdk_exec

The engine-execution layer of the SDK: twelve modules, ten leaves that need
nothing from the rest of the package except each other, and the plan gates
(`plan_validation_gate`, `parquet_glob_options`), which build on `sdk`;
and the engine context with its SQL door and its plan door (`engine_*` below),
which run a SQL query, or a logical plan built without SQL, over Parquet files, over CSV files named by `read_csv` (plain or
`.gz`, `.zst`, `.lz4`) and over local Iceberg tables (`iceberg_scan`, or a table
registered from a catalog), from text to record batches; `arrow_result`, which
readies those batches for the Arrow C stream; and writes a query's result to a
local Parquet, CSV or newline-delimited JSON file with `COPY ... TO`. Views, other writes, the plan cache and
the plan gates' call sites are not wired into the context yet.

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
| `engine_options` | `EngineOptions`: `worker_count` and `memory_budget_bytes`, each `Optional` (absent means the host profile's own value), and `spill_directory` (`Optional`; absent means no spill). Values the caller fills from its flags; no environment variable is read |
| `engine_context` | `EngineContext(options)`: probes the host once, applies the options over the profile, starts the worker runtime. Holds the catalog, the registered tables, `footers` (a `ParquetFooters`), `host_profile`, `runtime`, `spill_directory` and `statements_parsed` (how many SQL statements `run_sql` has started to parse on it). A count or budget below 1, and an empty spill directory, are refused with `ENGINE_OPTIONS_INVALID`. `begin_query` drops the footer cache |
| `engine_catalog` | `register_parquet(ctx, name, path)`: the table's schema is its file's footer |
| `engine_iceberg` | `register_iceberg_table(ctx, name, catalog, namespace, table, allow_moved_paths)`: asks an `iceberg_catalog.IcebergCatalog` where the table's current `metadata.json` is (a bare local path or a `file:///` URI; any other scheme is `ICEBERG_PATH_UNSUPPORTED`), reads the table's columns and current snapshot from it and registers it as `name` (not in `ctx.tables`, which lists Parquet tables) |
| `engine_lower` | `lowering_inputs` (the facts of each scan, from `ctx.footers`, in the cutter's scan order; a registered table's scan is checked against its registered schema; a scan of an S3 or GCS bucket or an Azure container has no facts, since `ctx.footers` reads the local file system only; an Iceberg scan is planned by `iceberg_scan.scan_planner.plan_iceberg_scan`, which reads its manifests, prunes by the pushed filter and matches the delete files) and `lower_for_context` |
| `engine_execute` | `run_lowered_plan_with(ctx, lowered, opener)`: a `RealBuilder` over a per-run metadata cache (keyed per file system) and expression pool, reading a Parquet scan of a bucket through the file system the `ScanFsOpener` opens on it (`objectstore_s3.S3ScanFs` for S3, `objectstore_gcs.GcsScanFs` for GCS, `azure_blob.AzureScanFs` for Azure; one opener, so one remote store kind, per run), the segment pool sized from the memory budget, the context's spill directory (when it has one) on the builder, each in-memory source of the plan (`params.batches`) as one resident batch in plan order, the aggregation, sort and window sink data (`params.agg`, `params.sort`, `params.window`) in plan order, `run_plan` on `ctx.runtime` with the host profile's thread count; returns the result segment's batch. `run_lowered_plan(ctx, lowered)` is that with `LocalOnlyScanFs`, which refuses a scan of a bucket with `SCAN_FS_UNSERVED`. `run_lowered_plan_with(ctx, lowered, opener, control)` runs under a `RunControl`: `run_plan` polls a clone of its token and counts the plan's segments into its progress; without one the run's token is its own and nothing cancels it |
| `engine_write` | `write_copy_result(batch, dest, fmt, codec)`: the result batch as a file at the local path `dest` in the format `fmt`, through `fs.atomic_write.write_file_atomic` (all or nothing), returning the rows written; `write_parquet_result(batch, dest, codec)` and `write_text_result(batch, dest, fmt, codec)` (CSV or JSON), which it calls; `count_result(rows)`, the one-row BIGINT `Count` batch a COPY answers; `check_copy_target(dest, fmt, codec)`, the refusals of a URL and of lz4 for CSV or JSON |
| `engine_write_text` | `encode_csv(batch)` and `encode_ndjson(batch)`: the bytes DuckDB's COPY writes for a result as CSV and as newline-delimited JSON; `compress_text(bytes, codec)`, the whole file as gzip or zstd; `text_writable(type)`; and the cell texts they are made of, `csv_double_text`, `json_double_text`, `date_text`, `decimal_text` |
| `engine_plan` | `run_plan(ctx, plan) -> SqlOutcome`: a logical plan that is already built (decoded from a `WirePlanEnvelope` by `plan_wire.plan_from_bytes`, or built in Mojo) optimized, lowered and run, with no SQL front end: the module imports none of `sql`'s tokenizer, parser, binder or front end, and a scan leaf carries its own source, so no table need be registered. `run_plan_batch(ctx, plan, opener, step)` is those three steps, which `run_sql` runs after it binds, so both doors share one route from the optimizer down. `optimize_for_run(plan)` is `optimize` (refusing a plan that needs a scalar subquery executed first, `OPTIMIZE_UNRESOLVED_SCALAR`) and then `plan_cse_eliminate`, which holds each subtree the plan repeats once (a CTE read twice, two equal UNION ALL branches) so lowering cuts it once and every reference reads it (`lowering.cut_shared`). Nothing raises: `SqlOutcome.refusal` holds the step (`optimize`, `lower`, `execute`) and that step's own message. `run_plan_with(ctx, plan, opener)` runs with the opener a scan of a bucket is read through. `SqlOutcome`, `SqlRefusal` and those step names are defined here |
| `engine_sql` | `run_sql(ctx, text) -> SqlOutcome`: tokenize and parse, `bind_statement`, then `engine_plan`'s steps (`optimize_for_run`, lower, run), and for a `COPY ... TO` write the file and answer `Count`. Each call adds one to `ctx.statements_parsed` as it starts to parse, so a caller can tell that a run went through the SQL front end. Nothing raises: `SqlOutcome.refusal` holds the step (`parse`, `bind`, `optimize`, `lower`, `execute`) and that step's own message; `engine_plan`'s `SqlOutcome`, `SqlRefusal`, `OPTIMIZE_UNRESOLVED_SCALAR` and step names are named here too. `run_sql_with(ctx, text, opener)` runs with the opener a scan of a bucket is read through. `run_sql(ctx, text, control)` and `run_sql_with(ctx, text, opener, control)` run under a `RunControl`: a cancel stops the plan's run at its next check and is refused at step `execute` with `pipeline_exec`'s cancelled error; parse, bind, optimize, lower and a COPY's write are not polled |
| `run_control` | `RunControl`: a cancel token and a segment progress counter (`pipeline_exec.run_progress.RunProgress`) behind a shared handle (`share()`). `cancel()` is one-way and may come from several threads at once: the first call claims the token through an atomic cell and cancels it with `RUN_CANCEL_REASON` (`the caller cancelled the run`), every later one does nothing. `snapshot()` reads the progress (`done` at most `total`); `token()` and `progress()` are what a run is handed |
| `arrow_result` | `arrow_result(outcome) -> ArrowResult`: the batches of a `SqlOutcome` and their schema, each batch's selection mask applied, checked to cross the Arrow C Stream Interface whole (`arrow_ipc.c_data_stream_check`). Raises with the step and message of a refusal, for an outcome with no batch, and naming a column the export cannot carry |

**Iceberg tables.** `SELECT ... FROM iceberg_scan('<path>' [, allow_moved_paths
= true] [, snapshot_from_id = <n>])` reads an Iceberg table on the local file
system; `<path>` is a `*.metadata.json` file or a table directory whose
`metadata/version-hint.text` names the version (`ICEBERG_TABLE_VERSION_UNKNOWN`
when there is none). `register_iceberg_table` does the same for a table a
catalog resolves, after which SQL says `SELECT ... FROM <name>`. The snapshot is
fixed when the relation is bound (the current one, or `snapshot_from_id`;
`ICEBERG_SNAPSHOT_NOT_FOUND` for an id the table lacks). The manifests are read
when the plan is lowered, and a scan refuses by name what the reader lacks
(format version 3, a delete form such as a deletion vector, an ORC data file, a
type with no Arrow mapping, a path off the local file system). Every other
option of DuckDB's `iceberg_scan` is refused at `parse` by name.

```text
var ctx = EngineContext()
var catalog = StorageBasedCatalog()
catalog.register("db", "orders", "/warehouse/db/orders/metadata/v3.metadata.json")
register_iceberg_table(ctx, "orders", catalog, "db", "orders")
var outcome = run_sql(ctx, "SELECT id FROM orders WHERE id < 10")
```

**COPY ... TO a local Parquet, CSV or JSON file.** `COPY <table> TO '<path>'`
and `COPY (<query>) TO '<path>' (FORMAT <format>, COMPRESSION <codec>)` run
the query like any other and write its result. The statement answers what
DuckDB answers: one row, one BIGINT NOT NULL column `Count`, the rows written.

- The format comes from `FORMAT` (`parquet`, `csv`, `json`), or from the
  extension as DuckDB infers it (`sql.sql_copy_format`); a name with no
  format's extension is `COPY_FORMAT_NOT_INFERRED` at `parse`.
- Parquet `COMPRESSION` is snappy (the default), uncompressed, zstd (level
  3), gzip (level 6), or lz4 or lz4_raw (both LZ4_RAW in the footer). CSV and
  JSON are compressed whole: gzip (level 6) or zstd (level 3) from
  `COMPRESSION` or a `.gz` or `.zst` destination, uncompressed otherwise;
  lz4, which DuckDB does not write for them either, is
  `COPY_COMPRESSION_UNSUPPORTED` at `bind`.
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
- A Parquet file: the result's column names in order; a nullable column OPTIONAL and
  a NOT NULL one REQUIRED; one row group per 122,880 rows; DATE annotated
  DATE, DECIMAL as FIXED_LEN_BYTE_ARRAY(16) with its precision and scale,
  strings UTF8. An empty result writes the schema with no rows. A column of a
  type the writer cannot annotate (TIMESTAMP, TIME, INTERVAL and the like, the
  unsigned and narrow integers, BLOB, nested) is `COPY_TYPE_UNSUPPORTED` at
  `execute`, before any file is touched.
- A CSV or JSON file holds the bytes DuckDB's COPY writes for the same rows
  (`engine_write_text`'s header has each rule). CSV: a header row, `,`
  between cells, `\n` after each line, NULL as an empty cell, a string
  quoted only when it is empty or holds `,`, `"` or a line break, DATE as
  `YYYY-MM-DD`, DECIMAL exact, DOUBLE in its shortest digits. JSON: one
  object per row in column order, NULL as `null`, DATE as a string, DECIMAL
  as a number. An empty result is the header row alone (CSV) or an empty
  file (JSON). A timestamp, time, interval, BLOB or nested column is
  `COPY_TYPE_UNSUPPORTED`, and two columns of one name (which DuckDB renames)
  `COPY_DUPLICATE_COLUMN`, both at `execute` before any file is touched.
  DELIMITER, QUOTE, HEADER false and the other CSV and JSON options are
  refused by name at `parse`.
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
var csv = run_sql(ctx, "COPY (SELECT 1 AS n, 'a,b' AS s) TO '" + dir + "/n.csv'")
assert_equal(Int(csv.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 1)
with open(dir + "/n.csv", "r") as f:
    assert_equal(f.read(), "n,s\n1,\"a,b\"\n")
```

The encoders on their own:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from sdk_exec.engine_write_text import csv_double_text, date_text, json_double_text

assert_equal(csv_double_text[DType.float64](1e16), "1e+16")
assert_equal(json_double_text(1e16), "10000000000000000.0")
assert_equal(date_text(-719163), "0001-12-31 (BC)")
```

Encoding a batch, and compressing the file:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from arrow.write_target import WCOMP_GZIP
from sdk_exec.engine_write_text import compress_text, encode_csv, encode_ndjson, text_writable

var k = PrimitiveArray[DType.int64].allocate(2)
k.set(0, 1)
k.set(1, 2)
var sb = SchemaBuilder()
sb.add_field(Field("k", ArrowType.INT64, False))
var rb = RecordBatchBuilder()
rb.add_column(Column.from_primitive[DType.int64](k^))
var batch = rb.build(sb.build())
assert_equal(String(unsafe_from_utf8=Span(encode_csv(batch))), "k\n1\n2\n")
assert_equal(String(unsafe_from_utf8=Span(encode_ndjson(batch))), "{\"k\":1}\n{\"k\":2}\n")
var gz = compress_text(encode_csv(batch), WCOMP_GZIP)
assert_equal(Int(gz[0]), 0x1F)
assert_equal(text_writable(ArrowType.TIMESTAMP_US), False)
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
(`STATEMENT_NOT_A_QUERY`, step `bind`); the door also refuses with `OPTIMIZE_UNRESOLVED_SCALAR` a plan whose optimization
asks for a scalar to be executed first (a scalar subquery whose body is not provably one row, see Subqueries below); a sink denied its memory by the
budget (unless it spills, see Spill below), a sum outside its declared type and a pool not whole after a run (step
`execute`); and whatever lowering, the binder or the parser refuses (INNER, LEFT, RIGHT, FULL, SEMI, ANTI and CROSS joins are served, a scalar
subquery being a CROSS join against its one-row aggregate; a join with a
residual predicate, a SEMI or ANTI join that builds its left side and a join
on keys the probe does not compare are `LOWERING_JOIN_UNSERVED` at `lower`;
a window function of a kind, type or frame the window sink does not serve is
`LOWERING_WINDOW_UNSERVED` at `lower`).
Lowering given fewer scan facts than
the plan has scans refuses by name (`LOWERING_INPUTS_SCAN_COUNT`);
`lowering_inputs` descends only scan, filter, project, limit, aggregate,
distinct, sort, window (PARTITION_BY), union and join nodes (a union's branches in order; a join's
left child, then its right, for every join, so a join the cutter refuses has
its scans' facts read first) and gives a facts entry per scan it reaches; the
cutter refuses any other node by name before it asks for the scans below it.
`worker_count` and
`memory_budget_bytes` have a lower bound of 1 and no upper bound. A
call is cancelled through the `RunControl` it is given (`run_sql(ctx, text,
control)`), from any thread; a call given none has a token nothing cancels.
After a refusal the context is unchanged and runs the next query.

**Subqueries.** An uncorrelated scalar subquery is served in a WHERE (under
AND, OR and IS NULL too), in a SELECT list (under CASE and coalesce too), in a
HAVING, in the SELECT list of a grouped query, beside an aggregate and inside
another scalar's body, when its body is provably one row: a global aggregate,
or a LIMIT 0 or LIMIT 1 body of a column type the pipeline's `max` carries
(integers, DATE, DECIMAL, floats). The optimizer makes it a CROSS join against
that row (a LIMIT body through a global `max`, so a body with no row is NULL,
as in DuckDB) and keeps its comparison a filter. Any other body (several rows
possible) is refused at `optimize` with `OPTIMIZE_UNRESOLVED_SCALAR`; DuckDB
raises for such a body when it has several rows and answers it when it has
one. `x IN (SELECT ...)` is a SEMI join and `x NOT IN (SELECT ...)` the
NULL-aware ANTI join, as a WHERE conjunct, over a one-table body or (bound
whole) a body with DISTINCT, GROUP BY / HAVING, a join, an expression or an
aggregate. Refused by name: IN, NOT IN or EXISTS in a HAVING or a grouped
SELECT list (`bind`), a left side that is not a column (`parse`), and keys
the hash join does not compare, DATE and DECIMAL among them
(`LOWERING_JOIN_UNSERVED` at `lower`).

A correlated scalar subquery (its WHERE names an outer column, TPC-H Q2, Q17
and Q20; Q2 as a whole is refused at `execute` for its ORDER BY on a DECIMAL
key, which the sort sink does not order) is served in a WHERE, anywhere in the predicate, and in the SELECT
list of an ungrouped query: the optimizer makes it a LEFT join of the outer
rows with its body grouped by the correlation keys, so an outer row with no
matching row (or a NULL key) reads the aggregates of no row, a count 0 and
every other aggregate NULL, as in DuckDB. `[NOT] EXISTS` as a WHERE conjunct
is a SEMI or ANTI join on its equality correlations (Q4, Q22). Refused by
name: a correlated scalar the binder does not build (`bind`, see
`src/sql/README.md`), and an EXISTS correlated by anything but equalities,
which needs a join residual (Q21's `l2.l_suppkey <> l1.l_suppkey`,
`LOWERING_JOIN_UNSERVED ... (a residual predicate)` at `lower`).

**The answer as an Arrow C stream.** A C entry point that fills a caller's
`struct ArrowArrayStream` calls `arrow_result` first, so every way the export
can fail is a raise before the caller's struct is touched, never an EIO from
the consumer's `get_schema` or `get_next`. It then hands
`result.take_batches()` and `result.take_schema()` to
`arrow_ipc.c_data_stream.build_record_batch_stream` with the caller's
pointer, in the module that owns that entry point. An `ArrowResult` owns its
batches and holds nothing of the `EngineContext`, which may be dropped
before the stream is read.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from sdk_exec.arrow_result import arrow_result
from sdk_exec.engine_sql import SqlOutcome
from std.testing import assert_equal

var fields = SchemaBuilder()
fields.add_field(Field("n", ArrowType.INT32, nullable=False))
var builder = RecordBatchBuilder.with_capacity(1)
builder.add_column(
    Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list([Int32(1)])
    )
)
var answer = SqlOutcome()
answer.batches.append(builder.build(fields.build()))

var result = arrow_result(answer^)
var batches = result.take_batches()
assert_equal(len(batches), 1)
assert_equal(batches[0].num_rows(), 1)
assert_equal(result.take_schema().field_name(0), "n")

# A refusal is a raise, with its step and message.
var refusal = String()
try:
    _ = arrow_result(SqlOutcome(String("bind"), String("no column nope")))
except e:
    refusal = String(e)
assert_equal(refusal, "run_sql refused at step bind: no column nope")
```

## Tests

The tests run when the package is built.

- `test_run_sql_copy_parquet`: `COPY ... TO` a local Parquet file answers one
  BIGINT NOT NULL row `Count`; the file read back equals the query that wrote
  it (a table of BIGINT, DOUBLE, VARCHAR, BOOLEAN, DATE and DECIMAL columns with
  NULLs, a query, an empty result, 130,000 rows in two row groups, a COPY over
  the file it reads, a relative path), and its footer names the codec asked
  for, for each of the six; an unknown extension, a URL, CREATE TABLE AS and
  a TIMESTAMP column are named refusals that create no file; a missing
  directory, a directory at the path and a full disk injected through the
  file system's test seam are named and leave no temporary file and the old
  file whole.
- `test_run_sql_copy_text`: `COPY ... TO` a local CSV or JSON file writes the
  bytes DuckDB writes for a table of BIGINT, DOUBLE, VARCHAR, BOOLEAN, DATE
  and DECIMAL columns with NULLs and for a filtered query; the format from
  `.csv`, `.json`, `.ndjson`, `.jsonl` or FORMAT; gzip and zstd from the
  extension or COMPRESSION; an empty result; lz4, a TIMESTAMP column and two
  columns of one name refused by name with no file made; a full disk and a
  missing directory leave the old file and no temporary file.
- `test_copy_text_encoding`: the CSV and JSON encoders give DuckDB's text
  for every type they write and NULL, doubles in fixed and exponent
  notation, NaN and the infinities, FLOATs, BC dates and years past 9999,
  exact decimals, quoting and escaping; gzip and zstd decompress to their
  input.

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
- `test_run_sql_window`: `run_sql` over a Parquet table DuckDB wrote (the
  `:window_oracle` build action) answers what the pinned DuckDB answers for
  every case of `tests/window/cases.sql`: ranking functions, `lag` and `lead`,
  running and whole-partition aggregates, `first_value`, `last_value` and
  `nth_value`, with no, one or two partition keys, several windows in one
  SELECT, a WHERE and an outer ORDER BY, on one and three workers, each column
  of its documented type; a sum over an INTEGER, a DATE partition key, a
  DECIMAL order key and a float default over a BIGINT lag are
  `LOWERING_WINDOW_UNSERVED` refusals at `lower`.
- `test_run_sql_window_frames`: `run_sql` over two Parquet tables DuckDB wrote
  (the `:window_frames_oracle` build action) answers what the pinned DuckDB
  answers for every case of `tests/window_frames/cases.sql`, on one and three
  workers: `ROWS` frames (sliding, empty at a partition's edge, running and
  tail, descending, offsets past the partition) and `RANGE` frames with
  offsets over a BIGINT key with ties and NULLs, an INTEGER key and a DOUBLE
  key with NaN, infinities, -0.0 and NULL, with keys at the ends of BIGINT and
  INTEGER; a `RANGE` bound that leaves the key's type fails at `execute` with
  DuckDB's overflow error, and a frame DuckDB refuses fails at `bind` with
  DuckDB's reason.
- `test_run_sql_s3`: catalog tables whose `ParquetSource` names an S3 bucket,
  read by `run_sql_with` through `S3ScanFs` over the fake S3, answer what the
  same files answer locally through `run_sql`: a filter and a projection, a
  GROUP BY and a count, a table of two keys, one key in two buckets under
  UNION ALL; a missing and a refused object are the store's NOT_FOUND and
  PERMISSION_DENIED at step `execute`; `run_sql` refuses the S3 scan with
  `SCAN_FS_UNSERVED`, and so does the S3 opener a `gs://` table.
- `test_run_sql_gcs_azure`: catalog tables whose `ParquetSource` names a GCS
  bucket or an Azure container (its scheme as `source_url` reads a `gs://` or
  `az://` URL), read by `run_sql_with` through `GcsScanFs` over
  objectstore_gcs's in-memory fake and through `AzureScanFs` over
  komira_test_fake_azure's fake Blob service, answer what the same files
  answer locally through `run_sql`: a filter and a projection, a GROUP BY and
  a count, a table of two keys, one key in two buckets (two containers) under
  UNION ALL; a missing and a refused object are the store's NOT_FOUND and
  PERMISSION_DENIED at step `execute`; `run_sql`, and the opener of the other
  store, refuse each with `SCAN_FS_UNSERVED` naming the store.
- `test_run_sql_q6`: TPC-H Q6's text from `bench_corpus` over a lineitem-shaped
  Parquet file gives the integer oracle's DECIMAL(38,4); a LEFT self-join counts the matched pairs and the unmatched rows of the
  oracle and a scalar subquery gives the oracle's count; a LEFT JOIN with a
  residual over both sides, a syntax error, an unknown table, a missing file,
  CREATE TABLE AS and a replaced file are named refusals, as are a tiny memory
  budget and an INT64 sum out of range; the context runs on after a refusal; the
  footer cache reads each file once per query and shares it between bind and
  lower; a file replaced between queries is read again; options are validated;
  contexts are created and dropped repeatedly, the segment pool whole after
  each run.
- `test_run_sql_subquery`: over Parquet tables the pinned DuckDB writes
  (`:subquery_oracle`, several row groups, NULLs, duplicate and unmatched
  values in BIGINT, INTEGER, DECIMAL, DATE and VARCHAR columns, an empty
  table), each query of `tests/subquery/cases.sql` answers what DuckDB
  answers, on one and three workers: scalar subqueries in a WHERE (=, <, >,
  BIGINT, DOUBLE, DECIMAL, DATE; the TPC-H Q15 shape over a CTE), over an
  empty table and as a LIMIT body with no row (NULL), in a SELECT list, under
  CASE and coalesce, in a grouped SELECT list, beside an aggregate, in a
  HAVING (the Q11 shape) and nested; IN and NULL-aware NOT IN over one-table
  bodies and over DISTINCT, GROUP BY / HAVING (the Q18 shape), join and
  expression bodies, with and without NULL, over the empty table, and IN and
  NOT IN lists with NULL; a scalar body of several rows and a VARCHAR LIMIT
  body are refused at `optimize`, DECIMAL and DATE IN keys at `lower`, an
  expression left of IN at `parse` and IN in a HAVING at `bind`; every case
  is run.
- `test_run_sql_correlated`: over the eight TPC-H-typed tables the pinned
  DuckDB writes (`:correlated_oracle`: orders with no lineitem, customers with
  no order, NULL keys, ties), each query of `tests/correlated/cases.sql`
  answers what DuckDB answers, on one and three workers: the corpus texts of
  TPC-H Q4, Q17, Q20 and Q22, and Q2's body without its ORDER BY and LIMIT;
  correlated scalars over no row (count 0, NULL), with NULL outer and inner
  keys, two keys, two in one WHERE, under OR and BETWEEN, in a SELECT list
  and a derived table; a DECIMAL compared with a DOUBLE; EXISTS and NOT
  EXISTS with NULL keys. Q21 and an EXISTS correlated by `>` are refused at
  `lower`, Q2 (its ORDER BY is a DECIMAL key, which the sort sink refuses)
  at `execute`, an EXISTS over a join and the unserved correlated scalar
  shapes at `bind`; the TPC-H lines are the corpus texts; every case is run.
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
- `test_run_sql_join_kinds`: over small Parquet tables the pinned DuckDB writes
  (`:join_kinds_oracle`, several row groups, NULL, duplicate and unmatched
  keys, an empty table), each query of `tests/join_kinds/cases.sql` answers what
  DuckDB answers, on one and on three workers: LEFT, RIGHT and FULL joins on
  INT64, STRING, INT32 = INT64 and two-column keys, against an empty table on
  either side; SEMI and ANTI joins as EXISTS, NOT EXISTS, IN, NOT IN (NULL-aware)
  and the SEMI JOIN and ANTI JOIN keywords; CROSS joins, a comma join, and
  uncorrelated scalar subqueries. A LEFT JOIN with a residual over both sides is
  still refused at `lower`.
- `test_run_sql_int_sum`: an integer `sum()` over INT64 and INT32 columns is
  DECIMAL(38, 0) and exact past the INT64 range; an empty or all-NULL sum is
  NULL; expressions, CASE and HAVING over the sum run.
- `test_run_sql_spill`: a GROUP BY of 60,001 groups (two rows each, a NULL
  key, NULL values) on a context whose memory budget the group tables
  outgrow and which has a spill directory answers an oracle computed in the
  test (count, exact sum, min, max, NULL where a group has no value) on one
  and two workers, as the same query with no budget does; the spill directory
  exists afterwards and is empty; the same budget with no spill directory is
  refused at `execute`; an ungrouped count and a GROUP BY of ten groups under
  the budget do not create the directory; an empty `spill_directory` is
  `ENGINE_OPTIONS_INVALID`; a directory that cannot be created fails the
  spilling query at `execute` and the context runs the next one.
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
- `test_arrow_result`: `run_sql` answers over a Parquet table with NULLs
  (a projection of INT64, INT32, VARCHAR and DECIMAL(10, 2) columns, count
  and sums, a filter that keeps no row) read back value for value by a
  consumer written in C (`src/tests/helpers/komira_test_arrow_c_consumer`)
  after the context is dropped, which releases the stream before it reads
  the chunks and calls every release twice; afterwards each result buffer is
  held by nothing else. A refusal raises with its step, an outcome with no
  batch is refused, a selection mask is applied, batches keep their order,
  and a column the export cannot carry is refused naming it.
- `test_run_sql_union_all`: UNION ALL over six small Parquet tables answers
  what DuckDB answers for the same SQL: INTEGER with BIGINT is BIGINT,
  INTEGER with FLOAT is FLOAT, BIGINT or FLOAT or a DECIMAL with DOUBLE is
  DOUBLE, DECIMAL(12,2) with DECIMAL(10,4) is DECIMAL(14,4) and with INTEGER
  DECIMAL(12,2), values exact and NULLs kept; three branches with a FROM-less
  one, count(*), sum, GROUP BY and WHERE over `FROM (... UNION ALL ...) u`, an
  empty branch, the first branch's names, LIMIT, integer literal branches
  (INTEGER, or BIGINT when one needs it); a VARCHAR with an INTEGER is refused
  at bind and an ORDER BY before UNION ALL at parse.
- `test_run_sql_topn`: ORDER BY with LIMIT and OFFSET through `run_sql` over
  Parquet tables in small row groups on 1, 3 and 7 workers: every case of the
  `order_by_limit` corpus with a LIMIT or an OFFSET (ties at the cut, NULLS
  FIRST and LAST in both directions, NaN above inf, a 20000-row table, total
  orders carrying `k`) answers the pinned DuckDB's rows in its order; the
  comparison reports a reordered, changed, missing and added row; an OFFSET with
  no LIMIT is refused at bind by name (the two corpus cases that have one are
  listed, not skipped); a negative LIMIT is refused at parse.
- `test_run_sql_set_ops`: UNION (bare and UNION DISTINCT), INTERSECT and
  EXCEPT through `run_sql` answer what the pinned DuckDB answers for each case
  of `tests/set_ops/cases.sql` (the conformance corpus's bare-UNION cases among
  them), on one worker and on three: NULL rows equal, an all-NULL and an empty
  input, repeated rows, several columns of mixed types, one column of each key
  type, NaN, 0.0 with -0.0, inputs widened to a common type (BIGINT and INTEGER
  with VARCHAR among them), INTERSECT binding tighter than UNION, UNION ALL and
  EXCEPT, a UNION ALL after a UNION keeping its duplicates, a chain in a CTE and
  in a derived table, a sort and an aggregation over the result; every case is
  run; INTERSECT ALL and EXCEPT ALL are refused at parse by name.
- `test_secret_capability_reveal`: a capability reveals exactly the secret
  bound to its own node id, once and after one store resolve; two capabilities
  over one bindings table each reveal their own value; an unbound node or a
  removed ref raises before the consumer is called.

## Limits

The context does not yet hold a source registry, a plan cache or the plan
validation switch.

**Spill.** `EngineOptions.spill_directory` lets a GROUP BY over fixed-width
keys (integers, floats, DATE32, BOOL, DECIMAL128, one or more columns) that
outgrows `memory_budget_bytes` spill instead of being refused at `execute`:
the grouped sink writes a worker's group table to disk by hash partition,
merges one partition at a time and deletes the files when the query ends
(`pipeline_exec`'s README says how). The answer is the one without a
spill, since the folds are exact. Each spill writes a sub-directory of its own
(`thsplc_groupagg_<pid>_<counter>`), so contexts and processes can share one
directory; a query that does not spill never creates it. Not spilled, and
refused over the budget as before: a GROUP BY with COUNT(DISTINCT) (its
refusal says so), a GROUP BY over a string or a mixed string key, the sort
(ORDER BY), and the output rows of every partition, which must fit the budget
together, since the result is returned whole. `run_sql` serves the plans `lowering` cuts: Parquet scans (one file or several; through `run_sql_with`, objects of an S3 or GCS bucket or an Azure container too, from a catalog table whose source names the bucket: no SQL text names an object-store URL yet, the context's footers read local files only, and the session holds no store settings or credentials), `read_csv`
scans of one local file with a header row (decoded whole before the first
morsel; `header=false` is refused at lowering, because the reader would name
the columns `col_0`, `col_1`, ... where DuckDB names them `column0`,
`column1`, ...), the one-row relation a SELECT with no FROM reads (an integer
literal of the result's SELECT list or of a UNION ALL branch's is INT32 when it fits, as in DuckDB; an
integer literal anywhere else, `1 + 1` included, is still INT64), filter,
projection, limit (with or without an offset), aggregation, distinct, sort and
top-n, window functions (ranking, LAG and LEAD, FIRST/LAST/NTH_VALUE and SUM,
COUNT, AVG, MIN and MAX over any `ROWS` or `RANGE` frame SQL allows, a
`RANGE` offset over one INT64, INT32 or FLOAT64 order key, with INT64, INT32,
FLOAT64, BOOL or STRING partition and order keys)
and UNION ALL, the
concatenation of its branches (UNION is a distinct over that concatenation). The post-rewrite gate and
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
