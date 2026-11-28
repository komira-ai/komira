# komira.pl: writing files

```python
import komira.pl as kpl

lf = kpl.scan_parquet("trips.parquet").filter(kpl.col("fare") > 10).sort("fare")
lf.sink_csv("out/fares.csv")
lf.sink_parquet("out/fares.parquet")                    # zstd
lf.sink_ndjson("out/fares.jsonl.gz", compression="gzip")
```

The sinks are newer than 0.1.1623. `lf.sink_csv(path)`, `lf.sink_parquet(path)` and
`lf.sink_ndjson(path)` run the frame's plan once through `komira_plan_stream`
with a write target, so the engine writes the file and no row comes back into
Python. Each writes all of the frame's rows (in its order when it is sorted) to
a local file, all or nothing, and returns `None` once the file is complete. An
existing file at the path is replaced. The file is the one
`COPY (<the frame's query>) TO path` writes with the same format and codec. A
relative path is resolved against the working directory at the call, and `~` is
expanded.

- `compression` is `"uncompressed"` (the default), `"gzip"` or `"zstd"` for CSV
  and NDJSON, and `"zstd"` (the default), `"snappy"`, `"gzip"`, `"lz4"` or
  `"uncompressed"` for Parquet. The format follows the verb and the codec the
  argument; the file's extension chooses neither.
- `sink_csv` writes a header line, `,` between cells, NULL as an empty cell and
  a string quoted only when it needs it. `include_header=True`,
  `separator=","`, `line_terminator="\n"`, `quote_char='"'`,
  `null_value=None` (or `""`) and `include_bom=False` are taken; any other
  value raises `UnsupportedOperation` naming the argument.
- Every sink takes `maintain_order` (either value; a sorted frame is written in
  its order), and refuses `compression_level`, `mkdir=True`, `lazy=True` and a
  file object in place of a path, each by name. A keyword of polars the sink
  does not take is Python's `TypeError`.
- `write_csv`, `write_parquet` and `write_ndjson` are polars' eager
  `DataFrame`'s, which `komira.pl` does not have: each raises `AttributeError`
  naming the sink to call.
- The engine refuses a URL destination (`UnsupportedOperation`,
  `STORAGE_URL_REFUSED`), a missing directory (`StorageError`,
  `STORAGE_NOT_FOUND`) and a column type the writer does not write
  (`UnsupportedOperation`, `COPY_TYPE_UNSUPPORTED`), and a refused write leaves
  the destination as it was.

The pandas-shaped frame writes with [`to_parquet`, `to_csv` and
`to_json`](../dataframe/writing_files.md). Back to [lazy frames](frames.md).
