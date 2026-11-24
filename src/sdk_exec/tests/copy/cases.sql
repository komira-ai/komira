-- The COPY cases DuckDB reads back. Each line is one COPY ... TO a Parquet,
-- CSV or newline-delimited JSON file; a case's name is its file name up to
-- the first `.`. komira runs every line through run_sql (the `:copy_komira`
-- build action, with each read_csv file name and the destination replaced by
-- their paths), and DuckDB runs the same lines in `:copy_readback_oracle`
-- before readback.sql reads both files. The CSV and JSON cases sort their
-- rows, so the two files of an uncompressed case can be compared byte for
-- byte. The inputs are the read_csv fixtures of tests/csv (their header says
-- what each holds).
COPY (SELECT id, qty, price, day, name, qty > 10 AS big FROM read_csv('typed.csv')) TO 'typed_default.parquet';
COPY (SELECT * FROM read_csv('typed.csv')) TO 'typed_zstd.parquet' (FORMAT parquet, COMPRESSION zstd);
COPY (SELECT * FROM read_csv('nulls.csv')) TO 'nulls_gzip.parquet' (COMPRESSION gzip);
COPY (SELECT * FROM read_csv('nulls.csv')) TO 'nulls_lz4.parquet' (COMPRESSION lz4_raw);
COPY (SELECT * FROM read_csv('quoted.csv')) TO 'quoted_uncompressed.parquet' (COMPRESSION uncompressed);
COPY (SELECT name, count(*) AS n, min(qty) AS low, max(day) AS last_day FROM read_csv('typed.csv') GROUP BY name) TO 'grouped_snappy.parquet' (COMPRESSION snappy);
COPY (SELECT * FROM read_csv('typed.csv') WHERE qty < 0) TO 'empty.parquet';
COPY (SELECT id, qty, price, day, name, qty > 10 AS big FROM read_csv('typed.csv') ORDER BY id) TO 'typed_csv.csv';
COPY (SELECT * FROM read_csv('quoted.csv') ORDER BY id) TO 'quoted_csv.csv' (FORMAT csv, HEADER true);
COPY (SELECT * FROM read_csv('nulls.csv') ORDER BY id) TO 'nulls_csv.csv';
COPY (SELECT id, CASE WHEN id % 2 = 0 THEN '' ELSE name END AS name FROM read_csv('nulls.csv') ORDER BY id) TO 'empty_string_csv.csv';
COPY (SELECT * FROM read_csv('typed.csv') WHERE qty < 0) TO 'empty_csv.csv';
COPY (SELECT name, count(*) AS n, sum(qty) AS total, min(day) AS first_day, max(id) AS last_id FROM read_csv('typed.csv') GROUP BY name ORDER BY name) TO 'grouped_csv.csv.gz';
COPY (SELECT * FROM read_csv('typed.csv') ORDER BY id) TO 'typed_zstd_csv.csv.zst';
COPY (SELECT id, qty, price, day, name, qty > 10 AS big FROM read_csv('typed.csv') ORDER BY id) TO 'typed_json.json';
COPY (SELECT * FROM read_csv('quoted.csv') ORDER BY id) TO 'quoted_json.json' (FORMAT json);
COPY (SELECT * FROM read_csv('nulls.csv') ORDER BY id) TO 'nulls_json.json';
COPY (SELECT name, count(*) AS n, sum(qty) AS total, min(day) AS first_day, max(id) AS last_id FROM read_csv('typed.csv') GROUP BY name ORDER BY name) TO 'grouped_json.json.gz';
COPY (SELECT * FROM read_csv('typed.csv') ORDER BY id) TO 'typed_zstd_json.json.zst';
