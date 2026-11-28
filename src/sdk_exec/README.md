# sdk_exec

The engine-execution layer of the SDK: twelve modules, ten leaves that need
nothing from the rest of the package except each other, and the plan gates
(`plan_validation_gate`, `parquet_glob_options`), which build on `sdk`;
and the engine context with its SQL door and its plan door (`engine_*` below).
The context runs a SQL query, or a logical plan built without SQL, from text to
record batches:

- over Parquet files;
- over CSV files named by `read_csv` (plain or `.gz`, `.zst`, `.lz4`);
- over local Iceberg tables (`iceberg_scan`, or a table registered from a
  catalog).

Around the context:

- `arrow_result` readies those batches for the Arrow C stream.
- `COPY ... TO` writes a query's result to a local Parquet, CSV or
  newline-delimited JSON file, or with `PARTITION_BY` to a Hive-partitioned
  directory of Parquet or CSV files, and `run_plan_write` writes the result of
  a plan built without SQL to one file the same way.

Views, other writes, the plan cache and the plan gates' call sites are not wired
into the context yet.

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
| `engine_write_partitioned` | `write_partitioned_result(batch, dest, fmt, codec, partition_by)`: a `COPY ... (PARTITION_BY (...))` result as DuckDB writes it, one `<column>=<value>` directory level per partition column and one `data_0.<ext>` file per distinct combination (`partition_file_name`), written with `engine_write`'s `write_copy_result`, returning the rows written; `check_partitioned_target(dest, partition_by)`, the refusals of a target that is a file or a directory holding anything (`COPY_TARGET_EXISTS`) and of a missing parent directory (`STORAGE_NOT_FOUND`); `partition_value_segment(value)`, a value's escaped directory text |
| `engine_write_text` | `encode_csv(batch)` and `encode_ndjson(batch)`: the bytes DuckDB's COPY writes for a result as CSV and as newline-delimited JSON; `compress_text(bytes, codec)`, the whole file as gzip or zstd; `text_writable(type)`; and the cell texts they are made of, `csv_double_text`, `json_double_text`, `date_text`, `decimal_text` |
| `engine_plan` | `run_plan(ctx, plan) -> SqlOutcome`: a logical plan that is already built (decoded from a `WirePlanEnvelope` by `plan_wire.plan_from_bytes`, or built in Mojo) optimized, lowered and run, with no SQL front end: the module imports none of `sql`'s tokenizer, parser, binder or front end, and a scan leaf carries its own source, so no table need be registered. `run_plan_batch(ctx, plan, opener, step)` is those three steps, which `run_sql` runs after it binds, so both doors share one route from the optimizer down. `run_plan_write(ctx, plan, target)` (and `run_plan_write(ctx, plan, target, opener)`) is the plan door's `COPY <plan> TO <target>`: it refuses the destination as `COPY ... TO` does, at step `bind` and before the plan runs or a file is touched (`STORAGE_URL_REFUSED` for a path with `://`, `COPY_COMPRESSION_UNSUPPORTED` for CSV or JSON with lz4), runs the plan's three steps, writes the result with `engine_write`'s `write_copy_result` and answers `count_result(rows)`, the one-row BIGINT `Count`; the bytes of the file are the ones `run_sql` writes for the same rows. `optimize_for_run(plan)` is `optimize` (refusing a plan that needs a scalar subquery executed first, `OPTIMIZE_UNRESOLVED_SCALAR`) and then `plan_cse_eliminate`, which holds each subtree the plan repeats once (a CTE read twice, two equal UNION ALL branches) so lowering cuts it once and every reference reads it (`lowering.cut_shared`). Nothing raises: `SqlOutcome.refusal` holds the step (`optimize`, `lower`, `execute`) and that step's own message. `run_plan_with(ctx, plan, opener)` runs with the opener a scan of a bucket is read through. `SqlOutcome`, `SqlRefusal` and those step names (`bind` among them) are defined here |
| `engine_sql` | `run_sql(ctx, text) -> SqlOutcome`: tokenize and parse, `bind_statement`, then `engine_plan`'s steps (`optimize_for_run`, lower, run), and for a `COPY ... TO` write the file and answer `Count`. Each call adds one to `ctx.statements_parsed` as it starts to parse, so a caller can tell that a run went through the SQL front end. Nothing raises: `SqlOutcome.refusal` holds the step (`parse`, `bind`, `optimize`, `lower`, `execute`), that step's own message, and for `parse` the `SqlPosition` (line and column, from 1) where the text stopped parsing (`SqlRefusal.position`, `None` for every other step and for `run_plan`); `engine_plan`'s `SqlOutcome`, `SqlRefusal`, `OPTIMIZE_UNRESOLVED_SCALAR` and step names are named here too. `run_sql_with(ctx, text, opener)` runs with the opener a scan of a bucket is read through. `run_sql(ctx, text, control)` and `run_sql_with(ctx, text, opener, control)` run under a `RunControl`: a cancel stops the plan's run at its next check and is refused at step `execute` with `pipeline_exec`'s cancelled error; parse, bind, optimize, lower and a COPY's write are not polled |
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
- A Parquet file holds:
  - the result's column names in order;
  - a nullable column OPTIONAL and a NOT NULL one REQUIRED;
  - one row group per 122,880 rows;
  - DATE annotated DATE;
  - DECIMAL as FIXED_LEN_BYTE_ARRAY(16) with its precision and scale;
  - strings UTF8;
  - TINYINT, SMALLINT and the unsigned integers as INT32 (UBIGINT INT64) with
    the ConvertedType INT_8, INT_16, UINT_8, UINT_16, UINT_32 or UINT_64, as
    DuckDB writes them (an unsigned chunk carries no min or max, since its
    signed order is not the values' order);
  - a timestamp as INT64 with the LogicalType TIMESTAMP of its unit (MICROS,
    MILLIS, NANOS; TIMESTAMP_S is written as microseconds, as DuckDB writes
    it, and a seconds value whose microseconds do not fit in an INT64 is
    refused) and the ConvertedType TIMESTAMP_MICROS or TIMESTAMP_MILLIS where
    one exists;
  - no rows, only the schema, for an empty result.
- A timestamp is written isAdjustedToUTC (DuckDB reads it as TIMESTAMPTZ) only
  when its field carries a time zone, as one read from such a file does;
  komira's own timestamps carry none (a `TIMESTAMPTZ '...'` literal binds to
  zone-less UTC microseconds), so they are written zone-less.
