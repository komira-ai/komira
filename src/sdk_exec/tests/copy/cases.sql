-- The COPY cases DuckDB reads back. Each line is one COPY ... TO a Parquet,
-- CSV or newline-delimited JSON file; a case's name is its file name up to
-- the first `.`. komira runs every line through run_sql (the `:copy_komira`
-- build action, with each read_csv file name and the destination replaced by
-- their paths), and DuckDB runs the same lines in `:copy_readback_oracle`
-- before readback.sql reads both files. The CSV and JSON cases sort their
-- rows, so the two files of an uncompressed case can be compared byte for
-- byte. The inputs are the read_csv fixtures of tests/csv (their header says
-- what each holds), and `times.parquet`, which the pinned DuckDB wrote
-- (tests/copy/times.sql says what it holds): its TIMESTAMP, TIMESTAMP_MS,
-- TIMESTAMP_NS, TIMESTAMPTZ and narrow and unsigned integer columns copied to
-- Parquet, CSV and JSON. The CSV and JSON cases leave out the rows of
-- 290309 BC, 294247 and year 10000: DuckDB cannot read those back from text
-- (its type detection overflows on them), and test_copy_text_encoding holds
-- their text. read_parquet file names are replaced by their paths
-- as read_csv ones are.
-- The hive_* cases write a Hive-partitioned directory (PARTITION_BY), named
-- like a file so a case's name is the part before the first `.`: two
-- partition levels of BIGINT, the BOOLEAN, DATE and DECIMAL directory texts,
-- NULL partitions, values DuckDB URL-escapes (a comma, quotes, a line break,
-- spaces, a multi-byte character), gzip CSV files, and an empty result,
-- which leaves an empty directory.
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
COPY (SELECT * FROM read_parquet('times.parquet') ORDER BY id) TO 'times_default.parquet';
COPY (SELECT * FROM read_parquet('times.parquet') WHERE id NOT IN (11, 12, 15) ORDER BY id) TO 'times_csv.csv';
COPY (SELECT * FROM read_parquet('times.parquet') WHERE id NOT IN (11, 12, 15) ORDER BY id) TO 'times_json.json';
COPY (SELECT id, qty, price, name, year(day) AS year, month(day) AS month FROM read_csv('typed.csv') ORDER BY id) TO 'hive_years.parquet' (FORMAT parquet, PARTITION_BY (year, month));
COPY (SELECT id, qty > 10 AS big, day, CAST(price AS DECIMAL(6, 3)) AS cost, name FROM read_csv('typed.csv') ORDER BY id) TO 'hive_types.parquet' (FORMAT parquet, PARTITION_BY (big, day, cost));
COPY (SELECT id, qty, name FROM read_csv('nulls.csv') ORDER BY id) TO 'hive_nulls.parquet' (FORMAT parquet, PARTITION_BY name);
COPY (SELECT id, amount, note FROM read_csv('quoted.csv') ORDER BY id) TO 'hive_escaped.parquet' (FORMAT parquet, PARTITION_BY (note));
COPY (SELECT name, qty, id FROM read_csv('typed.csv') ORDER BY id) TO 'hive_csv.csv' (FORMAT csv, COMPRESSION gzip, PARTITION_BY (name));
COPY (SELECT id, name FROM read_csv('typed.csv') WHERE qty < 0) TO 'hive_empty.parquet' (FORMAT parquet, PARTITION_BY (name));
