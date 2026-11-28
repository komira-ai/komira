- **komira.pl writes files; `to_csv` takes `sep` and `header`.** `lf.sink_csv(path)`,
  `lf.sink_parquet(path)` and `lf.sink_ndjson(path)` run the polars-shaped frame's plan once
  through the engine's plan entry and write its rows to a local CSV, Parquet or newline-delimited
  JSON file, in the frame's order when it is sorted, all or nothing, and return `None`; the file is
  the one `COPY (<the frame's query>) TO path` writes with the same format and codec.
  `compression` is `"uncompressed"` (the default), `"gzip"` or `"zstd"` for CSV and NDJSON, and
  `"zstd"` (the default), `"snappy"`, `"gzip"`, `"lz4"` or `"uncompressed"` for Parquet.
  `sink_csv` takes polars' CSV keywords at the value the writer writes (`include_header=True`,
  `separator=","`, `quote_char='"'`, `null_value=None`, `line_terminator="\n"`,
  `include_bom=False`), and every sink takes `maintain_order`; another value, `compression_level`,
  `mkdir=True`, `lazy=True` and a file object raise `UnsupportedOperation` naming the argument.
  `lf.write_csv`, `write_parquet` and `write_ndjson` raise `AttributeError` naming the sink. The
  pandas-shaped `df.to_csv` takes `sep=","` and `header=True`; another `sep`, `header=False` or a
  list of header names raises `UnsupportedOperation` naming the argument, where it was a
  `TypeError` before.