- A column of a type the Parquet writer cannot annotate (TIME, INTERVAL,
  DURATION, DATE64, BLOB, nested) is `COPY_TYPE_UNSUPPORTED` at `execute`,
  before any file is touched.
- A CSV or JSON file holds the bytes DuckDB's COPY writes for the same rows
  (`engine_write_text`'s header has each rule).
  - CSV: a header row, `,` between cells, `\n` after each line, NULL as an
    empty cell, a string quoted only when it is empty or holds `,`, `"` or a
    line break, DATE as `YYYY-MM-DD`, a timestamp as `YYYY-MM-DD HH:MM:SS`
    with the fraction of a second, trailing zeros removed, when it is not
    zero (`2015-09-04 12:30:45.12`), `+00` after a zoned one, and
    `infinity` / `-infinity` for INT64's extremes, DECIMAL exact, DOUBLE in
    its shortest digits.
  - JSON: one object per row in column order, NULL as `null`, DATE and
    timestamps as strings of the CSV text, DECIMAL as a number.
  - An empty result is the header row alone (CSV) or an empty file (JSON).
- A time, interval, duration, DATE64, BLOB or nested column in a CSV or JSON
  file is `COPY_TYPE_UNSUPPORTED`, and two columns of one name (which DuckDB renames)
  `COPY_DUPLICATE_COLUMN`, both at `execute` before any file is touched.
- DELIMITER, QUOTE, HEADER false and the other CSV and JSON options are
  refused by name at `parse`.
- `CREATE TABLE ... AS` writes into a catalog table, and no catalog is bound:
  it is refused with `STATEMENT_NOT_A_QUERY` at `bind`, naming the COPY that
  writes a file.

**COPY ... TO a Hive-partitioned directory.** `COPY (<query>) TO '<dir>'
(FORMAT parquet, PARTITION_BY (year, month))` writes the tree the pinned
DuckDB writes for the same statement (`engine_write_partitioned`):

```text
<dir>/year=2027/month=1/data_0.parquet
<dir>/year=2027/month=2/data_0.parquet
<dir>/year=2028/month=1/data_0.parquet
```

- One directory level per listed column, in the list's order; `PARTITION_BY
  year` names one column. Each file holds the rows of its combination in the
  result's order and every column but the partition columns. `FORMAT csv`
  writes `data_0.csv` (`.csv.gz`, `.csv.zst` when compressed); `FORMAT json`
  is refused at `parse`, as DuckDB refuses it.
- A directory is `<column>=<value>`, both URL-escaped as DuckDB escapes them
  (every byte but ASCII letters, digits and `- _ . ~` as `%XX`); the value is
  its VARCHAR text, NULL is `__HIVE_DEFAULT_PARTITION__` and the empty string
  an empty value. A partition column is an integer, BOOLEAN, VARCHAR, DATE or
  DECIMAL; any other type is `COPY_TYPE_UNSUPPORTED` at `execute`, before
  anything is made.
- A listed column the result does not have, or a list covering every column,
  is a bind error; a name listed twice, an empty list and the option given
  twice are refused at `parse`. `OVERWRITE`, `OVERWRITE_OR_IGNORE`, `APPEND`,
  `WRITE_PARTITION_COLUMNS`, `FILE_SIZE_BYTES`, `PER_THREAD_OUTPUT` and
  `FILENAME_PATTERN` are refused by name at `parse`.
- The target must not exist (its parent must) or must be an empty directory: a
  file or a directory holding anything is `COPY_TARGET_EXISTS`, a missing
  parent `STORAGE_NOT_FOUND`, both at `bind` before the query runs. An empty
  result leaves the target an empty directory.
- The result is held in memory and grouped there, as a COPY to one file holds
  it. Each file is written all or nothing, but the tree is not one unit: a
  failure part way leaves the files written before it.
- Only the SQL door writes a tree: `run_plan_write`'s `WriteTarget` has no
  partition columns yet.

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
var ts = run_sql(ctx, "COPY (SELECT TIMESTAMP '2015-09-04 12:30:45.120' AS at) TO '" + dir + "/at.csv'")
assert_equal(Int(ts.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 1)
with open(dir + "/at.csv", "r") as f:
    assert_equal(f.read(), "at\n2015-09-04 12:30:45.12\n")
```

A plan built without SQL text writes the same file through `run_plan_write`,
here a CSV file, then a Parquet file through the overload that takes the scan
opener; a destination URL is refused at `bind` and nothing runs:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from std.tempfile import mkdtemp
from arrow.write_target import WCOMP_SNAPPY, WCOMP_UNCOMPRESSED, WFMT_CSV, WFMT_PARQUET, WriteTarget
from pipeline_exec.source_parquet import LocalOnlyScanFs
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_plan import run_plan_write
from sdk_exec.engine_sql import run_sql
from sql.sql_frontend import plan_from_sql

var ctx = EngineContext(EngineOptions(worker_count=1))
var dir = mkdtemp(prefix="komira_plan_write_readme_")
var query = String("SELECT 1 AS n UNION ALL SELECT 2 ORDER BY n")
var csv = run_plan_write(
    ctx, plan_from_sql(query, ctx.catalog, ctx.footers), WriteTarget(dir + "/n.csv", WFMT_CSV, WCOMP_UNCOMPRESSED)
)
assert_equal(csv.batches[0].schema.field_name(0), "Count")
assert_equal(Int(csv.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 2)
with open(dir + "/n.csv", "r") as f:
    assert_equal(f.read(), "n\n1\n2\n")
var pq = run_plan_write(
    ctx,
    plan_from_sql(query, ctx.catalog, ctx.footers),
    WriteTarget(dir + "/n.parquet", WFMT_PARQUET, WCOMP_SNAPPY),
    LocalOnlyScanFs(),
)
assert_equal(Int(pq.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 2)
var back = run_sql(ctx, "SELECT count(*) AS rows FROM '" + dir + "/n.parquet'")
assert_equal(Int(back.batches[0].column_at(0).as_primitive[DType.int64]().get(0)), 2)
var url = run_plan_write(
    ctx, plan_from_sql(query, ctx.catalog, ctx.footers), WriteTarget("s3://bucket/n.parquet", WFMT_PARQUET, WCOMP_SNAPPY)
)
assert_equal(url.refusal.value().step, "bind")
assert_true(url.refusal.value().reason.startswith("STORAGE_URL_REFUSED: "))
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
assert_equal(text_writable(ArrowType.TIMESTAMP_US), True)
assert_equal(text_writable(ArrowType.TIME64_US), False)
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
budget (unless it spills, see Spill below; the reason begins with the code `MEMORY_BUDGET_EXCEEDED`, `pipeline_exec.segment_pool`), a sum outside its declared type and a pool not whole after a run (step
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

The tests are every `tests/test_*.mojo` file of the package. They run when the
package is built (the `sdk_exec` target), and each file's header says what it
covers. A new test is a new file there, with no list to extend. The one test
that needs DuckDB to read back the files `COPY` wrote,
`tests/test_copy_readback_duckdb.mojo`, runs with the `copy_readback` target.

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
