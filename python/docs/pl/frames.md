# komira.pl: lazy frames and readers

`komira.pl` is the polars-shaped DataFrame surface
([design](../../../docs/design/dataframe_surface.md)).

```python
import komira.pl as kpl

lf = kpl.scan_parquet("trips.parquet")
out = (
    lf.filter(kpl.col("fare") > 10)
    .with_columns((kpl.col("fare") / kpl.col("miles")).alias("per_mile"))
    .sort("per_mile", descending=True)
    .head(5)
    .collect()
)
out.to_polars()
```

A frame is a plan: no verb runs a query, and `collect()` encodes the plan and
runs it through `komira_plan_stream`. Nothing writes SQL text and nothing
imports polars.

- **Readers.** `scan_parquet`, `scan_ndjson` and `scan_csv`.
- **`LazyFrame`.** `select`, `with_columns`, `filter`, `sort`, `head`,
  `limit`, `slice`, `tail`, `top_k`, `bottom_k`, `drop`, `rename`,
  `drop_nulls`, `columns`, `schema`, `explain`, `collect` and
  [`sink_parquet`](#writing-a-parquet-file);
  [`group_by`, `join` and `unique`](group_by_join_unique.md) (newer than
  0.1.1623).
- **Module functions.** `col`, `lit`, `when`, `len`, `concat`.
- **Names it does not define** raise `AttributeError`, with the refusal
  tables' message for the names they hold.

The expressions are on [their own page](expressions.md). Not built yet: `sink_csv`,
`sink_ndjson`, `from_arrow`, `shift`, `join_asof`, regular expressions and `.dt`.

## Writing a Parquet file

```python
kpl.scan_csv("orders.csv").filter(kpl.col("amount") >= 75).sink_parquet("big_orders.parquet")
```

`lf.sink_parquet(path, *, compression="zstd")` runs the plan once and writes all
of the frame's rows to one local Parquet file, in its order when it is sorted,
all or nothing, and returns `None` once the file is complete, as polars'
`sink_parquet` does: no row reaches the caller. An existing file at the path is
replaced. A relative path is resolved against the working directory at the
call, and `~` is expanded.

- `compression` is `"zstd"` (polars' default), `"snappy"`, `"gzip"`, `"lz4"` or
  `"uncompressed"`; `"brotli"` raises `UnsupportedOperation`, and a value that
  is not a str is a `TypeError`.
- Every other keyword of polars' `sink_parquet` (`compression_level`,
  `statistics`, `row_group_size`, `data_page_size`, `maintain_order`,
  `storage_options`, `credential_provider`, `retries`, `sync_on_close`,
  `metadata`, `arrow_schema`, `mkdir`, `lazy`, `engine`, `optimizations`,
  `sinked_paths_callback`) raises `UnsupportedOperation` naming it, whatever its
  value. A keyword polars does not have is a `TypeError`, and a file object is
  refused: pass a path.
- The engine's refusals are those of the pandas-shaped `to_parquet`: a URL
  destination (`UnsupportedOperation`, `STORAGE_URL_REFUSED`), a missing
  directory (`StorageError`, `STORAGE_NOT_FOUND`) and a column type the writer
  does not write (`UnsupportedOperation`, `COPY_TYPE_UNSUPPORTED`); a refused
  write leaves the destination as it was.
