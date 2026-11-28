- **zstd and lz4 Parquet on macOS.** Reading a Parquet file compressed with zstd or lz4, and
  `COPY ... TO 'f.parquet' (FORMAT parquet, COMPRESSION zstd)`, work in the macOS arm64 wheel; before,
  they ended the Python process with no message (or, since the missing-library refusal, raised
  `compression: cannot load libzstd.dylib`). The zstd and lz4 codecs are now linked into libkomira,
  so neither platform needs a libzstd or a liblz4 on the host. Snappy, gzip and brotli are unchanged.
