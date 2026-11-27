- **Writing a Parquet file from a komira.pl frame.** `LazyFrame.sink_parquet(path, *,
  compression="zstd")` runs the plan through the engine's plan entry, as `DataFrame.to_parquet` does,
  writes the frame's rows to one local Parquet file, all or nothing, and returns `None`, as polars'
  `sink_parquet` does. `compression` is `"zstd"`, `"snappy"`, `"gzip"`, `"lz4"` or `"uncompressed"`;
  `"brotli"` and every other keyword of polars' `sink_parquet` (`row_group_size`, `statistics`,
  `maintain_order`, `storage_options`, `mkdir`, `lazy` and the rest) raise `UnsupportedOperation`
  naming it. A URL destination, a missing directory and a column type the writer does not write are
  refused as `to_parquet` refuses them.
