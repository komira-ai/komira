- **A glob or a folder in `read_parquet` and `scan_parquet`.** `komira.read_parquet("sales/*.parquet")` and
  `komira.pl.scan_parquet("sales/*.parquet")` read every file the pattern matches as one frame, the files in
  sorted order of their paths, and a folder reads its `.parquet` files with its `key=value` folders as
  columns, as `Session.register_parquet` reads them. `scan_parquet` takes polars' `hive_partitioning`
  (None, the default, reads the keys of a folder and not of a glob). A pattern that matches nothing raises
  `BindError` naming it. One file reads as before. Needs libkomira ABI 1.11, which adds
  `komira_parquet_source`.
