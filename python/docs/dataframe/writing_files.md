# Writing files

```python
df.to_parquet("out/readings.parquet")                       # Snappy
df.to_csv("out/readings.csv.gz")                            # gzip, from the extension
df.to_json("out/readings.jsonl", orient="records", lines=True)
```

`df.to_parquet(path, *, compression="snappy")`, `df.to_csv(path_or_buf, *,
compression="infer", index=True)` and `df.to_json(path_or_buf, *, orient=None,
lines=False, compression="infer")` run the plan once and write all of the
frame's rows (in its order when it is sorted, see [row order](row_order.md)) to
a local file, all or nothing, and return `None` once the file is complete. An
existing file at the path is replaced. The format follows the verb, not the
extension: `to_csv("x.parquet")` writes CSV. A relative path is resolved against
the working directory at the call, and `~` is expanded.

- `to_parquet` takes `compression` `"snappy"`, `"gzip"`, `"zstd"`, `"lz4"` or
  `None`. `to_csv` writes a header line; `index` is accepted and has no effect,
  as a frame has no index. `to_json` writes only `orient="records",
  lines=True`, one object per line.
- `to_csv` and `to_json` take `compression` `"infer"` (gzip for a path ending
  `.gz`, zstd for `.zst`, otherwise none), `"gzip"`, `"zstd"` or `None`. `bz2`,
  `zip`, `xz` and `tar`, named or inferred, raise `UnsupportedOperation`, as do
  `"brotli"` for Parquet, a dict of options, any other `to_json` form and
  `to_csv(None)`. A keyword the verb does not have is a `TypeError`.
- The engine refuses a URL destination (`UnsupportedOperation`,
  `STORAGE_URL_REFUSED`, step `bind`), a missing directory (`StorageError`,
  `STORAGE_NOT_FOUND`) and a column type the writer does not write, a binary
  column among them (`UnsupportedOperation`, `COPY_TYPE_UNSUPPORTED`), and a
  refused write leaves the destination as it was.

Back to [the DataFrame overview](overview.md).
