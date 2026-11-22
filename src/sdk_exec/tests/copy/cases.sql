-- The COPY cases DuckDB reads back. Each line is one COPY ... TO a Parquet
-- file; a case's name is its file name without `.parquet`. komira runs every
-- line through run_sql (the `:copy_komira` build action, with each read_csv
-- file name and the destination replaced by their paths), and DuckDB runs the
-- same lines in `:copy_readback` before readback.sql reads both files.
-- The inputs are the read_csv fixtures of tests/csv (their header says what
-- each holds).
COPY (SELECT id, qty, price, day, name, qty > 10 AS big, CAST('12.50' AS DECIMAL(10,2)) AS m FROM read_csv('typed.csv')) TO 'typed_default.parquet';
COPY (SELECT * FROM read_csv('typed.csv')) TO 'typed_zstd.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY (SELECT * FROM read_csv('nulls.csv')) TO 'nulls_gzip.parquet' (COMPRESSION gzip);
COPY (SELECT * FROM read_csv('nulls.csv')) TO 'nulls_lz4.parquet' (COMPRESSION lz4_raw);
COPY (SELECT * FROM read_csv('quoted.csv')) TO 'quoted_uncompressed.parquet' (COMPRESSION uncompressed);
COPY (SELECT name, count(*) AS n, min(price) AS low, max(day) AS last_day FROM read_csv('typed.csv') GROUP BY name) TO 'grouped_snappy.parquet' (COMPRESSION snappy);
COPY (SELECT * FROM read_csv('typed.csv') WHERE qty < 0) TO 'empty.parquet';
