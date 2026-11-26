- **Writing files from a DataFrame.** `df.to_parquet(path, *, compression="snappy")`,
  `df.to_csv(path_or_buf, *, compression="infer", index=True)` and `df.to_json(path_or_buf, *,
  orient=None, lines=False, compression="infer")` run the plan through the engine's plan entry,
  write the frame's rows to a local Parquet, CSV (with a header line) or newline-delimited JSON
  file, all or nothing, and return `None`. `to_json` writes only when called with
  `orient="records", lines=True` (one object per line) and refuses every other form. `compression`
  is `"snappy"`, `"gzip"`, `"zstd"`, `"lz4"` or `None` for Parquet, and `"infer"` (from `.gz` and
  `.zst`), `"gzip"`, `"zstd"` or `None` for CSV and JSON; `bz2`, `zip`, `xz`, `tar` and `brotli`
  raise `UnsupportedOperation`. The engine refuses a URL destination, a missing directory and a
  column type the writer does not write by name (`STORAGE_URL_REFUSED`, `STORAGE_NOT_FOUND`,
  `COPY_TYPE_UNSUPPORTED`), and leaves an existing file as it was. `UnsupportedOperation` has the
  codes `COPY_TYPE_UNSUPPORTED` and `COPY_COMPRESSION_UNSUPPORTED`. They need a libkomira that
  writes a plan's answer to a file.
