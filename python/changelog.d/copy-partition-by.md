- **A partitioned write with `COPY`.** `Session.sql("COPY (SELECT ...) TO 'dir' (FORMAT parquet,
  PARTITION_BY (year, month))")` writes a Hive-partitioned directory, the tree DuckDB writes:
  `dir/year=<y>/month=<m>/data_0.parquet` (`data_0.csv` with `FORMAT csv`), the partition columns
  kept out of the files, NULL as `__HIVE_DEFAULT_PARTITION__` and other values URL-escaped. It
  returns the rows written. A target that is a file or a directory holding anything raises
  `UnsupportedOperation` with the code `COPY_TARGET_EXISTS`; `OVERWRITE`, `APPEND` and DuckDB's other
  partitioned-write options are refused by name. The DataFrame write terminals write one file still.
